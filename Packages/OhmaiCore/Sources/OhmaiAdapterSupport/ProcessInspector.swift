import Darwin
import Foundation

/// Answers "is this pid alive, and since when?". Faked in tests.
public protocol ProcessInspector: Sendable {
    /// The process's start time, or nil if no such live process exists (zombies count as dead).
    func startTime(of pid: Int32) -> Date?
}

/// Reads the kernel's process table via `sysctl(KERN_PROC_PID)`.
public struct DarwinProcessInspector: ProcessInspector {
    public init() {}

    public func startTime(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        guard info.kp_proc.p_stat != SZOMB else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}

/// Whether a live process is still the one an agent recorded, rather than a reused pid.
public enum ProcessIdentity {
    /// How far a recorded time may sit before the kernel's start time (clock skew, rounding).
    static let tolerance: TimeInterval = 5

    /// - `sessionStartedAt`: when the agent says the session began. A process can't start
    ///   after its own session, so a later kernel start time means the pid was reused.
    /// - `recordedProcessStart`: the agent's copy of the process start time, if it keeps one.
    ///
    /// With neither, this can't tell and returns true; lease expiry still applies.
    public static func matches(kernelStart: Date, sessionStartedAt: Date?, recordedProcessStart: Date?) -> Bool {
        if let recordedProcessStart {
            return abs(kernelStart.timeIntervalSince(recordedProcessStart)) <= tolerance
        }
        if let sessionStartedAt {
            return kernelStart <= sessionStartedAt.addingTimeInterval(tolerance)
        }
        return true
    }
}
