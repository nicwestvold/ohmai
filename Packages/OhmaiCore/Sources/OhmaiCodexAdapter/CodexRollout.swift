import Foundation

/// What ohmai knows about one Codex rollout file, built incrementally from appended bytes.
///
/// **Privacy:** rollout lines carry the user's prompts, code and Codex's replies. Lines are
/// classified from their leading bytes only: `{"timestamp":"…","ordinal":N,"type":"…",
/// "payload":{"type":"…"`. Only the `session_meta` line is decoded, for the session id and
/// cwd. Every other line, message content included, is skipped undecoded.
///
/// **Undocumented format:** if Codex changes this layout, lines stop matching, no turns are
/// seen, and the Mac is allowed to sleep. The fixture tests catch it first.
public struct CodexRollout: Sendable, Equatable {
    public private(set) var sessionId: String?
    public private(set) var cwd: String?
    /// Turns started but not yet completed or aborted. Never negative.
    public private(set) var openTurns = 0
    /// When the outermost open turn started (its `task_started` line's timestamp).
    public private(set) var turnStartedAt: Date?
    /// Timestamp of the newest line seen.
    public private(set) var lastEventAt: Date?
    /// Lines whose layout didn't match; logged by the adapter.
    public private(set) var unrecognizedLines = 0

    /// Bytes after the last newline, waiting for the rest of their line.
    private var partial = Data()

    /// Lines longer than this are skipped (still counted as activity). `session_meta` is
    /// the only line we decode, and real ones are tens of KB.
    static let maxDecodedLine = 4 * 1024 * 1024

    public init() {}

    public var hasOpenTurn: Bool { openTurns > 0 }

    /// Feeds newly appended bytes. Incomplete trailing lines are held until the next feed.
    public mutating func feed(_ data: Data) {
        partial.append(data)
        var start = partial.startIndex
        while let newline = partial[start...].firstIndex(of: 0x0A) {
            consume(partial[start..<newline])
            start = partial.index(after: newline)
        }
        partial = Data(partial[start...])
        if partial.count > Self.maxDecodedLine {
            partial.removeAll()  // a runaway line; don't hold it in memory
        }
    }

    private mutating func consume(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let header = Header(line) else {
            unrecognizedLines += 1
            return
        }
        if let at = header.timestamp, at > (lastEventAt ?? .distantPast) { lastEventAt = at }

        switch (header.type, header.payloadType) {
        case ("session_meta", _):
            readSessionMeta(line)
        case ("event_msg", "task_started"):
            if openTurns == 0 { turnStartedAt = header.timestamp }
            openTurns += 1
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            openTurns = max(0, openTurns - 1)
        default:
            break
        }
    }

    private mutating func readSessionMeta(_ line: Data) {
        guard line.count <= Self.maxDecodedLine,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return }
        if let id = payload["id"] as? String, !id.isEmpty { sessionId = id }
        if let cwd = payload["cwd"] as? String { self.cwd = cwd }
    }
}

/// The fixed-order prefix of a rollout line, parsed without decoding the line.
struct Header: Equatable {
    let timestamp: Date?
    let type: String
    let payloadType: String?

    /// Only the first bytes are examined; the rest of the line (often content) is not.
    static let prefixLength = 256

    init?(_ line: Data) {
        // Lenient decode: the cut may split a multibyte character, which is fine here.
        let text = String(decoding: line.prefix(Self.prefixLength), as: UTF8.self)
        guard let match = text.firstMatch(of: Self.pattern) else { return nil }
        timestamp = Self.parseTimestamp(String(match.1))
        type = String(match.2)
        payloadType = match.3.map(String.init)
    }

    nonisolated(unsafe) private static let pattern =
        #/^\{"timestamp":"([^"]*)","ordinal":\d+,"type":"([a-z_]+)","payload":\{(?:"type":"([a-z_]+)")?/#

    static func parseTimestamp(_ raw: String) -> Date? {
        (try? fractional.parse(raw)) ?? (try? whole.parse(raw))
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
}
