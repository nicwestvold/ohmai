import Foundation

/// Finds when a Claude session's transcript was last written, from file modification times
/// only. Never opens a transcript: they contain the user's code and prompts.
///
/// Layout: `~/.claude/projects/<folder>/<sessionId>.jsonl`, with subagents in
/// `<folder>/<sessionId>/subagents/*.jsonl`.
public final class ClaudeTranscriptActivity: TranscriptActivity, @unchecked Sendable {
    private let projects: URL
    /// Remembered transcript location per session, so a scan doesn't list every project.
    private let lock = NSLock()
    private var found: [String: URL] = [:]

    public static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    public init(projects: URL = ClaudeTranscriptActivity.defaultProjectsDirectory) {
        self.projects = projects
    }

    public func lastWrite(sessionId: String) -> Date? {
        // Session ids are UUIDs; refuse anything that could walk the filesystem.
        guard !sessionId.isEmpty, !sessionId.contains("/"), !sessionId.contains("..") else { return nil }
        guard let transcript = locate(sessionId) else { return nil }
        let fm = FileManager.default
        var newest = modified(transcript)
        let subagents = transcript.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
        if let entries = try? fm.contentsOfDirectory(
            at: subagents, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for entry in entries where entry.pathExtension == "jsonl" {
                if let m = modified(entry), m > (newest ?? .distantPast) { newest = m }
            }
        }
        return newest
    }

    private func locate(_ sessionId: String) -> URL? {
        let fm = FileManager.default
        lock.lock(); defer { lock.unlock() }
        if let cached = found[sessionId], fm.fileExists(atPath: cached.path) { return cached }
        found[sessionId] = nil
        let folders = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            let candidate = folder.appending(path: "\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                found[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
