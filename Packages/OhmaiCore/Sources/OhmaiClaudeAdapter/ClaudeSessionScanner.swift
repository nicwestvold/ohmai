import Foundation
import OhmaiAdapterSupport
import OhmaiCore

/// When a session last showed signs of life beyond its status flag. Faked in tests.
public protocol TranscriptActivity: Sendable {
    /// The newest write to the session's transcript (or its subagents'), or nil if none found.
    func lastWrite(sessionId: String) -> Date?
}

/// Turns a snapshot of the sessions directory into `ActivityEvent`s. Pure apart from the
/// injected `ProcessInspector` and `TranscriptActivity`, so it's tested against fixtures.
///
/// **Quiet limit:** a `busy` status alone isn't trusted forever. If neither the transcript
/// nor the status has changed for `quietLimit`, the session is treated as stuck and released.
/// It comes back as soon as anything is written again.
///
/// Each scan re-emits `busy` / `waiting` for every live session: Claude only rewrites the
/// file when the status changes, so the scan itself is what renews the lease.
public struct ClaudeSessionScanner: Sendable {
    public struct Result: Sendable, Equatable {
        public var events: [ActivityEvent] = []
        /// Live sessions after this scan, with their pids, for exit watching.
        public var live: [SessionKey: Activity] = [:]
        /// Status strings this version doesn't understand, for logging once.
        public var unknownStatuses: Set<String> = []
        /// Busy sessions released for being quiet too long, for logging.
        public var quiet: Set<SessionKey> = []
    }

    private let inspector: any ProcessInspector
    private let transcripts: any TranscriptActivity

    public init(inspector: any ProcessInspector, transcripts: any TranscriptActivity) {
        self.inspector = inspector
        self.transcripts = transcripts
    }

    /// - `files`: contents of each `<pid>.json` in the directory.
    /// - `previous`: `live` from the last scan, so vanished sessions get a `gone`.
    /// - `quietLimit`: how long a busy session may go without any write.
    public func scan(files: [Data], previous: [SessionKey: Activity], now: Date, quietLimit: TimeInterval) -> Result {
        var result = Result()
        var projects: [SessionKey: String] = [:]

        for data in files {
            guard let file = ClaudeSessionFile.parse(data) else { continue }
            let key = SessionKey(agent: .claude, sessionId: file.sessionId, pid: file.pid)

            // Files outlive their processes; a reused pid is a different process.
            guard let kernelStart = inspector.startTime(of: file.pid),
                  ProcessIdentity.matches(
                    kernelStart: kernelStart,
                    sessionStartedAt: file.startedAt,
                    recordedProcessStart: file.processStart)
            else { continue }

            let activity: Activity
            switch file.status {
            case .busy:
                let lastSign = [transcripts.lastWrite(sessionId: file.sessionId), file.statusUpdatedAt]
                    .compactMap { $0 }.max()
                // No evidence at all (no transcript, no timestamp): fall back to lease expiry.
                if let lastSign, now.timeIntervalSince(lastSign) > quietLimit {
                    result.quiet.insert(key)
                    continue
                }
                activity = .busy
            case .waiting: activity = .waiting
            case .idle: activity = .idle
            case .unknown(let raw):
                // Unknown is never busy. A session we were tracking drops out of `live` and
                // gets `gone` below: when in doubt, release.
                result.unknownStatuses.insert(raw ?? "<missing>")
                continue
            }
            // If two files claim one key, keep the busiest reading.
            if let existing = result.live[key], rank(existing) >= rank(activity) { continue }
            result.live[key] = activity
            projects[key] = file.cwd
        }

        for (key, activity) in result.live.sorted(by: { $0.key.sessionId < $1.key.sessionId }) {
            result.events.append(ActivityEvent(session: key, activity: activity, at: now, project: projects[key]))
        }
        for key in previous.keys.sorted(by: { $0.sessionId < $1.sessionId }) where result.live[key] == nil {
            result.events.append(ActivityEvent(session: key, activity: .gone, at: now))
        }
        return result
    }

    private func rank(_ a: Activity) -> Int {
        switch a {
        case .busy: 3
        case .waiting: 2
        case .idle: 1
        case .gone: 0
        }
    }
}
