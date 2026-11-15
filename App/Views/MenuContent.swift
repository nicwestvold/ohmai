import OhmaiCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            running
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            UsageSection(usage: model.usage)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 14)

            footer
                .padding(6)
        }
        .frame(width: 320)
        .onAppear {
            model.lidRegistration.refresh()
            Task { await model.usage.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            MenuBarIcon(state: model.iconState)
                .font(.title2)
                .frame(width: 28)
                .foregroundStyle(model.decision.keepsAwake ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.decision.headline)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The decision's reason, plus power facts that aren't already in it.
    private var subtitle: String {
        var parts: [String] = []
        if let detail = model.decision.detail { parts.append(detail) }
        let source = switch model.power.source {
        case .ac: "on AC"
        case .battery(let p): p.map { "on battery \($0)%" } ?? "on battery"
        case .unknown: "power source unknown"
        }
        if !parts.contains(where: { $0.contains(source) }) { parts.append(source) }
        if model.power.thermal != .nominal, !parts.contains(where: { $0.contains("thermal") }) {
            parts.append("thermal \(model.power.thermal)")
        }
        if model.power.lowPowerMode, !parts.contains("Low Power Mode") { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            runningRows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runningRows: some View {
        let leases = model.leaseBook.leases
        if leases.isEmpty {
            Text("No agents running")
                .foregroundStyle(.secondary)
        } else {
            // Minute resolution: second-by-second counting is noise in a menu.
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(leases, id: \.session) { lease in
                        LeaseRow(lease: lease, now: context.date)
                    }
                }
            }
        }
    }

    private var problems: [String] {
        var result: [String] = []
        if let error = model.lidSession.lastError, model.prefsStore.prefs.lidClosedModeEnabled {
            result.append(error.description)
        }
        if let error = model.assertionError {
            result.append("Couldn't hold the power assertion (IOReturn \(error.code))")
        }
        return result
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if model.updater.canCheckForUpdates {
                Button {
                    dismiss()
                    model.updater.checkForUpdates()
                } label: {
                    MenuRowLabel(title: "Check for Updates…", systemImage: "arrow.down.circle")
                }
            }
            Button {
                dismiss()  // close the dropdown, like a native menu does
                NSApp.activate()
                openSettings()
            } label: {
                MenuRowLabel(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,")
            }
            .keyboardShortcut(",")
            Button { NSApp.terminate(nil) } label: {
                MenuRowLabel(title: "Quit ohmai", systemImage: "power", shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct LeaseRow: View {
    let lease: Lease
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(lease.isBusy ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(lease.session.agent.displayName)
                .fixedSize()
            if let project = lease.project {
                Text(URL(fileURLWithPath: project).lastPathComponent + "/")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(status)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private var status: String {
        let state = lease.isBusy ? "busy" : "waiting on you"
        return "\(state) · \(Self.compact(now.timeIntervalSince(lease.activitySince)))"
    }

    /// "now", "9m", "1h 5m".
    static func compact(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
