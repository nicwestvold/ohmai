import Foundation
import Testing
import OhmaiCore
import OhmaiTranscripts
import OhmaiUsage
@testable import OhmaiLedger

/// A temp home with agent folders and a temp database. Real files, fake content.
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "ohmai-ledger-\(UUID().uuidString)")
    var db: URL { root.appending(path: "ledger.sqlite") }
    var claudeFile: URL { root.appending(path: "home/.claude/projects/-Users-example-demo/s1.jsonl") }

    init() throws {
        try FileManager.default.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func importer() throws -> UsageImporter {
        try UsageImporter(database: db, sources: UsageImporter.defaultSources(home: root.appending(path: "home")))
    }

    func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func claudeLine(id: String, ts: String = "2026-11-14T12:00:00.000Z", output: Int = 100) -> String {
    #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"s1","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[{"type":"text","text":"placeholder"}],"usage":{"input_tokens":10,"output_tokens":\#(output),"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":50}}}}"#
}

@Suite("Ledger and importer", .serialized)
struct LedgerTests {
    @Test func importsIncrementallyAndResumesAfterPartialLines() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let importer = try box.importer()

        try box.append(claudeLine(id: "msg_1") + "\n" + claudeLine(id: "msg_2"), to: box.claudeFile)  // msg_2 unfinished
        var r = await importer.importAll()
        #expect(r.records == 1)

        try box.append("\n" + claudeLine(id: "msg_3") + "\n", to: box.claudeFile)
        r = await importer.importAll()
        #expect(r.records == 2)
        #expect(await importer.recordCount() == 3)

        r = await importer.importAll()  // nothing new
        #expect(r.records == 0 && r.files == 0)
    }

    @Test func duplicatesNeverDoubleCount() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.append(String(repeating: claudeLine(id: "msg_same") + "\n", count: 5), to: box.claudeFile)
        let importer = try box.importer()
        _ = await importer.importAll()
        #expect(await importer.recordCount() == 1)
    }

    @Test func replacedFileStartsOver() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.append(claudeLine(id: "msg_a") + "\n" + claudeLine(id: "msg_b") + "\n", to: box.claudeFile)
        let importer = try box.importer()
        _ = await importer.importAll()
        try FileManager.default.removeItem(at: box.claudeFile)
        try box.append(claudeLine(id: "msg_c") + "\n", to: box.claudeFile)  // new inode, smaller
        _ = await importer.importAll()
        #expect(await importer.recordCount() == 3)
    }

    @Test func survivesRestart() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.append(claudeLine(id: "msg_1") + "\n", to: box.claudeFile)
        _ = await (try box.importer()).importAll()
        try box.append(claudeLine(id: "msg_2") + "\n", to: box.claudeFile)
        let fresh = try box.importer()  // a new process: offsets come from the database
        let r = await fresh.importAll()
        #expect(r.records == 1)
        #expect(await fresh.recordCount() == 2)
    }

    @Test func importFilesIgnoresPathsOutsideSources() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.append(claudeLine(id: "msg_1") + "\n", to: box.claudeFile)
        let importer = try box.importer()
        let r = await importer.importFiles(["/etc/hosts", box.claudeFile.path])
        #expect(r.records == 1)
    }

    @Test func comparisonComesOutPriced() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.append(
            claudeLine(id: "msg_now", ts: "2026-11-10T12:00:00.000Z") + "\n" +
            claudeLine(id: "msg_then", ts: "2026-10-05T12:00:00.000Z") + "\n",
            to: box.claudeFile)
        let importer = try box.importer()
        _ = await importer.importAll()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
        let c = await importer.comparison(today: today, calendar: cal)
        let row = try #require(c.rows.first)
        #expect(row.agent == .claude)
        #expect(row.basis == .cost)
        // 10×4 + 100×20 + 1000×0.20 + 50×8 = 2640 per million → $0.00264 each
        #expect(abs(row.thisMonth.cost - 0.00264) < 1e-9)
        #expect(row.change == 0)
        #expect(row.thisMonth.tokens == 1160)
    }
}
