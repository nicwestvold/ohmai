import Foundation
import OhmaiLidXPC
import os

let log = Logger(subsystem: LidHelperXPC.helperBundleID, category: "helper")

/// Owns the controller and its tick timer. Main actor only.
@MainActor
public final class LidRuntime {
    public let controller: LidController
    private var timer: DispatchSourceTimer?

    /// How often guards and lease expiry are checked while engaged.
    static let tickInterval: DispatchTimeInterval = .seconds(5)

    public init(controller: LidController) {
        self.controller = controller
    }

    public func start() {
        controller.start()
        log.notice("started; disablesleep reset to 0 (pending retry: \(self.controller.resetPending))")
        updateTimer()
    }

    /// Called on SIGTERM and on any fatal path: sleep must be back on before we go.
    public func shutdown() {
        controller.release()
        log.notice("shutting down; released")
    }

    func perform<T>(_ body: (LidController, Date) -> T) -> T {
        let wasEngaged = controller.isEngaged
        let result = body(controller, .now)
        if wasEngaged != controller.isEngaged {
            log.notice("engaged: \(self.controller.isEngaged)")
        }
        updateTimer()
        return result
    }

    private func updateTimer() {
        guard controller.needsTicking else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.perform { controller, now in controller.tick(now: now) }
            }
        }
        t.resume()
        timer = t
    }
}

/// The exported XPC object. Calls arrive on XPC's queue and hop to the main actor.
public final class LidService: NSObject, LidHelperProtocol, Sendable {
    private let runtime: LidRuntime
    private let helperVersion: String

    public init(runtime: LidRuntime, helperVersion: String) {
        self.runtime = runtime
        self.helperVersion = helperVersion
    }

    public func engage(leaseSeconds: Int, batteryFloorPercent: Int, reply: @escaping @Sendable (Bool, String?) -> Void) {
        onMain { runtime in
            let refusal = runtime.perform { c, now in
                c.engage(leaseSeconds: leaseSeconds, batteryFloorPercent: batteryFloorPercent, now: now)
            }
            if let refusal { log.notice("engage refused: \(refusal.description)") }
            reply(refusal == nil, refusal?.description)
        }
    }

    public func renew(leaseSeconds: Int, batteryFloorPercent: Int, reply: @escaping @Sendable (Bool) -> Void) {
        onMain { runtime in
            reply(runtime.perform { c, now in
                c.renew(leaseSeconds: leaseSeconds, batteryFloorPercent: batteryFloorPercent, now: now)
            })
        }
    }

    public func release(reply: @escaping @Sendable (Bool) -> Void) {
        onMain { runtime in reply(runtime.perform { c, _ in c.release() }) }
    }

    public func status(reply: @escaping @Sendable (Bool, Date?) -> Void) {
        onMain { runtime in reply(runtime.controller.isEngaged, runtime.controller.expiresAt) }
    }

    public func version(reply: @escaping @Sendable (String) -> Void) {
        reply(helperVersion)
    }

    private func onMain(_ body: @escaping @MainActor @Sendable (LidRuntime) -> Void) {
        let runtime = runtime
        DispatchQueue.main.async { MainActor.assumeIsolated { body(runtime) } }
    }
}

/// Accepts connections only from ohmai itself, matched by code-signing requirement.
public final class LidListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let service: LidService
    private let requirement: String

    public init(service: LidService, requirement: String) {
        self.service = service
        self.requirement = requirement
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: LidHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
