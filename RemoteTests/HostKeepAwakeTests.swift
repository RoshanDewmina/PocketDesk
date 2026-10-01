import XCTest

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
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: false, sharing: true, phoneConnected: true) == (false, false),
                      "Turning off Keep awake leaves normal macOS sleep settings in charge")
    }

    func testIdleConnectedSessionKeepsAssertionsWithoutInputOrAudioActivityAndPauseReleasesDisplay() {
        var acquired = 0
        var released: [UInt32] = []
        let display = HostKeepAwake(backend: .init(acquire: { acquired += 1; return 17 },
                                                 release: { released.append($0); return true }))
        // The owner chose keep-awake. Idle video/view-only/audio activity is not a power predicate.
        for _ in 0..<4 {
            let desired = HostPowerPolicy.assertions(keepAwake: true, sharing: true, phoneConnected: true)
            XCTAssertTrue(desired.system)
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
        XCTAssertTrue(HostPowerPolicy.assertions(keepAwake: false, sharing: true, phoneConnected: true) == (false, false))
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
