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
        Text(c.map { "\(Self.monthName($0.today)) so far" } ?? "Usage")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func hero(_ c: MonthComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label(c)
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // No "+" on the hero: unpriced agents show their tokens in their own row below.
                    Text(c.total.basis == .cost ? Format.dollars(c.total.thisMonth.cost) : Format.amount(c.total.thisMonth, basis: .tokens))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    if c.total.basis == .cost {
                        // The explanation lives on hover; no extra control in the menu.
                        Text("est.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(Self.explanation(c))
                    }
                }
                Spacer(minLength: 8)
                DailySparkline(values: c.daily, lastMonth: c.lastMonthDaily, today: c.today.day, month: c.today, basis: c.total.basis)
                    .frame(minWidth: 84, maxWidth: 124)
                    .frame(height: 38)
                    .padding(.bottom, 6)
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
            "Bars: the solid fill is this month so far, the light bar behind it is last month's total, and the tick marks where last month stood on the same day.",
            "Daily chart: this month's days over a soft area for last month's, day by day.",
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

/// One column per day of this month, over a soft area showing last month's days (aligned by
/// day of month, same scale). Past days are drawn, today is full strength, future days are
/// faint placeholders. Hover a column for both days' values.
private struct DailySparkline: View {
    let values: [Double]
    let lastMonth: [Double]
    let today: Int
    let month: DayKey
    let basis: MonthComparison.Row.Basis

    var body: some View {
        let ghost = (0..<values.count).map { $0 < lastMonth.count ? lastMonth[$0] : 0 }
        let peak = max(values.max() ?? 0, ghost.max() ?? 0, .leastNonzeroMagnitude)
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(values.count)
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                // Last month: a filled area through the day centers.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in ghost.enumerated() {
                        path.addLine(to: CGPoint(x: slot * (CGFloat(i) + 0.5), y: h - h * v / peak))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: h))
                    path.closeSubpath()
                }
                .fill(.primary.opacity(0.13))

                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        let day = index + 1
                        let past = day <= today
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(fill(day: day, past: past))
                            .frame(maxWidth: .infinity)
                            .frame(height: past ? max(2, h * value / peak) : 2)
                            .contentShape(Rectangle())
                            .help(past ? tooltip(day: day, value: value, ghost: ghost[index]) : "")
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Daily usage this month, \(today) of \(values.count) days so far, over last month")
    }

    private func fill(day: Int, past: Bool) -> some ShapeStyle {
        if !past { return AnyShapeStyle(.primary.opacity(0.15)) }
        return day == today ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.75))
    }

    private func tooltip(day: Int, value: Double, ghost: Double) -> String {
        let date = Calendar.current.date(from: DateComponents(year: month.year, month: month.month, day: day)) ?? .now
        return "\(date.formatted(.dateTime.month(.abbreviated).day())): \(amount(value))\nSame day last month: \(amount(ghost))"
    }

    private func amount(_ v: Double) -> String {
        basis == .cost ? Format.dollars(v) : Format.tokens(Int(v)) + " tokens"
    }
}

/// Name, figure, and a bullet bar on one shared scale: the solid fill is this month, the
/// light bar behind it is last month's total, and the tick is where last month stood on the
/// same day. Whichever is larger spans the full width, so the bar always says something.
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
            if row.lastMonthTotal.tokens > 0 {
                BulletBar(
                    current: value(row.thisMonth),
                    reference: value(row.lastMonthTotal),
                    mark: partial ? nil : value(row.lastMonthSameDays),
                    tint: row.agent?.color ?? .accentColor)
            }
        }
        .contentShape(Rectangle())
        .help(details)
    }

    private func value(_ t: UsageTotals) -> Double { row.basis == .cost ? t.cost : Double(t.tokens) }

    /// "of $2,905 in Oct" under last month, "2.1× Oct" past it, "new" with no history.
    private var trailing: String {
        guard row.lastMonthTotal.tokens > 0, let progress = row.progress else { return "new" }
        if progress > 1 { return Format.multiple(progress) + " \(lastMonth.prefix(3))" }
        return "of " + Format.amount(row.lastMonthTotal, basis: row.basis)
    }

    private var details: String {
        var lines = ["\(Format.tokens(row.thisMonth.tokens)) tokens this month"]
        if row.lastMonthTotal.tokens > 0 {
            lines.append("Light bar: all of \(lastMonth), \(Format.dollars(row.lastMonthTotal.cost)) (\(Format.tokens(row.lastMonthTotal.tokens)) tokens)")
            lines.append("Same days in \(lastMonth): \(Format.dollars(row.lastMonthSameDays.cost)) (\(Format.tokens(row.lastMonthSameDays.tokens)) tokens)")
        }
        if !row.thisMonth.fullyPriced {
            lines.append("\(Format.tokens(row.thisMonth.unpricedTokens)) tokens from models without a known price")
        }
        return lines.joined(separator: "\n")
    }
}

/// Current vs reference on one scale (the larger spans the width).
private struct BulletBar: View {
    let current: Double
    let reference: Double
    let mark: Double?
    let tint: Color

    var body: some View {
        let scale = max(current, reference, .leastNonzeroMagnitude)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.06))
                Capsule()
                    .fill(tint.opacity(0.28))
                    .frame(width: max(6, w * reference / scale))
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, w * current / scale), height: 6)
                if let mark, mark > 0 {
                    Capsule()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 2, height: 14)
                        .offset(x: min(w - 2, w * mark / scale - 1))
                }
            }
            .frame(height: 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("This month \(Int(100 * current / max(reference, .leastNonzeroMagnitude))) percent of last month")
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
