import OhmaiCore
import OhmaiUsage
import SwiftUI

/// This month so far against last month, per agent: the same-days change (fair) and last
/// month's full total (scale), as one bar each.
struct UsageSection: View {
    let usage: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = usage.comparison, !c.rows.isEmpty {
                header(c)
                ForEach(c.rows, id: \.agent) { row in
                    UsageRow(row: row, title: row.agent?.displayName ?? "Total", partial: c.partialHistory)
                }
                if c.rows.count > 1 {
                    Divider().opacity(0.5)
                    UsageRow(row: c.total, title: "Total", partial: c.partialHistory, emphasized: true)
                }
                Text(footnote(c))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if usage.importing {
                header(nil)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading your history…").foregroundStyle(.secondary)
                }
            } else if let failed = usage.failed {
                Text(failed).font(.caption).foregroundStyle(.orange)
            } else {
                header(nil)
                Text("No usage yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ c: MonthComparison?) -> some View {
        HStack {
            Text(c.map { "\(Self.monthName($0.today)) so far" } ?? "Usage")
            Spacer()
            if let c { Text("vs \(Self.monthName(c.lastMonth))") }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }

    private func footnote(_ c: MonthComparison) -> String {
        var parts = ["Estimated API cost. Tick: same day last month."]
        if c.partialHistory {
            parts.append("Last month is incomplete (older transcripts were already deleted); ohmai keeps its own copy from now on.")
        }
        return parts.joined(separator: " ")
    }

    static func monthName(_ day: DayKey) -> String {
        let date = Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: 1)) ?? .now
        return date.formatted(.dateTime.month(.wide))
    }
}

private struct UsageRow: View {
    let row: MonthComparison.Row
    let title: String
    let partial: Bool
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .fontWeight(emphasized ? .semibold : .regular)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 6)
                Text(amounts)
                    .monospacedDigit()
                    .fixedSize()
                ChangeBadge(change: partial ? nil : row.change, isNew: row.lastMonthTotal.tokens == 0)
                    .frame(width: 52, alignment: .trailing)
            }
            if let progress = row.progress {
                ComparisonBar(progress: progress, mark: partial ? nil : row.sameDaysMark)
            }
        }
        .contentShape(Rectangle())
        .help(details)
    }

    /// Hover: the full picture in words.
    private var details: String {
        var lines = ["\(Format.tokens(row.thisMonth.tokens)) tokens this month"]
        if row.lastMonthTotal.tokens > 0 {
            lines.append("Same days last month: \(Format.tokens(row.lastMonthSameDays.tokens)) tokens, \(Format.dollars(row.lastMonthSameDays.cost))")
            lines.append("All of last month: \(Format.tokens(row.lastMonthTotal.tokens)) tokens, \(Format.dollars(row.lastMonthTotal.cost))")
        }
        if !row.thisMonth.fullyPriced {
            lines.append("\(Format.tokens(row.thisMonth.unpricedTokens)) tokens from models without a known price")
        }
        lines.append("Costs are estimates at API list prices, not a bill.")
        return lines.joined(separator: "\n")
    }

    /// "$212 / $498", or tokens when the agent's models aren't priced.
    private var amounts: AttributedString {
        let now: String, then: String?
        switch row.basis {
        case .cost:
            // "+" marks a lower bound: some tokens had no price.
            now = Format.dollars(row.thisMonth.cost) + (row.thisMonth.fullyPriced ? "" : "+")
            then = row.lastMonthTotal.cost > 0 ? Format.dollars(row.lastMonthTotal.cost) : nil
        case .tokens:
            now = Format.tokens(row.thisMonth.tokens) + " tok"
            then = row.lastMonthTotal.tokens > 0 ? Format.tokens(row.lastMonthTotal.tokens) : nil
        }
        var s = AttributedString(now)
        if let then {
            var rest = AttributedString(" / \(then)")
            rest.foregroundColor = .secondary
            s += rest
        }
        return s
    }
}

/// Fill: this month so far. Tick: where last month was on the same day. End: last month's total.
private struct ComparisonBar: View {
    let progress: Double
    let mark: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(progress > 1 ? Color.orange.gradient : Color.accentColor.gradient)
                    .frame(width: max(4, w * min(progress, 1)))
                if let mark, mark > 0, mark < 1 {
                    Rectangle()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 1.5, height: 9)
                        .offset(x: w * mark - 0.75)
                }
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("\(Int(progress * 100)) percent of last month")
    }
}

private struct ChangeBadge: View {
    let change: Double?
    let isNew: Bool

    var body: some View {
        Group {
            if isNew {
                Text("new").foregroundStyle(.secondary)
            } else if let change {
                Text("\(change >= 0 ? "▲" : "▼") \(Format.percent(abs(change)))")
                    .foregroundStyle(change >= 0 ? Color.orange : Color.green)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
    }
}

enum Format {
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

    /// "23%", "1.8×" above 999%.
    static func percent(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f×", v + 1) : "\(Int((v * 100).rounded()))%"
    }
}
