import Foundation
import Testing
import OhmaiCore
import OhmaiUsage
@testable import OhmaiTranscripts

private func lines(_ path: String) throws -> [Data] {
    let parts = path.split(separator: "/")
    let url = try #require(Bundle.module.url(
        forResource: String(parts[1].split(separator: ".")[0]), withExtension: "jsonl",
        subdirectory: "Fixtures/\(parts[0])"))
    return try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
}

private func parse(_ format: TranscriptParser.Format, _ fixture: String, path: String = "/x/2026-11-15T01-15-47-988Z_sess-pi.jsonl") throws -> [UsageRecord] {
    var parser = TranscriptParser(format: format, path: path)
    return parser.parse(lines: try lines(fixture))
}

/// Same-key records collapse, as the ledger's unique key does.
private func deduped(_ records: [UsageRecord]) -> [UsageRecord] {
    var seen = Set<String>()
    return records.filter { seen.insert($0.dedupeKey).inserted }
}

@Suite("Claude transcripts")
struct ClaudeTranscriptTests {
    @Test func extractsUsagePerApiMessage() throws {
        let records = deduped(try parse(.claude, "claude-2.1.325/session.jsonl"))
        // Expected values computed independently from the fixture (see README).
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0.agent == .claude && $0.model == "claude-opus-5-5" })
        #expect(records.map(\.input).reduce(0, +) == 8)
        #expect(records.map(\.output).reduce(0, +) == 1437)
        #expect(records.map(\.cacheRead).reduce(0, +) == 125_492)
        #expect(records.map(\.cacheWrite1h).reduce(0, +) == 24_722)
        #expect(records.map(\.cacheWrite5m).reduce(0, +) == 0)
    }

    @Test func repeatedLinesShareOneKey() throws {
        let all = try parse(.claude, "claude-2.1.325/session.jsonl")
        #expect(all.count == 7)                 // 7 lines carry usage
        #expect(Set(all.map(\.dedupeKey)).count == 3)
    }

    @Test func fallsBackToTotalCacheWriteWithoutSplit() {
        let line = #"{"type":"assistant","timestamp":"2026-11-14T20:00:00.000Z","sessionId":"s","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":4}}}"#
        let r = TranscriptParser.claude(Data(line.utf8))
        #expect(r?.cacheWrite5m == 300)
        #expect(r?.cacheWrite1h == 0)
    }

    @Test func ignoresSyntheticAndNonAssistantLines() {
        let synthetic = #"{"type":"assistant","timestamp":"2026-11-14T20:00:00.000Z","message":{"id":"msg_2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        let user = #"{"type":"user","timestamp":"2026-11-14T20:00:00.000Z","message":{"role":"user","content":"\"type\":\"assistant\",\"usage\":{\"input_tokens\":5}"}}"#
        #expect(TranscriptParser.claude(Data(synthetic.utf8)) == nil)
        #expect(TranscriptParser.claude(Data(user.utf8)) == nil)
    }

    @Test func garbageIsSkipped() {
        #expect(TranscriptParser.claude(Data(#"{"type":"assistant","usage":{"#.utf8)) == nil)
    }
}

@Suite("Codex transcripts")
struct CodexTranscriptTests {
    @Test func extractsOneRecordPerResponse() throws {
        let records = try parse(.codex, "codex-0.169.0/rollout.jsonl")
        #expect(records.count == 6)
        #expect(Set(records.map(\.dedupeKey)).count == 6)
        #expect(records.allSatisfy { $0.agent == .codex && $0.model == "gpt-6.1-sol" })
        #expect(records.map(\.input).reduce(0, +) == 5293)       // uncached only
        #expect(records.map(\.cacheRead).reduce(0, +) == 94_848)
        #expect(records.map(\.output).reduce(0, +) == 1131)
        #expect(records.allSatisfy { !$0.sessionId.isEmpty })
    }

    @Test func stateCarriesAcrossIncrementalReads() throws {
        let all = try lines("codex-0.169.0/rollout.jsonl")
        var first = TranscriptParser(format: .codex, path: "/x")
        _ = first.parse(lines: all.prefix(10))
        // Resume as the ledger does: a fresh parser with the saved state.
        var resumed = TranscriptParser(format: .codex, path: "/x", state: first.state)
        let rest = resumed.parse(lines: all.dropFirst(10))
        #expect(first.state.model == "gpt-6.1-sol")
        #expect(rest.allSatisfy { $0.model == "gpt-6.1-sol" })
    }
}

@Suite("pi transcripts")
struct PiTranscriptTests {
    @Test func extractsAssistantAndUsageEntries() throws {
        let records = try parse(.pi, "pi-1.5.2/session.jsonl")
        #expect(records.count == 3)
        #expect(records.map(\.model) == ["anthropic/claude-opus-5-5", "anthropic/claude-opus-5-5", "openai-codex/gpt-6.1-sol"])
        #expect(records[0].recordedCost == 0.018348)
        #expect(records[0].cacheRead == 20_000)
        #expect(records[1].cacheRead == 21_000)
        #expect(records.allSatisfy { $0.sessionId == "sess-pi" })
    }

    @Test func textMentioningUsageIsNotUsage() throws {
        let records = try parse(.pi, "pi-1.5.2/session.jsonl")
        // e4's text contains `"usage":{"input":999}`, escaped; the real usage is 100.
        #expect(records.last?.input == 100)
    }
}

@Suite("Privacy boundary")
struct PrivacyBoundaryTests {
    /// Records hold numbers and metadata only: no field can carry text from a message.
    @Test func recordsCarryNoContent() throws {
        for (format, fixture) in [(TranscriptParser.Format.claude, "claude-2.1.325/session.jsonl"),
                                  (.codex, "codex-0.169.0/rollout.jsonl"), (.pi, "pi-1.5.2/session.jsonl")] {
            for r in try parse(format, fixture) {
                #expect(!String(describing: r).contains("placeholder"), "\(format) record leaked text")
            }
        }
    }
}
