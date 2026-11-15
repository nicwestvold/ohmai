import Foundation
import Testing
@testable import OhmaiCore

private func event(_ activity: Activity, _ id: String = "s1", at: Date, agent: Agent = .claude) -> ActivityEvent {
    ActivityEvent(session: key(id, agent: agent), activity: activity, at: at)
}

@Suite("LeaseBook")
struct LeaseBookTests {
    @Test func busyGrantsLease() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0), now: t0)
        #expect(book.leases == [busyLease()])
        #expect(book.leases[0].expiresAt(prefs: .default) == t0.plus(minutes: 10))
    }

    @Test func waitingGrantsCappedLease() {
        var book = LeaseBook()
        book.apply(event(.waiting, at: t0), now: t0)
        #expect(book.leases == [waitingLease()])
    }

    @Test func busyRenewsLease() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0), now: t0)
        book.apply(event(.busy, at: t0.plus(minutes: 8)), now: t0.plus(minutes: 8))
        let lease = book.leases[0]
        #expect(lease.grantedAt == t0)
        #expect(lease.expiresAt(prefs: .default) == t0.plus(minutes: 18))
    }

    @Test(arguments: [Activity.idle, .gone])
    func idleAndGoneRelease(_ activity: Activity) {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0), now: t0)
        book.apply(event(activity, at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(book.leases.isEmpty)
    }

    @Test func outOfOrderIdleStillReleases() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0.plus(minutes: 5)), now: t0.plus(minutes: 5))
        book.apply(event(.idle, at: t0), now: t0.plus(minutes: 5))
        #expect(book.leases.isEmpty)
    }

    @Test func idleForUnknownSessionIsHarmless() {
        var book = LeaseBook()
        book.apply(event(.idle, at: t0), now: t0)
        #expect(book.leases.isEmpty)
    }

    @Test func busyToWaitingStartsCap() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0), now: t0)
        book.apply(event(.waiting, at: t0.plus(minutes: 3)), now: t0.plus(minutes: 3))
        #expect(book.leases[0].kind == .waiting(since: t0.plus(minutes: 3)))
    }

    @Test func repeatedWaitingKeepsOriginalSince() {
        var book = LeaseBook()
        book.apply(event(.waiting, at: t0), now: t0)
        for minute in stride(from: 5.0, through: 55.0, by: 5.0) {
            book.apply(event(.waiting, at: t0.plus(minutes: minute)), now: t0.plus(minutes: minute))
        }
        let lease = book.leases[0]
        #expect(lease.kind == .waiting(since: t0))
        #expect(lease.expiresAt(prefs: .default) == t0.plus(minutes: 60))
        #expect(!lease.isActive(at: t0.plus(minutes: 60), prefs: .default))
    }

    @Test func waitingToBusyClearsCap() {
        var book = LeaseBook()
        book.apply(event(.waiting, at: t0), now: t0)
        book.apply(event(.busy, at: t0.plus(minutes: 58)), now: t0.plus(minutes: 58))
        let lease = book.leases[0]
        #expect(lease.kind == .busy)
        #expect(lease.isActive(at: t0.plus(minutes: 65), prefs: .default))
    }

    @Test func waitingAgainAfterBusyRestartsCap() {
        var book = LeaseBook()
        book.apply(event(.waiting, at: t0), now: t0)
        book.apply(event(.busy, at: t0.plus(minutes: 30)), now: t0.plus(minutes: 30))
        book.apply(event(.waiting, at: t0.plus(minutes: 40)), now: t0.plus(minutes: 40))
        #expect(book.leases[0].kind == .waiting(since: t0.plus(minutes: 40)))
    }

    @Test func futureTimestampsAreClampedToNow() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0.plus(minutes: 600)), now: t0)
        #expect(book.leases[0].lastSignalAt == t0)
        #expect(!book.leases[0].isActive(at: t0.plus(minutes: 10), prefs: .default))
    }

    @Test func staleSignalIsIgnored() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0.plus(minutes: 5)), now: t0.plus(minutes: 5))
        book.apply(event(.waiting, at: t0), now: t0.plus(minutes: 6))
        let lease = book.leases[0]
        #expect(lease.kind == .busy)
        #expect(lease.lastSignalAt == t0.plus(minutes: 5))
    }

    @Test func sessionsAreIndependent() {
        var book = LeaseBook()
        book.apply(event(.busy, "a", at: t0), now: t0)
        book.apply(event(.busy, "b", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        book.apply(event(.idle, "a", at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        #expect(book.leases.map(\.session.sessionId) == ["b"])
    }

    @Test func sameSessionIdOnDifferentAgentsIsDistinct() {
        var book = LeaseBook()
        book.apply(event(.busy, "x", at: t0, agent: .claude), now: t0)
        book.apply(event(.busy, "x", at: t0, agent: .codex), now: t0)
        #expect(book.leases.count == 2)
    }

    @Test func pruneRemovesOnlyExpired() {
        var book = LeaseBook()
        book.apply(event(.busy, "old", at: t0), now: t0)
        book.apply(event(.busy, "new", at: t0.plus(minutes: 8)), now: t0.plus(minutes: 8))
        let removed = book.prune(at: t0.plus(minutes: 10), prefs: .default)
        #expect(removed.map(\.session.sessionId) == ["old"])
        #expect(book.leases.map(\.session.sessionId) == ["new"])
    }

    @Test func leasesAreOrderedByGrant() {
        var book = LeaseBook()
        book.apply(event(.busy, "c", at: t0.plus(minutes: 2)), now: t0.plus(minutes: 2))
        book.apply(event(.busy, "a", at: t0), now: t0.plus(minutes: 2))
        book.apply(event(.busy, "b", at: t0.plus(minutes: 1)), now: t0.plus(minutes: 2))
        #expect(book.leases.map(\.session.sessionId) == ["a", "b", "c"])
    }

    @Test func nextExpiryIsNilWithNoLeases() {
        #expect(LeaseBook().nextExpiry(prefs: .default) == nil)
    }

    @Test func nextExpiryIsTheEarliestLease() {
        var book = LeaseBook()
        book.apply(event(.busy, "late", at: t0.plus(minutes: 5)), now: t0.plus(minutes: 5))
        book.apply(event(.busy, "early", at: t0), now: t0.plus(minutes: 5))
        #expect(book.nextExpiry(prefs: .default) == t0.plus(minutes: 10))
    }

    @Test func nextExpiryHonoursWaitingCap() {
        var book = LeaseBook()
        book.apply(event(.waiting, at: t0), now: t0)
        book.apply(event(.waiting, at: t0.plus(minutes: 55)), now: t0.plus(minutes: 55))
        #expect(book.nextExpiry(prefs: .default) == t0.plus(minutes: 60))
    }

    @Test func nextExpiryIsNilAfterRelease() {
        var book = LeaseBook()
        book.apply(event(.busy, at: t0), now: t0)
        book.apply(event(.idle, at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(book.nextExpiry(prefs: .default) == nil)
    }
}

@Suite("LeaseBook project metadata")
struct LeaseProjectTests {
    @Test func projectIsKeptAndUpdated() {
        var book = LeaseBook()
        book.apply(ActivityEvent(session: key(), activity: .busy, at: t0, project: "/a"), now: t0)
        book.apply(ActivityEvent(session: key(), activity: .busy, at: t0.plus(minutes: 1)), now: t0.plus(minutes: 1))
        #expect(book.leases[0].project == "/a")
        book.apply(ActivityEvent(session: key(), activity: .waiting, at: t0.plus(minutes: 2), project: "/b"), now: t0.plus(minutes: 2))
        #expect(book.leases[0].project == "/b")
    }
}
