import XCTest
import IOKit.ps

private final class FakePowerSource: HostPowerSourceReading {
    var value: HostPowerSnapshot
    init(_ value: HostPowerSnapshot) { self.value = value }
    func snapshot() -> HostPowerSnapshot { value }
}

final class HostKeepAwakeTests: XCTestCase {
    func testAssertionIsAcquiredOnceAndReleasedOnStop() {
        var acquireCount = 0
        var released: [UInt32] = []
        let keepAwake = HostKeepAwake(backend: HostKeepAwakeBackend(
            acquire: {
                acquireCount += 1
                return 42
            },
            release: {
                released.append($0)
                return true
            }
        ))

        XCTAssertTrue(keepAwake.start())
        XCTAssertTrue(keepAwake.start())
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertEqual(acquireCount, 1)

        XCTAssertTrue(keepAwake.stop())
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertEqual(released, [42])
    }

    func testFailedAcquisitionNeverReportsActive() {
        let keepAwake = HostKeepAwake(backend: HostKeepAwakeBackend(
            acquire: { nil },
            release: { _ in XCTFail("No assertion should be released"); return false }
        ))

        XCTAssertFalse(keepAwake.start())
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertTrue(keepAwake.stop())
    }

    func testReleaseIsRetriedAndRemainsVisibleAfterFailure() {
        var releaseCount = 0
        let keepAwake = HostKeepAwake(backend: HostKeepAwakeBackend(
            acquire: { 7 },
            release: { _ in
                releaseCount += 1
                return false
            }
        ))

        XCTAssertTrue(keepAwake.start())
        XCTAssertFalse(keepAwake.stop())
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertEqual(releaseCount, 3)
    }

