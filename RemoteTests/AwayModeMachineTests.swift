import XCTest

final class AwayModeMachineTests: XCTestCase {
    private let ready = AwayConditions(enabled: true, sharingWanted: true, sharingActive: true, accessibility: true)

    func testArmsOnlyWhenEveryRequirementHolds() {
        for (name, change, reason) in [
            ("sharing off", { (c: inout AwayConditions) in c.sharingWanted = false }, AwayUnavailableReason.sharingOff),
            ("not running", { $0.sharingActive = false }, .sharingOff),
            ("locked", { $0.screenLocked = true }, .macLocked),
            ("no Accessibility", { $0.accessibility = false }, .needsAccessibility),
            ("managed", { $0.managed = true }, .managed),
            ("battery", { $0.onACPower = false }, .onBattery),
            ("safe mode", { $0.safeMode = true }, .safeMode)
        ] as [(String, (inout AwayConditions) -> Void, AwayUnavailableReason)] {
            var c = ready; change(&c)
            var m = AwayModeMachine()
            m.update(c, now: 0)
            XCTAssertEqual(m.phase, .off, name)
            XCTAssertEqual(AwayModeMachine.unavailableReason(c), reason, name)
        }
        var m = AwayModeMachine(); var off = ready; off.enabled = false
        m.update(off, now: 0); XCTAssertEqual(m.phase, .off, "Opt-in")
        m.update(ready, now: 0); XCTAssertEqual(m.phase, .armedPresent)
        XCTAssertTrue(m.holdsDisplayAwake); XCTAssertFalse(m.wantsCover); XCTAssertEqual(m.protocolState, .armed)
    }

    func testCoversAfterTwoIdleMinutesAndLocalInputResetsTheTimer() {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        m.tick(now: 119); XCTAssertEqual(m.phase, .armedPresent); XCTAssertEqual(m.coversIn(now: 119), 1)
        m.localInput(now: 100); m.tick(now: 219); XCTAssertEqual(m.phase, .armedPresent)
        m.tick(now: 220); XCTAssertEqual(m.phase, .armedCovered); XCTAssertTrue(m.wantsCover); XCTAssertEqual(m.protocolState, .covered)
    }

    func testAnyLocalTouchWhileCoveredLocks() {
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
        XCTAssertEqual(m.localInput(now: 2), .lock(.touched))
        XCTAssertEqual(m.phase, .locking(.touched)); XCTAssertTrue(m.wantsCover); XCTAssertTrue(m.holdsDisplayAwake)
        XCTAssertNil(m.localInput(now: 2.5), "One lock request at a time")
    }

