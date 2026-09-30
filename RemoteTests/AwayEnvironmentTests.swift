import XCTest

final class AwayEnvironmentTests: XCTestCase {
    func testGateIsOffByDefaultAndPreviewKeyTurnsItOn() {
        let defaults = UserDefaults(suiteName: "away-gate-\(UUID())")!
        XCTAssertFalse(AwayModeGate.releaseDefault)
        XCTAssertFalse(AwayModeGate.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AwayModeGate.previewKey)
        XCTAssertTrue(AwayModeGate.isEnabled(defaults: defaults))
    }

    func testPowerParsing() {
        let battery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 42, "Max Capacity": 100]
        XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: "AC Power", sources: [battery], lowPowerMode: false),
                       HostPowerSnapshot(onACPower: true, batteryPercent: 42, lowPowerMode: false))
        XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: "Battery Power", sources: [battery], lowPowerMode: true),
                       HostPowerSnapshot(onACPower: false, batteryPercent: 42, lowPowerMode: true))
        XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: nil, sources: [], lowPowerMode: false),
                       HostPowerSnapshot(onACPower: true, batteryPercent: nil, lowPowerMode: false), "Desktop Macs have no battery")
        let odd: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 5000, "Max Capacity": 5000]
        XCTAssertEqual(HostPowerSourceParser.snapshot(providingType: "Battery Power", sources: [odd], lowPowerMode: false).batteryPercent, 100)
        let zeroMax: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 10, "Max Capacity": 0]
        XCTAssertNil(HostPowerSourceParser.snapshot(providingType: "Battery Power", sources: [zeroMax], lowPowerMode: false).batteryPercent)
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 1, "Max Capacity": 100]
        XCTAssertNil(HostPowerSourceParser.snapshot(providingType: "AC Power", sources: [ups], lowPowerMode: false).batteryPercent,
                     "Only the internal battery counts")
    }

    func testManagedWhenAnyLockKeyIsForced() {
        XCTAssertFalse(ManagedLockPolicy.isManaged(isForced: { _, _ in false }))
        for key in ManagedLockPolicy.keys {
            XCTAssertTrue(ManagedLockPolicy.isManaged(isForced: { k, d in k == key && d == ManagedLockPolicy.domain }), key)
        }
    }

    func testLiveReadersDoNotCrash() {
        _ = SystemPowerSource().snapshot()
        _ = ManagedLockPolicy.isManaged()
        XCTAssertGreaterThanOrEqual(HostIdle.systemIdleSeconds(), 0)
    }

    func testPowerPolicyTruthTable() {
        typealias P = HostPowerPolicy
        XCTAssertTrue(P.assertions(keepAwake: true, sharing: true, phoneConnected: false) == (true, false), "Unchanged without Away")
        XCTAssertTrue(P.assertions(keepAwake: true, sharing: true, phoneConnected: true) == (true, true))
        XCTAssertTrue(P.assertions(keepAwake: true, sharing: true, phoneConnected: false, awayArmed: true) == (true, true),
                      "Armed holds the display on with no phone, so display-off never locks")
        XCTAssertTrue(P.assertions(keepAwake: false, sharing: true, phoneConnected: false, awayArmed: true) == (true, true),
                      "Away mode is its own keep-awake request")
        XCTAssertTrue(P.assertions(keepAwake: true, sharing: false, phoneConnected: false, awayArmed: true) == (false, false),
                      "Nothing is held while sharing is not running")
        XCTAssertTrue(P.assertions(keepAwake: false, sharing: true, phoneConnected: true, awayArmed: false) == (false, false))
    }

    func testLockWarnings() {
        var t = HostLockWarningTracker()
        let at = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(t.screenLocked(at: at, uptime: 100, sharingWanted: false, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 999),
                     "Not sharing: nothing to warn about")
        XCTAssertNil(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: true, lockRequestedByFarside: true, idleSeconds: 999),
                     "Away mode's own lock is expected")
        XCTAssertNil(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 2),
                     "Someone at the Mac chose to lock it")
        XCTAssertEqual(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 600),
                       .lockedWhileSharing(at: at))
        t.screenSaverStarted(uptime: 95)
        XCTAssertEqual(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: true, lockRequestedByFarside: false, idleSeconds: 0),
                       .screenSaverLocked(at: at, awayArmed: true), "The screen saver is the cause even though idle was reset")
        t.screenSaverStopped()
        t.screenSaverStarted(uptime: 10)
        XCTAssertEqual(t.screenLocked(at: at, uptime: 100, sharingWanted: true, awayArmed: false, lockRequestedByFarside: false, idleSeconds: 600),
                       .screenSaverLocked(at: at, awayArmed: false), "Still running, so still the cause")
    }
}
