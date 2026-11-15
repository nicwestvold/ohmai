import Foundation
import OhmaiCore

/// One model response's token usage. This is everything ohmai keeps from a transcript:
/// numbers and metadata, never content.
public struct UsageRecord: Sendable, Equatable, Hashable {
    /// Unique per response, so re-importing a file never double-counts.
    public let dedupeKey: String
    public let agent: Agent
    public let sessionId: String
    public let model: String
    public let timestamp: Date
    /// Uncached input.
    public let input: Int
    /// Output, including reasoning/thinking (already counted here by every provider we read).
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite5m: Int
    public let cacheWrite1h: Int
    /// The part of `output` that was reasoning. Informational; never added to totals.
    public let reasoning: Int
    /// Cost the agent itself recorded (pi), in USD. Nil means "estimate from the price table".
    public let recordedCost: Double?

    public init(
        dedupeKey: String, agent: Agent, sessionId: String, model: String, timestamp: Date,
        input: Int, output: Int, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
        reasoning: Int = 0, recordedCost: Double? = nil
    ) {
        self.dedupeKey = dedupeKey
        self.agent = agent
        self.sessionId = sessionId
        self.model = model
        self.timestamp = timestamp
        self.input = max(0, input)
        self.output = max(0, output)
        self.cacheRead = max(0, cacheRead)
        self.cacheWrite5m = max(0, cacheWrite5m)
        self.cacheWrite1h = max(0, cacheWrite1h)
        self.reasoning = max(0, reasoning)
        self.recordedCost = recordedCost
    }

    /// Every token type counts, cache reads included (design.md → Usage and metrics).
    public var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

/// Summed usage for some slice (an agent-day, a month). Cost splits into what's known
/// and what couldn't be priced, so the UI never presents a partial sum as complete.
public struct UsageTotals: Sendable, Equatable {
    public var tokens: Int = 0
    /// USD, from recorded costs and the price table.
    public var cost: Double = 0
    /// Tokens from models with no known price.
    public var unpricedTokens: Int = 0

    public init(tokens: Int = 0, cost: Double = 0, unpricedTokens: Int = 0) {
        self.tokens = tokens
        self.cost = cost
        self.unpricedTokens = unpricedTokens
    }

    /// True when every token has a price, so `cost` is a complete estimate.
    public var fullyPriced: Bool { unpricedTokens == 0 }

    public static func + (a: Self, b: Self) -> Self {
        Self(tokens: a.tokens + b.tokens, cost: a.cost + b.cost, unpricedTokens: a.unpricedTokens + b.unpricedTokens)
    }
}
