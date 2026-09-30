import XCTest

@MainActor
private final class FakeVitalsSources: MacVitalsSources {
    var powerGeneration = 0
    var memoryPressure: MacMemoryPressure = .normal
    var power: MacPowerReading? = MacPowerReading(power: "battery", batteryPercent: 64, charging: false)
    var warning = 1
    var thermal = 0
    var lowPower = false
    var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    var own = 0.0
    var processors = 10
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var powerReads = 0
    private(set) var tickReads = 0

    func start() { started += 1 }
    func stop() { stopped += 1 }
    func readPower() -> MacPowerReading? { powerReads += 1; return power }
    func batteryWarningLevel() -> Int { warning }
    func thermalState() -> Int { thermal }
    func lowPowerMode() -> Bool { lowPower }
    func cpuTicks() -> CPUTicks? { tickReads += 1; return ticks }
    func ownCPUSeconds() -> Double { own }
    func processorCount() -> Int { processors }

    /// `busy` of every processor ran for `seconds`; `ownShare` of all capacity was Farside.
    func run(seconds: Double, busy: Double, ownShare: Double = 0) {
        let total = UInt32(seconds * 100 * Double(processors))
        let busyTicks = UInt32((Double(total) * busy).rounded())
        ticks.user &+= busyTicks
        ticks.idle &+= total - busyTicks
        own += seconds * Double(processors) * ownShare
    }
}

@MainActor
final class MacVitalsMonitorTests: XCTestCase {
    // MARK: Processor arithmetic

