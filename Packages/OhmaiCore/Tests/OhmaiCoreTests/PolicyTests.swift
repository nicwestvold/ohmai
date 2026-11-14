import Foundation
import Testing
@testable import OhmaiCore

private let ac = PowerState(source: .ac)
private func battery(_ percent: Int?, lowPower: Bool = false) -> PowerState {
    PowerState(source: .battery(percent: percent), lowPowerMode: lowPower)
}

private func decide(
    _ leases: [Lease] = [busyLease()],
    power: PowerState = ac,
    prefs: Prefs = .default,
    now: Date = t0.plus(minutes: 1)
) -> Decision {
    Policy.decide(leases: leases, power: power, prefs: prefs, now: now)
}

@Suite("Rule 1: leases and the master switch")
struct RuleOneTests {
    @Test func noLeasesAllowsSleep() {
        #expect(decide([]) == .allowSleep(.noLeases))
    }

    @Test func keepAwakeOffAllowsSleepEvenWithLeases() {
        #expect(decide(prefs: Prefs(keepAwakeEnabled: false)) == .allowSleep(.keepAwakeOff))
    }

    @Test func busyLeaseKeepsAwake() {
        #expect(decide() == .stayAwake(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func countsAllActiveLeases() {
        let d = decide([busyLease("a"), waitingLease("b"), busyLease("c")])
        #expect(d == .stayAwake(AwakeReason(sessionCount: 3, source: .ac)))
    }

    @Test func busyLeaseExpiresAfterSignalTimeout() {
        #expect(decide(now: t0.plus(minutes: 9.9)).keepsAwake)
        #expect(decide(now: t0.plus(minutes: 10)) == .allowSleep(.noLeases))
    }

    @Test func expiredLeasesAreNotCounted() {
        let fresh = busyLease("fresh", at: t0.plus(minutes: 15))
        let stale = busyLease("stale", at: t0)
        #expect(decide([fresh, stale], now: t0.plus(minutes: 16)) == .stayAwake(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func customSignalTimeout() {
        let prefs = Prefs(signalTimeout: 120)
        #expect(decide(prefs: prefs, now: t0.plus(minutes: 1.9)).keepsAwake)
        #expect(!decide(prefs: prefs, now: t0.plus(minutes: 2)).keepsAwake)
    }
}

@Suite("Waiting-lease cap")
struct WaitingCapTests {
    @Test func waitingLeaseKeepsAwakeWithinCap() {
        let lease = waitingLease(since: t0, lastSignal: t0.plus(minutes: 55))
        #expect(decide([lease], now: t0.plus(minutes: 59)).keepsAwake)
    }

    @Test func waitingLeaseReleasesAtCapEvenWithFreshSignals() {
        let lease = waitingLease(since: t0, lastSignal: t0.plus(minutes: 59))
        #expect(decide([lease], now: t0.plus(minutes: 60)) == .allowSleep(.noLeases))
    }

    @Test func waitingLeaseStillExpiresOnSignalTimeout() {
        #expect(decide([waitingLease(since: t0)], now: t0.plus(minutes: 10)) == .allowSleep(.noLeases))
    }

    @Test func customWaitingCap() {
        let prefs = Prefs(waitingCap: 5 * 60)
        let lease = waitingLease(since: t0, lastSignal: t0.plus(minutes: 4))
        #expect(decide([lease], prefs: prefs, now: t0.plus(minutes: 4.9)).keepsAwake)
        #expect(!decide([lease], prefs: prefs, now: t0.plus(minutes: 5)).keepsAwake)
    }

    @Test func busyLeaseHasNoCap() {
        let lease = Lease(session: key(), kind: .busy, grantedAt: t0, lastSignalAt: t0.plus(minutes: 300))
        #expect(decide([lease], now: t0.plus(minutes: 305)).keepsAwake)
    }
}

@Suite("Rule 2: thermal")
struct ThermalTests {
    @Test(arguments: [ThermalState.serious, .critical])
    func hotAllowsSleep(_ thermal: ThermalState) {
        let d = decide(power: PowerState(source: .ac, thermal: thermal))
        #expect(d == .allowSleep(.thermal(thermal)))
        if case .allowSleep(let r) = d { #expect(r.overridesAgents) }
    }

    @Test(arguments: [ThermalState.nominal, .fair])
    func coolStaysAwake(_ thermal: ThermalState) {
        #expect(decide(power: PowerState(source: .ac, thermal: thermal)).keepsAwake)
    }

    @Test func thermalBeatsAC() {
        #expect(!decide(power: PowerState(source: .ac, thermal: .serious)).keepsAwake)
    }
}

@Suite("Rule 3: battery")
struct BatteryTests {
    @Test(arguments: [0, 1, 25, 49])
    func belowFloorAllowsSleep(_ percent: Int) {
        #expect(decide(power: battery(percent)) == .allowSleep(.batteryLow(percent: percent)))
    }

    @Test(arguments: [50, 51, 80, 100])
    func atOrAboveFloorStaysAwake(_ percent: Int) {
        #expect(decide(power: battery(percent)) == .stayAwake(AwakeReason(sessionCount: 1, source: .battery(percent: percent))))
    }

    @Test func customFloor() {
        let prefs = Prefs(batteryFloorPercent: 20)
        #expect(decide(power: battery(20), prefs: prefs).keepsAwake)
        #expect(!decide(power: battery(19), prefs: prefs).keepsAwake)
    }

