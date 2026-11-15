import Foundation
import Testing
import OhmaiAdapterSupport
import OhmaiCore
@testable import OhmaiCodexAdapter

private let session = "00000000-0000-7000-8000-000000000001"
private let path = "/Users/example/.codex/sessions/2026/11/14/rollout-2026-11-14T15-11-18-\(session).jsonl"

private func fixture(_ name: String, version: String = "codex-0.169.0") throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/\(version)"))
    return try Data(contentsOf: url)
}

private func rollout(_ name: String) throws -> CodexRollout {
    var r = CodexRollout()
    r.feed(try fixture(name))
    return r
}

@Suite("CodexRollout")
struct CodexRolloutTests {
    @Test func completedTurnIsClosed() throws {
        let r = try rollout("complete")
        #expect(r.sessionId == session)
        #expect(r.cwd == "/Users/example/projects/demo")
        #expect(!r.hasOpenTurn)
        #expect(r.unrecognizedLines == 0)
        #expect(r.lastEventAt != nil)
    }

    @Test func turnInProgressIsOpen() throws {
        #expect(try rollout("open-turn").hasOpenTurn)
    }

    @Test func abortedTurnIsClosed() throws {
        #expect(try !rollout("aborted").hasOpenTurn)
    }

    @Test func feedingInArbitraryChunksGivesTheSameResult() throws {
        let data = try fixture("open-turn")
        for size in [1, 7, 100, 4096] {
            var r = CodexRollout()
            var i = data.startIndex
            while i < data.endIndex {
                let end = data.index(i, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                r.feed(data[i..<end])
                i = end
            }
            #expect(r == (try rollout("open-turn")), "chunk size \(size)")
        }
    }

    @Test func incompleteTrailingLineWaitsForTheRest() throws {
        let data = try fixture("complete")
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var r = CodexRollout()
        r.feed(Data(lines.dropLast().joined(separator: [0x0A])) + Data([0x0A]))
        #expect(r.hasOpenTurn)
        let last = Data(lines.last!)
        r.feed(last.prefix(40))          // half a task_complete line
        #expect(r.hasOpenTurn)
        r.feed(last.dropFirst(40) + Data([0x0A]))
        #expect(!r.hasOpenTurn)
    }

    @Test func unknownLayoutIsCountedNotGuessed() {
        var r = CodexRollout()
        r.feed(Data(#"{"type":"event_msg","payload":{"type":"task_started"},"timestamp":"2026-11-14T20:11:18.952Z"}"#.utf8 + [0x0A]))
        #expect(!r.hasOpenTurn)
        #expect(r.unrecognizedLines == 1)
    }

    @Test func turnCountNeverGoesNegative() {
        var r = CodexRollout()
        let line = #"{"timestamp":"2026-11-14T20:11:18.952Z","ordinal":1,"type":"event_msg","payload":{"type":"task_complete"}}"#
        r.feed(Data((line + "\n" + line + "\n").utf8))
        #expect(r.openTurns == 0)
    }

    /// Privacy: a message whose text mentions a turn event must not be read as one.
    @Test func contentThatLooksLikeAnEventIsIgnored() {
        var r = CodexRollout()
        let line = #"{"timestamp":"2026-11-14T20:11:18.952Z","ordinal":3,"type":"response_item","payload":{"type":"message","content":[{"text":"\"type\":\"task_started\""}]}}"#
        r.feed(Data((line + "\n").utf8))
        #expect(!r.hasOpenTurn)
    }

    @Test func parsesTimestamps() throws {
        let fractional = try #require(Header.parseTimestamp("2026-11-14T20:11:18.952Z"))
        #expect(abs(fractional.timeIntervalSince1970 - 1_794_687_078.952) < 0.001)
        #expect(Header.parseTimestamp("2026-11-14T20:11:18Z") == Date(timeIntervalSince1970: 1_794_687_078))
        #expect(Header.parseTimestamp("nope") == nil)
    }

    @Test func sessionIdFallsBackToFilename() {
        #expect(CodexActivityRule.sessionId(fromFilename: path) == session)
        #expect(CodexActivityRule.sessionId(fromFilename: "/x/rollout-short.jsonl") == nil)
    }
}

@Suite("CodexActivityRule")
struct CodexActivityRuleTests {
    let now = Date(timeIntervalSince1970: 1_794_687_100)
    let key = SessionKey(agent: .codex, sessionId: session, pid: 0)

    func tracked(_ name: String, modified: Date?) throws -> [String: CodexActivityRule.Tracked] {
        [path: CodexActivityRule.Tracked(rollout: try rollout(name), modified: modified)]
    }

    @Test func openTurnRecentlyWrittenIsBusy() throws {
        let result = CodexActivityRule.evaluate(
            tracked: try tracked("open-turn", modified: now), liveness: [path: .alive(pid: 99)],
            previous: [], now: now, quietLimit: 3600)
        #expect(result.events == [ActivityEvent(session: key, activity: .busy, at: now, project: "/Users/example/projects/demo")])
    }

    @Test(arguments: [CodexLiveness.alive(pid: 1), .unknown])
    func aliveOrUnknownStaysBusy(_ liveness: CodexLiveness) throws {
        let result = CodexActivityRule.evaluate(
            tracked: try tracked("open-turn", modified: now), liveness: [path: liveness],
            previous: [], now: now, quietLimit: 3600)
        #expect(result.live == [key])
    }

    @Test func noCodexProcessMeansGone() throws {
        let result = CodexActivityRule.evaluate(
            tracked: try tracked("open-turn", modified: now), liveness: [path: .dead],
            previous: [key], now: now, quietLimit: 3600)
        #expect(result.events == [ActivityEvent(session: key, activity: .gone, at: now)])
    }

    @Test func closedTurnReleases() throws {
        let result = CodexActivityRule.evaluate(
            tracked: try tracked("complete", modified: now), liveness: [:], previous: [key], now: now, quietLimit: 3600)
        #expect(result.events.map(\.activity) == [.gone])
    }

    @Test func openButSilentPastQuietLimitReleases() throws {
        // The fixture's last line is at 20:11:19Z; check two hours later.
        let later = now.addingTimeInterval(7200)
        let result = CodexActivityRule.evaluate(
            tracked: try tracked("open-turn", modified: now), liveness: [path: .unknown],
            previous: [key], now: later, quietLimit: 3600)
        #expect(result.events.map(\.activity) == [.gone])
    }

    @Test func busyIsReEmittedEachEvaluationToRenew() throws {
        let t = try tracked("open-turn", modified: now)
        let first = CodexActivityRule.evaluate(tracked: t, liveness: [:], previous: [], now: now, quietLimit: 3600)
        let second = CodexActivityRule.evaluate(tracked: t, liveness: [:], previous: first.live, now: now.addingTimeInterval(30), quietLimit: 3600)
        #expect(second.events.map(\.activity) == [.busy])
    }
}

private struct FakeOpenFiles: OpenFileLookup {
    var processes: [Int32: Set<String>]
    func pids(named name: String) -> [Int32] { name == "codex" ? Array(processes.keys).sorted() : [] }
    func openPaths(of pid: Int32) -> Set<String> { processes[pid] ?? [] }
}

@Suite("CodexProcessProbe")
struct CodexProcessProbeTests {
    @Test func noCodexRunningIsDead() {
        #expect(CodexProcessProbe(files: FakeOpenFiles(processes: [:])).liveness(of: [path]) == [path: .dead])
    }

    @Test func holderIsAlive() {
        let files = FakeOpenFiles(processes: [10: ["/other"], 20: [path]])
        #expect(CodexProcessProbe(files: files).liveness(of: [path]) == [path: .alive(pid: 20)])
    }

    @Test func codexRunningButNotHoldingIsUnknown() {
        let files = FakeOpenFiles(processes: [10: ["/other"]])
        #expect(CodexProcessProbe(files: files).liveness(of: [path]) == [path: .unknown])
    }

    @Test func realLookupFindsOwnOpenFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ohmai-openfile-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let open = LibprocOpenFiles().openPaths(of: ProcessInfo.processInfo.processIdentifier)
        #expect(open.contains(LibprocOpenFiles.canonicalPath(url.path)))
    }
}
