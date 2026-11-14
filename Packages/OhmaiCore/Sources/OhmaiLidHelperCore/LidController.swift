import Foundation
import OhmaiCore
import OhmaiLidXPC

/// Turns system sleep off and on. The only real implementation runs `pmset`.
public protocol SleepSetting {
    func setSleepDisabled(_ disabled: Bool) throws
}

/// The helper's own view of power, independent of the app.
public protocol PowerReading {
    func read() -> (source: PowerSource, thermal: ThermalState)
}

public enum LidRefusal: Error, Equatable, CustomStringConvertible {
    case batteryBelowFloor(percent: Int?, floor: Int)
    case thermal(ThermalState)
    case powerSourceUnknown
    case sleepSettingFailed

    public var description: String {
        switch self {
        case .batteryBelowFloor(let p, let floor): "battery \(p.map { "\($0)%" } ?? "unknown") is below \(floor)%"
        case .thermal(let t): "thermal state is \(t)"
        case .powerSourceUnknown: "power source unknown"
        case .sleepSettingFailed: "pmset failed"
        }
    }
}

/// The dead-man switch. The app asks; this decides, and it defaults to sleep being allowed.
///
/// - `start()` always resets `disablesleep` to 0.
/// - A lease always expires: `tick(now:)` releases once `expiresAt` passes.
/// - Battery and thermal guards are checked on every engage, renew and tick.
/// - If turning sleep back on fails, it's retried on every tick until it succeeds.
@MainActor
public final class LidController {
    public private(set) var isEngaged = false
    public private(set) var expiresAt: Date?
    /// Turning sleep back on failed and must be retried.
    public private(set) var resetPending = false

    private var floor = 30
    private let sleep: any SleepSetting
    private let power: any PowerReading

    public init(sleep: any SleepSetting, power: any PowerReading) {
        self.sleep = sleep
        self.power = power
    }

    /// Whether the runtime needs to keep calling `tick(now:)`.
    public var needsTicking: Bool { isEngaged || resetPending }

    public func start() {
        reset()
    }

    /// Engages, or renews if already engaged. Returns nil on success.
    public func engage(leaseSeconds: Int, batteryFloorPercent: Int, now: Date) -> LidRefusal? {
        floor = batteryFloorPercent.clamped(to: LidHelperXPC.batteryFloorRange)
        if let refusal = guardRefusal() {
            if isEngaged || resetPending { reset() }
            return refusal
        }
        if !isEngaged {
            do {
                try sleep.setSleepDisabled(true)
            } catch {
                reset()  // the command may have half-applied
                return .sleepSettingFailed
            }
            isEngaged = true
        }
        expiresAt = now.addingTimeInterval(TimeInterval(leaseSeconds.clamped(to: LidHelperXPC.leaseSecondsRange)))
        return nil
    }

    /// Extends an existing lease. Never engages.
    public func renew(leaseSeconds: Int, batteryFloorPercent: Int, now: Date) -> Bool {
        guard isEngaged else { return false }
        return engage(leaseSeconds: leaseSeconds, batteryFloorPercent: batteryFloorPercent, now: now) == nil
    }

    /// Returns whether sleep is confirmed back on.
    @discardableResult
    public func release() -> Bool {
        reset()
        return !resetPending
    }

    public func tick(now: Date) {
        if isEngaged {
            if let expiresAt, now >= expiresAt {
                reset()
            } else if guardRefusal() != nil {
                reset()
            }
        } else if resetPending {
            reset()
        }
    }

    private func reset() {
        isEngaged = false
        expiresAt = nil
        do {
            try sleep.setSleepDisabled(false)
            resetPending = false
        } catch {
            resetPending = true
        }
    }

    private func guardRefusal() -> LidRefusal? {
        let (source, thermal) = power.read()
        if thermal >= .serious { return .thermal(thermal) }
        switch source {
        case .ac:
            return nil
        case .battery(let percent):
            guard let percent, percent >= floor else { return .batteryBelowFloor(percent: percent, floor: floor) }
            return nil
        case .unknown:
            return .powerSourceUnknown
        }
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