    func testBatteryPausesIdleSleepPreventionButNeverTheConnectedPhoneDisplayHold() {
        let onBattery = HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: false, onBattery: true)
        XCTAssertFalse(onBattery.system, "Keep-awake pauses on battery")
        XCTAssertFalse(onBattery.display)
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: true, onBattery: true)
                      == (false, true), "A connected phone still holds the display on battery")
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: false, sharing: true, phoneConnected: true, onBattery: true)
                      == (false, true))
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: false, onBattery: false)
                      == (true, false), "Resumes on power")
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: false, awayArmed: true,
                                                 onBattery: true) == (true, true),
                      "Away mode keeps its own battery limit")
    }

    @MainActor
    func testBatteryWatchFollowsAnInjectedPowerSource() {
        let power = FakePowerSource(HostPowerSnapshot(onACPower: true, batteryPercent: 80))
        let watch = HostBatteryWatch(power: power)
        XCTAssertFalse(watch.onBattery)

        power.value = HostPowerSnapshot(onACPower: false, batteryPercent: 79)
        XCTAssertTrue(watch.refresh())
        XCTAssertTrue(watch.onBattery)
        XCTAssertFalse(watch.refresh(), "Only a change of source is reported")

        power.value = HostPowerSnapshot(onACPower: true, batteryPercent: 79)
        XCTAssertTrue(watch.refresh())
        XCTAssertFalse(watch.onBattery)

        XCTAssertFalse(HostBatteryWatch(power: FakePowerSource(HostPowerSnapshot(onACPower: false, batteryPercent: nil)))
            .onBattery, "A Mac without a battery reading is treated as on power")
    }

    func testAFailedPowerReadCountsAsOnPower() {
        let failed = HostPowerSourceParser.snapshot(providingType: nil, sources: [], lowPowerMode: false)
        XCTAssertFalse(failed.onBatteryPower)
        let battery = HostPowerSourceParser.snapshot(
            providingType: kIOPMBatteryPowerKey,
            sources: [[kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 100]],
            lowPowerMode: false)
        XCTAssertTrue(battery.onBatteryPower)
    }

    func testDisplayHoldIgnoresKeepAwakeAndBattery() {
        for keepAwake in [false, true] {
            for onBattery in [false, true] {
                for sharing in [false, true] {
                    for phone in [false, true] {
                        for away in [false, true] {
                            let display = HostPowerPolicy.assertions(keepAwake: keepAwake, sharing: sharing,
                                                                     phoneConnected: phone, awayArmed: away,
                                                                     onBattery: onBattery).display
                            XCTAssertEqual(display, sharing && (phone || away),
                                           "keepAwake \(keepAwake) battery \(onBattery) sharing \(sharing) phone \(phone) away \(away)")
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testUnpluggingReleasesOnlyTheIdleSleepAssertionOnTheNextApply() {
        var held: Set<UInt32> = []
        func backend(_ id: UInt32) -> HostKeepAwakeBackend {
            HostKeepAwakeBackend(acquire: { held.insert(id); return id }, release: { held.remove($0); return true })
        }
        let power = FakePowerSource(HostPowerSnapshot(onACPower: true, batteryPercent: 90))
        let assertions = HostPowerAssertions(system: HostKeepAwake(backend: backend(1)),
                                             display: HostKeepAwake(backend: backend(2)),
                                             battery: HostBatteryWatch(power: power))

        XCTAssertTrue(assertions.apply(keepAwake: true, sharing: true, phoneConnected: true, awayArmed: false))
        XCTAssertEqual(held, [1, 2])

        power.value = HostPowerSnapshot(onACPower: false, batteryPercent: 89)
        assertions.apply(keepAwake: true, sharing: true, phoneConnected: true, awayArmed: false)
        XCTAssertTrue(assertions.battery.onBattery, "Each apply rereads the power source")
        XCTAssertEqual(held, [2], "Idle-sleep prevention pauses; the connected phone keeps the display")

        power.value = HostPowerSnapshot(onACPower: true, batteryPercent: 89)
        assertions.apply(keepAwake: true, sharing: true, phoneConnected: false, awayArmed: false)
        XCTAssertEqual(held, [1])
        assertions.releaseAll()
        XCTAssertTrue(held.isEmpty)
    }

    func testOnlyLiveOrRecoveringCoordinatorStateKeepsAccessActive() {
        XCTAssertTrue(HostActiveAccessPolicy.isRunning(
            status: "Connection interrupted · retrying…",
            hostRegistered: false,
            connected: false,
            awaitingApproval: false
        ))
        XCTAssertTrue(HostActiveAccessPolicy.isRunning(
            status: "Ready for your paired phone",
            hostRegistered: true,
            connected: false,
            awaitingApproval: false
        ))
        XCTAssertFalse(HostActiveAccessPolicy.isRunning(
            status: "Connection timed out. Check that the Mac is awake and the service is reachable.",
            hostRegistered: false,
            connected: false,
            awaitingApproval: false
        ))
    }
}

final class HostAvailabilityTests: XCTestCase {
    func testDisplaySleepAloneKeepsSharingWhileSleepLockAndUserSwitchTearDown() {
        XCTAssertEqual(HostSleepPolicy.response(to: .displaySlept), .displayAsleep)
        XCTAssertEqual(HostSleepPolicy.response(to: .displayWoke), .displayAwake)
        XCTAssertEqual(HostSleepPolicy.response(to: .systemWillSleep), .tearDown(.sleeping))
        XCTAssertEqual(HostSleepPolicy.response(to: .screenLocked), .tearDown(.locked))
        XCTAssertEqual(HostSleepPolicy.response(to: .sessionResigned), .tearDown(.switchedUser))
        for event in [HostSleepPolicy.Event.systemDidWake, .sessionActivated, .screenUnlocked] {
            XCTAssertEqual(HostSleepPolicy.response(to: event), .recover)
        }
    }

    func testSystemStaysReachableWhileSharingButTheDisplayIsHeldOnlyForAConnectedPhone() {
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: false) == (true, false))
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: true) == (true, true))
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: false, phoneConnected: true) == (false, false))
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: false, sharing: true, phoneConnected: true) == (false, true),
                      "A live phone automatically holds the display; idle system reachability remains opt-in")
    }

    func testIdleConnectedSessionKeepsAssertionsWithoutInputOrAudioActivityAndPauseReleasesDisplay() {
        var acquired = 0
        var released: [UInt32] = []
        let display = HostKeepAwake(backend: .init(acquire: { acquired += 1; return 17 },
                                                 release: { released.append($0); return true }))
        // No idle reachability consent: a connected viewer still holds the display.
        for _ in 0..<4 {
            let desired = HostPowerPolicy.assertions(keepAwake: false, sharing: true, phoneConnected: true)
            XCTAssertFalse(desired.system)
            if desired.display { XCTAssertTrue(display.start()) }
        }
        XCTAssertEqual(acquired, 1, "A long idle session reuses its assertion")
        let paused = HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: false)
        XCTAssertTrue(paused.system, "Explicit reachability choice remains independent of live display")
        XCTAssertFalse(paused.display)
        XCTAssertTrue(display.stop())
        XCTAssertEqual(released, [17])
        XCTAssertFalse(display.isActive)
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: true, sharing: false, phoneConnected: false) == (false, false))
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: false, sharing: true, phoneConnected: true) == (false, true))
    }

    func testLockDetectionReadsTheSessionDictionary() {
        XCTAssertTrue(HostScreenLock.isLocked(["CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(HostScreenLock.isLocked(["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(HostScreenLock.isLocked(["kCGSSessionOnConsoleKey": true]))
        XCTAssertFalse(HostScreenLock.isLocked(nil))
    }

    func testPresenceTravelsOnlyOnCaptureStatusAndOlderPeersIgnoreIt() throws {
        XCTAssertNoThrow(try RemoteAction(action: "capture", hostState: HostPresence.displayAsleep.rawValue).validate())
        XCTAssertNoThrow(try RemoteAction(action: "wake", epoch: 2).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", hostState: "locked").validate())
        XCTAssertThrowsError(try RemoteAction(action: "wake", epoch: 2, hostState: "locked").validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", hostState: "not valid").validate())
        let future = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(
            RemoteAction(action: "capture", hostState: "hibernating")))
        XCTAssertNoThrow(try future.validate())
        XCTAssertNil(future.hostState.flatMap(HostPresence.init(rawValue:)))
    }
}