    func testLockConfirmedByLockedScreenEndsAwayMode() {
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1); m.localInput(now: 2)
        var locked = ready; locked.screenLocked = true
        m.update(locked, now: 3)
        XCTAssertEqual(m.phase, .off); XCTAssertFalse(m.wantsCover); XCTAssertFalse(m.holdsDisplayAwake)
        m.update(ready, now: 100); XCTAssertEqual(m.phase, .armedPresent, "Re-arms after the owner unlocks")
    }

    func testLockTimeoutReleasesDisplayButKeepsCover() {
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1); m.localInput(now: 10)
        m.tick(now: 11.9); XCTAssertEqual(m.phase, .locking(.touched))
        m.tick(now: 12); XCTAssertEqual(m.phase, .lockFailed(.touched))
        XCTAssertTrue(m.wantsCover); XCTAssertFalse(m.holdsDisplayAwake, "Let the Mac's own display-sleep lock apply")
    }

    func testTouchAfterFailedLockRetries() {
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1); m.localInput(now: 10); m.tick(now: 12)
        XCTAssertEqual(m.localInput(now: 20), .lock(.touched)); XCTAssertEqual(m.phase, .locking(.touched))
    }

    func testLockingKeepsTheCoverOnlyWhenItWasCovered() {
        var present = AwayModeMachine(); present.update(ready, now: 0)
        XCTAssertEqual(present.end(.stopSharing, now: 1), .lock(.stopSharing))
        XCTAssertFalse(present.wantsCover, "Someone was using the Mac; don't black it out")
        var covered = AwayModeMachine(); covered.update(ready, now: 0); covered.coverNow(now: 1)
        covered.end(.stopSharing, now: 2); XCTAssertTrue(covered.wantsCover)
    }

    func testEveryExitLocksExceptTurningItOffAtTheMac() {
        for reason in [AwayEndReason.stopSharing, .quit, .expiry, .battery, .phoneRequest, .screensChanged] {
            var m = AwayModeMachine(); m.update(ready, now: 0)
            XCTAssertEqual(m.end(reason, now: 1), .lock(reason), reason.rawValue)
        }
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
        m.turnOffAtMac(); XCTAssertEqual(m.phase, .off); XCTAssertFalse(m.wantsCover)
    }

    func testStopSharingIsSeenThroughConditions() {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        var stopped = ready; stopped.sharingWanted = false; stopped.sharingActive = false
        XCTAssertEqual(m.update(stopped, now: 1), .lock(.stopSharing))
    }

    func testSharingBlipDoesNotEndAwayMode() {
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
        var blip = ready; blip.sharingActive = false
        XCTAssertNil(m.update(blip, now: 2)); XCTAssertEqual(m.phase, .armedCovered)
    }

    func testLosingARequirementLocks() {
        for change in [{ (c: inout AwayConditions) in c.accessibility = false }, { $0.managed = true }, { $0.safeMode = true }] {
            var m = AwayModeMachine(); m.update(ready, now: 0)
            var c = ready; change(&c)
            XCTAssertEqual(m.update(c, now: 1), .lock(.lostRequirement))
        }
    }

    func testMacLockedElsewhereJustEnds() {
        var m = AwayModeMachine(); m.update(ready, now: 0); m.coverNow(now: 1)
        var locked = ready; locked.screenLocked = true
        XCTAssertNil(m.update(locked, now: 2)); XCTAssertEqual(m.phase, .off)
    }

    func testBatteryWithoutAPhoneEndsAfterFiveMinutes() {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        var battery = ready; battery.onACPower = false; battery.batteryPercent = 90
        XCTAssertNil(m.update(battery, now: 10)); XCTAssertEqual(m.batteryEndsIn(now: 10), 300)
        XCTAssertNil(m.tick(now: 309))
        XCTAssertEqual(m.tick(now: 310), .lock(.battery))
    }

    func testBatteryWithAPhoneEndsAtTwentyPercent() {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        var c = ready; c.onACPower = false; c.phoneConnected = true; c.batteryPercent = 21
        XCTAssertNil(m.update(c, now: 1)); XCTAssertNil(m.tick(now: 10_000)); XCTAssertNil(m.batteryEndsIn(now: 10))
        c.batteryPercent = 20
        XCTAssertEqual(m.update(c, now: 10_001), .lock(.battery))
    }

    func testPowerReturningCancelsTheBatteryClock() {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        var b = ready; b.onACPower = false; m.update(b, now: 10)
        m.update(ready, now: 200); XCTAssertNil(m.tick(now: 400)); XCTAssertNil(m.batteryEndsIn(now: 400))
    }

    func testExpiresAfterADayWithoutAPhone() {
        var m = AwayModeMachine(); m.update(ready, now: 0)
        var phone = ready; phone.phoneConnected = true
        m.update(phone, now: 1_000); m.update(ready, now: 2_000)
        XCTAssertNil(m.tick(now: 2_000 + 86_399))
        XCTAssertEqual(m.tick(now: 2_000 + 86_400), .lock(.expiry))
    }

    func testPhoneRequestLocksEvenWhenOff() {
        var m = AwayModeMachine()
        XCTAssertEqual(m.end(.phoneRequest, now: 0), .lock(.phoneRequest)); XCTAssertFalse(m.wantsCover)
        var n = AwayModeMachine(); XCTAssertNil(n.end(.stopSharing, now: 0))
    }

    func testRelaunchAfterACrashLocksFirstBehindTheCover() {
        var m = AwayModeMachine()
        XCTAssertEqual(m.end(.relaunchedAfterExit, now: 0), .lock(.relaunchedAfterExit))
        XCTAssertTrue(m.wantsCover); XCTAssertEqual(m.protocolState, .covered)
        m.update(ready, now: 0.5); XCTAssertEqual(m.phase, .locking(.relaunchedAfterExit), "Does not re-arm before the lock")
    }

    func testClockGoingBackwardsNeverCoversOrLocksEarly() {
        var m = AwayModeMachine(); m.update(ready, now: 100)
        XCTAssertNil(m.tick(now: 50)); XCTAssertEqual(m.phase, .armedPresent)
    }
}
