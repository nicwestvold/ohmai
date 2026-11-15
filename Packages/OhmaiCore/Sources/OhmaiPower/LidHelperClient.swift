import Foundation
import OhmaiLidXPC
import Synchronization

public enum LidHelperError: Error, Equatable, CustomStringConvertible {
    case refused(String)
    case unreachable
    case timedOut
    case misconfigured

    public var description: String {
        switch self {
        case .refused(let reason): "Lid helper refused: \(reason)"
        case .unreachable: "Lid helper isn't reachable"
        case .timedOut: "Lid helper didn't respond"
        case .misconfigured: "This build has no valid team ID"
        }
    }
}

/// The app's view of the lid helper. Faked in tests.
@MainActor
public protocol LidHelperClient: AnyObject {
    func engage(leaseSeconds: Int, batteryFloorPercent: Int) async -> Result<Void, LidHelperError>
    func renew(leaseSeconds: Int, batteryFloorPercent: Int) async -> Bool
    func release() async -> Bool
    func version() async -> String?
}

/// Talks to the privileged helper over XPC, and checks that the helper is ours too.
@MainActor
public final class XPCLidHelperClient: LidHelperClient {
    private let requirement: String?
    private var connection: NSXPCConnection?
    private static let replyTimeout: Duration = .seconds(5)

    /// `teamID` comes from Info.plist (`OHMAITeamID`), never from code.
    public init(teamID: String) {
        requirement = LidHelperXPC.requirement(identifier: LidHelperXPC.helperBundleID, teamID: teamID)
    }

    public func engage(leaseSeconds: Int, batteryFloorPercent: Int) async -> Result<Void, LidHelperError> {
        let result: Result<(Bool, String?), LidHelperError> = await call { proxy, done in
            proxy.engage(leaseSeconds: leaseSeconds, batteryFloorPercent: batteryFloorPercent) { done(.success(($0, $1))) }
        }
        switch result {
        case .success((true, _)): return .success(())
        case .success((false, let reason)): return .failure(.refused(reason ?? "unknown"))
        case .failure(let error): return .failure(error)
        }
    }

    public func renew(leaseSeconds: Int, batteryFloorPercent: Int) async -> Bool {
        let result: Result<Bool, LidHelperError> = await call { proxy, done in
            proxy.renew(leaseSeconds: leaseSeconds, batteryFloorPercent: batteryFloorPercent) { done(.success($0)) }
        }
        return (try? result.get()) ?? false
    }

    public func release() async -> Bool {
        let result: Result<Bool, LidHelperError> = await call { proxy, done in
            proxy.release { done(.success($0)) }
        }
        return (try? result.get()) ?? false
    }

    public func version() async -> String? {
        let result: Result<String, LidHelperError> = await call { proxy, done in
            proxy.version { done(.success($0)) }
        }
        return try? result.get()
    }

    /// One request with an error handler and a timeout; resumes exactly once.
    private func call<T: Sendable>(
        _ body: (LidHelperProtocol, @escaping @Sendable (Result<T, LidHelperError>) -> Void) -> Void
    ) async -> Result<T, LidHelperError> {
        guard let connection = currentConnection() else { return .failure(.misconfigured) }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            // XPC calls this on its own queue. `@Sendable` keeps it from inheriting this type's
            // main-actor isolation, which Swift 6 checks at runtime and traps on (it crashed
            // the app when the helper was unregistered mid-connection).
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(.failure(.unreachable)) }
            guard let helper = proxy as? LidHelperProtocol else {
                once.resume(.failure(.unreachable))
                return
            }
            body(helper) { once.resume($0) }
            Task {
                try? await Task.sleep(for: Self.replyTimeout)
                once.resume(.failure(.timedOut))
            }
        }
    }

    /// Test hook: cut the connection, as unregistering the helper does, so pending requests
    /// fail through XPC's error handler.
    func invalidateConnection() {
        connection?.invalidate()
    }

    private func currentConnection() -> NSXPCConnection? {
        if let connection { return connection }
        guard let requirement else { return nil }
        let c = NSXPCConnection(machServiceName: LidHelperXPC.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: LidHelperProtocol.self)
        c.setCodeSigningRequirement(requirement)
        // Also called on an XPC queue: not main-actor code (see `call`).
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }
}

/// Resumes a continuation at most once, from whichever path gets there first.
private final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = Mutex(continuation) }
    func resume(_ value: T) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}
