import Foundation
import Testing
import OhmaiCore
@testable import OhmaiPower

@MainActor
final class FakeLidClient: LidHelperClient {
    enum Call: Equatable { case engage(Int), renew(Int), release }
    private(set) var calls: [Call] = []
    var engageResult: Result<Void, LidHelperError> = .success(())
    var renewResult = true

    func engage(leaseSeconds: Int, batteryFloorPercent: Int) async -> Result<Void, LidHelperError> {
        calls.append(.engage(batteryFloorPercent))
        return engageResult
    }
    func renew(leaseSeconds: Int, batteryFloorPercent: Int) async -> Bool {
        calls.append(.renew(batteryFloorPercent))
        return renewResult
    }
    func release() async -> Bool {
        calls.append(.release)
        return true
    }
    func version() async -> String? { "1" }
}

private let lidClosed = Decision.stayAwakeLidClosed(AwakeReason(sessionCount: 1, source: .ac))
private let awake = Decision.stayAwake(AwakeReason(sessionCount: 1, source: .ac))

@MainActor
@Suite("LidSession")
struct LidSessionTests {
    let client = FakeLidClient()
    let session: LidSession

    // A long interval so the real renew loop never fires during a test.
    init() { session = LidSession(client: client, renewInterval: .seconds(3600)) }

    @Test func lidClosedDecisionEngages() async {
        session.apply(lidClosed, batteryFloorPercent: 30)
        await session.settle()
        #expect(client.calls == [.engage(30)])
        #expect(session.isEngaged)
    }

    @Test func otherDecisionsNeverEngage() async {
        session.apply(awake, batteryFloorPercent: 30)
        session.apply(.allowSleep(.noLeases), batteryFloorPercent: 30)
        await session.settle()
        #expect(client.calls.isEmpty)
    }

    @Test func leavingLidClosedReleasesImmediately() async {
        session.apply(lidClosed, batteryFloorPercent: 30)
        await session.settle()
        session.apply(awake, batteryFloorPercent: 30)
        await session.settle()
        #expect(client.calls == [.engage(30), .release])
        #expect(!session.isEngaged)
    }

    /// Queued work acts on the latest decision, so a quick flip-flop never touches pmset.
    @Test func flipFlopBeforeHelperRepliesDoesNothing() async {
        session.apply(lidClosed, batteryFloorPercent: 30)
        session.apply(awake, batteryFloorPercent: 30)
        await session.settle()
        #expect(client.calls.isEmpty)
        #expect(!session.isEngaged)
    }

    @Test func repeatedDecisionIsIdempotent() async {
        session.apply(lidClosed, batteryFloorPercent: 30)
        session.apply(lidClosed, batteryFloorPercent: 30)
        await session.settle()
        #expect(client.calls == [.engage(30)])
    }

    @Test func tickRenewsWithCurrentFloor() async {
        session.apply(lidClosed, batteryFloorPercent: 30)
        await session.settle()
        session.apply(lidClosed, batteryFloorPercent: 40)
        await session.tick()
        #expect(client.calls == [.engage(30), .renew(40)])
    }

    @Test func failedRenewReengagesOnNextTick() async {
        session.apply(lidClosed, batteryFloorPercent: 30)
        await session.settle()
        client.renewResult = false
        await session.tick()
        #expect(!session.isEngaged)
        await session.tick()
        #expect(client.calls == [.engage(30), .renew(30), .engage(30)])
        #expect(session.isEngaged)
    }

    @Test func refusalIsReportedAndRetried() async {
        client.engageResult = .failure(.refused("battery 20% is below 30%"))
        session.apply(lidClosed, batteryFloorPercent: 30)
        await session.settle()
        #expect(!session.isEngaged)
        #expect(session.lastError == .refused("battery 20% is below 30%"))

        client.engageResult = .success(())
        await session.tick()
        #expect(session.isEngaged)
        #expect(session.lastError == nil)
    }

    @Test func tickDoesNothingWhenNotWanted() async {
        await session.tick()
        #expect(client.calls.isEmpty)
    }
}
