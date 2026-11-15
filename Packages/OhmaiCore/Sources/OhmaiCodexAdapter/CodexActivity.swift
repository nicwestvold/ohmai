import Foundation
import OhmaiAdapterSupport
import OhmaiCore

/// Whether the Codex process behind a rollout is still running.
public enum CodexLiveness: Sendable, Equatable {
    /// A `codex` process has the rollout open.
    case alive(pid: Int32)
    /// No `codex` process is running at all, so nothing can be working on it.
    case dead
    /// Some `codex` is running, but none is known to hold this file. The quiet limit decides.
    case unknown
}

/// Rollouts don't record a pid, so look for a `codex` process with the file open.
public struct CodexProcessProbe: Sendable {
    private let files: any OpenFileLookup

    public init(files: any OpenFileLookup = LibprocOpenFiles()) {
        self.files = files
    }

    /// One pass over the running `codex` processes, answering for several rollouts at once.
    public func liveness(of paths: [String]) -> [String: CodexLiveness] {
        let pids = files.pids(named: "codex")
        guard !pids.isEmpty else { return Dictionary(uniqueKeysWithValues: paths.map { ($0, .dead) }) }
        let open = pids.map { ($0, files.openPaths(of: $0)) }
        var result: [String: CodexLiveness] = [:]
        for path in paths {
            let resolved = LibprocOpenFiles.canonicalPath(path)
            if let (pid, _) = open.first(where: { $0.1.contains(path) || $0.1.contains(resolved) }) {
                result[path] = .alive(pid: pid)
            } else {
                result[path] = .unknown
            }
        }
        return result
    }
}

/// Decides which tracked rollouts are busy right now. Pure, so it's unit-tested.
///
/// A rollout is busy when it has an open turn, it has been written within `quietLimit`,
/// and its process isn't known to be gone. Codex doesn't persist approval prompts, so a
/// session waiting on approval looks busy here; the quiet limit bounds it.
public enum CodexActivityRule {
    public struct Tracked: Sendable, Equatable {
        public var rollout: CodexRollout
        /// The file's modification time.
        public var modified: Date?

        public init(rollout: CodexRollout, modified: Date?) {
            self.rollout = rollout
            self.modified = modified
        }
    }

    /// Codex sessions have no stable pid in their key; liveness is tracked per file.
    static func key(for path: String, rollout: CodexRollout) -> SessionKey {
        SessionKey(agent: .codex, sessionId: rollout.sessionId ?? sessionId(fromFilename: path) ?? path, pid: 0)
    }

    /// `rollout-<ts>-<uuid>.jsonl` → the uuid.
    static func sessionId(fromFilename path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    public static func evaluate(
        tracked: [String: Tracked],
        liveness: [String: CodexLiveness],
        previous: Set<SessionKey>,
        now: Date,
        quietLimit: TimeInterval
    ) -> (events: [ActivityEvent], live: Set<SessionKey>) {
        var events: [ActivityEvent] = []
        var live = Set<SessionKey>()

        for (path, entry) in tracked.sorted(by: { $0.key < $1.key }) where entry.rollout.hasOpenTurn {
            let lastSign = [entry.modified, entry.rollout.lastEventAt].compactMap { $0 }.max()
            guard let lastSign, now.timeIntervalSince(lastSign) <= quietLimit else { continue }
            if liveness[path] == .dead { continue }
            let key = key(for: path, rollout: entry.rollout)
            guard live.insert(key).inserted else { continue }
            events.append(ActivityEvent(session: key, activity: .busy, at: now, project: entry.rollout.cwd))
        }
        for key in previous.sorted(by: { $0.sessionId < $1.sessionId }) where !live.contains(key) {
            events.append(ActivityEvent(session: key, activity: .gone, at: now))
        }
        return (events, live)
    }
}
