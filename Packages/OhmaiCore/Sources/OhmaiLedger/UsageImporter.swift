import Foundation
import OhmaiCore
import OhmaiTranscripts
import OhmaiUsage

/// Imports usage from agent transcripts into the ledger, incrementally, off the main actor.
///
/// - Each file is read from its stored byte offset, in chunks, never whole.
/// - Only complete lines are consumed; a half-written last line is re-read next time.
/// - Records and the new offset commit in one transaction, so a crash or quit mid-import
///   resumes where it stopped, and re-reading can never double-count (unique keys).
/// - A replaced or truncated file (new inode, or smaller than the offset) starts over.
public actor UsageImporter {
    public struct Source: Sendable {
        public let format: TranscriptParser.Format
        public let root: URL
        public let includes: @Sendable (String) -> Bool

        public init(format: TranscriptParser.Format, root: URL, includes: @escaping @Sendable (String) -> Bool) {
            self.format = format
            self.root = root
            self.includes = includes
        }
    }

    public struct Report: Sendable, Equatable {
        public var files = 0
        public var bytes: UInt64 = 0
        public var records = 0
        public var changed: Bool { records > 0 }
    }

    public static func defaultSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Source] {
        [
            Source(format: .claude, root: home.appending(path: ".claude/projects")) { $0.hasSuffix(".jsonl") },
            Source(format: .codex, root: home.appending(path: ".codex/sessions")) {
                ($0 as NSString).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix(".jsonl")
            },
            Source(format: .pi, root: home.appending(path: ".pi/agent/sessions")) { $0.hasSuffix(".jsonl") },
        ]
    }

    public static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ohmai/ledger.sqlite")
    }

    static let chunkSize = 4 << 20
    /// Commit at least this often, so a long first import is resumable and memory stays flat.
    static let commitEvery = 16 << 20

    private let ledger: Ledger
    public nonisolated let sources: [Source]

    public init(database: URL = UsageImporter.defaultDatabase, sources: [Source] = UsageImporter.defaultSources()) throws {
        self.ledger = try Ledger(url: database)
        self.sources = sources
    }

    /// Walks every source. The first run backfills all history still on disk.
    public func importAll() -> Report {
        var report = Report()
        for source in sources {
            guard let walker = FileManager.default.enumerator(
                at: source.root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker where source.includes(url.path) {
                if Task.isCancelled { return report }
                importFile(url.path, format: source.format, into: &report)
            }
        }
        releaseMemory()
        return report
    }

    /// Imports just these paths (from FSEvents). Paths outside every source are ignored.
    public func importFiles(_ paths: [String]) -> Report {
        var report = Report()
        for path in Set(paths) {
            guard let source = sources.first(where: { path.hasPrefix($0.root.path) && $0.includes(path) }) else { continue }
            importFile(path, format: source.format, into: &report)
        }
        releaseMemory()
        return report
    }

    /// Imports touch a lot of memory briefly; give it back so idle ohmai stays small.
    private func releaseMemory() {
        ledger.releaseMemory()
        malloc_zone_pressure_relief(nil, 0)
    }

    public func comparison(today: Date = .now, prices: PriceTable = .bundled, calendar: Calendar = .current) -> MonthComparison {
        let todayKey = DayKey(today, calendar: calendar)
        let lastMonthStart = calendar.date(from: DateComponents(
            year: todayKey.month == 1 ? todayKey.year - 1 : todayKey.year,
            month: todayKey.month == 1 ? 12 : todayKey.month - 1, day: 1))!
        let groups = (try? ledger.groups(since: lastMonthStart.addingTimeInterval(-86_400))) ?? []
        let daily = groups.map { g in
            DailyUsage(agent: g.agent, day: g.day, totals: Self.totals(g, prices: prices))
        }
        let earliest = (try? ledger.earliest()).flatMap { $0 }.map { DayKey($0, calendar: calendar) }
        return MonthComparison.build(daily: daily, today: todayKey, historyStart: earliest, calendar: calendar)
    }

    public func recordCount() -> Int { (try? ledger.recordCount()) ?? 0 }

    static func totals(_ g: Ledger.Group, prices: PriceTable) -> UsageTotals {
        let record = UsageRecord(
            dedupeKey: "", agent: g.agent, sessionId: "", model: g.model, timestamp: .distantPast,
            input: g.input, output: g.output, cacheRead: g.cacheRead,
            cacheWrite5m: g.cacheWrite5m, cacheWrite1h: g.cacheWrite1h, recordedCost: g.recordedCost)
        return prices.totals(for: record)
    }

    // MARK: - One file

    private func importFile(_ path: String, format: TranscriptParser.Format, into report: inout Report) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        var mark = (try? ledger.mark(for: path)) ?? Ledger.FileMark(offset: 0, inode: inode, state: .init())
        if mark.inode != inode || size < mark.offset {
            mark = Ledger.FileMark(offset: 0, inode: inode, state: .init())
        }
        guard size > mark.offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        report.files += 1

        var parser = TranscriptParser(format: format, path: path, state: mark.state)
        var pending: [UsageRecord] = []
        var carry = Data()
        var consumed = mark.offset
        var sinceCommit = 0

        do {
            try handle.seek(toOffset: mark.offset)
            var finished = false
            while !finished {
                // Drain per chunk: Foundation's file reads and JSON decoding autorelease, and
                // nothing else drains a pool inside this loop. Without it, memory grows with
                // the whole history (measured: ~4.9 GB peak on a 3.5 GB first import).
                finished = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { return true }
                    carry.append(chunk)
                    guard let lastNewline = carry.lastIndex(of: 0x0A) else { return false }
                    let complete = carry[carry.startIndex...lastNewline]
                    pending += parser.parse(lines: complete.split(separator: 0x0A, omittingEmptySubsequences: true).lazy.map { Data($0) })
                    let used = complete.count
                    consumed += UInt64(used)
                    sinceCommit += used
                    carry = Data(carry[carry.index(after: lastNewline)...])

                    if sinceCommit >= Self.commitEvery {
                        try commit(&pending, path: path, offset: consumed, inode: inode, state: parser.state, report: &report)
                        sinceCommit = 0
                    }
                    return Task.isCancelled
                }
            }
            try commit(&pending, path: path, offset: consumed, inode: inode, state: parser.state, report: &report)
            report.bytes += consumed - mark.offset
        } catch {
            // Leave the mark where the last commit put it; the next run retries from there.
        }
    }

    private func commit(_ records: inout [UsageRecord], path: String, offset: UInt64, inode: UInt64,
                        state: TranscriptParser.State, report: inout Report) throws {
        try ledger.commit(records, path: path, mark: Ledger.FileMark(offset: offset, inode: inode, state: state))
        report.records += records.count
        records.removeAll(keepingCapacity: true)
    }
}
