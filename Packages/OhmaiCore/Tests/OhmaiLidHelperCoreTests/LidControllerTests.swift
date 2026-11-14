import Foundation
import Testing
import OhmaiCore
import OhmaiLidXPC
@testable import OhmaiLidHelperCore

/// Records every `disablesleep` value and can fail on demand. Never touches the system.
final class FakeSleepSetting: SleepSetting {
    struct Boom: Error {}
    private(set) var history: [Bool] = []
    var failing = false

    /// What the system would currently report; nil until something was set.
    var current: Bool? { history.last }

    func setSleepDisabled(_ disabled: Bool) throws {
        if failing { throw Boom() }
        history.append(disabled)
    }
}

final class FakePower: PowerReading {
    var source: PowerSource = .ac
    var thermal: ThermalState = .nominal
    func read() -> (source: PowerSource, thermal: ThermalState) { (source, thermal) }
}

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@MainActor
@Suite("LidController: dead-man switch")
struct LidControllerTests {
    let sleep = FakeSleepSetting()
    let power = FakePower()
    let controller: LidController

    init() { controller = LidController(sleep: sleep, power: power) }

    @Test func startAlwaysResetsToZero() {
        controller.start()
        #expect(sleep.history == [false])
        #expect(!controller.isEngaged)
    }

    @Test func engageDisablesSleepWithLease() {
        #expect(controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0) == nil)
        #expect(sleep.current == true)
        #expect(controller.isEngaged)
        #expect(controller.expiresAt == t0.addingTimeInterval(90))
    }

    @Test func leaseExpiryReleases() {
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        controller.tick(now: t0.addingTimeInterval(89))
        #expect(controller.isEngaged)
        controller.tick(now: t0.addingTimeInterval(90))
        #expect(!controller.isEngaged)
        #expect(sleep.current == false)
    }

    @Test func renewExtendsLease() {
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        #expect(controller.renew(leaseSeconds: 90, batteryFloorPercent: 30, now: t0.addingTimeInterval(30)))
        controller.tick(now: t0.addingTimeInterval(100))
        #expect(controller.isEngaged)
        #expect(sleep.history == [true])  // renewing doesn't rerun pmset
    }

    @Test func renewNeverEngages() {
        #expect(!controller.renew(leaseSeconds: 90, batteryFloorPercent: 30, now: t0))
        #expect(sleep.history.isEmpty)
    }

    @Test func releaseTurnsSleepBackOn() {
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        #expect(controller.release())
        #expect(sleep.current == false)
        #expect(controller.expiresAt == nil)
    }

    @Test(arguments: [(-5, 1), (0, 1), (90, 90), (300, 300), (86_400, 300)])
    func leaseIsClamped(_ requested: Int, _ granted: Int) {
        _ = controller.engage(leaseSeconds: requested, batteryFloorPercent: 30, now: t0)
        #expect(controller.expiresAt == t0.addingTimeInterval(TimeInterval(granted)))
    }

    @Test func notTickingWhenIdle() {
        controller.start()
        #expect(!controller.needsTicking)
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        #expect(controller.needsTicking)
    }
}

@MainActor
@Suite("LidController: battery and thermal guards")
struct LidGuardTests {
    let sleep = FakeSleepSetting()
    let power = FakePower()
    let controller: LidController

    init() { controller = LidController(sleep: sleep, power: power) }

    @Test(arguments: [ThermalState.serious, .critical])
    func hotRefusesEngage(_ thermal: ThermalState) {
        power.thermal = thermal
        #expect(controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0) == .thermal(thermal))
        #expect(sleep.history.isEmpty)
    }

    @Test func gettingHotWhileEngagedReleasesOnTick() {
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        power.thermal = .serious
        controller.tick(now: t0.addingTimeInterval(5))
        #expect(!controller.isEngaged)
        #expect(sleep.current == false)
    }

    @Test(arguments: [(29, false), (30, true), (100, true)])
    func batteryFloor(_ percent: Int, engages: Bool) {
        power.source = .battery(percent: percent)
        let refusal = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        #expect((refusal == nil) == engages)
    }

    @Test func batteryDrainingWhileEngagedReleasesOnTick() {
        power.source = .battery(percent: 40)
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        power.source = .battery(percent: 29)
        controller.tick(now: t0.addingTimeInterval(5))
        #expect(!controller.isEngaged)
        #expect(sleep.current == false)
    }

    @Test func unpluggingBelowFloorReleasesOnRenew() {
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        power.source = .battery(percent: 10)
        #expect(!controller.renew(leaseSeconds: 90, batteryFloorPercent: 30, now: t0.addingTimeInterval(30)))
        #expect(sleep.current == false)
    }

    @Test func unknownChargeOrSourceRefuses() {
        power.source = .battery(percent: nil)
        #expect(controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0) == .batteryBelowFloor(percent: nil, floor: 30))
        power.source = .unknown
        #expect(controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0) == .powerSourceUnknown)
        #expect(sleep.history.allSatisfy { $0 == false })
    }

    @Test func appCannotLowerFloorBelowMinimum() {
        power.source = .battery(percent: 5)
        #expect(controller.engage(leaseSeconds: 90, batteryFloorPercent: 0, now: t0) == .batteryBelowFloor(percent: 5, floor: 10))
    }
}

@MainActor
@Suite("LidController: pmset failures")
struct LidFailureTests {
    let sleep = FakeSleepSetting()
    let power = FakePower()
    let controller: LidController

    init() { controller = LidController(sleep: sleep, power: power) }

    @Test func failedEngageIsNotEngaged() {
        sleep.failing = true
        #expect(controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0) == .sleepSettingFailed)
        #expect(!controller.isEngaged)
    }

    @Test func failedReleaseIsRetriedOnTick() {
        _ = controller.engage(leaseSeconds: 90, batteryFloorPercent: 30, now: t0)
        sleep.failing = true
        #expect(!controller.release())
        #expect(controller.resetPending)
        #expect(controller.needsTicking)

        controller.tick(now: t0.addingTimeInterval(5))
        #expect(controller.resetPending)

        sleep.failing = false
        controller.tick(now: t0.addingTimeInterval(10))
        #expect(!controller.resetPending)
        #expect(sleep.current == false)
        #expect(!controller.needsTicking)
    }

    @Test func failedStartupResetIsRetried() {
        sleep.failing = true
        controller.start()
        #expect(controller.needsTicking)
        sleep.failing = false
        controller.tick(now: t0)
        #expect(sleep.history == [false])
    }
}

@Suite("Code-signing requirement")
struct RequirementTests {
    @Test func buildsRequirementFromTeamID() {
        #expect(LidHelperXPC.requirement(identifier: "com.westvold.ohmai", teamID: "ABCDE12345")
            == "anchor apple generic and identifier \"com.westvold.ohmai\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    @Test(arguments: ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE\"1234", "$(OHMAI_TE", "ABCDÉ12345"])
    func invalidTeamIDFailsClosed(_ id: String) {
        #expect(LidHelperXPC.requirement(identifier: "com.westvold.ohmai", teamID: id) == nil)
    }
}
