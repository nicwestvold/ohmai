import AppKit
import Foundation
import Observation
import OhmaiAdapterSupport
import OhmaiClaudeAdapter
import OhmaiCodexAdapter
import OhmaiPiAdapter
import OhmaiLidXPC
import OhmaiCore
import OhmaiPower

/// What the 16px menu bar icon shows.
enum MenuBarIconState: Equatable {
    case asleep
    case working
    case waiting
    case shades
}

/// Wires power inputs, leases, `Policy`, `AssertionManager` and the lid helper together.
@MainActor
@Observable
final class AppModel {
    let prefsStore: PrefsStore
    let power: PowerMonitor
    let updater: any Updater
    let lidRegistration: LidHelperRegistration
    let lidSession: LidSession
    let usage = UsageModel()
    let launchAtLogin = LaunchAtLogin()

    private(set) var leaseBook = LeaseBook()
    private(set) var decision: Decision = .allowSleep(.noLeases)
    private(set) var assertionError: AssertionError?

    @ObservationIgnored private let assertions: AssertionManager
    @ObservationIgnored private let claude: StatusDirectoryAdapter
    @ObservationIgnored private let codex: CodexRolloutAdapter
    @ObservationIgnored private let pi: StatusDirectoryAdapter
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
        assertions: AssertionManager = AssertionManager(),
        lidRegistration: LidHelperRegistration = LidHelperRegistration(),
        lidSession: LidSession? = nil,
        claude: StatusDirectoryAdapter = AppModel.makeClaudeAdapter(),
        codex: CodexRolloutAdapter = AppModel.makeCodexAdapter(),
        pi: StatusDirectoryAdapter = AppModel.makePiAdapter()
    ) {
        self.updater = updater
        self.prefsStore = prefsStore
        self.power = power
        self.assertions = assertions
        self.lidRegistration = lidRegistration
        self.claude = claude
        self.codex = codex
        self.pi = pi
        // The team ID reaches code only via Info.plist (`OHMAI_TEAM_ID`).
        let teamID = Bundle.main.object(forInfoDictionaryKey: "OHMAITeamID") as? String ?? ""
        self.lidSession = lidSession ?? LidSession(client: XPCLidHelperClient(teamID: teamID))

        lidRegistration.onChange = { [weak self] in self?.reevaluate() }

        prefsStore.onChange = { [weak self] in self?.reevaluate() }
        power.onChange = { [weak self] in self?.reevaluate() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.assertions.releaseAll()
                // Best effort: the helper's own 90s lease releases it if this doesn't land.
                self?.lidSession.apply(.allowSleep(.keepAwakeOff), batteryFloorPercent: 100)
            }
        }
        // After sleep, re-check at once rather than trusting a timer scheduled before it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.claude.rescan()
                self?.codex.rescan()
                self?.pi.rescan()
                self?.reevaluate()
            }
        }
        claude.onEvents = { [weak self] in self?.handle($0) }
        codex.onEvents = { [weak self] in self?.handle($0) }
        pi.onEvents = { [weak self] in self?.handle($0) }
        claude.quietLimit = prefsStore.prefs.busyQuietLimit
        codex.quietLimit = prefsStore.prefs.busyQuietLimit
        pi.quietLimit = prefsStore.prefs.busyQuietLimit
        claude.start()
        codex.start()
        pi.start()
        usage.start()
        launchAtLogin.applyDefaultIfNeeded()
        restoreLidHelperIfNeeded()
        reevaluate()
        #if DEBUG
        Snapshots.runIfRequested(model: self)
        #endif
    }

    static func makeClaudeAdapter() -> StatusDirectoryAdapter {
        #if DEBUG
        // Debug builds only: point at a scratch directory for manual testing.
        if let dir = ProcessInfo.processInfo.environment["OHMAI_CLAUDE_SESSIONS_DIR"] {
            return ClaudeSessions.makeAdapter(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        #endif
        return ClaudeSessions.makeAdapter()
    }

    static func makeCodexAdapter() -> CodexRolloutAdapter {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["OHMAI_CODEX_SESSIONS_DIR"] {
            return CodexRolloutAdapter(root: URL(fileURLWithPath: dir, isDirectory: true))
        }
        #endif
        return CodexRolloutAdapter()
    }

    static func makePiAdapter() -> StatusDirectoryAdapter {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["OHMAI_PI_STATUS_DIR"] {
            return PiSessions.makeAdapter(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        #endif
        return PiSessions.makeAdapter()
    }

    var powerState: PowerState {
        PowerState(
            source: power.source,
            lowPowerMode: power.lowPowerMode,
            thermal: power.thermal,
            lidHelperApproved: lidRegistration.status == .enabled
        )
    }

    var iconState: MenuBarIconState {
        // Shades only once the helper has actually engaged, not merely when the policy wants it.
        if lidSession.isEngaged { return .shades }
        let leases = leaseBook.leases
        if leases.contains(where: { !$0.isBusy }) { return .waiting }
        if !leases.isEmpty { return .working }
        return .asleep
    }

    var headerFace: HeaderFace {
        if lidSession.isEngaged { return .shades }
        let leases = leaseBook.leases
        guard !leases.isEmpty else { return .asleep }
        if case .allowSleep(let reason) = decision, reason.overridesAgents { return .drowsy }
        if leases.contains(where: { !$0.isBusy }) { return .oh }
        return .focused
    }

    /// Entry point for adapters. One reevaluation per batch.
    func handle(_ events: [ActivityEvent]) {
        let now = Date.now
        for event in events { leaseBook.apply(event, now: now) }
        reevaluate()
    }

    func reevaluate() {
        let now = Date.now
        let prefs = prefsStore.prefs
        if claude.quietLimit != prefs.busyQuietLimit {
            claude.quietLimit = prefs.busyQuietLimit
            codex.quietLimit = prefs.busyQuietLimit
            pi.quietLimit = prefs.busyQuietLimit
            claude.rescan()
            codex.rescan()
            pi.rescan()
        }
        leaseBook.prune(at: now, prefs: prefs)
        let next = Policy.decide(leases: leaseBook.leases, power: powerState, prefs: prefs, now: now)
        if next != decision { decision = next }
        assertions.apply(decision, keepDisplayAwake: prefs.keepDisplayAwake)
        assertionError = assertions.lastError
        lidSession.apply(decision, batteryFloorPercent: prefs.lidClosedBatteryFloorPercent)
        scheduleExpiryCheck(at: leaseBook.nextExpiry(prefs: prefs), now: now)
    }

    /// Replacing the app (a manual update) drops the helper's registration. If the user had
    /// lid-closed mode on, they already consented: register again. If macOS wants approval,
    /// the Lid Closed tab and dropdown say so (no System Settings window at launch).
    private func restoreLidHelperIfNeeded() {
        // macOS reports a dropped registration as either "not registered" or "not found".
        // "Not found" can also mean a build without the helper (Debug): only re-register when
        // this bundle actually contains the launchd plist.
        let dropped = lidRegistration.status == .notRegistered || lidRegistration.status == .notFound
        let bundled = FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchDaemons/\(LidHelperXPC.launchdPlistName)").path)
        guard prefsStore.prefs.lidClosedModeEnabled, dropped, bundled else { return }
        lidRegistration.register()
    }

    /// The Settings toggle. Enabling registers the helper (macOS then asks for approval);
    /// disabling releases first, then unregisters.
    func setLidClosedMode(_ enabled: Bool) {
        prefsStore.prefs.lidClosedModeEnabled = enabled
        if enabled {
            lidRegistration.register()
            // macOS doesn't always prompt (e.g. it already notified about this developer),
            // so take the user straight to where approval happens.
            if lidRegistration.status == .requiresApproval { lidRegistration.openLoginItems() }
        } else {
            Task {
                await lidSession.settle()
                await lidRegistration.unregister()
            }
        }
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
