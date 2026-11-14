import Foundation

/// Why ohmai is letting the Mac sleep.
public enum SleepReason: Sendable, Equatable {
    case noLeases
    case keepAwakeOff
    case thermal(ThermalState)
    case batteryLow(percent: Int?)
    case lowPowerMode
    case powerSourceUnknown

    /// True when agents are running but the power policy overrode them, which is worth
    /// telling the user about ("agent still running").
    public var overridesAgents: Bool {
        switch self {
        case .noLeases, .keepAwakeOff: false
        case .thermal, .batteryLow, .lowPowerMode, .powerSourceUnknown: true
        }
    }
}

/// Why ohmai is keeping the Mac awake.
public struct AwakeReason: Sendable, Equatable {
    public let sessionCount: Int
    public let source: PowerSource

    public init(sessionCount: Int, source: PowerSource) {
        self.sessionCount = sessionCount
        self.source = source
    }
}

public enum Decision: Sendable, Equatable {
    case allowSleep(SleepReason)
    case stayAwake(AwakeReason)
    case stayAwakeLidClosed(AwakeReason)

    public var keepsAwake: Bool {
        if case .allowSleep = self { false } else { true }
    }

    /// One line for the menu, e.g. "Awake: 2 agents · on AC".
    public var summary: String {
        switch self {
        case .allowSleep(let reason):
            switch reason {
            case .noLeases: return "Asleep: no agents"
            case .keepAwakeOff: return "Keep-awake is off"
            case .thermal(let t): return "Letting Mac sleep: thermal \(t)"
            case .batteryLow(let p): return "Letting Mac sleep: battery \(p.map { "\($0)%" } ?? "low")"
            case .lowPowerMode: return "Letting Mac sleep: Low Power Mode"
            case .powerSourceUnknown: return "Letting Mac sleep: power source unknown"
            }
        case .stayAwake(let r):
            return "Awake: \(Self.describe(r))"
        case .stayAwakeLidClosed(let r):
            return "Awake, lid closed: \(Self.describe(r))"
        }
    }

    private static func describe(_ r: AwakeReason) -> String {
        let agents = r.sessionCount == 1 ? "1 agent" : "\(r.sessionCount) agents"
        let source = switch r.source {
        case .ac: "on AC"
        case .battery(let p): "on battery \(p.map { "\($0)%" } ?? "")".trimmingCharacters(in: .whitespaces)
        case .unknown: "power unknown"
        }
        return "\(agents) · \(source)"
    }
}

/// The power policy. Pure: no I/O, no clock reads. `now` is an input so lease expiry is
/// decided here too, and a caller can't forget to drop expired leases.
public enum Policy {
    public static func decide(leases: [Lease], power: PowerState, prefs: Prefs, now: Date) -> Decision {
        // Rule 1: nothing to keep awake for.
        guard prefs.keepAwakeEnabled else { return .allowSleep(.keepAwakeOff) }
        let active = leases.filter { $0.isActive(at: now, prefs: prefs) }
        guard !active.isEmpty else { return .allowSleep(.noLeases) }

        // Rule 2: too hot.
        if power.thermal >= .serious { return .allowSleep(.thermal(power.thermal)) }

        // Rule 3: battery. "Below the floor" is strict: exactly at the floor stays awake.
        // An unreadable charge or source counts as below: when in doubt, release.
        switch power.source {
        case .ac:
            break
        case .unknown:
            return .allowSleep(.powerSourceUnknown)
        case .battery(let percent):
            guard let percent, percent >= prefs.batteryFloorPercent else {
                return .allowSleep(.batteryLow(percent: percent))
            }
            if power.lowPowerMode { return .allowSleep(.lowPowerMode) }
        }

        let reason = AwakeReason(sessionCount: active.count, source: power.source)

        // Rule 4: lid-closed mode. Only busy leases count; waiting never keeps a closed lid awake.
        if prefs.lidClosedModeEnabled,
           power.lidHelperApproved,
           active.contains(where: \.isBusy),
           power.thermal <= .fair,
           lidBatteryOK(power.source, floor: prefs.lidClosedBatteryFloorPercent) {
            return .stayAwakeLidClosed(reason)
        }

        // Rule 5.
        return .stayAwake(reason)
    }

    private static func lidBatteryOK(_ source: PowerSource, floor: Int) -> Bool {
        switch source {
        case .ac: true
        case .battery(let percent): percent.map { $0 >= floor } ?? false
        case .unknown: false
        }
    }
}
