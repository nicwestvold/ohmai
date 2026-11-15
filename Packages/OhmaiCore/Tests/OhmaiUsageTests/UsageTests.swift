import Foundation
import Testing
import OhmaiCore
@testable import OhmaiUsage

private func record(model: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, w5: Int = 0, w1h: Int = 0, cost: Double? = nil) -> UsageRecord {
    UsageRecord(dedupeKey: UUID().uuidString, agent: .claude, sessionId: "s", model: model, timestamp: .now,
                input: input, output: output, cacheRead: cacheRead, cacheWrite5m: w5, cacheWrite1h: w1h, recordedCost: cost)
}

@Suite("PriceTable")
struct PriceTableTests {
    let table = PriceTable.bundled

    @Test func bundledTableLoads() {
        #expect(table.version >= 1)
        #expect(table.models.count >= 10)
        #expect(table.price(for: "claude-opus-5-5")?.input == 4)
    }

    @Test func cacheDefaultsAndOverrides() throws {
        let opus = try #require(table.price(for: "claude-opus-5-5"))
        #expect(opus.cacheRead == 0.20)          // listed exception
        #expect(opus.cacheWrite5m == 5.0)        // 1.25 × 4
        #expect(opus.cacheWrite1h == 8.0)        // 2 × 4
        let haiku = try #require(table.price(for: "claude-haiku-4-5"))
        #expect(abs(haiku.cacheRead - 0.1) < 1e-9)  // 0.1 × input default
    }

    @Test func lookupStripsSnapshotsAndPrefixes() {
        #expect(table.price(for: "claude-sonnet-4-6-20260101") != nil)
        #expect(table.price(for: "anthropic.claude-opus-5-5") != nil)
        #expect(table.price(for: "gpt-6.1-sol") == nil)
        #expect(table.price(for: "<synthetic>") == nil)
    }

    @Test func costEstimate() {
        // 1M of each at Opus 5.5: 4 + 20 + 0.20 + 5 + 8 = 37.20
        let t = table.totals(for: record(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, w5: 1_000_000, w1h: 1_000_000))
        #expect(abs(t.cost - 37.2) < 1e-9)
        #expect(t.tokens == 5_000_000)
        #expect(t.fullyPriced)
    }

    @Test func recordedCostWins() {
        let t = table.totals(for: record(model: "anything", input: 100, cost: 0.42))
        #expect(t.cost == 0.42)
        #expect(t.fullyPriced)
    }

    @Test func unknownModelIsUnpricedNotZero() {
        let t = table.totals(for: record(model: "gpt-6.1-sol", input: 500, output: 500))
        #expect(t.unpricedTokens == 1000)
        #expect(!t.fullyPriced)
    }
}

