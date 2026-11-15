import Foundation
import OhmaiCore
import OhmaiUsage

/// **The privacy boundary.** This module is the only code in ohmai that reads transcripts,
/// and its public API returns only `UsageRecord`s: numbers and metadata.
///
/// - Lines are pre-filtered by raw bytes and only candidate lines are decoded. A JSON key
///   can only appear unescaped as a real key, never inside a string value, so the filters
///   can't be tripped by anything a user wrote.
/// - Decoded lines are reduced to usage fields and dropped immediately. Nothing else is
///   kept, logged or returned.
/// - Formats are undocumented: unknown shapes are skipped, never guessed at.
public struct TranscriptParser: Sendable {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case claude, codex, pi
    }

    /// What a parser must remember between incremental reads of one file. Persisted by the
    /// ledger alongside the file's byte offset. Contains no content.
    public struct State: Sendable, Equatable, Codable {
        /// Codex: the session id from `session_meta`, which only the first line carries.
        public var sessionId: String?
        /// Codex: the model from the latest `turn_context`.
        public var model: String?

        public init(sessionId: String? = nil, model: String? = nil) {
            self.sessionId = sessionId
            self.model = model
        }
    }

    public let format: Format
    public private(set) var state: State
    private let path: String

    public init(format: Format, path: String, state: State = State()) {
        self.format = format
        self.path = path
        self.state = state
    }

    /// Parses complete lines (no trailing newline needed). Returns usage found in them.
    public mutating func parse(lines: some Sequence<Data>) -> [UsageRecord] {
        var out: [UsageRecord] = []
        for line in lines {
            switch format {
            case .claude: if let r = Self.claude(line) { out.append(r) }
            case .codex: if let r = codex(line) { out.append(r) }
            case .pi: if let r = Self.pi(line, path: path) { out.append(r) }
            }
        }
        return out
    }

    // MARK: - Claude Code

    private static let claudeAssistant = Data(#""type":"assistant""#.utf8)
    private static let usageKey = Data(#""usage":{"#.utf8)

    static func claude(_ line: Data) -> UsageRecord? {
        guard contains(line, claudeAssistant), contains(line, usageKey),
              let json = object(line),
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let timestamp = date(json["timestamp"])
        else { return nil }
        // One API message is written as several lines with identical usage: key on its id.
        guard let id = (message["id"] as? String) ?? (json["requestId"] as? String) else { return nil }

        let creation = usage["cache_creation"] as? [String: Any]
        let write5m = int(creation?["ephemeral_5m_input_tokens"])
        let write1h = int(creation?["ephemeral_1h_input_tokens"])
        let writeTotal = int(usage["cache_creation_input_tokens"])
        let details = usage["output_tokens_details"] as? [String: Any]

        return UsageRecord(
            dedupeKey: "claude:\(id)",
            agent: .claude,
            sessionId: json["sessionId"] as? String ?? "",
            model: model,
            timestamp: timestamp,
            input: int(usage["input_tokens"]),
            output: int(usage["output_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"]),
            // The split, when present; otherwise treat all writes as 5-minute (the cheaper rate).
            cacheWrite5m: creation == nil ? writeTotal : write5m,
            cacheWrite1h: creation == nil ? 0 : write1h,
            reasoning: int(details?["thinking_tokens"]))
    }

    // MARK: - Codex

    /// Codex lines lead with `{"timestamp":…,"ordinal":N,"type":"…"`; only these are decoded.
    private static let codexTypes = ["session_meta", "turn_context", "token_usage_record"]
        .map { Data(#""type":"\#($0)""#.utf8) }

    mutating func codex(_ line: Data) -> UsageRecord? {
        let head = line.prefix(160)
        guard Self.codexTypes.contains(where: { Self.contains(head, $0) }),
              let json = Self.object(line), let payload = json["payload"] as? [String: Any]
        else { return nil }

        switch json["type"] as? String {
        case "session_meta":
            if let id = payload["id"] as? String { state.sessionId = id }
            return nil
        case "turn_context":
            if let model = payload["model"] as? String { state.model = model }
            return nil
        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any],
                  let responseId = payload["response_id"] as? String,
                  let timestamp = Self.date(json["timestamp"])
            else { return nil }
            let input = Self.int(usage["input_tokens"])
            let cached = Self.int(usage["cached_input_tokens"])
            return UsageRecord(
                dedupeKey: "codex:\(responseId)",
                agent: .codex,
                sessionId: payload["session_id"] as? String ?? state.sessionId ?? "",
                model: state.model ?? "unknown",
                timestamp: timestamp,
                // Codex's input includes the cached part.
                input: input - cached,
                output: Self.int(usage["output_tokens"]),
                cacheRead: cached,
                cacheWrite5m: Self.int(usage["cache_write_input_tokens"]),
                reasoning: Self.int(usage["reasoning_output_tokens"]))
        default:
            return nil
        }
    }

    // MARK: - pi

    static func pi(_ line: Data, path: String) -> UsageRecord? {
        guard contains(line, usageKey), let json = object(line),
              let id = json["id"] as? String, let timestamp = date(json["timestamp"])
        else { return nil }

        // Assistant messages carry usage on `message`; standalone usage entries (e.g.
        // cache warming) carry it at the top level.
        let message = json["message"] as? [String: Any]
        let source: [String: Any]?
        switch json["type"] as? String {
        case "message" where message?["role"] as? String == "assistant": source = message
        case "usage": source = json
        default: source = nil
        }
        guard let source, let usage = source["usage"] as? [String: Any] else { return nil }
        let cost = (usage["cost"] as? [String: Any]).flatMap { ($0["total"] as? NSNumber)?.doubleValue }
        let session = sessionId(fromPiPath: path)

        return UsageRecord(
            dedupeKey: "pi:\(session):\(id)",
            agent: .pi,
            sessionId: session,
            model: [source["provider"] as? String, source["model"] as? String].compactMap { $0 }.joined(separator: "/"),
            timestamp: timestamp,
            input: int(usage["input"]),
            output: int(usage["output"]),  // pi's output already includes reasoning
            cacheRead: int(usage["cacheRead"]),
            cacheWrite5m: int(usage["cacheWrite"]),
            recordedCost: cost)
    }

    /// `<timestamp>_<uuid>.jsonl` → the uuid.
    static func sessionId(fromPiPath path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.split(separator: "_").last.map(String.init) ?? name
    }

    // MARK: - Helpers

    /// Byte search via memmem: the pre-filter runs over every line of gigabytes of history.
    static func contains(_ haystack: Data, _ needle: Data) -> Bool {
        haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                guard let hp = h.baseAddress, let np = n.baseAddress, h.count >= n.count else { return false }
                return memmem(hp, h.count, np, n.count) != nil
            }
        }
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        guard let s = value as? String else { return nil }
        return (try? fractional.parse(s)) ?? (try? whole.parse(s))
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
}
