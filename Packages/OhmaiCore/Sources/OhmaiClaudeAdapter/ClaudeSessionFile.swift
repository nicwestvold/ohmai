import Foundation

/// One `~/.claude/sessions/<pid>.json`. **Undocumented format**: parse defensively.
///
/// Decodes only what ohmai needs. Fields like `name` (which Claude derives from the
/// conversation) are deliberately never read.
public struct ClaudeSessionFile: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case busy
        case idle
        case waiting
        /// A value this version of ohmai doesn't know. Never treated as busy.
        case unknown(String?)
    }

    public let pid: Int32
    public let sessionId: String
    public let cwd: String?
    public let status: Status
    /// When the session began (`startedAt`, epoch ms).
    public let startedAt: Date?
    /// The process start time Claude recorded (`procStart`, ctime-style, UTC).
    public let processStart: Date?

    /// Largest file we'll read. Real ones are well under 1 KB.
    public static let maxSize = 64 * 1024

    /// Returns nil for anything that isn't a usable session record.
    public static func parse(_ data: Data) -> ClaudeSessionFile? {
        guard data.count <= maxSize,
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let pidNumber = json["pid"] as? NSNumber,
              let pid = Int32(exactly: pidNumber.int64Value), pid > 0,
              let sessionId = json["sessionId"] as? String, !sessionId.isEmpty
        else { return nil }

        let rawStatus = json["status"] as? String
        let status: Status = switch rawStatus {
        case "busy": .busy
        case "idle": .idle
        case "waiting": .waiting
        default: .unknown(rawStatus)
        }

        return ClaudeSessionFile(
            pid: pid,
            sessionId: sessionId,
            cwd: json["cwd"] as? String,
            status: status,
            startedAt: (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
            processStart: (json["procStart"] as? String).flatMap(parseProcStart)
        )
    }

    /// `procStart` looks like `ps -o lstart` in UTC: "Sat Nov 14 20:56:27 2026"
    /// (single-digit days may be space-padded).
    static func parseProcStart(_ raw: String) -> Date? {
        let collapsed = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return procStartFormatter.date(from: collapsed)
    }

    private static let procStartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}
