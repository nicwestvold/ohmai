import SwiftUI

/// Opt-in for lid-closed mode, behind an explanation of what it does and what it risks.
struct LidClosedSection: View {
    let model: AppModel
    @State private var confirming = false

    var body: some View {
        @Bindable var store = model.prefsStore
        let registration = model.lidRegistration
        let enabled = store.prefs.lidClosedModeEnabled

        Section {
            Toggle("Keep working with the lid closed", isOn: Binding(
                get: { enabled },
                set: { on in
                    if on { confirming = true } else { model.setLidClosedMode(false) }
                }
            ))

            Text(Self.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if enabled {
                LabeledContent("Helper", value: registration.status.summary)
                if registration.status == .requiresApproval {
                    Button("Open Login Items…") { registration.openLoginItems() }
                }
                if let error = registration.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Stepper(value: $store.prefs.lidClosedBatteryFloorPercent, in: 10...95, step: 5) {
                    LabeledContent("On battery, only above", value: "\(store.prefs.lidClosedBatteryFloorPercent)%")
                }
            }
        } header: {
            Text("Lid closed")
        }
        .onAppear { registration.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            registration.refresh()
        }
        .alert("Keep working with the lid closed?", isPresented: $confirming) {
            Button("Install Helper") { model.setLidClosedMode(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.risks)
        }
    }

    static let explanation = """
        Closing the lid normally puts the Mac to sleep, even mid-task. With this on, ohmai \
        keeps it awake while an agent is busy (not while it's waiting on you), using a small \
        helper that runs as root.
        """

    static let risks = """
        A closed MacBook in a bag can get hot and drain its battery. ohmai lets it sleep on \
        battery below your floor, when the Mac gets hot, as soon as agents finish, and within \
        90 seconds if ohmai itself stops responding.

        macOS will ask you to approve the helper in System Settings → Login Items. \
        It only ever runs `pmset disablesleep`.
        """
}
