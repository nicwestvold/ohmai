import Foundation
import OhmaiCore
import OhmaiPower

/// The helper's one and only system command: `/usr/bin/pmset -a disablesleep 0|1`.
/// Fixed path, fixed arguments, no shell.
public struct PmsetSleepSetting: SleepSetting {
    public struct Failed: Error { public let status: Int32 }

    public init() {}

    public func setSleepDisabled(_ disabled: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failed(status: process.terminationStatus)
        }
    }
}

public struct SystemPowerReading: PowerReading {
    public init() {}

    public func read() -> (source: PowerSource, thermal: ThermalState) {
        (PowerSourceReader.current(), ThermalState(ProcessInfo.processInfo.thermalState))
    }
}
