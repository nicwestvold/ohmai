import Foundation
import Synchronization
import Testing
@testable import OhmaiLidHelperCore

/// Counts calls from any thread.
final class Counter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@MainActor
@Suite("LidService: stale binary")
struct LidServiceTests {
    let sleep = FakeSleepSetting()

    func makeService(stale: Bool, restarts: Counter) -> LidService {
        let runtime = LidRuntime(controller: LidController(sleep: sleep, power: FakePower()))
        return LidService(
            runtime: runtime, helperVersion: "12",
            staleBinary: { stale }, restart: { restarts.bump() })
    }

    /// Lets queued `DispatchQueue.main.async` work run.
    func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test func currentBinaryServesRequests() async {
        let restarts = Counter(), replies = Counter()
        let service = makeService(stale: false, restarts: restarts)
        service.version { #expect($0 == "12"); replies.bump() }
        service.engage(leaseSeconds: 90, batteryFloorPercent: 30) { ok, _ in #expect(ok); replies.bump() }
        await drainMain()
        #expect(replies.count == 2)
        #expect(restarts.count == 0)
        #expect(sleep.history == [true])
    }

    /// The restart happens on a request, which XPC only delivers from a signature-checked
    /// caller; it never touches `disablesleep` itself (the restart path turns sleep back on).
    @Test func staleBinaryRestartsInsteadOfServing() async {
        let restarts = Counter(), replies = Counter()
        let service = makeService(stale: true, restarts: restarts)
        service.version { _ in replies.bump() }
        service.engage(leaseSeconds: 90, batteryFloorPercent: 30) { _, _ in replies.bump() }
        await drainMain()
        #expect(replies.count == 0)
        #expect(restarts.count == 2)
        #expect(sleep.history.isEmpty)
    }
}