    func testOthersFractionSubtractsFarside() throws {
        let a = CPUTicks(user: 1000, system: 500, idle: 8500, nice: 0)
        let b = CPUTicks(user: 1800, system: 1000, idle: 8700, nice: 0)
        let whole = try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 10))
        XCTAssertEqual(whole, 1300.0 / 1500.0, accuracy: 0.0001)
        let others = try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 6, wallSeconds: 2, processors: 10))
        XCTAssertEqual(others, 1300.0 / 1500.0 - 0.3, accuracy: 0.0001, "6 CPU-seconds of 20 available were Farside's")
    }

    func testNiceTicksCountAsBusy() throws {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 0, system: 0, idle: 100, nice: 100)
        XCTAssertEqual(try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 1)), 0.5, accuracy: 0.0001)
    }

    func testTickCountersWrap() throws {
        let a = CPUTicks(user: UInt32.max - 99, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 100, system: 0, idle: 200, nice: 0)
        XCTAssertEqual(try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 4)), 0.5, accuracy: 0.0001)
    }

    func testNoElapsedTimeIsNoSample() {
        let a = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(MacCPU.othersFraction(previous: a, current: a, ownCPUSeconds: 0, wallSeconds: 2, processors: 4))
        let b = CPUTicks(user: 20, system: 10, idle: 20, nice: 0)
        XCTAssertNil(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 0, processors: 4))
        XCTAssertNil(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 0, wallSeconds: 2, processors: 0))
    }

    func testFractionIsClamped() throws {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 10, system: 0, idle: 90, nice: 0)
        XCTAssertEqual(try XCTUnwrap(MacCPU.othersFraction(previous: a, current: b, ownCPUSeconds: 5, wallSeconds: 1, processors: 1)), 0)
    }

    // MARK: Policy

    func testBusyNeedsTenSecondsAtEightyFivePercent() {
        var policy = MacLoadPolicy()
        for _ in 0..<4 { policy.observe(processorFraction: 0.9, over: 2) }
        XCTAssertEqual(policy.level, .ok, "8 s is not enough")
        policy.observe(processorFraction: 0.9, over: 2)
        XCTAssertEqual(policy.level, .busy)
        XCTAssertEqual(policy.cause, .processor)
    }

    func testExactlyEightyFiveCounts() {
        var policy = MacLoadPolicy()
        for _ in 0..<5 { policy.observe(processorFraction: 0.85, over: 2) }
        XCTAssertEqual(policy.level, .busy)
    }

    func testBetweenThresholdsKeepsTheLevel() {
        var calm = MacLoadPolicy()
        for _ in 0..<10 { calm.observe(processorFraction: 0.8, over: 2) }
        XCTAssertEqual(calm.level, .ok)
        var busy = MacLoadPolicy()
        for _ in 0..<5 { busy.observe(processorFraction: 0.95, over: 2) }
        for _ in 0..<10 { busy.observe(processorFraction: 0.75, over: 2) }
        XCTAssertEqual(busy.level, .busy, "70–85 % holds whichever level it had")
    }

    func testClearsOnceTheTenSecondAverageDropsBelowSeventy() {
        var policy = MacLoadPolicy()
        for _ in 0..<5 { policy.observe(processorFraction: 0.95, over: 2) }
        for _ in 0..<2 { policy.observe(processorFraction: 0.5, over: 2) }
        XCTAssertEqual(policy.level, .busy, "Rolling mean (3 × 95 % + 2 × 50 %) / 5 = 77 %")
        policy.observe(processorFraction: 0.5, over: 2)
        XCTAssertEqual(policy.level, .ok, "(2 × 95 % + 3 × 50 %) / 5 = 68 %")
        XCTAssertNil(policy.cause)
    }

    func testTimerJitterStillFillsTheWindow() {
        var policy = MacLoadPolicy()
        for _ in 0..<4 { policy.observe(processorFraction: 0.9, over: 2.25) }
        policy.observe(processorFraction: 0.9, over: 2.0)
        XCTAssertEqual(policy.level, .busy)
    }

    func testMemoryPressure() {
        var policy = MacLoadPolicy()
        policy.observe(memoryPressure: .warning)
        XCTAssertEqual(policy.level, .ok)
        policy.observe(memoryPressure: .critical)
        XCTAssertEqual(policy.level, .busy)
        XCTAssertEqual(policy.cause, .memory)
        policy.observe(memoryPressure: .warning)
        XCTAssertEqual(policy.level, .busy, "Warning neither sets nor clears")
        policy.observe(memoryPressure: .normal)
        XCTAssertEqual(policy.level, .ok)
    }

    func testMemoryNamesTheCauseWhenBoth() {
        var policy = MacLoadPolicy()
        for _ in 0..<5 { policy.observe(processorFraction: 0.95, over: 2) }
        policy.observe(memoryPressure: .critical)
        XCTAssertEqual(policy.cause, .memory)
        policy.observe(memoryPressure: .normal)
        XCTAssertEqual(policy.cause, .processor)
    }

    func testNonsenseSamplesAreIgnored() {
        var policy = MacLoadPolicy()
        policy.observe(processorFraction: .nan, over: 2)
        policy.observe(processorFraction: 0.9, over: -1)
        policy.observe(processorFraction: 0.9, over: 0)
        for _ in 0..<4 { policy.observe(processorFraction: 0.9, over: 2) }
        XCTAssertEqual(policy.level, .ok, "Ignored samples fill no part of the window")
    }

    // MARK: Monitor

    func testNothingIsSampledOutsideASession() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        XCTAssertNil(monitor.current(now: 0))
        XCTAssertEqual(fake.started, 0)
        XCTAssertEqual(fake.tickReads + fake.powerReads, 0)
        monitor.start(now: 0)
        monitor.start(now: 0.1)
        XCTAssertEqual(fake.started, 1, "A second start is a no-op")
        XCTAssertTrue(monitor.isRunning)
        XCTAssertNotNil(monitor.current(now: 0.25))
        monitor.stop()
        XCTAssertEqual(fake.stopped, 1)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertNil(monitor.current(now: 1))
    }

    func testProcessorIsSampledEveryTwoSeconds() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        XCTAssertEqual(fake.tickReads, 1, "Baseline")
        for step in 1...7 { _ = monitor.current(now: Double(step) * 0.25) }
        XCTAssertEqual(fake.tickReads, 1)
        _ = monitor.current(now: 2)
        XCTAssertEqual(fake.tickReads, 2)
        _ = monitor.current(now: 2.25)
        XCTAssertEqual(fake.tickReads, 2)
    }

    func testPowerIsReadOnChangeAtMostOncePerSecond() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        XCTAssertEqual(fake.powerReads, 1)
        _ = monitor.current(now: 0.5)
        XCTAssertEqual(fake.powerReads, 1, "No notification, no read")
        fake.powerGeneration += 1
        fake.power = MacPowerReading(power: "ac", batteryPercent: 64, charging: true)
        XCTAssertEqual(monitor.current(now: 0.75)?.power, "battery", "Too soon after the last read")
        XCTAssertEqual(monitor.current(now: 1.0)?.power, "ac")
        XCTAssertEqual(fake.powerReads, 2)
        _ = monitor.current(now: 1.25)
        XCTAssertEqual(fake.powerReads, 2)
    }

    func testReportsBatteryThermalAndLowPowerMode() throws {
        let fake = FakeVitalsSources()
        fake.thermal = 2
        fake.lowPower = true
        fake.warning = 2
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        let vitals = try XCTUnwrap(monitor.current(now: 0.25))
        XCTAssertEqual(vitals, MacVitals(power: "battery", batteryPercent: 64, charging: false, batteryWarning: 2,
                                         thermal: 2, lowPowerMode: true, load: "ok", loadCause: nil))
    }

    func testFailedPowerReadOmitsOnlyBatteryFields() throws {
        let fake = FakeVitalsSources()
        fake.power = nil
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        let vitals = try XCTUnwrap(monitor.current(now: 0.25))
        XCTAssertNil(vitals.power)
        XCTAssertNil(vitals.batteryPercent)
        XCTAssertNil(vitals.batteryWarning)
        XCTAssertEqual(vitals.thermal, 0)
        XCTAssertEqual(vitals.load, "ok")
    }

    func testWarningLevelNeedsABattery() throws {
        let fake = FakeVitalsSources()
        fake.power = MacPowerReading(power: "ac")
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        XCTAssertNil(try XCTUnwrap(monitor.current(now: 0.25)).batteryWarning)
    }

    func testBusyAfterTenSecondsOfOtherApps() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        var levels: [Double: String] = [:]
        for step in 1...48 {
            let now = Double(step) * 0.25
            fake.run(seconds: 0.25, busy: 0.95)
            levels[now] = monitor.current(now: now)?.load
        }
        XCTAssertEqual(levels[9.75], "ok")
        XCTAssertEqual(levels[10], "busy")
        XCTAssertEqual(monitor.current(now: 12)?.loadCause, "processor")
    }

    func testFarsidesOwnLoadIsSubtracted() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        for step in 1...120 {
            fake.run(seconds: 0.25, busy: 0.95, ownShare: 0.3)
            XCTAssertEqual(monitor.current(now: Double(step) * 0.25)?.load, "ok", "Farside's own 30 % must not count")
        }
    }

    func testMemoryPressureMakesTheMacBusy() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        fake.memoryPressure = .critical
        XCTAssertEqual(monitor.current(now: 0.25)?.load, "busy")
        XCTAssertEqual(monitor.current(now: 0.5)?.loadCause, "memory")
        fake.memoryPressure = .normal
        XCTAssertEqual(monitor.current(now: 0.75)?.load, "ok")
    }

    func testStopForgetsTheLoad() {
        let fake = FakeVitalsSources()
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        fake.memoryPressure = .critical
        _ = monitor.current(now: 0.25)
        monitor.stop()
        fake.memoryPressure = .normal
        monitor.start(now: 10)
        XCTAssertEqual(monitor.current(now: 10.25)?.load, "ok")
    }

    func testOutputAlwaysValidates() throws {
        let fake = FakeVitalsSources()
        fake.power = MacPowerReading(power: "a power word far too long", batteryPercent: 250, charging: nil)
        fake.thermal = 9
        fake.warning = 0
        let monitor = MacVitalsMonitor(sources: fake)
        monitor.start(now: 0)
        let vitals = try XCTUnwrap(monitor.current(now: 0.25))
        XCTAssertNoThrow(try vitals.validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 1, macVitals: vitals).validate())
    }
}
