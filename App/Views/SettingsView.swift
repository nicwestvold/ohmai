import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var store = model.prefsStore

        Form {
            Section("Keep awake") {
                Toggle("Keep the Mac awake while agents work", isOn: $store.prefs.keepAwakeEnabled)
                Toggle("Keep the display on too", isOn: $store.prefs.keepDisplayAwake)
                    .disabled(!store.prefs.keepAwakeEnabled)
            }

            Section("Battery") {
                Stepper(value: $store.prefs.batteryFloorPercent, in: 10...95, step: 5) {
                    LabeledContent("Let the Mac sleep below", value: "\(store.prefs.batteryFloorPercent)%")
                }
            }

            Section("Leases") {
                Stepper(value: minutes($store.prefs.signalTimeout), in: 1...60) {
                    LabeledContent("Release after no signal for", value: "\(Int(store.prefs.signalTimeout / 60)) min")
                }
                Stepper(value: minutes($store.prefs.waitingCap), in: 5...240, step: 5) {
                    LabeledContent("Stop waiting on you after", value: "\(Int(store.prefs.waitingCap / 60)) min")
                }
                Stepper(value: minutes($store.prefs.busyQuietLimit), in: 15...480, step: 15) {
                    LabeledContent("Release a busy agent that's written nothing for", value: "\(Int(store.prefs.busyQuietLimit / 60)) min")
                }
                Text("A long build or test run writes nothing until it finishes. Raise this if yours run longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LidClosedSection(model: model)

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: automaticChecks)
                    .disabled(!model.updater.canCheckForUpdates)
                if !model.updater.canCheckForUpdates {
                    Text("Updates not available in this build")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { model.updater.automaticallyChecksForUpdates },
            set: { model.updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private func minutes(_ seconds: Binding<TimeInterval>) -> Binding<Int> {
        Binding(
            get: { Int(seconds.wrappedValue / 60) },
            set: { seconds.wrappedValue = TimeInterval($0 * 60) }
        )
    }
}
