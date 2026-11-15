import SwiftUI

/// Opt-in for lid-closed mode, behind an explanation of what it does and what it risks.
/// Sections for the Advanced tab's form.
struct LidClosedSections: View {
    let model: AppModel
    @State private var confirming = false

    var body: some View {
        @Bindable var store = model.prefsStore
        let registration = model.lidRegistration
        let enabled = store.prefs.lidClosedModeEnabled

        Group {
            Section {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { on in if on { confirming = true } else { model.setLidClosedMode(false) } }
                )) {
                    Text("Keep working with the lid closed")
                    Footnote("Closing the lid normally sleeps the Mac, even mid-task. With this on, a busy agent keeps it awake. An agent waiting on you never does.")
                }
            } header: {
                Text("Lid closed")
            }

            if enabled && registration.status == .requiresApproval {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("One more step", systemImage: "exclamationmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Approve ohmai in System Settings → General → Login Items & Extensions, under Allow in the Background. Until then, lid-closed mode stays off.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Login Items…") { registration.openLoginItems() }
                    }
                    .padding(.vertical, 4)
                    // Approval happens in System Settings, which doesn't tell us. Re-check while
                    // this banner is on screen only, so it clears on its own.
                    .task {
                        while !Task.isCancelled && registration.status == .requiresApproval {
                            try? await Task.sleep(for: .seconds(2))
                            registration.refresh()
                        }
                    }
                }
            }

            if enabled {
                Section {
                    LabeledContent("Helper") {
                        HelperBadge(status: registration.status)
                    }
                    if let error = registration.lastError {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    Picker(selection: $store.prefs.lidClosedBatteryFloorPercent) {
                        ForEach([20, 30, 40, 50, 60], id: \.self) { Text("\($0)%").tag($0) }
                    } label: {
                        Text("On battery, only above")
                    }
                } footer: {
                    Footnote("If ohmai stops responding, the helper turns sleep back on by itself within 90 seconds.")
                }
            }
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

    static let risks = """
        A closed MacBook in a bag can get hot and drain its battery. ohmai lets it sleep on \
        battery below your floor, when it gets hot, as soon as agents finish, and within \
        90 seconds if ohmai itself stops responding.

        This installs a small helper that runs as root. Its only job is turning sleep off \
        and on (pmset disablesleep). macOS will ask you to approve it in Login Items.
        """
}

private struct HelperBadge: View {
    let status: LidHelperRegistration.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch status {
        case .enabled: "Approved"
        case .requiresApproval: "Waiting for approval"
        case .notRegistered: "Not installed"
        case .notFound: "Missing from this build"
        case .unknown: "Checking…"
        }
    }

    private var color: Color {
        switch status {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notRegistered, .unknown: .secondary
        case .notFound: .red
        }
    }
}
