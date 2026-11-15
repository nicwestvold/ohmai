import Foundation

/// Bundled, versioned per-model prices. Nothing is fetched: the table ships with the app and
/// is updated with releases. Costs are "what it would have cost on the API", an estimate.
public struct PriceTable: Sendable, Equatable {
    /// USD per million tokens.
    public struct Price: Sendable, Equatable, Decodable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite5m: Double
        public let cacheWrite1h: Double

        public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead ?? input * 0.1
            self.cacheWrite5m = cacheWrite5m ?? input * 1.25
            self.cacheWrite1h = cacheWrite1h ?? input * 2
        }

        private enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite5m, cacheWrite1h }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                input: try c.decode(Double.self, forKey: .input),
                output: try c.decode(Double.self, forKey: .output),
                cacheRead: try c.decodeIfPresent(Double.self, forKey: .cacheRead),
                cacheWrite5m: try c.decodeIfPresent(Double.self, forKey: .cacheWrite5m),
                cacheWrite1h: try c.decodeIfPresent(Double.self, forKey: .cacheWrite1h))
        }
    }

    public let version: Int
    public let asOf: String
    public let models: [String: Price]

    public init(version: Int, asOf: String, models: [String: Price]) {
        self.version = version
        self.asOf = asOf
        self.models = models
    }

    private struct File: Decodable {
        let version: Int
        let asOf: String
        let models: [String: Price]
    }

    public static func decode(_ data: Data) throws -> PriceTable {
        let file = try JSONDecoder().decode(File.self, from: data)
        return PriceTable(version: file.version, asOf: file.asOf, models: file.models)
    }

    /// The table bundled with this build.
    public static let bundled: PriceTable = {
        guard let url = Bundle.module.url(forResource: "prices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? decode(data)
        else { return PriceTable(version: 0, asOf: "", models: [:]) }
        return table
    }()

    /// Exact id first, then with a trailing date snapshot removed (`…-20250929`),
    /// then with a provider prefix removed (`anthropic.`, `anthropic/`).
    public func price(for model: String) -> Price? {
        if let p = models[model] { return p }
        var id = model
        for prefix in ["anthropic.", "anthropic/", "us.anthropic."] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        if let p = models[id] { return p }
        if let range = id.range(of: #"[-@]\d{8}$"#, options: .regularExpression) {
            id.removeSubrange(range)
            if let p = models[id] { return p }
        }
        return nil
    }

    /// Recorded cost wins; otherwise the table; otherwise unpriced.
    public func totals(for record: UsageRecord) -> UsageTotals {
        if let recorded = record.recordedCost {
            return UsageTotals(tokens: record.totalTokens, cost: recorded)
        }
        guard let p = price(for: record.model) else {
            return UsageTotals(tokens: record.totalTokens, cost: 0, unpricedTokens: record.totalTokens)
        }
        let perToken = 1.0 / 1_000_000
        let cost = (Double(record.input) * p.input
            + Double(record.output) * p.output
            + Double(record.cacheRead) * p.cacheRead
            + Double(record.cacheWrite5m) * p.cacheWrite5m
            + Double(record.cacheWrite1h) * p.cacheWrite1h) * perToken
        return UsageTotals(tokens: record.totalTokens, cost: cost)
    }
}
