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
    /// Wakes the app when the earliest lease expires. Nil when there are no leases, so an
    /// idle ohmai schedules no timers at all.
    @ObservationIgnored private var expiryTimer: Task<Void, Never>?
    @ObservationIgnored private var scheduledExpiry: Date?

    /// How late an expiry check may fire, so the system can coalesce the wakeup.
    private static let expiryTolerance: Duration = .seconds(2)

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
        // After sleep, re-check at once rather than trusting a timer scheduled before it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
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
        scheduleExpiryCheck(at: leaseBook.nextExpiry(prefs: prefs), now: now)
    }

    private func scheduleExpiryCheck(at expiry: Date?, now: Date) {
        guard expiry != scheduledExpiry else { return }
        expiryTimer?.cancel()
        scheduledExpiry = expiry
        guard let expiry else {
            expiryTimer = nil
            return
        }
        let delay = Duration.seconds(max(0, expiry.timeIntervalSince(now)))
        expiryTimer = Task { [weak self] in
            // ContinuousClock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: delay, tolerance: Self.expiryTolerance, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.scheduledExpiry = nil
            self.reevaluate()
        }
    }
}
