import Foundation
import IOKit.pwr_mgt
import OhmaiCore

public enum AssertionKind: Sendable, Hashable, CaseIterable {
    case preventIdleSystemSleep
    case preventIdleDisplaySleep
}

public struct AssertionToken: Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

/// The OS-level power assertion API. Faked in tests: tests never change real power state.
public protocol PowerAssertions {
    func create(_ kind: AssertionKind, reason: String) throws -> AssertionToken
    func release(_ token: AssertionToken)
}

public struct AssertionError: Error, Equatable {
    public let code: Int32
}

/// Turns a `Decision` into held or released power assertions.
///
/// Lid-closed mode (the lid helper) arrives in build step 2. Until then
/// `.stayAwakeLidClosed` holds the same idle-sleep assertion as `.stayAwake`.
@MainActor
public final class AssertionManager {
    private struct Held { let token: AssertionToken; let reason: String }

    private let assertions: any PowerAssertions
    private var held: [AssertionKind: Held] = [:]
    public private(set) var lastError: AssertionError?

    public init(assertions: any PowerAssertions = IOKitPowerAssertions()) {
        self.assertions = assertions
    }

    public func isHolding(_ kind: AssertionKind) -> Bool { held[kind] != nil }
    public func reason(for kind: AssertionKind) -> String? { held[kind]?.reason }

    public func apply(_ decision: Decision, keepDisplayAwake: Bool) {
        var wanted: [AssertionKind: String] = [:]
        switch decision {
        case .allowSleep:
            break
        case .stayAwake(let r), .stayAwakeLidClosed(let r):
            let reason = "ohmai: \(r.sessionCount) agent session(s) active"
            wanted[.preventIdleSystemSleep] = reason
            if keepDisplayAwake { wanted[.preventIdleDisplaySleep] = reason }
        }

        // Release first: when in doubt, release.
        for (kind, h) in held where wanted[kind] == nil {
            assertions.release(h.token)
            held[kind] = nil
        }
        // Create or replace. A replacement is created before the old one is released, so
        // there's no gap in which the Mac could idle-sleep.
        lastError = nil
        for (kind, reason) in wanted where held[kind]?.reason != reason {
            do {
                let token = try assertions.create(kind, reason: reason)
                if let old = held[kind] { assertions.release(old.token) }
                held[kind] = Held(token: token, reason: reason)
            } catch {
                lastError = error as? AssertionError ?? AssertionError(code: -1)
            }
        }
    }

    public func releaseAll() {
        apply(.allowSleep(.keepAwakeOff), keepDisplayAwake: false)
    }
}

/// The real IOPMAssertion implementation.
public struct IOKitPowerAssertions: PowerAssertions {
    public init() {}

    public func create(_ kind: AssertionKind, reason: String) throws -> AssertionToken {
        let type = switch kind {
        case .preventIdleSystemSleep: kIOPMAssertionTypePreventUserIdleSystemSleep
        case .preventIdleDisplaySleep: kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else { throw AssertionError(code: result) }
        return AssertionToken(rawValue: id)
    }

    public func release(_ token: AssertionToken) {
        IOPMAssertionRelease(token.rawValue)
    }
}
