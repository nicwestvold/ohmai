import Foundation
import OhmaiCore
import os

/// Watches a directory of per-process `<pid>.json` status files and reports activity.
/// Used for Claude Code (`~/.claude/sessions/`) and pi (written by ohmai's extension).
///
/// Wakes for: file changes (FSEvents, coalesced), a watched process exiting (kqueue), and a
/// renewal scan every `renewInterval`, but only while some session is busy, waiting or quiet.
/// With no active sessions it holds no timers.
@MainActor
public final class StatusDirectoryAdapter {
    public var onEvents: (([ActivityEvent]) -> Void)?
    /// How long a busy session may go without writing anything. Set from Prefs.
    public var quietLimit: TimeInterval = Prefs.default.busyQuietLimit

    private let name: String
    private let directory: URL
    private let parse: @Sendable (Data) -> StatusRecord?
    private let maxFileSize: Int
    private let scanner: StatusRecordScanner
    private let renewInterval: Duration
    private let log: Logger
    private var live: [SessionKey: Activity] = [:]
    private var loggedUnknown: Set<String> = []
    private var loggedQuiet: Set<SessionKey> = []
    private var directoryWatcher: DirectoryWatcher?
    private var parentWatcher: DirectoryWatcher?
    private var exitWatcher: ProcessExitWatcher?
    private var renewTimer: Task<Void, Never>?

    /// - `name`: for logs, e.g. "claude".
    /// - `parse`: turns one file's bytes into a record; nil skips the file.
    public init(
        name: String,
        directory: URL,
        maxFileSize: Int = 64 * 1024,
        parse: @escaping @Sendable (Data) -> StatusRecord?,
        inspector: any ProcessInspector = DarwinProcessInspector(),
        transcripts: any TranscriptActivity,
        renewInterval: Duration = .seconds(30)
    ) {
        self.name = name
        self.directory = directory
        self.maxFileSize = maxFileSize
        self.parse = parse
        self.scanner = StatusRecordScanner(inspector: inspector, transcripts: transcripts)
        self.renewInterval = renewInterval
        self.log = Logger(subsystem: "com.westvold.ohmai", category: "\(name)-adapter")
    }

    public func start() {
        exitWatcher = ProcessExitWatcher { [weak self] _ in self?.rescan() }
        startWatching()
        rescan()
    }

    /// Re-reads the directory now. Also called on system wake.
    public func rescan() {
        let records = readSessionFiles().compactMap(parse)
        let result = scanner.scan(records: records, previous: live, now: .now, quietLimit: quietLimit)
        live = result.live

        for key in result.quiet.subtracting(loggedQuiet) {
            log.notice("\(self.name, privacy: .public) session pid \(key.pid, privacy: .public) is busy but silent past the quiet limit; releasing")
        }
        loggedQuiet = result.quiet

        for raw in result.unknownStatuses.subtracting(loggedUnknown) {
            log.warning("unknown \(self.name, privacy: .public) session status \(raw, privacy: .public); treating as unknown")
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
            // Only `<pid>.json`. Skips anything else (Claude's `.key` files are never read).
            guard url.pathExtension == "json", Int32(url.deletingPathExtension().lastPathComponent) != nil,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maxFileSize
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
