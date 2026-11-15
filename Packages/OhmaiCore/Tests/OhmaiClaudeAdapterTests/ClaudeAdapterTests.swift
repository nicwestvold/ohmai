import Foundation
import Testing
import OhmaiAdapterSupport
import OhmaiCore
@testable import OhmaiClaudeAdapter

/// The fixture's process: `procStart` "Sat Nov 14 20:56:27 2026" UTC.
private let fixturePid: Int32 = 4242
private let fixtureProcessStart = Date(timeIntervalSince1970: 1_794_689_787)
private let fixtureSession = "00000000-0000-4000-8000-000000000001"
private let now = Date(timeIntervalSince1970: 1_794_702_400)

struct FakeInspector: ProcessInspector {
    var processes: [Int32: Date]
    func startTime(of pid: Int32) -> Date? { processes[pid] }
}

private let alive = FakeInspector(processes: [fixturePid: fixtureProcessStart])
private let dead = FakeInspector(processes: [:])

private func fixture(_ name: String, version: String = "claude-2.1.325") throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name, withExtension: "json", subdirectory: "Fixtures/\(version)/sessions"))
    return try Data(contentsOf: url)
}

/// A fixture with some fields changed, for edge cases.
private func edited(_ name: String, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    var json = try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    edit(&json)
    return try JSONSerialization.data(withJSONObject: json)
}

private let key = SessionKey(agent: .claude, sessionId: fixtureSession, pid: fixturePid)

@Suite("ClaudeSessionFile")
struct ClaudeSessionFileTests {
    @Test(arguments: [("busy", ClaudeSessionFile.Status.busy), ("idle", .idle), ("waiting", .waiting)])
    func parsesFixtures(_ name: String, _ status: ClaudeSessionFile.Status) throws {
        let file = try #require(ClaudeSessionFile.parse(fixture(name)))
        #expect(file.pid == fixturePid)
        #expect(file.sessionId == fixtureSession)
        #expect(file.cwd == "/Users/example/projects/demo")
        #expect(file.status == status)
        #expect(file.startedAt == Date(timeIntervalSince1970: 1_794_689_789.293))
        #expect(file.processStart == fixtureProcessStart)
    }

    @Test func unknownStatusIsUnknown() throws {
        let data = try edited("busy") { $0["status"] = "thinking-hard" }
        #expect(ClaudeSessionFile.parse(data)?.status == .unknown("thinking-hard"))
        let missing = try edited("busy") { $0["status"] = nil }
        #expect(ClaudeSessionFile.parse(missing)?.status == .unknown(nil))
    }

    @Test func unknownFieldsAreIgnored() throws {
        let data = try edited("busy") { $0["somethingNew"] = ["nested": true] }
        #expect(ClaudeSessionFile.parse(data)?.status == .busy)
    }

    @Test func rejectsUnusableRecords() throws {
        #expect(ClaudeSessionFile.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeSessionFile.parse(Data("[]".utf8)) == nil)
        #expect(ClaudeSessionFile.parse(try edited("busy") { $0["pid"] = nil }) == nil)
        #expect(ClaudeSessionFile.parse(try edited("busy") { $0["pid"] = -1 }) == nil)
        #expect(ClaudeSessionFile.parse(try edited("busy") { $0["pid"] = "4242" }) == nil)
        #expect(ClaudeSessionFile.parse(try edited("busy") { $0["sessionId"] = "" }) == nil)
        #expect(ClaudeSessionFile.parse(Data(repeating: 0x20, count: ClaudeSessionFile.maxSize + 1)) == nil)
    }

    @Test func toleratesMissingOptionalFields() throws {
        let data = try edited("busy") { json in
            for k in ["cwd", "startedAt", "procStart"] { json[k] = nil }
        }
        let file = try #require(ClaudeSessionFile.parse(data))
        #expect(file.cwd == nil)
        #expect(file.startedAt == nil)
        #expect(file.processStart == nil)
    }

    @Test func parsesSpacePaddedProcStart() {
        #expect(ClaudeSessionFile.parseProcStart("Wed Nov  4 09:05:01 2026")
            == ClaudeSessionFile.parseProcStart("Wed Nov 4 09:05:01 2026"))
        #expect(ClaudeSessionFile.parseProcStart("Wed Nov 4 09:05:01 2026") != nil)
        #expect(ClaudeSessionFile.parseProcStart("garbage") == nil)
    }

    /// Privacy: the derived session `name` must never be surfaced.
    @Test func neverReadsName() throws {
        let file = try #require(ClaudeSessionFile.parse(fixture("busy")))
        #expect(!String(describing: file).contains("placeholder-name"))
    }
}

@Suite("ClaudeSessionScanner")
struct ClaudeSessionScannerTests {
    @Test(arguments: [("busy", Activity.busy), ("waiting", .waiting), ("idle", .idle)])
    func emitsActivityForLiveSession(_ name: String, _ activity: Activity) throws {
        let result = ClaudeSessionScanner(inspector: alive).scan(files: [try fixture(name)], previous: [:], now: now)
        #expect(result.events == [ActivityEvent(session: key, activity: activity, at: now, project: "/Users/example/projects/demo")])
        #expect(result.live == [key: activity])
    }

