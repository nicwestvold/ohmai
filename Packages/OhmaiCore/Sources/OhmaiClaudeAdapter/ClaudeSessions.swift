import Foundation
import OhmaiAdapterSupport
import OhmaiCore

/// Claude Code activity: `~/.claude/sessions/<pid>.json` (undocumented) through the shared
/// status-directory adapter, with transcript modification times as proof of life.
public enum ClaudeSessions {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions", directoryHint: .isDirectory)
    }

    @MainActor
    public static func makeAdapter(directory: URL = defaultDirectory) -> StatusDirectoryAdapter {
        StatusDirectoryAdapter(
            name: "claude",
            directory: directory,
            maxFileSize: ClaudeSessionFile.maxSize,
            parse: { ClaudeSessionFile.parse($0)?.record },
            transcripts: ClaudeTranscriptActivity())
    }

    /// Parses and scans in one step. Used by tests against fixtures.
    static func scan(
        files: [Data], scanner: StatusRecordScanner, previous: [SessionKey: Activity], now: Date, quietLimit: TimeInterval
    ) -> StatusRecordScanner.Result {
        scanner.scan(
            records: files.compactMap { ClaudeSessionFile.parse($0)?.record },
            previous: previous, now: now, quietLimit: quietLimit)
    }
}


