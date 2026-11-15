import Foundation

/// Where the Mac is drawing power from.
public enum PowerSource: Sendable, Equatable {
    case ac
    /// On battery. `percent` is nil when the charge couldn't be read.
    case battery(percent: Int?)
    /// The power source couldn't be determined. Policy treats this conservatively.
    case unknown
}

/// Mirrors `ProcessInfo.ThermalState`, so `Policy` stays free of system types.
public enum ThermalState: Int, Sendable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Everything `Policy` needs to know about the machine.
public struct PowerState: Sendable, Equatable {
    public var source: PowerSource
    public var lowPowerMode: Bool
    public var thermal: ThermalState
    /// The lid helper is registered and approved by the user (build step 2).
    public var lidHelperApproved: Bool

    public init(
        source: PowerSource,
        lowPowerMode: Bool = false,
        thermal: ThermalState = .nominal,
        lidHelperApproved: Bool = false
    ) {
        self.source = source
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.lidHelperApproved = lidHelperApproved
    }
}

/// User-configurable settings that affect the decision.
public struct Prefs: Sendable, Equatable {
    public var keepAwakeEnabled: Bool
    public var keepDisplayAwake: Bool
    /// On battery, allow sleep below this charge.
    public var batteryFloorPercent: Int
    public var lidClosedModeEnabled: Bool
    /// On battery, never keep a closed lid awake below this charge.
    public var lidClosedBatteryFloorPercent: Int
    /// A lease expires after this long without a signal.
    public var signalTimeout: TimeInterval
    /// A waiting lease expires this long after waiting started.
    public var waitingCap: TimeInterval
    /// Adapters release a busy session with no transcript or status writes for this long.
    public var busyQuietLimit: TimeInterval

    public init(
        keepAwakeEnabled: Bool = true,
        keepDisplayAwake: Bool = false,
        batteryFloorPercent: Int = 50,
        lidClosedModeEnabled: Bool = false,
        lidClosedBatteryFloorPercent: Int = 30,
        signalTimeout: TimeInterval = 10 * 60,
        waitingCap: TimeInterval = 60 * 60,
        busyQuietLimit: TimeInterval = 60 * 60
    ) {
        self.keepAwakeEnabled = keepAwakeEnabled
        self.keepDisplayAwake = keepDisplayAwake
        self.batteryFloorPercent = batteryFloorPercent
        self.lidClosedModeEnabled = lidClosedModeEnabled
        self.lidClosedBatteryFloorPercent = lidClosedBatteryFloorPercent
        self.signalTimeout = signalTimeout
        self.waitingCap = waitingCap
        self.busyQuietLimit = busyQuietLimit
    }

    public static let `default` = Prefs()
}
