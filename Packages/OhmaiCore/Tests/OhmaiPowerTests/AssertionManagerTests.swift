import Foundation
import Testing
import OhmaiCore
@testable import OhmaiPower

final class FakeAssertions: PowerAssertions {
    enum Call: Equatable {
        case create(AssertionKind, String, UInt32)
        case release(UInt32)
    }

    private(set) var calls: [Call] = []
    private(set) var live: Set<UInt32> = []
    var failNextCreate = false
    private var nextId: UInt32 = 1

    func create(_ kind: AssertionKind, reason: String) throws -> AssertionToken {
        if failNextCreate {
            failNextCreate = false
            throw AssertionError(code: 42)
        }
        let id = nextId
        nextId += 1
        live.insert(id)
        calls.append(.create(kind, reason, id))
        return AssertionToken(rawValue: id)
    }

    func release(_ token: AssertionToken) {
        live.remove(token.rawValue)
        calls.append(.release(token.rawValue))
    }
}

private func awake(_ n: Int) -> Decision { .stayAwake(AwakeReason(sessionCount: n, source: .ac)) }

@MainActor
@Suite("AssertionManager")
struct AssertionManagerTests {
    let fake = FakeAssertions()
    let manager: AssertionManager

    init() { manager = AssertionManager(assertions: fake) }

    @Test func stayAwakeHoldsIdleSleepAssertion() {
        manager.apply(awake(2), keepDisplayAwake: false)
        #expect(fake.calls == [.create(.preventIdleSystemSleep, "ohmai: 2 agent session(s) active", 1)])
        #expect(manager.isHolding(.preventIdleSystemSleep))
        #expect(!manager.isHolding(.preventIdleDisplaySleep))
    }

    @Test func sameDecisionIsIdempotent() {
        manager.apply(awake(1), keepDisplayAwake: false)
        manager.apply(awake(1), keepDisplayAwake: false)
        #expect(fake.calls.count == 1)
    }

    @Test func reasonChangeReplacesWithoutGap() {
        manager.apply(awake(1), keepDisplayAwake: false)
        manager.apply(awake(2), keepDisplayAwake: false)
        #expect(fake.calls == [
            .create(.preventIdleSystemSleep, "ohmai: 1 agent session(s) active", 1),
            .create(.preventIdleSystemSleep, "ohmai: 2 agent session(s) active", 2),
            .release(1),
        ])
        #expect(fake.live == [2])
    }

    @Test func allowSleepReleases() {
        manager.apply(awake(1), keepDisplayAwake: true)
        manager.apply(.allowSleep(.noLeases), keepDisplayAwake: true)
        #expect(fake.live.isEmpty)
        #expect(!manager.isHolding(.preventIdleSystemSleep))
    }

    @Test func displayAssertionFollowsPref() {
        manager.apply(awake(1), keepDisplayAwake: true)
        #expect(manager.isHolding(.preventIdleDisplaySleep))
        manager.apply(awake(1), keepDisplayAwake: false)
        #expect(!manager.isHolding(.preventIdleDisplaySleep))
        #expect(manager.isHolding(.preventIdleSystemSleep))
        #expect(fake.live.count == 1)
    }

    @Test func lidClosedHoldsIdleAssertionUntilHelperExists() {
        manager.apply(.stayAwakeLidClosed(AwakeReason(sessionCount: 1, source: .ac)), keepDisplayAwake: false)
        #expect(manager.isHolding(.preventIdleSystemSleep))
    }

    @Test func createFailureIsReportedAndRetried() {
        fake.failNextCreate = true
        manager.apply(awake(1), keepDisplayAwake: false)
        #expect(manager.lastError == AssertionError(code: 42))
        #expect(!manager.isHolding(.preventIdleSystemSleep))

        manager.apply(awake(1), keepDisplayAwake: false)
        #expect(manager.lastError == nil)
        #expect(manager.isHolding(.preventIdleSystemSleep))
    }

    @Test func failedReplacementKeepsOldAssertion() {
        manager.apply(awake(1), keepDisplayAwake: false)
        fake.failNextCreate = true
        manager.apply(awake(2), keepDisplayAwake: false)
        #expect(manager.reason(for: .preventIdleSystemSleep) == "ohmai: 1 agent session(s) active")
        #expect(fake.live == [1])
    }

    @Test func releaseAllReleasesEverything() {
        manager.apply(awake(3), keepDisplayAwake: true)
        manager.releaseAll()
        #expect(fake.live.isEmpty)
    }
}
