import Foundation
import Observation
import OhmaiCore

/// Persists `Prefs` in UserDefaults.
@MainActor
@Observable
final class PrefsStore {
    var prefs: Prefs {
        didSet {
            guard prefs != oldValue else { return }
            save()
            onChange?()
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let keepAwakeEnabled = "keepAwakeEnabled"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let batteryFloorPercent = "batteryFloorPercent"
        static let signalTimeout = "signalTimeoutSeconds"
        static let waitingCap = "waitingCapSeconds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = Prefs.default
        defaults.register(defaults: [
            Key.keepAwakeEnabled: d.keepAwakeEnabled,
            Key.keepDisplayAwake: d.keepDisplayAwake,
            Key.batteryFloorPercent: d.batteryFloorPercent,
            Key.signalTimeout: d.signalTimeout,
            Key.waitingCap: d.waitingCap,
        ])
        // Lid-closed prefs are added with the lid helper (build step 2).
        prefs = Prefs(
            keepAwakeEnabled: defaults.bool(forKey: Key.keepAwakeEnabled),
            keepDisplayAwake: defaults.bool(forKey: Key.keepDisplayAwake),
            batteryFloorPercent: defaults.integer(forKey: Key.batteryFloorPercent),
            signalTimeout: defaults.double(forKey: Key.signalTimeout),
            waitingCap: defaults.double(forKey: Key.waitingCap)
        )
    }

    private func save() {
        defaults.set(prefs.keepAwakeEnabled, forKey: Key.keepAwakeEnabled)
        defaults.set(prefs.keepDisplayAwake, forKey: Key.keepDisplayAwake)
        defaults.set(prefs.batteryFloorPercent, forKey: Key.batteryFloorPercent)
        defaults.set(prefs.signalTimeout, forKey: Key.signalTimeout)
        defaults.set(prefs.waitingCap, forKey: Key.waitingCap)
    }
}
