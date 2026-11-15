import Foundation
import OhmaiAdapterSupport
import OhmaiCore

/// pi activity, from status files written by ohmai's own pi extension (`Resources/ohmai.ts`)
/// to `~/Library/Application Support/ohmai/pi/<pid>.json`.
public enum PiSessions {
    public static var statusDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ohmai/pi", directoryHint: .isDirectory)
    }

    /// Creates the status directory (ohmai's own), so it can be watched before pi first runs.
    @MainActor
    public static func makeAdapter(directory: URL = statusDirectory) -> StatusDirectoryAdapter {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StatusDirectoryAdapter(
            name: "pi",
            directory: directory,
            parse: PiStatusFile.parse,
            transcripts: SessionFileActivity())
    }
}

/// One status file from the extension. We own this format; `v` versions it.
public enum PiStatusFile {
    public static func parse(_ data: Data) -> StatusRecord? {
        guard data.count <= 64 * 1024,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pidNumber = json["pid"] as? NSNumber,
              let pid = Int32(exactly: pidNumber.int64Value), pid > 0
        else { return nil }

        let raw = json["status"] as? String
        let status: StatusRecord.Status = switch raw {
        case "busy": .busy
        case "idle": .idle
        case "waiting": .waiting
        default: .unknown(raw)
        }
        // A session that hasn't saved yet has no id; the pid still identifies the process.
        let sessionId = (json["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "pid-\(pid)"

        return StatusRecord(
            agent: .pi,
            pid: pid,
            sessionId: sessionId,
            cwd: json["cwd"] as? String,
            status: status,
            startedAt: millis(json["startedAt"]),
            processStart: millis(json["processStart"]),
            statusUpdatedAt: millis(json["statusUpdatedAt"]),
            transcriptPath: json["sessionFile"] as? String
        )
    }

    private static func millis(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}

/// Proof of life from the session file pi names, by modification time only.
struct SessionFileActivity: TranscriptActivity {
    func lastWrite(for record: StatusRecord) -> Date? {
        guard let path = record.transcriptPath, path.hasSuffix(".jsonl") else { return nil }
        return try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
