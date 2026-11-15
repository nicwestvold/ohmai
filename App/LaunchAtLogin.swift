import Foundation
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.westvold.ohmai", category: "login-item")

/// Launch at login via `SMAppService.mainApp`. On by default (design.md), with a Settings
/// toggle. Debug builds never register on their own, so a build in `build/` doesn't become
/// your login item.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var enabled = false
    private(set) var needsApproval = false
    private(set) var lastError: String?

    @ObservationIgnored private let service = SMAppService.mainApp
    @ObservationIgnored private let defaults: UserDefaults
    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    /// First launch of a release build: turn it on once. After that the user's choice stands.
    func applyDefaultIfNeeded() {
        #if DEBUG
        return
        #else
        guard !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
        defaults.set(true, forKey: Self.defaultAppliedKey)
        set(true)
        #endif
    }

    func set(_ on: Bool) {
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
