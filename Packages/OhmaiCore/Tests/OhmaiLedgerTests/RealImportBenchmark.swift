import Darwin
import Foundation
import Testing
import OhmaiUsage
@testable import OhmaiLedger

/// Opt-in: imports this Mac's real transcripts into a scratch database and reports timing and
/// totals (numbers only). Run with `OHMAI_BENCH_DB=/path/to/scratch.sqlite swift test -c release
/// --filter RealImportBenchmark`. Never runs by default.
@Suite("RealImportBenchmark", .enabled(if: ProcessInfo.processInfo.environment["OHMAI_BENCH_DB"] != nil))
struct RealImportBenchmark {
    @Test func firstImportThenIncremental() async throws {
        let db = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OHMAI_BENCH_DB"]!)
        let importer = try UsageImporter(database: db)
        let clock = ContinuousClock()
        var report = UsageImporter.Report()
        let first = try await clock.measure { report = await importer.importAll() }
        print("BENCH peak footprint after first import: \(peakFootprintMB()) MB")
        print("BENCH first import: \(first), files \(report.files), \(report.bytes / 1_048_576) MB, records \(report.records)")
        let second = try await clock.measure { report = await importer.importAll() }
        print("BENCH second import: \(second), files \(report.files), records \(report.records)")
        let comparison = await importer.comparison()
        for row in comparison.rows + [comparison.total] {
            print("BENCH \(row.agent?.rawValue ?? "total"): this month \(row.thisMonth.tokens) tok $\(Int(row.thisMonth.cost)) | same days \(row.lastMonthSameDays.tokens) tok $\(Int(row.lastMonthSameDays.cost)) | last month \(row.lastMonthTotal.tokens) tok $\(Int(row.lastMonthTotal.cost)) | basis \(row.basis) change \(row.change.map { String(format: "%+.0f%%", $0 * 100) } ?? "new") partial \(comparison.partialHistory)")
        }
    }
}

private func peakFootprintMB() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return info.ledger_phys_footprint_peak / 1_048_576
}
