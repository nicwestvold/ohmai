import Foundation
import Observation
import OhmaiCore
import OhmaiLidXPC

/// Drives the lid helper from the policy's `Decision`: engage on `.stayAwakeLidClosed`,
/// renew every 30s while it holds, release as soon as it doesn't.
///
/// The app is the convenience; the helper is the safety. If the app stalls, the helper's
/// 90s lease runs out and it turns sleep back on by itself.
@MainActor
@Observable
public final class LidSession {
    public private(set) var isEngaged = false
    public private(set) var lastError: LidHelperError?

    @ObservationIgnored private let client: any LidHelperClient
    @ObservationIgnored private let renewInterval: Duration
    @ObservationIgnored private var wantEngaged = false
    @ObservationIgnored private var batteryFloorPercent = 30
    @ObservationIgnored private var renewLoop: Task<Void, Never>?
    /// Operations run strictly in order, so an engage can't overtake a release.
    @ObservationIgnored private var tail: Task<Void, Never>?

    public init(client: any LidHelperClient, renewInterval: Duration = LidHelperXPC.renewInterval) {
        self.client = client
        self.renewInterval = renewInterval
    }

    public func apply(_ decision: Decision, batteryFloorPercent: Int) {
        let want = if case .stayAwakeLidClosed = decision { true } else { false }
        self.batteryFloorPercent = batteryFloorPercent
        guard want != wantEngaged else { return }
        wantEngaged = want
        if want {
            startRenewLoop()
        } else {
            renewLoop?.cancel()
            renewLoop = nil
        }
        enqueue { await $0.reconcile() }
    }

    /// Waits until queued helper calls have finished. For tests and shutdown.
    public func settle() async {
        while let current = tail {
            await current.value
            if tail == current { break }
        }
    }

    /// One renew-loop step; exposed so tests don't wait on real time.
    func tick() async {
        enqueue { await $0.reconcile() }
        await settle()
    }

    private func reconcile() async {
        switch (wantEngaged, isEngaged) {
        case (true, false):
            switch await client.engage(leaseSeconds: LidHelperXPC.leaseSeconds, batteryFloorPercent: batteryFloorPercent) {
            case .success:
                isEngaged = true
                lastError = nil
            case .failure(let error):
                lastError = error
            }
        case (true, true):
            if await !client.renew(leaseSeconds: LidHelperXPC.leaseSeconds, batteryFloorPercent: batteryFloorPercent) {
                // The helper released (guard, restart or expiry). Try to re-engage next tick.
                isEngaged = false
            }
        case (false, true):
            // Even if this fails, the helper's lease expires on its own.
            _ = await client.release()
            isEngaged = false
        case (false, false):
            break
        }
    }

    private func enqueue(_ op: @escaping @MainActor (LidSession) async -> Void) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await op(self)
        }
    }

    private func startRenewLoop() {
        renewLoop?.cancel()
        let interval = renewInterval
        renewLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.enqueue { await $0.reconcile() }
            }
        }
    }
}
