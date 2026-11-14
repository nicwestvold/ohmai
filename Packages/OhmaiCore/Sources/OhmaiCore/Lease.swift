import Foundation

/// A time-boxed claim to stay awake, renewed by signals from a busy or waiting session.
///
/// Every lease expires: a busy lease when signals stop for `Prefs.signalTimeout`, a waiting
/// lease at the earlier of that and `Prefs.waitingCap` after waiting started.
/// Pid liveness and start-time checks are layered on by the session registry (build step 3).
public struct Lease: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case busy
        case waiting(since: Date)
    }

    public let session: SessionKey
    public var kind: Kind
    public let grantedAt: Date
    public var lastSignalAt: Date

    public init(session: SessionKey, kind: Kind, grantedAt: Date, lastSignalAt: Date) {
        self.session = session
        self.kind = kind
        self.grantedAt = grantedAt
        self.lastSignalAt = lastSignalAt
    }

    public var isBusy: Bool { kind == .busy }

    public func expiresAt(prefs: Prefs) -> Date {
        let signalExpiry = lastSignalAt.addingTimeInterval(prefs.signalTimeout)
        switch kind {
        case .busy:
            return signalExpiry
        case .waiting(let since):
            return min(signalExpiry, since.addingTimeInterval(prefs.waitingCap))
        }
    }

    public func isActive(at now: Date, prefs: Prefs) -> Bool {
        now < expiresAt(prefs: prefs)
    }
}

/// The set of current leases, keyed by session. A pure value type: feed it events and a clock.
public struct LeaseBook: Sendable, Equatable {
    public private(set) var leasesBySession: [SessionKey: Lease] = [:]

    public init() {}

    /// Leases in a stable order (oldest grant first).
    public var leases: [Lease] {
        leasesBySession.values.sorted {
            ($0.grantedAt, $0.session.sessionId) < ($1.grantedAt, $1.session.sessionId)
        }
    }

    /// Applies an event. Timestamps in the future are clamped to `now`, so a skewed clock
    /// can't stretch a lease. `idle` and `gone` always release, even if out of order:
    /// when in doubt, release.
    public mutating func apply(_ event: ActivityEvent, now: Date) {
        let at = min(event.at, now)
        let key = event.session

        switch event.activity {
        case .idle, .gone:
            leasesBySession[key] = nil

        case .busy, .waiting:
            guard var lease = leasesBySession[key] else {
                let kind: Lease.Kind = event.activity == .busy ? .busy : .waiting(since: at)
                leasesBySession[key] = Lease(session: key, kind: kind, grantedAt: at, lastSignalAt: at)
                return
            }
            // Ignore stale, out-of-order signals.
            guard at >= lease.lastSignalAt else { return }
            lease.lastSignalAt = at
            switch (lease.kind, event.activity) {
            case (.waiting, .waiting):
                break  // keep the original `since`: the cap counts from when waiting started
            case (_, .waiting):
                lease.kind = .waiting(since: at)
            default:
                lease.kind = .busy
            }
            leasesBySession[key] = lease
        }
    }

    /// Removes expired leases and returns them.
    @discardableResult
    public mutating func prune(at now: Date, prefs: Prefs) -> [Lease] {
        let expired = leasesBySession.values.filter { !$0.isActive(at: now, prefs: prefs) }
        for lease in expired { leasesBySession[lease.session] = nil }
        return expired
    }
}
