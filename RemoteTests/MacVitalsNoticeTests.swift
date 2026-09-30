import XCTest

final class MacVitalsNoticeTests: XCTestCase {
    private var policy = MacVitalsNoticePolicy()
    private let warmPill = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "thermal")
    private let powerPill = BusyState(level: .strained, fps: 60, longEdge: 1920, reason: "power")
    private let encodingPill = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "encoding")

    private func battery(_ percent: Int?, warning: Int = 1, load: String = "ok") -> MacVitals {
        MacVitals(power: "battery", batteryPercent: percent, charging: false, batteryWarning: warning, load: load)
    }
    private func adapter(_ percent: Int = 80, charging: Bool = true) -> MacVitals {
        MacVitals(power: "ac", batteryPercent: percent, charging: charging, batteryWarning: 1, load: "ok")
    }
    private func see(_ vitals: MacVitals?, at now: TimeInterval, pill: BusyState? = nil) -> String? {
        policy.observe(vitals, pill: pill, now: now)
    }

    func testCopy() {
        XCTAssertEqual(MacVitalsNotice.unplugged(64), "Your Mac is now on battery · 64%.")
        XCTAssertEqual(MacVitalsNotice.unplugged(nil), "Your Mac is now on battery.")
        XCTAssertEqual(MacVitalsNotice.low(18), "Your Mac is on battery · 18%. Plug it in to keep going.")
        XCTAssertEqual(MacVitalsNotice.critical(9), "Your Mac is at 9% and may sleep soon. Plug it in or save your work.")
        XCTAssertEqual(MacVitalsNotice.critical(nil), "Your Mac’s battery is almost empty and it may sleep soon. Plug it in or save your work.")
        XCTAssertEqual(MacVitalsNotice.busy, "Your Mac is busy with other apps, so it may respond slowly.")
    }

    func testUnplugIsAnnouncedOnceUntilPluggedInAgain() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertEqual(see(battery(64), at: 10), MacVitalsNotice.unplugged(64))
        XCTAssertNil(see(battery(63), at: 20))
        XCTAssertNil(see(adapter(), at: 30))
        XCTAssertEqual(see(battery(62), at: 40), MacVitalsNotice.unplugged(62))
    }

    func testStartingOnBatteryIsNotAnUnplug() {
        XCTAssertNil(see(battery(64), at: 0))
        XCTAssertNil(see(battery(64), at: 10))
    }

    func testLowThenCriticalOncePerSession() {
        XCTAssertNil(see(battery(40), at: 0))
        XCTAssertEqual(see(battery(20), at: 10), MacVitalsNotice.low(20))
        XCTAssertNil(see(battery(19), at: 20))
        XCTAssertEqual(see(battery(10), at: 30), MacVitalsNotice.critical(10))
        XCTAssertNil(see(battery(9), at: 40))
        XCTAssertNil(see(battery(5), at: 50))
    }

    func testStartingLowNotifiesAtOnce() {
        XCTAssertEqual(see(battery(15), at: 0), MacVitalsNotice.low(15))
    }

    func testHoveringAtTwentyNotifiesOnce() {
        XCTAssertEqual(see(battery(20), at: 0), MacVitalsNotice.low(20))
        for (index, percent) in [21, 20, 22, 19, 24, 20].enumerated() {
            XCTAssertNil(see(battery(percent), at: Double(index + 1) * 10), "\(percent)%")
        }
        XCTAssertNil(see(battery(25), at: 100), "25 % re-arms without a notice")
        XCTAssertEqual(see(battery(20), at: 110), MacVitalsNotice.low(20))
    }

    func testHoveringAtTenNotifiesOnce() {
        XCTAssertEqual(see(battery(10), at: 0), MacVitalsNotice.critical(10))
        for (index, percent) in [11, 10, 12, 9, 14, 10].enumerated() {
            XCTAssertNil(see(battery(percent), at: Double(index + 1) * 10), "\(percent)%")
        }
        XCTAssertNil(see(battery(15), at: 100))
        XCTAssertEqual(see(battery(10), at: 110), MacVitalsNotice.critical(10))
    }

    func testPluggingInReArms() {
        XCTAssertEqual(see(battery(18), at: 0), MacVitalsNotice.low(18))
        XCTAssertNil(see(adapter(18), at: 10))
        XCTAssertEqual(see(battery(18), at: 20), MacVitalsNotice.low(18), "Low outranks the unplug it came with")
        XCTAssertNil(see(battery(18), at: 30), "…and the unplug is not shown afterwards")
    }

    func testTheMostSevereWins() {
        XCTAssertNil(see(adapter(8), at: 0))
        XCTAssertEqual(see(battery(8), at: 10), MacVitalsNotice.critical(8))
        XCTAssertNil(see(battery(8), at: 20))
        XCTAssertNil(see(battery(7), at: 30), "Critical also disarms the milder 20 % notice")
    }

    func testMacOSFinalWarningIsCritical() {
        XCTAssertEqual(see(battery(30, warning: 3), at: 0), MacVitalsNotice.critical(30))
        var fresh = MacVitalsNoticePolicy()
        XCTAssertEqual(fresh.observe(battery(nil, warning: 3), pill: nil, now: 0), MacVitalsNotice.critical(nil))
    }

    func testBusyIsOncePerSession() {
        XCTAssertEqual(see(adapter().withLoad("busy"), at: 0), MacVitalsNotice.busy)
        XCTAssertNil(see(adapter(), at: 10))
        XCTAssertNil(see(adapter().withLoad("busy"), at: 20))
        var next = MacVitalsNoticePolicy()
        XCTAssertEqual(next.observe(adapter().withLoad("busy"), pill: nil, now: 30), MacVitalsNotice.busy, "A new session announces it again")
    }

    func testNoticesAreSpacedSoNoneIsOverwritten() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertEqual(see(battery(64, load: "busy"), at: 1), MacVitalsNotice.unplugged(64))
        XCTAssertNil(see(battery(64, load: "busy"), at: 2))
        XCTAssertNil(see(battery(64, load: "busy"), at: 6.9))
        XCTAssertEqual(see(battery(64, load: "busy"), at: 7), MacVitalsNotice.busy)
    }

    func testCriticalWaitsForSpacingButNotForAPill() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertEqual(see(battery(30), at: 1), MacVitalsNotice.unplugged(30))
        XCTAssertNil(see(battery(9), at: 3, pill: warmPill), "Still inside the 6 s of the last notice")
        XCTAssertEqual(see(battery(9), at: 7, pill: warmPill), MacVitalsNotice.critical(9))
    }

    func testThermalOrPowerPillHoldsTheMilderNotices() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertNil(see(battery(64), at: 1, pill: powerPill))
        XCTAssertEqual(see(battery(64), at: 3), MacVitalsNotice.unplugged(64), "Shown once the pill clears")
        XCTAssertNil(see(battery(18), at: 20, pill: warmPill))
        XCTAssertEqual(see(battery(18), at: 21, pill: encodingPill), MacVitalsNotice.low(18), "Only thermal or power pills hold")
        XCTAssertNil(see(battery(18).withLoad("busy"), at: 40, pill: warmPill))
        XCTAssertEqual(see(battery(18).withLoad("busy"), at: 41), MacVitalsNotice.busy)
    }

    func testAHeldUnplugNoticeExpires() {
        XCTAssertNil(see(adapter(), at: 0))
        XCTAssertNil(see(battery(64), at: 1, pill: warmPill))
        XCTAssertNil(see(battery(64), at: 12), "10 s after the unplug, 'now on battery' is no longer news")
    }

    func testMissingOrUnknownVitalsSayNothing() {
        XCTAssertNil(see(nil, at: 0))
        XCTAssertNil(see(MacVitals(power: "solar", batteryPercent: 3), at: 10))
    }
}

private extension MacVitals {
    func withLoad(_ load: String) -> MacVitals {
        var copy = self
        copy.load = load
        return copy
    }
}
