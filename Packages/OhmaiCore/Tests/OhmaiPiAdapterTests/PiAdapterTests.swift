import Foundation
import Testing
import OhmaiAdapterSupport
import OhmaiCore
@testable import OhmaiPiAdapter

private let pid: Int32 = 4242
private let processStart = Date(timeIntervalSince1970: 1_794_689_787)
private let now = Date(timeIntervalSince1970: 1_794_702_400)

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ohmai-pi-v1"))
    return try Data(contentsOf: url)
}

private struct FakeInspector: ProcessInspector {
    var processes: [Int32: Date]
    func startTime(of pid: Int32) -> Date? { processes[pid] }
}

private struct FakeTranscripts: TranscriptActivity {
    var write: Date?
    func lastWrite(for record: StatusRecord) -> Date? { write }
}

private func scan(_ names: [String], alive: Bool = true, transcript: Date? = now, previous: [SessionKey: Activity] = [:]) throws -> StatusRecordScanner.Result {
    let scanner = StatusRecordScanner(
        inspector: FakeInspector(processes: alive ? [pid: processStart] : [:]),
        transcripts: FakeTranscripts(write: transcript))
    return scanner.scan(records: try names.map { try #require(PiStatusFile.parse(fixture($0))) },
                        previous: previous, now: now, quietLimit: 3600)
}

private let key = SessionKey(agent: .pi, sessionId: "sess-1", pid: pid)

@Suite("PiStatusFile")
struct PiStatusFileTests {
    @Test(arguments: [("busy", StatusRecord.Status.busy), ("idle", .idle), ("waiting", .waiting)])
    func parses(_ name: String, _ status: StatusRecord.Status) throws {
        let r = try #require(PiStatusFile.parse(fixture(name)))
        #expect(r.agent == .pi)
        #expect(r.pid == pid)
        #expect(r.sessionId == "sess-1")
        #expect(r.status == status)
        #expect(r.cwd == "/Users/example/demo")
        #expect(r.processStart == processStart)
        #expect(r.transcriptPath?.hasSuffix(".jsonl") == true)
    }

    @Test func unsavedSessionFallsBackToPid() throws {
        let r = try #require(PiStatusFile.parse(fixture("busy-unsaved")))
        #expect(r.sessionId == "pid-4242")
        #expect(r.transcriptPath == nil)
    }

    @Test func rejectsGarbage() {
        #expect(PiStatusFile.parse(Data("{}".utf8)) == nil)
        #expect(PiStatusFile.parse(Data(#"{"pid":0,"status":"busy"}"#.utf8)) == nil)
        #expect(PiStatusFile.parse(Data("nope".utf8)) == nil)
    }

    @Test func unknownStatusIsUnknown() {
        #expect(PiStatusFile.parse(Data(#"{"pid":5,"status":"dreaming"}"#.utf8))?.status == .unknown("dreaming"))
    }
}

@Suite("pi through StatusRecordScanner")
struct PiScanTests {
    @Test func busyKeepsAwake() throws {
        #expect(try scan(["busy"]).events == [ActivityEvent(
            session: key, activity: .busy, at: now, project: "/Users/example/demo",
            since: Date(timeIntervalSince1970: 1_794_702_374))])
    }

    @Test func waitingAndIdle() throws {
        #expect(try scan(["waiting"]).events.map(\.activity) == [.waiting])
        #expect(try scan(["idle"]).events.map(\.activity) == [.idle])
    }

    @Test func deadPidIsGone() throws {
        #expect(try scan(["busy"], alive: false, previous: [key: .busy]).events.map(\.activity) == [.gone])
    }

    @Test func silentPastQuietLimitIsReleased() throws {
        let result = try scan(["busy"], transcript: now.addingTimeInterval(-7200), previous: [key: .busy])
        // statusUpdatedAt in the fixture is 26s before `now`, so it still counts as life.
        #expect(result.events.map(\.activity) == [.busy])
        let stale = String(decoding: try fixture("busy"), as: UTF8.self)
            .replacingOccurrences(of: "\"statusUpdatedAt\":1794702374000", with: "\"statusUpdatedAt\":1794690000000")
        let record = try #require(PiStatusFile.parse(Data(stale.utf8)))
        let scanner = StatusRecordScanner(
            inspector: FakeInspector(processes: [pid: processStart]),
            transcripts: FakeTranscripts(write: now.addingTimeInterval(-7200)))
        #expect(scanner.scan(records: [record], previous: [key: .busy], now: now, quietLimit: 3600).quiet == [key])
    }
}

@Suite("PiExtensionInstaller")
struct PiExtensionInstallerTests {
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ohmai-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        return root
    }

    @Test func bundledExtensionIsShippedAndMarked() throws {
        let data = try #require(PiExtensionInstaller.bundledExtension)
        #expect(PiExtensionInstaller.isOurs(data))
        let text = String(decoding: data, as: UTF8.self)
        // The fields the parser relies on are the ones the extension writes.
        for field in ["pid", "processStart", "startedAt", "status", "statusUpdatedAt", "sessionId", "sessionFile", "cwd"] {
            #expect(text.contains("\(field)"), "extension should write \(field)")
        }
        #expect(!text.contains("fetch("), "the extension makes no network calls")
        #expect(!text.contains("setInterval"), "the extension runs no timers")
    }

    @Test func installUpdateUninstall() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appending(path: ".pi/agent")
        let v1 = PiExtensionInstaller(agentDirectory: agent, bundled: Data("// ohmai-extension-version: 1\n".utf8))
        #expect(v1.status() == .notInstalled)
        try v1.install()
        #expect(v1.status() == .installed)

        let v2 = PiExtensionInstaller(agentDirectory: agent, bundled: Data("// ohmai-extension-version: 2\n".utf8))
        #expect(v2.status() == .outdated)
        try v2.install()
        #expect(v2.status() == .installed)

        try v2.uninstall()
        #expect(v2.status() == .notInstalled)
    }

    @Test func neverTouchesSomeoneElsesFile() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appending(path: ".pi/agent")
        let theirs = agent.appending(path: "extensions/ohmai.ts")
        try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// someone else's\n".utf8).write(to: theirs)
        let installer = PiExtensionInstaller(agentDirectory: agent, bundled: Data("// ohmai-extension-version: 1\n".utf8))
        #expect(throws: PiExtensionInstaller.Failure.notOurs) { try installer.install() }
        #expect(throws: PiExtensionInstaller.Failure.notOurs) { try installer.uninstall() }
        #expect(FileManager.default.contents(atPath: theirs.path) == Data("// someone else's\n".utf8))
    }

    @Test func noPiMeansNoInstall() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ohmai-nopi-\(UUID().uuidString)")
        let installer = PiExtensionInstaller(agentDirectory: root.appending(path: ".pi/agent"), bundled: Data("x".utf8))
        #expect(installer.status() == .piNotFound)
        #expect(throws: PiExtensionInstaller.Failure.piNotFound) { try installer.install() }
    }
}
