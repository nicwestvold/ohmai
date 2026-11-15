import OhmaiCore
import OhmaiUsage
import SwiftUI

/// This month at a glance: one hero figure for the total, then a meter per agent.
/// Each meter's track is last month's total, the fill is this month so far, and the tick is
/// where last month stood on the same day.
struct UsageSection: View {
    let usage: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = usage.comparison, !c.rows.isEmpty {
                hero(c)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(c.rows, id: \.agent) { row in
                        AgentMeter(row: row, lastMonth: Self.monthName(c.lastMonth), partial: c.partialHistory)
                    }
                }
            } else if usage.importing {
                label(nil)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your history…").foregroundStyle(.secondary)
                }
            } else if let failed = usage.failed {
                Text(failed).font(.callout).foregroundStyle(Theme.waiting)
            } else {
                label(nil)
                Text("No usage yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ c: MonthComparison?) -> some View {
        HStack {
            Text(c.map { "\(Self.monthName($0.today)) so far" } ?? "Usage")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let c {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .help(Self.explanation(c))
            }
        }
    }

    private func hero(_ c: MonthComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label(c)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // No "+" on the hero: unpriced agents show their tokens in their own row below.
                Text(c.total.basis == .cost ? Format.dollars(c.total.thisMonth.cost) : Format.amount(c.total.thisMonth, basis: .tokens))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if c.total.basis == .cost {
                    Text("est.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            context(c)
                .font(.callout)
        }
    }

    /// One line of comparison under the hero figure.
    @ViewBuilder
    private func context(_ c: MonthComparison) -> some View {
        let last = Self.monthName(c.lastMonth)
        if c.total.lastMonthTotal.tokens == 0 {
            Text("Nothing recorded for \(last)").foregroundStyle(.secondary)
        } else if c.partialHistory || c.total.change == nil {
            Text("\(Format.amount(c.total.lastMonthTotal, basis: c.total.basis)) in \(last) (incomplete)")
                .foregroundStyle(.secondary)
        } else if let change = c.total.change {
            HStack(spacing: 4) {
                Text("\(change >= 0 ? "↑" : "↓") \(Format.percent(abs(change)))")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("vs the same days in \(last)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func explanation(_ c: MonthComparison) -> String {
        var lines = [
            "Estimated cost at API list prices: what this usage would cost on the API, not a bill.",
            "Each bar's track is last month's total; the fill is this month so far; the tick marks the same day last month.",
            "Models without a known price are counted in tokens and left out of the dollar total.",
        ]
        if c.partialHistory {
            lines.append("Last month is incomplete: older transcripts were already deleted. ohmai keeps its own copy from now on.")
        }
        return lines.joined(separator: "\n\n")
    }

    static func monthName(_ day: DayKey) -> String {
        let date = Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: 1)) ?? .now
        return date.formatted(.dateTime.month(.wide))
    }
}

/// Name, figure, and a meter: fill = this month, track = last month, tick = same day.
private struct AgentMeter: View {
    let row: MonthComparison.Row
    let lastMonth: String
    let partial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(row.agent?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(row.agent?.displayName ?? "Total")
                Spacer(minLength: 8)
                Text(Format.amount(row.thisMonth, basis: row.basis))
                    .fontWeight(.medium)
                    .monospacedDigit()
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let progress = row.progress {
                Meter(progress: progress, mark: partial ? nil : row.sameDaysMark, tint: row.agent?.color ?? .accentColor)
            }
        }
        .contentShape(Rectangle())
        .help(details)
    }

    /// "of $2,905" while under last month, "2.1× Oct" once past it, "new" with no history.
    private var trailing: String {
        guard row.lastMonthTotal.tokens > 0, let progress = row.progress else { return "new" }
        if progress > 1 { return Format.multiple(progress) + " \(lastMonth.prefix(3))" }
        return "of " + Format.amount(row.lastMonthTotal, basis: row.basis)
    }

    private var details: String {
        var lines = ["\(Format.tokens(row.thisMonth.tokens)) tokens this month"]
        if row.lastMonthTotal.tokens > 0 {
            lines.append("Same days in \(lastMonth): \(Format.tokens(row.lastMonthSameDays.tokens)) tokens, \(Format.dollars(row.lastMonthSameDays.cost))")
            lines.append("All of \(lastMonth): \(Format.tokens(row.lastMonthTotal.tokens)) tokens, \(Format.dollars(row.lastMonthTotal.cost))")
        }
        if !row.thisMonth.fullyPriced {
            lines.append("\(Format.tokens(row.thisMonth.unpricedTokens)) tokens from models without a known price")
        }
        return lines.joined(separator: "\n")
    }
}

/// A thin meter. Past 100% it stays full and the figure says by how much: the track is a
/// reference, not a limit, so "over" isn't drawn as an alarm.
private struct Meter: View {
    let progress: Double
    let mark: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, w * min(progress, 1)))
                if let mark, mark > 0, mark < 1 {
                    Capsule()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 2, height: 12)
                        .offset(x: w * mark - 1)
                }
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("\(Int(progress * 100)) percent of last month")
    }
}

enum Format {
    static func amount(_ t: UsageTotals, basis: MonthComparison.Row.Basis) -> String {
        switch basis {
        case .cost: dollars(t.cost) + (t.fullyPriced ? "" : "+")
        case .tokens: tokens(t.tokens) + " tokens"
        }
    }

    /// "14.2B", "193K", "812".
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return String(format: "%.1fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.0fK", d / 1e3)
        default: return "\(n)"
        }
    }

    /// "$5,934", "$41", "<$1".
    static func dollars(_ v: Double) -> String {
        if v > 0 && v < 1 { return "<$1" }
        return "$" + Int(v.rounded()).formatted(.number.grouping(.automatic))
    }

    /// "23%", or "4.0×" past 999%.
    static func percent(_ v: Double) -> String {
        v >= 10 ? multiple(v + 1) : "\(Int((v * 100).rounded()))%"
    }

    /// "2.1×".
    static func multiple(_ v: Double) -> String {
        String(format: "%.1f×", v)
    }
}