@Suite("MonthComparison")
struct MonthComparisonTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func day(_ y: Int, _ m: Int, _ d: Int) -> DayKey { DayKey(year: y, month: m, day: d) }
    func usage(_ agent: Agent, _ k: DayKey, cost: Double, tokens: Int = 1000) -> DailyUsage {
        DailyUsage(agent: agent, day: k, totals: UsageTotals(tokens: tokens, cost: cost))
    }

    @Test func sameDaysAndFullMonth() throws {
        let today = day(2026, 11, 14)
        let daily = [
            usage(.claude, day(2026, 11, 1), cost: 10),
            usage(.claude, day(2026, 11, 14), cost: 20),
            usage(.claude, day(2026, 10, 3), cost: 15),
            usage(.claude, day(2026, 10, 14), cost: 10),
            usage(.claude, day(2026, 10, 15), cost: 100),  // after the same-days window
            usage(.claude, day(2026, 9, 30), cost: 999),   // two months back: ignored
        ]
        let c = MonthComparison.build(daily: daily, today: today, historyStart: day(2026, 9, 1), calendar: cal)
        let row = try #require(c.rows.first)
        #expect(row.thisMonth.cost == 30)
        #expect(row.lastMonthSameDays.cost == 25)
        #expect(row.lastMonthTotal.cost == 125)
        #expect(row.basis == .cost)
        #expect(abs(row.change! - 0.2) < 1e-9)
        #expect(abs(row.progress! - 0.24) < 1e-9)
        #expect(abs(row.sameDaysMark! - 0.2) < 1e-9)
        #expect(!c.partialHistory)
    }

    @Test func januaryComparesWithDecember() {
        let c = MonthComparison.build(
            daily: [usage(.codex, day(2026, 12, 5), cost: 4), usage(.codex, day(2027, 1, 5), cost: 2)],
            today: day(2027, 1, 10), historyStart: day(2026, 12, 1), calendar: cal)
        #expect(c.lastMonth == day(2026, 12, 1))
        #expect(c.rows.first?.change == -0.5)
    }

    @Test func thirtyFirstAgainstAThirtyDayMonthUsesAllOfIt() {
        let c = MonthComparison.build(
            daily: [usage(.claude, day(2026, 11, 30), cost: 7), usage(.claude, day(2026, 12, 31), cost: 7)],
            today: day(2026, 12, 31), historyStart: day(2026, 1, 1), calendar: cal)
        #expect(c.rows.first?.lastMonthSameDays.cost == 7)
        #expect(c.rows.first?.change == 0)
    }

    @Test func marchAfterFebruary() {
        let c = MonthComparison.build(
            daily: [usage(.pi, day(2027, 2, 28), cost: 3)],
            today: day(2027, 3, 30), historyStart: day(2027, 1, 1), calendar: cal)
        #expect(c.rows.first?.lastMonthSameDays.cost == 3)
    }

    @Test func nothingLastMonthIsNew() {
        let c = MonthComparison.build(daily: [usage(.pi, day(2026, 11, 2), cost: 5)], today: day(2026, 11, 14), historyStart: day(2026, 11, 2), calendar: cal)
        #expect(c.rows.first?.change == nil)
        #expect(c.rows.first?.progress == nil)
        #expect(c.partialHistory)
    }

    @Test func unpricedTokensSwitchTheBasisToTokens() {
        let daily = [
            DailyUsage(agent: .codex, day: day(2026, 11, 3), totals: UsageTotals(tokens: 300, cost: 0, unpricedTokens: 300)),
            DailyUsage(agent: .codex, day: day(2026, 10, 3), totals: UsageTotals(tokens: 200, cost: 0, unpricedTokens: 200)),
        ]
        let row = MonthComparison.build(daily: daily, today: day(2026, 11, 14), historyStart: day(2026, 1, 1), calendar: cal).rows[0]
        #expect(row.basis == .tokens)
        #expect(row.change == 0.5)
    }

    @Test func totalStaysOnCostWhenOneAgentIsUnpriced() {
        let daily = [
            usage(.claude, day(2026, 11, 2), cost: 10),
            usage(.claude, day(2026, 10, 2), cost: 5),
            DailyUsage(agent: .codex, day: day(2026, 11, 3), totals: UsageTotals(tokens: 300, cost: 0, unpricedTokens: 300)),
        ]
        let c = MonthComparison.build(daily: daily, today: day(2026, 11, 14), historyStart: day(2026, 1, 1), calendar: cal)
        #expect(c.rows.first { $0.agent == .codex }?.basis == .tokens)
        #expect(c.total.basis == .cost)
        #expect(!c.total.thisMonth.fullyPriced)
        #expect(c.total.change == 1)
    }

    @Test func totalRowSumsAgentsAndKeepsOrder() {
        let daily = [
            usage(.pi, day(2026, 11, 2), cost: 1),
            usage(.claude, day(2026, 11, 2), cost: 2),
            usage(.claude, day(2026, 10, 2), cost: 1),
        ]
        let c = MonthComparison.build(daily: daily, today: day(2026, 11, 14), historyStart: day(2026, 1, 1), calendar: cal)
        #expect(c.rows.map(\.agent) == [.claude, .pi])
        #expect(c.total.thisMonth.cost == 3)
        #expect(c.total.lastMonthSameDays.cost == 1)
    }

    @Test func futureDaysThisMonthAreIgnored() {
        let c = MonthComparison.build(daily: [usage(.claude, day(2026, 11, 20), cost: 9)], today: day(2026, 11, 14), historyStart: nil, calendar: cal)
        #expect(c.rows.first?.thisMonth.cost ?? 0 == 0)
    }
}
