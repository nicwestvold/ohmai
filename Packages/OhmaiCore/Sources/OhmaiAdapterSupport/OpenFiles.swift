import Darwin
import Foundation

/// Which processes have a file open, for agents that don't record their pid. Faked in tests.
public protocol OpenFileLookup: Sendable {
    /// Pids of live processes whose executable name is `name`.
    func pids(named name: String) -> [Int32]
    /// Paths of regular files `pid` has open. Empty if it can't be inspected.
    func openPaths(of pid: Int32) -> Set<String>
}

/// libproc implementation. Only sees the current user's processes, which is all we need.
public struct LibprocOpenFiles: OpenFileLookup {
    public init() {}

    public func pids(named name: String) -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return Self.string(buffer) == name
        }
    }

    public func openPaths(of pid: Int32) -> Set<String> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard filled > 0 else { return [] }

        var paths = Set<String>()
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            guard got > 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                Self.string(Array(raw.bindMemory(to: CChar.self)))
            }
            if !path.isEmpty { paths.insert(path) }
        }
        return paths
    }

    /// The kernel's spelling of `path` (e.g. `/var/…` becomes `/private/var/…`), which is
    /// what `openPaths` reports. Foundation's `resolvingSymlinksInPath` goes the other way.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(decoding: UnsafeRawBufferPointer(start: resolved, count: strlen(resolved)), as: UTF8.self)
    }

    private static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
