import CoreServices
import Foundation

/// Calls back when any process in a set exits, via kqueue (`NOTE_EXIT`). No polling.
@MainActor
public final class ProcessExitWatcher {
    private var sources: [Int32: any DispatchSourceProcess] = [:]
    private let onExit: @MainActor (Int32) -> Void

    public init(onExit: @escaping @MainActor (Int32) -> Void) {
        self.onExit = onExit
    }

    /// Watches exactly `pids`: adds new ones, drops the rest.
    public func watch(_ pids: Set<Int32>) {
        for (pid, source) in sources where !pids.contains(pid) {
            source.cancel()
            sources[pid] = nil
        }
        for pid in pids where sources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.sources[pid]?.cancel()
                    self?.sources[pid] = nil
                    self?.onExit(pid)
                }
            }
            source.resume()
            sources[pid] = source
        }
    }

    isolated deinit {
        sources.values.forEach { $0.cancel() }
    }
}

/// FSEvents on one directory tree, coalesced by `latency`.
@MainActor
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    /// Returns nil if the stream couldn't be created (e.g. the path doesn't exist).
    public init?(path: String, latency: TimeInterval, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
