import OhmaiCore
import OhmaiPiAdapter
import SwiftUI

/// Native tabbed Settings: one short page per concern instead of one long form.
struct SettingsView: View {
    let model: AppModel

    enum Tab: Hashable { case general, power, lid, agents }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            PowerTab(model: model)
                .tabItem { Label("Power", systemImage: "battery.75percent") }
                .tag(Tab.power)
            LidClosedTab(model: model)
                .tabItem { Label("Lid Closed", systemImage: "laptopcomputer") }
                .tag(Tab.lid)
            AgentsTab(model: model)
                .tabItem { Label("Agents", systemImage: "terminal") }
                .tag(Tab.agents)
        }
        .frame(width: 500)
    }
}

/// A grouped settings page sized to its content.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's secondary explanation, kept short.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralTab: View {
    let model: AppModel
    @State private var footprint: Footprint?

    var body: some View {
        @Bindable var store = model.prefsStore

        SettingsPage {
            Section {
                Toggle(isOn: $store.prefs.keepAwakeEnabled) {
                    Text("Keep the Mac awake while agents work")
                    Footnote("Only while a session is busy or waiting on you. When they're done, your Mac sleeps as usual.")
                }
                Toggle("Keep the display on too", isOn: $store.prefs.keepDisplayAwake)
                    .disabled(!store.prefs.keepAwakeEnabled)
            }

            Section {
                Toggle(isOn: automaticChecks) {
                    Text("Check for updates automatically")
                    if !model.updater.canCheckForUpdates {
                        Footnote("Updates aren't available in this build.")
                    }
                }
                .disabled(!model.updater.canCheckForUpdates)
            }

            Section {
                LabeledContent("ohmai itself", value: footprint?.summary ?? "…")
                LabeledContent("Version", value: Self.version)
            } footer: {
                Text("Reads transcripts only for usage numbers. Never stores or sends what you wrote.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { footprint = .current() }
    }

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { model.updater.automaticallyChecksForUpdates },
            set: { model.updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Power

struct PowerTab: View {
    let model: AppModel

    var body: some View {
        @Bindable var store = model.prefsStore

        SettingsPage {
            Section {
                Picker(selection: $store.prefs.batteryFloorPercent) {
                    ForEach([20, 30, 40, 50, 60, 70, 80], id: \.self) { Text("\($0)%").tag($0) }
                } label: {
                    Text("On battery, let the Mac sleep below")
                }
                LabeledContent("In Low Power Mode") { Text("Always lets the Mac sleep").foregroundStyle(.secondary) }
                LabeledContent("When the Mac gets hot") { Text("Always lets the Mac sleep").foregroundStyle(.secondary) }
            } footer: {
                Footnote("Plugged in, ohmai keeps the Mac awake for as long as agents work.")
            }

            Section("Sessions") {
                Picker(selection: $store.prefs.waitingCap) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { Text(Self.minutes($0)).tag(TimeInterval($0 * 60)) }
                } label: {
                    Text("Stop waiting for you after")
                    Footnote("An agent asking for approval keeps the Mac awake this long, then lets it sleep.")
                }
                Picker(selection: $store.prefs.busyQuietLimit) {
                    ForEach([30, 60, 120, 240, 480], id: \.self) { Text(Self.minutes($0)).tag(TimeInterval($0 * 60)) }
                } label: {
                    Text("Give up on a silent agent after")
                    Footnote("A busy agent that writes nothing for this long is treated as stuck. Raise it if your builds or test runs take longer.")
                }
            }
        }
    }

    static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) minutes" : (m == 60 ? "1 hour" : "\(m / 60) hours")
    }
}

// MARK: - Agents

struct AgentsTab: View {
    let model: AppModel
    @State private var piStatus: PiExtensionInstaller.Status = .notInstalled
    @State private var piError: String?
    private let installer = PiExtensionInstaller()

    var body: some View {
        SettingsPage {
            Section {
                AgentRow(
                    name: "Claude Code", detail: "Watches ~/.claude/sessions. Nothing to install.",
                    found: exists(".claude/sessions"), running: running(.claude))
                AgentRow(
                    name: "Codex", detail: "Watches ~/.codex/sessions. Nothing to install.",
                    found: exists(".codex/sessions"), running: running(.codex))
                AgentRow(
                    name: "pi", detail: piDetail,
                    found: piStatus == .piNotFound ? false : (piStatus == .installed ? true : nil),
                    running: running(.pi))
                if piStatus != .piNotFound {
                    PiExtensionControls(status: piStatus, error: piError, install: installPi, remove: removePi)
                }
            } footer: {
                Footnote("ohmai only reads session status and file timestamps here. It never reads your prompts or code to decide.")
            }
        }
        .onAppear { piStatus = installer.status() }
    }

    private var piDetail: String {
        switch piStatus {
        case .piNotFound: "Not found in ~/.pi."
        case .notInstalled: "Needs a small extension that tells ohmai when pi is busy."
        case .installed: "Extension installed in ~/.pi/agent/extensions. Restart pi or run /reload to load changes."
        case .outdated: "The installed extension is out of date."
        }
    }

    private func installPi() {
        do { try installer.install(); piError = nil } catch { piError = Self.describe(error) }
        piStatus = installer.status()
    }

    private func removePi() {
        do { try installer.uninstall(); piError = nil } catch { piError = Self.describe(error) }
        piStatus = installer.status()
    }

    private static func describe(_ error: Error) -> String {
        switch error as? PiExtensionInstaller.Failure {
        case .notOurs?: "~/.pi/agent/extensions/ohmai.ts exists and isn't ohmai's. Leaving it alone."
        case .piNotFound?: "pi isn't installed."
        case .bundledExtensionMissing?: "This build is missing the extension."
        case nil: error.localizedDescription
        }
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: relative).path)
    }

    private func running(_ agent: OhmaiCore.Agent) -> Int {
        model.leaseBook.leases.filter { $0.session.agent == agent }.count
    }
}

private struct PiExtensionControls: View {
    let status: PiExtensionInstaller.Status
    let error: String?
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer()
                switch status {
                case .notInstalled: Button("Install Extension", action: install)
                case .outdated: Button("Update Extension", action: install)
                case .installed: Button("Remove Extension", role: .destructive, action: remove)
                case .piNotFound: EmptyView()
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

private struct AgentRow: View {
    let name: String
    let detail: String
    /// nil: not supported yet.
    let found: Bool?
    let running: Int

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(status).foregroundStyle(.secondary)
            }
        } label: {
            Text(name)
            Footnote(detail)
        }
    }

    private var status: String {
        if running > 0 { return running == 1 ? "1 running" : "\(running) running" }
        switch found {
        case true?: return "Ready"
        case false?: return "Not installed"
        case nil: return "Not set up"
        }
    }

    private var color: Color {
        if running > 0 { return .green }
        return found == true ? Color.secondary.opacity(0.5) : .clear
    }
}
