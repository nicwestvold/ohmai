import Foundation
@testable import OhmaiCore

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

func key(_ id: String = "s1", agent: Agent = .claude, pid: Int32 = 100) -> SessionKey {
    SessionKey(agent: agent, sessionId: id, pid: pid)
}

func busyLease(_ id: String = "s1", at: Date = t0) -> Lease {
    Lease(session: key(id), kind: .busy, grantedAt: at, lastSignalAt: at)
}

func waitingLease(_ id: String = "s1", since: Date = t0, lastSignal: Date? = nil) -> Lease {
    Lease(session: key(id), kind: .waiting(since: since), grantedAt: since, lastSignalAt: lastSignal ?? since)
}

extension Date {
    func plus(minutes: Double) -> Date { addingTimeInterval(minutes * 60) }
}
