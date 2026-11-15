import Foundation
import Observation
import OhmaiAdapterSupport
import OhmaiLedger
import OhmaiUsage
import os

private let log = Logger(subsystem: "com.westvold.ohmai", category: "usage")

/// Keeps the month comparison fresh. Imports run on the importer actor at background
/// priority; this type only holds the cached result the dropdown reads. No timers: it wakes
/// for FSEvents (coalesced to 10s) and when the dropdown opens.
@MainActor
@Observable
final class UsageModel {
    private(set) var comparison: MonthComparison?
    private(set) var importing = false
    private(set) var failed: String?

    @ObservationIgnored private var importer: UsageImporter?
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var pending = Set<String>()
    @ObservationIgnored private var draining = false

    func start() {
        do {
            let importer = try UsageImporter(database: Self.databaseURL)
            self.importer = importer
            importing = true
            Task(priority: .background) {
                let report = await importer.importAll()
                log.notice("initial import: \(report.files) files, \(report.records) records")
                self.importing = false
                await self.refresh()
                self.watch(importer.sources)
            }
        } catch {
            failed = "Couldn't open the usage database"
            log.error("ledger open failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cheap (one grouped query); called when the dropdown opens so day and month
    /// boundaries roll over without a timer.
    func refresh() async {
        guard let importer else { return }
        let next = await importer.comparison()
        if next != comparison { comparison = next }
    }

    private func watch(_ sources: [UsageImporter.Source]) {
        watchers = sources.compactMap { source in
            DirectoryWatcher(path: source.root.path, latency: 10) { [weak self] paths in
                self?.enqueue(paths)
            }
        }
    }

    private func enqueue(_ paths: [String]) {
        pending.formUnion(paths)
        guard !draining, let importer else { return }
        draining = true
        Task(priority: .background) {
            while !self.pending.isEmpty {
                let batch = Array(self.pending)
                self.pending.removeAll()
                let report = await importer.importFiles(batch)
                if report.changed { await self.refresh() }
            }
            self.draining = false
        }
    }

    static var databaseURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["OHMAI_LEDGER_DB"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        return UsageImporter.defaultDatabase
    }
}
