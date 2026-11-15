import OhmaiCore
import OhmaiPiAdapter
import SwiftUI

// Pages of the Settings window (SettingsWindow.swift). General and Agents are about what
// ohmai is for: your agents and their usage. Sleep behavior is real but secondary, so it
// lives under Advanced.

/// A grouped settings page that scrolls when it needs to.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
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
    @State private var confirmingUninstall = false
    @State private var deleteHistory = true

    var body: some View {
        @Bindable var store = model.prefsStore

        SettingsPage {
            Section {
                HStack(spacing: 14) {
                    HeaderFaceView(face: .focused)
                        .foregroundStyle(Theme.amber)
                        .frame(width: 52, height: 52)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ohmai").font(.title2.weight(.semibold))
                        Text("Your AI coding agents and their usage, at a glance.")
                            .foregroundStyle(.secondary)
                        Text("Version \(Self.version)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle(isOn: launchAtLogin) {
                    Text("Open ohmai at login")
                    Footnote("ohmai keeps its own copy of your usage history, which only grows while it's running.")
                }
                if model.launchAtLogin.needsApproval {
                    HStack {
                        Footnote("macOS needs your OK in Login Items.")
                        Spacer()
                        Button("Open Login Items…") { model.launchAtLogin.openLoginItems() }
                    }
                }
                if let error = model.launchAtLogin.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            // Only builds with an updater show this; v1 has none and makes no network calls.
            if model.updater.canCheckForUpdates {
                Section {
                    Toggle("Check for updates automatically", isOn: automaticChecks)
                }
            }

            Section {
                LabeledContent("Memory and disk", value: footprint?.summary ?? "…")
            } footer: {
                Text("ohmai makes no network requests. It reads transcripts only for usage numbers and never stores what you wrote.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Remove ohmai and everything it installed") {
                    Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                }
            }
        }
        .onAppear {
            footprint = .current()
            model.launchAtLogin.refresh()
        }
        .sheet(isPresented: $confirmingUninstall) {
            UninstallSheet(deleteHistory: $deleteHistory) {
                confirmingUninstall = false
                Task { await Uninstaller.run(model: model, deleteHistory: deleteHistory) }
            } cancel: {
                confirmingUninstall = false
            }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { model.launchAtLogin.enabled }, set: { model.launchAtLogin.set($0) })
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

// MARK: - Advanced

/// Sleep behavior, timeouts and the optional lid-closed helper. Plain, factual wording.
struct AdvancedTab: View {
    let model: AppModel

    var body: some View {
        @Bindable var store = model.prefsStore

        Form {
            Section {
                Toggle(isOn: $store.prefs.keepAwakeEnabled) {
                    Text("Prevent idle sleep while an agent is working")
                    Footnote("A standard power assertion, like caffeinate. Released as soon as agents stop or go quiet.")
                }
                Toggle("Keep the display on too", isOn: $store.prefs.keepDisplayAwake)
                    .disabled(!store.prefs.keepAwakeEnabled)
                Picker(selection: $store.prefs.batteryFloorPercent) {
                    ForEach([20, 30, 40, 50, 60, 70, 80], id: \.self) { Text("\($0)%").tag($0) }
                } label: {
                    Text("Allow sleep on battery below")
                }
                .disabled(!store.prefs.keepAwakeEnabled)
            } header: {
                Text("Idle sleep")
            } footer: {
                Footnote("Low Power Mode and high temperature always allow sleep.")
            }

            Section("Session timeouts") {
                Picker(selection: $store.prefs.waitingCap) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { Text(Self.minutes($0)).tag(TimeInterval($0 * 60)) }
                } label: {
                    Text("Waiting on you counts as active for")
                }
                Picker(selection: $store.prefs.busyQuietLimit) {
                    ForEach([30, 60, 120, 240, 480], id: \.self) { Text(Self.minutes($0)).tag(TimeInterval($0 * 60)) }
                } label: {
                    Text("Treat a silent agent as stuck after")
                    Footnote("Raise this if your builds or test runs write nothing for longer.")
                }
            }

            LidClosedSections(model: model)
        }
        .formStyle(.grouped)
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

private struct UninstallSheet: View {
    @Binding var deleteHistory: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall ohmai?").font(.headline)
            Text("This turns sleep back on, removes the lid helper (it runs as root), the login item and the pi extension, then moves ohmai to the Trash.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also delete usage history and settings", isOn: $deleteHistory)
            Footnote("Usage history is the only copy of months Claude Code has already deleted from its own transcripts.")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive, action: confirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
