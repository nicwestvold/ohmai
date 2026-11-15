import Foundation
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.westvold.ohmai", category: "login-item")

/// Launch at login via `SMAppService.mainApp`. On by default (design.md), with a Settings
/// toggle. Debug builds never register on their own, so a build in `build/` doesn't become
/// your login item.
///
/// Stores the user's *choice*, not "the default was applied": replacing the app (a manual
/// update) silently drops the registration, so every launch re-registers if the choice is on.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var enabled = false
    private(set) var needsApproval = false
    private(set) var lastError: String?

    @ObservationIgnored private let service = SMAppService.mainApp
    @ObservationIgnored private let defaults: UserDefaults
    private static let choiceKey = "launchAtLoginChoice"  // "on" | "off"; absent = on (the default)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    /// Every launch of a release build: if the choice is on but macOS has no registration
    /// (first run, or the app was replaced), register. A choice of off is left alone.
    func applyDefaultIfNeeded() {
        #if DEBUG
        return
        #else
        refresh()
        let choice = defaults.string(forKey: Self.choiceKey) ?? "on"
        guard choice == "on", !enabled, !needsApproval else { return }
        log.notice("login item missing while the choice is on; registering")
        register(true)
        #endif
    }

    /// The Settings toggle: remembers the choice, then applies it.
    func set(_ on: Bool) {
        defaults.set(on ? "on" : "off", forKey: Self.choiceKey)
        register(on)
    }

    private func register(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() {
        enabled = service.status == .enabled
        needsApproval = service.status == .requiresApproval
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
