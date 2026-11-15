import Foundation
import OhmaiAdapterSupport
import OhmaiCore
import os

private let log = Logger(subsystem: "com.westvold.ohmai", category: "codex-adapter")

/// Watches `~/.codex/sessions/**/rollout-*.jsonl` and reports Codex activity.
///
/// - Reads each rollout incrementally from a stored byte offset, in chunks; never whole.
/// - Wakes on FSEvents (coalesced), on a watched `codex` process exiting, and on a renewal
///   scan every `renewInterval` while some turn is open. Idle, it holds no timers.
@MainActor
public final class CodexRolloutAdapter {
    public var onEvents: (([ActivityEvent]) -> Void)?
    /// How long an open turn may go without any write. Set from Prefs.
    public var quietLimit: TimeInterval = Prefs.default.busyQuietLimit

    private struct FileState {
        var offset: UInt64 = 0
        var tracked = CodexActivityRule.Tracked(rollout: CodexRollout(), modified: nil)
    }

    private let root: URL
    private let probe: CodexProcessProbe
    private let renewInterval: Duration
    private var files: [String: FileState] = [:]
    private var live = Set<SessionKey>()
    private var loggedLayout = false
    private var watcher: DirectoryWatcher?
    private var parentWatcher: DirectoryWatcher?
    private var exitWatcher: ProcessExitWatcher?
    private var renewTimer: Task<Void, Never>?

    static let chunkSize = 1 << 20

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions", directoryHint: .isDirectory)
    }

    public init(
        root: URL = CodexRolloutAdapter.defaultRoot,
        probe: CodexProcessProbe = CodexProcessProbe(),
        renewInterval: Duration = .seconds(30)
    ) {
        self.root = root
        self.probe = probe
        self.renewInterval = renewInterval
    }

    public func start() {
        exitWatcher = ProcessExitWatcher { [weak self] _ in self?.evaluate() }
        startWatching()
        // Only rollouts touched within the quiet limit can hold a busy turn.
        for path in recentRollouts() { read(path) }
        evaluate()
    }

    /// Re-checks liveness and the quiet limit now. Also called on system wake.
    public func rescan() {
        for path in files.keys { read(path) }
        evaluate()
    }

    // MARK: - Reading

    private func recentRollouts() -> [String] {
        let cutoff = Date.now.addingTimeInterval(-quietLimit)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var paths: [String] = []
        for case let url as URL in walker where Self.isRollout(url.path) {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified >= cutoff { paths.append(url.path) }
        }
        return paths
    }

    static func isRollout(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    private func read(_ path: String) {
        var state = files[path] ?? FileState()
        let url = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            files[path] = nil  // deleted
            return
        }
        state.tracked.modified = attributes[.modificationDate] as? Date
        if size < state.offset {
            state = FileState()  // truncated or replaced: start over
            state.tracked.modified = attributes[.modificationDate] as? Date
        }
        if size > state.offset, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: state.offset)
            while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                state.tracked.rollout.feed(chunk)
                state.offset += UInt64(chunk.count)
            }
        }
        if state.tracked.rollout.unrecognizedLines > 0, !loggedLayout {
            log.warning("Codex rollout lines with an unrecognized layout; the format may have changed")
            loggedLayout = true
        }
        files[path] = state
    }

    // MARK: - Deciding

    private func evaluate() {
        let now = Date.now
        let open = files.filter { $0.value.tracked.rollout.hasOpenTurn }
        let liveness = open.isEmpty ? [:] : probe.liveness(of: Array(open.keys))
        let result = CodexActivityRule.evaluate(
            tracked: files.mapValues(\.tracked), liveness: liveness, previous: live, now: now, quietLimit: quietLimit)
        live = result.live

        // Forget rollouts that can't matter any more, so memory stays flat.
        let cutoff = now.addingTimeInterval(-quietLimit)
        files = files.filter { _, state in
            state.tracked.rollout.hasOpenTurn || (state.tracked.modified ?? .distantPast) >= cutoff
        }

        let pids = liveness.values.compactMap { if case .alive(let pid) = $0 { pid } else { nil } }
        exitWatcher?.watch(Set(pids))
        updateRenewTimer(active: !open.isEmpty)
        if !result.events.isEmpty { onEvents?(result.events) }
    }

    // MARK: - Watching

    private func startWatching() {
        watcher = DirectoryWatcher(path: root.path, latency: 2.0) { [weak self] paths in
            guard let self else { return }
            let changed = paths.filter(Self.isRollout)
            guard !changed.isEmpty else { return }
            for path in Set(changed) { self.read(path) }
            self.evaluate()
        }
        if watcher == nil {
            let parent = root.deletingLastPathComponent()
            parentWatcher = DirectoryWatcher(path: parent.path, latency: 5.0) { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: self.root.path) else { return }
                self.parentWatcher = nil
                self.startWatching()
            }
        } else {
            parentWatcher = nil
        }
    }

    private func updateRenewTimer(active: Bool) {
        guard active else {
            renewTimer?.cancel()
            renewTimer = nil
            return
        }
        guard renewTimer == nil else { return }
        let interval = renewInterval
        renewTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.rescan()
            }
        }
    }
}
