import Foundation
import OhmaiCore

/// A local calendar day.
public struct DayKey: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func < (a: Self, b: Self) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    /// The first day of the previous month.
    var previousMonthStart: DayKey {
        month == 1 ? DayKey(year: year - 1, month: 12, day: 1) : DayKey(year: year, month: month - 1, day: 1)
    }

    func sameMonth(as other: DayKey) -> Bool { year == other.year && month == other.month }

    func daysInMonth(calendar: Calendar) -> Int {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        return calendar.range(of: .day, in: .month, for: date)!.count
    }
}

public struct DailyUsage: Sendable, Equatable {
    public let agent: Agent
    public let day: DayKey
    public let totals: UsageTotals

    public init(agent: Agent, day: DayKey, totals: UsageTotals) {
        self.agent = agent
        self.day = day
        self.totals = totals
    }
}

/// This month so far against last month: both the same days (the fair comparison) and
/// last month's full total (the scale), per agent and overall.
public struct MonthComparison: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        /// What the change is computed on.
        public enum Basis: Sendable, Equatable { case cost, tokens }

        public let agent: Agent?  // nil for the total row
        public let thisMonth: UsageTotals
        /// Last month, days 1 through today's day of month (or all of it, if shorter).
        public let lastMonthSameDays: UsageTotals
        public let lastMonthTotal: UsageTotals
        public let basis: Basis

        /// Fractional change vs the same days last month; nil when there's nothing to compare
        /// against (shown as "new").
        public var change: Double? {
            let now = value(thisMonth), then = value(lastMonthSameDays)
            guard then > 0 else { return nil }
            return (now - then) / then
        }

        /// This month so far as a fraction of last month's total, for the bar. Unclamped.
        public var progress: Double? {
            let total = value(lastMonthTotal)
            return total > 0 ? value(thisMonth) / total : nil
        }

        /// Where the same-days point sits on the bar.
        public var sameDaysMark: Double? {
            let total = value(lastMonthTotal)
            return total > 0 ? value(lastMonthSameDays) / total : nil
        }

        func value(_ t: UsageTotals) -> Double { basis == .cost ? t.cost : Double(t.tokens) }
    }

    public let today: DayKey
    public let lastMonth: DayKey
    public let rows: [Row]
    public let total: Row
    /// The ledger doesn't reach back to the start of last month, so comparisons are partial.
    public let partialHistory: Bool

    /// - `daily`: per-agent, per-day totals (any range; other months are ignored).
    /// - `historyStart`: the earliest day the ledger has data for.
    public static func build(
        daily: [DailyUsage], today: DayKey, historyStart: DayKey?, calendar: Calendar = .current
    ) -> MonthComparison {
        let lastMonth = today.previousMonthStart
        let lastMonthDays = lastMonth.daysInMonth(calendar: calendar)
        let sameDaysLimit = min(today.day, lastMonthDays)

        var this: [Agent: UsageTotals] = [:]
        var same: [Agent: UsageTotals] = [:]
        var full: [Agent: UsageTotals] = [:]
        for d in daily {
            if d.day.sameMonth(as: today), d.day.day <= today.day {
                this[d.agent, default: UsageTotals()] = this[d.agent, default: UsageTotals()] + d.totals
            } else if d.day.sameMonth(as: lastMonth) {
                full[d.agent, default: UsageTotals()] = full[d.agent, default: UsageTotals()] + d.totals
                if d.day.day <= sameDaysLimit {
                    same[d.agent, default: UsageTotals()] = same[d.agent, default: UsageTotals()] + d.totals
                }
            }
        }

        let agents = Agent.allCases.filter { this[$0] != nil || full[$0] != nil }
        let rows = agents.map { agent in
            row(agent: agent, this: this[agent] ?? UsageTotals(), same: same[agent] ?? UsageTotals(), full: full[agent] ?? UsageTotals())
        }
        let sum = { (pick: (Row) -> UsageTotals) in rows.map(pick).reduce(UsageTotals(), +) }
        let total = row(agent: nil, this: sum(\.thisMonth), same: sum(\.lastMonthSameDays), full: sum(\.lastMonthTotal))

        return MonthComparison(
            today: today, lastMonth: lastMonth, rows: rows, total: total,
            partialHistory: historyStart.map { $0 > lastMonth } ?? true)
    }

    /// Compare on estimated cost when every token involved has a price (cost weights cache
    /// reads properly); otherwise on tokens, so an unpriced model doesn't skew the change.
    private static func row(agent: Agent?, this: UsageTotals, same: UsageTotals, full: UsageTotals) -> Row {
        let priced = this.fullyPriced && same.fullyPriced && full.fullyPriced && (this.cost + full.cost) > 0
        return Row(agent: agent, thisMonth: this, lastMonthSameDays: same, lastMonthTotal: full, basis: priced ? .cost : .tokens)
    }
}
