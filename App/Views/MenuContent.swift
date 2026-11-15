import OhmaiCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if !model.leaseBook.leases.isEmpty {
                running
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 16)

            UsageSection(usage: model.usage)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.waiting)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider().padding(.horizontal, 16)

            footer
                .padding(6)
        }
        .frame(width: 340)
        .onAppear {
            model.lidRegistration.refresh()
            Task { await model.usage.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            // The app icon's look: amber face on an ink tile.
            HeaderFaceView(face: model.headerFace)
                .foregroundStyle(Theme.amber)
                .frame(width: 44, height: 44)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// What your agents are doing, in words.
    private var title: String {
        let leases = model.leaseBook.leases
        let waiting = leases.filter { !$0.isBusy }.count
        let busy = leases.count - waiting
        switch (busy, waiting) {
        case (0, 0): return "All quiet"
        case (_, 0): return busy == 1 ? "1 agent working" : "\(busy) agents working"
        case (0, _): return waiting == 1 ? "1 agent needs you" : "\(waiting) agents need you"
        default: return "\(busy) working · \(waiting) need\(waiting == 1 ? "s" : "") you"
        }
    }

    /// Which agents are active. Power behavior stays out of the headline; it lives in
    /// Settings → Advanced.
    private var subtitle: String {
        let agents = Agent.allCases.filter { agent in
            model.leaseBook.leases.contains { $0.session.agent == agent }
        }
        return agents.isEmpty ? "No agents running" : agents.map(\.displayName).joined(separator: " · ")
    }

    // MARK: - Running

    private var running: some View {
        // Minute resolution: second-by-second counting is noise in a menu.
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                ForEach(model.leaseBook.leases, id: \.session) { lease in
                    LeaseRow(lease: lease, now: context.date)
                }
            }
        }
    }

    private var problems: [String] {
        var result: [String] = []
        if model.prefsStore.prefs.lidClosedModeEnabled, model.lidRegistration.status == .requiresApproval {
            result.append("Lid-closed mode needs your approval in Login Items")
        }
        if let error = model.lidSession.lastError, model.prefsStore.prefs.lidClosedModeEnabled,
           model.lidRegistration.status == .enabled {
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
                SettingsWindow.shared.show(model: model)
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

/// One session: the project first (that's what you recognize), the agent beneath it.
private struct LeaseRow: View {
    let lease: Lease
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(lease.session.agent.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(project)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(lease.session.agent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            if !lease.isBusy {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.waiting.opacity(0.12))
            }
        }
    }

    private var project: String {
        lease.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project"
    }

    @ViewBuilder
    private var status: some View {
        let elapsed = Self.compact(now.timeIntervalSince(lease.activitySince))
        if lease.isBusy {
            Text("working · \(elapsed)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Label("needs you · \(elapsed)", systemImage: "hourglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.waiting)
                .monospacedDigit()
        }
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
