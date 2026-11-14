import AppKit
import Foundation
import Observation
import OhmaiCore
import OhmaiPower

/// What the 16px menu bar icon shows.
enum MenuBarIconState: Equatable {
    case asleep
    case working
    case waiting
    case shades
}

/// Wires power inputs, leases, `Policy` and `AssertionManager` together.
@MainActor
@Observable
final class AppModel {
    let prefsStore: PrefsStore
    let power: PowerMonitor
    let updater: any Updater

    private(set) var leaseBook = LeaseBook()
    private(set) var decision: Decision = .allowSleep(.noLeases)
    private(set) var assertionError: AssertionError?

    @ObservationIgnored private let assertions: AssertionManager
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// How often leases are re-checked for expiry, independent of incoming events.
    private static let tickInterval: Duration = .seconds(15)

    init(
        updater: any Updater,
        prefsStore: PrefsStore = PrefsStore(),
        power: PowerMonitor = PowerMonitor(),
        assertions: AssertionManager = AssertionManager()
    ) {
        self.updater = updater
        self.prefsStore = prefsStore
        self.power = power
        self.assertions = assertions

        prefsStore.onChange = { [weak self] in self?.reevaluate() }
        power.onChange = { [weak self] in self?.reevaluate() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.assertions.releaseAll() }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.reevaluate()
            }
        }
        reevaluate()
    }

    var powerState: PowerState {
        // The lid helper arrives in build step 2; until then it's never approved.
        PowerState(source: power.source, lowPowerMode: power.lowPowerMode, thermal: power.thermal, lidHelperApproved: false)
    }

    var iconState: MenuBarIconState {
        if case .stayAwakeLidClosed = decision { return .shades }
        let leases = leaseBook.leases
        if leases.contains(where: { !$0.isBusy }) { return .waiting }
        if !leases.isEmpty { return .working }
        return .asleep
    }

    /// Entry point for adapters (build step 3 onward).
    func handle(_ event: ActivityEvent) {
        leaseBook.apply(event, now: .now)
        reevaluate()
    }

    func reevaluate() {
        let now = Date.now
        let prefs = prefsStore.prefs
        leaseBook.prune(at: now, prefs: prefs)
        let next = Policy.decide(leases: leaseBook.leases, power: powerState, prefs: prefs, now: now)
        if next != decision { decision = next }
        assertions.apply(decision, keepDisplayAwake: prefs.keepDisplayAwake)
        assertionError = assertions.lastError
    }
}
