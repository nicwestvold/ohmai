import Foundation
import OhmaiCore
import OhmaiTranscripts
import OhmaiUsage
import SQLite3

/// The local SQLite store: usage records plus a byte offset per transcript file, so imports
/// are incremental and survive restarts. Owned by `UsageImporter`; not thread-safe alone.
///
/// Holds only what `UsageRecord` holds: numbers and metadata, never content.
final class Ledger {
    enum Failure: Error, Equatable { case open(String), sql(String) }

    struct FileMark: Equatable {
        var offset: UInt64
        var inode: UInt64
        var state: TranscriptParser.State
    }

    struct Group: Equatable {
        let agent: Agent
        let day: DayKey
        let model: String
        let input, output, cacheRead, cacheWrite5m, cacheWrite1h: Int
        /// Sum of agent-recorded costs, when this group's records carry them (pi).
        let recordedCost: Double?
    }

    private var db: OpaquePointer?
    static let schemaVersion: Int32 = 1

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw Failure.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version")
        guard version < Self.schemaVersion else { return }
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_records (
                dedupe_key TEXT PRIMARY KEY,
                agent TEXT NOT NULL, session TEXT NOT NULL, model TEXT NOT NULL, ts REAL NOT NULL,
                input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                cache_write_5m INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL,
                reasoning INTEGER NOT NULL, recorded_cost REAL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS usage_ts ON usage_records(ts);
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY, offset INTEGER NOT NULL, inode INTEGER NOT NULL, state BLOB
            ) WITHOUT ROWID;
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    // MARK: - Writing

    /// Inserts records (duplicates ignored) and moves the file's mark, atomically.
    func commit(_ records: [UsageRecord], path: String, mark: FileMark) throws {
        try exec("BEGIN")
        do {
            let insert = try prepare("""
                INSERT OR IGNORE INTO usage_records VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(insert) }
            for r in records {
                sqlite3_reset(insert)
                bind(insert, 1, r.dedupeKey)
                bind(insert, 2, r.agent.rawValue)
                bind(insert, 3, r.sessionId)
                bind(insert, 4, r.model)
                sqlite3_bind_double(insert, 5, r.timestamp.timeIntervalSince1970)
                for (i, n) in [r.input, r.output, r.cacheRead, r.cacheWrite5m, r.cacheWrite1h, r.reasoning].enumerated() {
                    sqlite3_bind_int64(insert, Int32(6 + i), Int64(n))
                }
                if let cost = r.recordedCost { sqlite3_bind_double(insert, 12, cost) } else { sqlite3_bind_null(insert, 12) }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.sql(message) }
            }
            try setMark(mark, path: path)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func setMark(_ mark: FileMark, path: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO files VALUES (?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        sqlite3_bind_int64(stmt, 2, Int64(mark.offset))
        sqlite3_bind_int64(stmt, 3, Int64(bitPattern: mark.inode))
        let state = (try? JSONEncoder().encode(mark.state)) ?? Data()
        _ = state.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(state.count), SQLITE_TRANSIENT) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sql(message) }
    }

    // MARK: - Reading

    func mark(for path: String) throws -> FileMark? {
        let stmt = try prepare("SELECT offset, inode, state FROM files WHERE path = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let blob = sqlite3_column_blob(stmt, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 2))) }
        let state = blob.flatMap { try? JSONDecoder().decode(TranscriptParser.State.self, from: $0) } ?? .init()
        return FileMark(
            offset: UInt64(sqlite3_column_int64(stmt, 0)),
            inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)),
            state: state)
    }

    /// Usage grouped by agent, local day and model, from `since` on.
    func groups(since: Date) throws -> [Group] {
        let stmt = try prepare("""
            SELECT agent, date(ts, 'unixepoch', 'localtime') AS day, model,
                   SUM(input), SUM(output), SUM(cache_read), SUM(cache_write_5m), SUM(cache_write_1h),
                   SUM(recorded_cost), recorded_cost IS NOT NULL AS has_cost
            FROM usage_records WHERE ts >= ?
            GROUP BY agent, day, model, has_cost
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        var out: [Group] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let agent = Agent(rawValue: text(stmt, 0)), let day = Self.day(text(stmt, 1)) else { continue }
            out.append(Group(
                agent: agent, day: day, model: text(stmt, 2),
                input: int(stmt, 3), output: int(stmt, 4), cacheRead: int(stmt, 5),
                cacheWrite5m: int(stmt, 6), cacheWrite1h: int(stmt, 7),
                recordedCost: sqlite3_column_int(stmt, 9) != 0 ? sqlite3_column_double(stmt, 8) : nil))
        }
        return out
    }

    func earliest() throws -> Date? {
        let stmt = try prepare("SELECT MIN(ts) FROM usage_records")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    func recordCount() throws -> Int { try scalarInt("SELECT COUNT(*) FROM usage_records") }

    // MARK: - SQLite plumbing

    private var message: String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sql(message) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.sql(message) }
        return stmt
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.sql(message) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private func int(_ stmt: OpaquePointer?, _ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }

    static func day(_ s: String) -> DayKey? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? DayKey(year: p[0], month: p[1], day: p[2]) : nil
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
