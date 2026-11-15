import Foundation
import OhmaiCore

/// One agent process's self-reported state, read from a per-process status file
/// (Claude's `~/.claude/sessions/<pid>.json`, ohmai's pi extension file).
public struct StatusRecord: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case busy
        case idle
        case waiting
        /// A value this version of ohmai doesn't know. Never treated as busy.
        case unknown(String?)
    }

    public let agent: Agent
    public let pid: Int32
    public let sessionId: String
    public let cwd: String?
    public let status: Status
    /// When the session began.
    public let startedAt: Date?
    /// The process start time the agent recorded, if any.
    public let processStart: Date?
    /// When `status` last changed.
    public let statusUpdatedAt: Date?
    /// The session's transcript, when the record names it.
    public let transcriptPath: String?

    public init(
        agent: Agent, pid: Int32, sessionId: String, cwd: String?, status: Status,
        startedAt: Date? = nil, processStart: Date? = nil, statusUpdatedAt: Date? = nil, transcriptPath: String? = nil
    ) {
        self.agent = agent
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.processStart = processStart
        self.statusUpdatedAt = statusUpdatedAt
        self.transcriptPath = transcriptPath
    }

    public var key: SessionKey { SessionKey(agent: agent, sessionId: sessionId, pid: pid) }
}

/// When a session last wrote anything beyond its status flag. Faked in tests.
public protocol TranscriptActivity: Sendable {
    /// The newest write to the session's transcript(s), or nil if none found.
    func lastWrite(for record: StatusRecord) -> Date?
}

/// Turns a snapshot of status records into `ActivityEvent`s. Pure apart from the injected
/// `ProcessInspector` and `TranscriptActivity`, so it's tested against fixtures.
///
/// - **Liveness:** files outlive their processes, and pids get reused; both are dropped.
/// - **Renewal:** each scan re-emits `busy` / `waiting` for every live session, because
///   agents only rewrite their status when it changes.
/// - **Quiet limit:** a `busy` status alone isn't trusted forever. If neither the transcript
///   nor the status has changed for `quietLimit`, the session is released until it writes again.
public struct StatusRecordScanner: Sendable {
    public struct Result: Sendable, Equatable {
        public var events: [ActivityEvent] = []
        /// Live sessions after this scan, for exit watching and the next scan's `previous`.
        public var live: [SessionKey: Activity] = [:]
        /// Status strings this version doesn't understand, for logging once.
        public var unknownStatuses: Set<String> = []
        /// Busy sessions released for being quiet too long.
        public var quiet: Set<SessionKey> = []
    }

    private let inspector: any ProcessInspector
    private let transcripts: any TranscriptActivity

    public init(inspector: any ProcessInspector, transcripts: any TranscriptActivity) {
        self.inspector = inspector
        self.transcripts = transcripts
    }

    public func scan(
        records: [StatusRecord], previous: [SessionKey: Activity], now: Date, quietLimit: TimeInterval
    ) -> Result {
        var result = Result()
        var projects: [SessionKey: String] = [:]

        for record in records {
            let key = record.key
            guard let kernelStart = inspector.startTime(of: record.pid),
                  ProcessIdentity.matches(
                    kernelStart: kernelStart,
                    sessionStartedAt: record.startedAt,
                    recordedProcessStart: record.processStart)
            else { continue }

            let activity: Activity
            switch record.status {
            case .busy:
                let lastSign = [transcripts.lastWrite(for: record), record.statusUpdatedAt].compactMap { $0 }.max()
                // No evidence at all: fall back to lease expiry.
                if let lastSign, now.timeIntervalSince(lastSign) > quietLimit {
                    result.quiet.insert(key)
                    continue
                }
                activity = .busy
            case .waiting: activity = .waiting
            case .idle: activity = .idle
            case .unknown(let raw):
                // Never busy. A tracked session drops out of `live` and gets `gone` below.
                result.unknownStatuses.insert(raw ?? "<missing>")
                continue
            }
            // If two records claim one key, keep the busiest reading.
            if let existing = result.live[key], Self.rank(existing) >= Self.rank(activity) { continue }
            result.live[key] = activity
            projects[key] = record.cwd
        }

        for (key, activity) in result.live.sorted(by: { $0.key.sessionId < $1.key.sessionId }) {
            result.events.append(ActivityEvent(session: key, activity: activity, at: now, project: projects[key]))
        }
        for key in previous.keys.sorted(by: { $0.sessionId < $1.sessionId }) where result.live[key] == nil {
            result.events.append(ActivityEvent(session: key, activity: .gone, at: now))
        }
        return result
    }

    private static func rank(_ a: Activity) -> Int {
        switch a {
        case .busy: 3
        case .waiting: 2
        case .idle: 1
        case .gone: 0
        }
    }
}
