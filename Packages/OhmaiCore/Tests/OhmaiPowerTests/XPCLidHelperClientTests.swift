import Foundation
import Testing
@testable import OhmaiPower

/// Drives the real XPC client and cuts its connection mid-request, as unregistering the
/// helper does. XPC then reports the failure through the error handler, on its own queue.
/// Regression test for a crash: that handler inherited main-actor isolation and Swift's
/// runtime isolation check trapped.
@MainActor
@Suite("XPCLidHelperClient connection failures")
struct XPCLidHelperClientTests {
    @Test func connectionCutMidRequestFailsInsteadOfCrashing() async throws {
        let client = XPCLidHelperClient(teamID: "ABCDE12345")
        let pending = Task { await client.release() }
        try await Task.sleep(for: .milliseconds(200))
        client.invalidateConnection()
        let start = ContinuousClock.now
        #expect(await pending.value == false)
        // Failed through the error handler, not the 5 s reply timeout.
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func invalidTeamIDNeverConnects() async {
        let client = XPCLidHelperClient(teamID: "not-a-team")
        let result = await client.engage(leaseSeconds: 90, batteryFloorPercent: 30)
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error == .misconfigured)
    }
}