    @Test func unreadableChargeAllowsSleep() {
        #expect(decide(power: battery(nil)) == .allowSleep(.batteryLow(percent: nil)))
    }

    @Test func lowPowerModeOnBatteryAllowsSleep() {
        #expect(decide(power: battery(90, lowPower: true)) == .allowSleep(.lowPowerMode))
    }

    @Test func lowPowerModeOnACStaysAwake() {
        #expect(decide(power: PowerState(source: .ac, lowPowerMode: true)).keepsAwake)
    }

    @Test func unknownSourceAllowsSleep() {
        #expect(decide(power: PowerState(source: .unknown)) == .allowSleep(.powerSourceUnknown))
    }

    @Test func noAgentsIsNotAnOverride() {
        #expect(!SleepReason.noLeases.overridesAgents)
        #expect(!SleepReason.keepAwakeOff.overridesAgents)
        #expect(SleepReason.batteryLow(percent: 10).overridesAgents)
        #expect(SleepReason.lowPowerMode.overridesAgents)
    }
}

@Suite("Rule 4: lid-closed mode")
struct LidClosedTests {
    let lidPrefs = Prefs(lidClosedModeEnabled: true)
    let approvedAC = PowerState(source: .ac, lidHelperApproved: true)

    @Test func allConditionsMetEngagesLidClosed() {
        #expect(decide(power: approvedAC, prefs: lidPrefs) == .stayAwakeLidClosed(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func modeDisabledFallsBackToStayAwake() {
        #expect(decide(power: approvedAC) == .stayAwake(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func helperNotApprovedFallsBackToStayAwake() {
        #expect(decide(power: ac, prefs: lidPrefs) == .stayAwake(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func waitingOnlyNeverKeepsLidClosedAwake() {
        #expect(decide([waitingLease()], power: approvedAC, prefs: lidPrefs) == .stayAwake(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func oneBusyAmongWaitingIsEnough() {
        let d = decide([waitingLease("w"), busyLease("b")], power: approvedAC, prefs: lidPrefs)
        #expect(d == .stayAwakeLidClosed(AwakeReason(sessionCount: 2, source: .ac)))
    }

    @Test func expiredBusyLeaseDoesNotCount() {
        let staleBusy = busyLease("b", at: t0)
        let freshWaiting = waitingLease("w", since: t0.plus(minutes: 12))
        let d = decide([staleBusy, freshWaiting], power: approvedAC, prefs: lidPrefs, now: t0.plus(minutes: 13))
        #expect(d == .stayAwake(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func fairThermalStillEngages() {
        let power = PowerState(source: .ac, thermal: .fair, lidHelperApproved: true)
        #expect(decide(power: power, prefs: lidPrefs) == .stayAwakeLidClosed(AwakeReason(sessionCount: 1, source: .ac)))
    }

    @Test func seriousThermalAllowsSleep() {
        let power = PowerState(source: .ac, thermal: .serious, lidHelperApproved: true)
        #expect(decide(power: power, prefs: lidPrefs) == .allowSleep(.thermal(.serious)))
    }

    /// With the default floors (50 / 30), rule 3 always wins first on battery.
    @Test func batteryFloorStillAppliesFirst() {
        let power = PowerState(source: .battery(percent: 40), lidHelperApproved: true)
        #expect(decide(power: power, prefs: lidPrefs) == .allowSleep(.batteryLow(percent: 40)))
    }

    @Test(arguments: [(29, false), (30, true), (31, true), (100, true)])
    func lidBatteryFloor(_ percent: Int, engages: Bool) {
        // Lower the general floor so only the lid floor is in play.
        let prefs = Prefs(batteryFloorPercent: 10, lidClosedModeEnabled: true, lidClosedBatteryFloorPercent: 30)
        let power = PowerState(source: .battery(percent: percent), lidHelperApproved: true)
        let reason = AwakeReason(sessionCount: 1, source: .battery(percent: percent))
        #expect(decide(power: power, prefs: prefs) == (engages ? .stayAwakeLidClosed(reason) : .stayAwake(reason)))
    }

    @Test func lowPowerModeOnBatteryBlocksLidClosed() {
        let prefs = Prefs(batteryFloorPercent: 10, lidClosedModeEnabled: true)
        let power = PowerState(source: .battery(percent: 90), lowPowerMode: true, lidHelperApproved: true)
        #expect(decide(power: power, prefs: prefs) == .allowSleep(.lowPowerMode))
    }

    @Test func keepAwakeOffBeatsLidClosed() {
        let prefs = Prefs(keepAwakeEnabled: false, lidClosedModeEnabled: true)
        #expect(decide(power: approvedAC, prefs: prefs) == .allowSleep(.keepAwakeOff))
    }
}

@Suite("Summaries")
struct SummaryTests {
    @Test func summaries() {
        #expect(Decision.allowSleep(.noLeases).summary == "Asleep: no agents")
        #expect(Decision.stayAwake(AwakeReason(sessionCount: 2, source: .ac)).summary == "Awake: 2 agents · on AC")
        #expect(Decision.stayAwake(AwakeReason(sessionCount: 1, source: .battery(percent: 80))).summary == "Awake: 1 agent · on battery 80%")
        #expect(Decision.stayAwakeLidClosed(AwakeReason(sessionCount: 1, source: .ac)).summary == "Awake, lid closed: 1 agent · on AC")
        #expect(Decision.allowSleep(.batteryLow(percent: 42)).summary == "Letting Mac sleep: battery 42%")
    }
}
