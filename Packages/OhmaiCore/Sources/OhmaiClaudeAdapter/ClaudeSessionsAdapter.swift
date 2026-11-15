import Foundation
import OhmaiAdapterSupport
import OhmaiCore
import os

private let log = Logger(subsystem: "com.westvold.ohmai", category: "claude-adapter")

/// Watches `~/.claude/sessions/` and reports Claude Code activity.
///
/// Wakes for: file changes (FSEvents, coalesced), a watched process exiting (kqueue), and a
/// renewal scan every `renewInterval`, but only while some session is busy or waiting.
/// With no active Claude sessions it holds no timers.
@MainActor
public final class ClaudeSessionsAdapter {
    public var onEvents: (([ActivityEvent]) -> Void)?
    /// How long a busy session may go without writing anything. Set from Prefs.
    public var quietLimit: TimeInterval = Prefs.default.busyQuietLimit

    private let directory: URL
    private let scanner: ClaudeSessionScanner
    private let renewInterval: Duration
    private var live: [SessionKey: Activity] = [:]
    private var loggedUnknown: Set<String> = []
    private var loggedQuiet: Set<SessionKey> = []
    private var directoryWatcher: DirectoryWatcher?
    private var parentWatcher: DirectoryWatcher?
    private var exitWatcher: ProcessExitWatcher?
    private var renewTimer: Task<Void, Never>?

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions", directoryHint: .isDirectory)
    }

    public init(
        directory: URL = ClaudeSessionsAdapter.defaultDirectory,
        inspector: any ProcessInspector = DarwinProcessInspector(),
        transcripts: any TranscriptActivity = ClaudeTranscriptActivity(),
        renewInterval: Duration = .seconds(30)
    ) {
        self.directory = directory
        self.scanner = ClaudeSessionScanner(inspector: inspector, transcripts: transcripts)
        self.renewInterval = renewInterval
    }

    public func start() {
        exitWatcher = ProcessExitWatcher { [weak self] _ in self?.rescan() }
        startWatching()
        rescan()
    }

    /// Re-reads the directory now. Also called on system wake.
    public func rescan() {
        let files = readSessionFiles()
        let result = scanner.scan(files: files, previous: live, now: .now, quietLimit: quietLimit)
        live = result.live

        for key in result.quiet.subtracting(loggedQuiet) {
            log.notice("Claude session pid \(key.pid, privacy: .public) is busy but silent past the quiet limit; releasing")
        }
        loggedQuiet = result.quiet

        for raw in result.unknownStatuses.subtracting(loggedUnknown) {
            log.warning("unknown Claude session status \(raw, privacy: .public); treating as unknown")
            loggedUnknown.insert(raw)
        }
        exitWatcher?.watch(Set(live.keys.map(\.pid)).union(loggedQuiet.map(\.pid)))
        updateRenewTimer()
        if !result.events.isEmpty { onEvents?(result.events) }
    }

    private func readSessionFiles() -> [Data] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            // Only `<pid>.json`. Skips the `.key` files next to them, which ohmai never reads.
            guard url.pathExtension == "json", Int32(url.deletingPathExtension().lastPathComponent) != nil,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= ClaudeSessionFile.maxSize
            else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    private func startWatching() {
        directoryWatcher = DirectoryWatcher(path: directory.path, latency: 1.0) { [weak self] in self?.rescan() }
        if directoryWatcher == nil {
            // Claude hasn't created the directory yet. Watch the parent until it does.
            let parent = directory.deletingLastPathComponent()
            parentWatcher = DirectoryWatcher(path: parent.path, latency: 5.0) { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: self.directory.path) else { return }
                self.parentWatcher = nil
                self.startWatching()
                self.rescan()
            }
        } else {
            parentWatcher = nil
        }
    }

    private func updateRenewTimer() {
        // Quiet sessions keep the scan going too, so they come back once they write again.
        let active = live.values.contains { $0 == .busy || $0 == .waiting } || !loggedQuiet.isEmpty
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