    @Test func busyIsReEmittedEveryScanToRenew() throws {
        let scanner = ClaudeSessionScanner(inspector: alive)
        let first = scanner.scan(files: [try fixture("busy")], previous: [:], now: now)
        let second = scanner.scan(files: [try fixture("busy")], previous: first.live, now: now.addingTimeInterval(30))
        #expect(second.events.map(\.activity) == [.busy])
        #expect(second.events.first?.at == now.addingTimeInterval(30))
    }

    @Test func deadPidIsIgnoredAndGoneIfKnown() throws {
        let scanner = ClaudeSessionScanner(inspector: dead)
        #expect(scanner.scan(files: [try fixture("busy")], previous: [:], now: now).events.isEmpty)
        let result = scanner.scan(files: [try fixture("busy")], previous: [key: .busy], now: now)
        #expect(result.events == [ActivityEvent(session: key, activity: .gone, at: now)])
        #expect(result.live.isEmpty)
    }

    @Test func removedFileIsGone() {
        let result = ClaudeSessionScanner(inspector: alive).scan(files: [], previous: [key: .busy], now: now)
        #expect(result.events == [ActivityEvent(session: key, activity: .gone, at: now)])
    }

    @Test func reusedPidIsNotTheSession() throws {
        // Same pid, but the kernel says this process started an hour later.
        let reused = FakeInspector(processes: [fixturePid: fixtureProcessStart.addingTimeInterval(3600)])
        let result = ClaudeSessionScanner(inspector: reused).scan(files: [try fixture("busy")], previous: [key: .busy], now: now)
        #expect(result.events.map(\.activity) == [.gone])
    }

    @Test func reusedPidDetectedFromStartedAtWhenProcStartMissing() throws {
        let data = try edited("busy") { $0["procStart"] = nil }
        let reused = FakeInspector(processes: [fixturePid: fixtureProcessStart.addingTimeInterval(3600)])
        #expect(ClaudeSessionScanner(inspector: reused).scan(files: [data], previous: [:], now: now).events.isEmpty)
        #expect(ClaudeSessionScanner(inspector: alive).scan(files: [data], previous: [:], now: now).events.map(\.activity) == [.busy])
    }

    @Test func unknownStatusEmitsNothingAndReleasesKnownSession() throws {
        let data = try edited("busy") { $0["status"] = "pondering" }
        let result = ClaudeSessionScanner(inspector: alive).scan(files: [data], previous: [key: .busy], now: now)
        #expect(result.events == [ActivityEvent(session: key, activity: .gone, at: now)])
        #expect(result.unknownStatuses == ["pondering"])
    }

    @Test func newSessionIdInSamePidReplacesOldOne() throws {
        // `/clear` or `/resume` swaps the session id while the process lives on.
        let data = try edited("busy") { $0["sessionId"] = "00000000-0000-4000-8000-000000000002" }
        let result = ClaudeSessionScanner(inspector: alive).scan(files: [data], previous: [key: .busy], now: now)
        #expect(result.events.map(\.activity) == [.busy, .gone])
        #expect(result.events.last?.session == key)
    }

    @Test func multipleSessionsAreIndependent() throws {
        let other = try edited("waiting") { json in
            json["pid"] = 5151
            json["sessionId"] = "00000000-0000-4000-8000-000000000003"
        }
        let inspector = FakeInspector(processes: [fixturePid: fixtureProcessStart, 5151: fixtureProcessStart])
        let result = ClaudeSessionScanner(inspector: inspector).scan(files: [try fixture("busy"), other], previous: [:], now: now)
        #expect(Set(result.events.map(\.activity)) == [.busy, .waiting])
        #expect(result.live.count == 2)
    }

    @Test func garbageFilesAreSkipped() throws {
        let result = ClaudeSessionScanner(inspector: alive).scan(
            files: [Data("{".utf8), try fixture("busy")], previous: [:], now: now)
        #expect(result.events.map(\.activity) == [.busy])
    }
}

@Suite("ProcessIdentity")
struct ProcessIdentityTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func recordedStartMustMatchWithinTolerance() {
        #expect(ProcessIdentity.matches(kernelStart: start, sessionStartedAt: nil, recordedProcessStart: start.addingTimeInterval(1)))
        #expect(!ProcessIdentity.matches(kernelStart: start, sessionStartedAt: nil, recordedProcessStart: start.addingTimeInterval(60)))
    }

    @Test func processMustPredateSession() {
        #expect(ProcessIdentity.matches(kernelStart: start, sessionStartedAt: start.addingTimeInterval(3600), recordedProcessStart: nil))
        #expect(!ProcessIdentity.matches(kernelStart: start.addingTimeInterval(60), sessionStartedAt: start, recordedProcessStart: nil))
    }

    @Test func noEvidenceMeansMatch() {
        #expect(ProcessIdentity.matches(kernelStart: start, sessionStartedAt: nil, recordedProcessStart: nil))
    }

    @Test func realInspectorSeesThisProcess() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let started = try #require(DarwinProcessInspector().startTime(of: me))
        #expect(started <= .now)
        #expect(started > .now.addingTimeInterval(-3600))
        #expect(DarwinProcessInspector().startTime(of: 0) == nil)
        #expect(DarwinProcessInspector().startTime(of: Int32.max) == nil)
    }
}
