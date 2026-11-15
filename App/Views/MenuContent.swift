import OhmaiCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.decision.summary)
                .font(.headline)

            Divider()

            running

            Divider()

            Text(powerLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.lidSession.lastError, model.prefsStore.prefs.lidClosedModeEnabled {
                Text(error.description)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.assertionError {
                Text("Couldn't hold the power assertion (IOReturn \(error.code))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.lidRegistration.refresh() }
    }

    @ViewBuilder
    private var running: some View {
        Text("Running")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        let leases = model.leaseBook.leases
        if leases.isEmpty {
            Text("No agents running")
                .foregroundStyle(.secondary)
        } else {
            ForEach(leases, id: \.session) { lease in
                HStack {
                    Circle()
                        .fill(lease.isBusy ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(lease.session.agent.displayName)
                    if let project = lease.project {
                        Text(URL(fileURLWithPath: project).lastPathComponent + "/")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(lease.isBusy ? "busy" : "waiting on you")
                        .foregroundStyle(.secondary)
                    Text(lease.grantedAt, style: .relative)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
            if model.updater.canCheckForUpdates {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
    }

    private var powerLine: String {
        let source = switch model.power.source {
        case .ac: "On AC"
        case .battery(let p): p.map { "On battery \($0)%" } ?? "On battery"
        case .unknown: "Power source unknown"
        }
        var parts = [source, "thermal \(model.power.thermal)"]
        if model.power.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }
}
