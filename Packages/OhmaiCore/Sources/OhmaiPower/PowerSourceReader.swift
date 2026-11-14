import Foundation
import IOKit.ps
import OhmaiCore

/// Reads the current power source from IOKit.
enum PowerSourceReader {
    static func current() -> PowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return parse(providingType: providing, descriptions: descriptions)
    }

    // IOKit/ps/IOPSKeys.h values, spelled out so parsing is testable without IOKit.
    static let acPower = "AC Power"                // kIOPSACPowerValue
    static let batteryPower = "Battery Power"      // kIOPSBatteryPowerValue
    static let typeKey = "Type"                    // kIOPSTypeKey
    static let internalBattery = "InternalBattery" // kIOPSInternalBatteryType
    static let currentCapacityKey = "Current Capacity" // kIOPSCurrentCapacityKey
    static let maxCapacityKey = "Max Capacity"     // kIOPSMaxCapacityKey

    /// Desktops report "AC Power" with no batteries. Anything else (UPS, unrecognised values)
    /// is treated as battery with an unknown charge, which the policy handles conservatively.
    static func parse(providingType: String?, descriptions: [[String: Any]]) -> PowerSource {
        switch providingType {
        case acPower:
            return .ac
        case batteryPower:
            let battery = descriptions.first { $0[typeKey] as? String == internalBattery }
            return .battery(percent: battery.flatMap(percent(of:)))
        case nil:
            return .unknown
        default:
            return .battery(percent: nil)
        }
    }

    private static func percent(of description: [String: Any]) -> Int? {
        guard let current = description[currentCapacityKey] as? Int,
              let max = description[maxCapacityKey] as? Int, max > 0 else { return nil }
        return Swift.min(100, Swift.max(0, current * 100 / max))
    }
}
