import XCTest

final class MacVitalsPowerTests: XCTestCase {
    private func battery(_ current: Any?, max: Any? = 100, charging: Bool? = false,
                         state: String = "Battery Power", present: Bool = true) -> [String: Any] {
        var description: [String: Any] = ["Type": "InternalBattery", "Power Source State": state, "Is Present": present]
        if let current { description["Current Capacity"] = current }
        if let max { description["Max Capacity"] = max }
        if let charging { description["Is Charging"] = charging }
        return description
    }

    private func read(_ descriptions: [[String: Any]], _ providing: String?) -> MacPowerReading? {
        MacPowerParser.reading(descriptions: descriptions, providingType: providing)
    }

    func testLaptopOnBattery() {
        XCTAssertEqual(read([battery(64)], "Battery Power"), MacPowerReading(power: "battery", batteryPercent: 64, charging: false))
    }

    func testLaptopChargingAndHeld() {
        XCTAssertEqual(read([battery(82, charging: true, state: "AC Power")], "AC Power"),
                       MacPowerReading(power: "ac", batteryPercent: 82, charging: true))
        XCTAssertEqual(read([battery(80, charging: false, state: "AC Power")], "AC Power"),
                       MacPowerReading(power: "ac", batteryPercent: 80, charging: false), "Optimised charging holds at 80 %")
    }

    func testDesktopHasNoBatteryFields() {
        XCTAssertEqual(read([], "AC Power"), MacPowerReading(power: "ac"))
    }

    func testUPSReportsAPercentOnlyWhenItHasOne() {
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 80, "Max Capacity": 100, "Power Source State": "Battery Power"]
        XCTAssertEqual(read([ups], "UPS Power"), MacPowerReading(power: "ups", batteryPercent: 80))
        XCTAssertEqual(read([["Type": "UPS"]], "UPS Power"), MacPowerReading(power: "ups"))
    }

    func testInternalBatteryWinsOverAUPS() {
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 30, "Max Capacity": 100]
        XCTAssertEqual(read([ups, battery(70, state: "AC Power")], "AC Power")?.batteryPercent, 70)
    }

    func testMissingKeysOmitOnlyWhatIsMissing() {
        XCTAssertEqual(read([battery(nil, max: nil, charging: nil)], "Battery Power"), MacPowerReading(power: "battery"))
    }

    func testCapacityIsARatioNotAssumedPercent() {
        XCTAssertEqual(read([battery(4200, max: 5000)], "Battery Power")?.batteryPercent, 84)
        XCTAssertEqual(read([battery(29)], "Battery Power")?.batteryPercent, 29, "No floating-point loss at Max Capacity 100")
        XCTAssertEqual(read([battery(57)], "Battery Power")?.batteryPercent, 57)
        XCTAssertEqual(read([battery(58)], "Battery Power")?.batteryPercent, 58)
        XCTAssertEqual(read([battery(1, max: 3)], "Battery Power")?.batteryPercent, 33)
        XCTAssertNil(read([battery(50, max: 0)], "Battery Power")?.batteryPercent)
        XCTAssertNil(read([battery(-5, max: 100)], "Battery Power")?.batteryPercent)
        XCTAssertEqual(read([battery(120, max: 100)], "Battery Power")?.batteryPercent, 100)
        XCTAssertNil(read([battery("64", max: 100)], "Battery Power")?.batteryPercent, "Only numbers count")
    }

    func testProvidingTypeFallsBackToTheBatterysState() {
        XCTAssertEqual(read([battery(50)], nil)?.power, "battery")
        XCTAssertEqual(read([battery(50, state: "AC Power")], "Solar")?.power, "ac")
        XCTAssertNil(read([battery(50, state: "Off Line")], nil)?.power)
    }

    func testAnAbsentBatteryIsIgnored() {
        XCTAssertEqual(read([battery(50, present: false)], "AC Power"), MacPowerReading(power: "ac"))
    }

    func testNothingKnownIsNil() {
        XCTAssertNil(read([], nil))
        XCTAssertNil(read([["Type": "Unknown"]], "Mystery"))
    }

    func testBridgedNumbersFromIOKit() {
        let bridged: [String: Any] = ["Type": "InternalBattery", "Current Capacity": NSNumber(value: 37),
                                      "Max Capacity": NSNumber(value: 100), "Is Charging": NSNumber(value: false),
                                      "Power Source State": "Battery Power"]
        XCTAssertEqual(read([bridged], "Battery Power"), MacPowerReading(power: "battery", batteryPercent: 37, charging: false))
    }

    @MainActor
    func testLiveSourcesReadThisMac() {
        let live = LiveMacVitalsSources()
        live.start()
        defer { live.stop() }
        XCTAssertNotNil(live.cpuTicks())
        XCTAssertGreaterThan(live.processorCount(), 0)
        XCTAssertGreaterThan(live.ownCPUSeconds(), 0)
        XCTAssertTrue(MacVitals.thermalRange.contains(live.thermalState()))
        XCTAssertTrue(MacVitals.warningRange.contains(live.batteryWarningLevel()))
        if let power = live.readPower() {
            XCTAssertTrue(power.power.map { ["battery", "ac", "ups"].contains($0) } ?? true)
            XCTAssertTrue(power.batteryPercent.map(MacVitals.percentRange.contains) ?? true)
            print("MacVitalsPowerTests live reading: \(power)")
        }
    }

    @MainActor
    func testLiveReadsAreCheap() {
        let live = LiveMacVitalsSources()
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 {
            _ = live.readPower()
            _ = live.cpuTicks()
            _ = live.ownCPUSeconds()
        }
        let perRead = (ProcessInfo.processInfo.systemUptime - start) / 200
        print("MacVitalsPowerTests one power + CPU read: \(String(format: "%.3f", perRead * 1000)) ms")
        XCTAssertLessThan(perRead, 0.01, "A read that runs at most once a second must stay far under 10 ms")
    }

    @MainActor
    func testStopIsSafeTwiceAndWithoutStart() {
        let live = LiveMacVitalsSources()
        live.stop()
        live.start()
        live.start()
        live.stop()
        live.stop()
        XCTAssertEqual(live.memoryPressure, .normal)
    }
}
