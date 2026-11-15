import Testing
import OhmaiCore
@testable import OhmaiPowerSource

@Suite("PowerSourceReader.parse")
struct PowerSourceReaderTests {
    private func battery(current: Int, max: Int = 100) -> [String: Any] {
        ["Type": "InternalBattery", "Current Capacity": current, "Max Capacity": max]
    }

    @Test func acIsAC() {
        #expect(PowerSourceReader.parse(providingType: "AC Power", descriptions: [battery(current: 10)]) == .ac)
    }

    @Test func desktopWithNoBatteriesIsAC() {
        #expect(PowerSourceReader.parse(providingType: "AC Power", descriptions: []) == .ac)
    }

    @Test func batteryReportsPercent() {
        #expect(PowerSourceReader.parse(providingType: "Battery Power", descriptions: [battery(current: 73)]) == .battery(percent: 73))
    }

    @Test func percentIsScaledByMaxCapacity() {
        #expect(PowerSourceReader.parse(providingType: "Battery Power", descriptions: [battery(current: 2500, max: 5000)]) == .battery(percent: 50))
    }

    @Test func ignoresNonInternalSources() {
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 99, "Max Capacity": 100]
        #expect(PowerSourceReader.parse(providingType: "Battery Power", descriptions: [ups, battery(current: 20)]) == .battery(percent: 20))
    }

    @Test func missingCapacityIsUnknownPercent() {
        #expect(PowerSourceReader.parse(providingType: "Battery Power", descriptions: [["Type": "InternalBattery"]]) == .battery(percent: nil))
        #expect(PowerSourceReader.parse(providingType: "Battery Power", descriptions: [battery(current: 50, max: 0)]) == .battery(percent: nil))
    }

    @Test func upsOrUnrecognisedIsBatteryWithUnknownCharge() {
        #expect(PowerSourceReader.parse(providingType: "UPS Power", descriptions: []) == .battery(percent: nil))
    }

    @Test func noProvidingTypeIsUnknown() {
        #expect(PowerSourceReader.parse(providingType: nil, descriptions: []) == .unknown)
    }
}
