import XCTest

@MainActor
final class AwayModeControllerTests: XCTestCase {
    func testArmsAndStartsWatchingLocalInput() {
        let rig = AwayRig()
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.machine.phase, .armedPresent)
        XCTAssertFalse(rig.controller.wantsCover)
        XCTAssertTrue(rig.controller.holdsDisplayAwake)
        XCTAssertEqual(rig.controller.protocolState, .armed)
        XCTAssertTrue(rig.monitor.isRunning)
        XCTAssertTrue(rig.ticker.isRunning)
        XCTAssertEqual(rig.ticker.interval, AwayModeController.tickInterval)
        XCTAssertEqual(rig.host.changes, 1)
        XCTAssertEqual(rig.locker.requests, 0)
    }

    func testCoversAfterIdleThenLocksOnTouchAndDropsTheCoverOnceLocked() {
        let rig = AwayRig()
        rig.controller.refresh()
        rig.clock = 121; rig.controller.tick()
        XCTAssertTrue(rig.controller.wantsCover)
        XCTAssertEqual(rig.controller.protocolState, .covered)

        rig.monitor.fire()
        XCTAssertEqual(rig.locker.requests, 1)
        XCTAssertEqual(rig.controller.machine.phase, .locking(.touched))
        XCTAssertTrue(rig.controller.wantsCover, "The cover stays up while macOS locks")
        XCTAssertTrue(rig.host.messages.contains("Lock requested for this Mac: touched"))

        rig.locker.locked = true
        rig.clock = 121.5; rig.controller.tick()
        XCTAssertEqual(rig.controller.machine.phase, .off)
        XCTAssertFalse(rig.controller.wantsCover)
        XCTAssertFalse(rig.monitor.isRunning)
        XCTAssertTrue(rig.controller.lockRequestedByFarside)
        XCTAssertEqual(rig.locker.requests, 1)
    }

    func testLockStaysOursUntilTheHostSeesItAndClearsOnReArm() {
        let rig = AwayRig()
        rig.controller.refresh()
        rig.controller.coverNow()
        rig.monitor.fire()
        rig.locker.locked = true
        rig.clock = 1; rig.controller.tick()
        XCTAssertEqual(rig.controller.machine.phase, .off)
        rig.clock = 2; rig.controller.tick()
        XCTAssertTrue(rig.controller.lockRequestedByFarside, "The host's lock notification may arrive after the machine went off")

        rig.host.conditions.screenLocked = true
        rig.controller.refresh()
        XCTAssertFalse(rig.controller.lockRequestedByFarside, "Once the host has seen the lock, a later lock is not ours")

        // A lock request that never landed stays ours until Away mode arms again.
        let failed = AwayRig()
        failed.locker.postSucceeds = false
        failed.controller.refresh()
        failed.controller.end(.phoneRequest)
        failed.clock = 3; failed.controller.tick()
        XCTAssertEqual(failed.controller.machine.phase, .off)
        failed.controller.turnOffAtMac()
        XCTAssertTrue(failed.controller.lockRequestedByFarside)
        failed.controller.refresh()
        XCTAssertEqual(failed.controller.machine.phase, .armedPresent)
        XCTAssertFalse(failed.controller.lockRequestedByFarside)
    }

    func testPhoneInputNeverLocksOrResetsIdle() {
        let rig = AwayRig()
        rig.host.conditions.phoneConnected = true
        rig.controller.refresh()
        // Phone input reaches the controller only through the monitor, which drops injected events.
        for second in 1...121 {
            rig.clock = TimeInterval(second)
            rig.controller.tick()
        }
        XCTAssertEqual(rig.controller.machine.phase, .armedCovered)
        XCTAssertTrue(rig.controller.wantsCover)
        XCTAssertEqual(rig.locker.requests, 0)
    }

    func testFailedPostStillTimesOutToLockFailedAndReleasesDisplay() {
        let rig = AwayRig()
        rig.locker.postSucceeds = false
        rig.controller.refresh()
        rig.clock = 121; rig.controller.tick()
        rig.monitor.fire()
        XCTAssertEqual(rig.locker.requests, 1)
        XCTAssertEqual(rig.controller.readout(available: true).phase, .locking)

        rig.clock = 123; rig.controller.tick()
        XCTAssertFalse(rig.controller.holdsDisplayAwake, "Let the Mac's own display-sleep lock apply")
        XCTAssertTrue(rig.controller.wantsCover)
        XCTAssertEqual(rig.controller.readout(available: true).phase, .lockFailed)
        XCTAssertTrue(rig.host.messages.contains("Couldn’t send the lock shortcut"))
        XCTAssertTrue(rig.monitor.isRunning, "A later touch retries the lock")
    }

    func testBatteryReadFromPowerSource() {
        let rig = AwayRig()
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.machine.phase, .armedPresent)
        rig.power.current = HostPowerSnapshot(onACPower: false, batteryPercent: 80, lowPowerMode: false)
        for step in 1...601 {
            rig.clock = TimeInterval(step) * 0.5
            rig.controller.tick()
        }
        XCTAssertEqual(rig.locker.requests, 1)
        XCTAssertEqual(rig.controller.machine.phase, .locking(.battery))
        XCTAssertTrue(rig.host.messages.contains("Lock requested for this Mac: battery"))
    }

    func testManagedMacNeverArms() {
        let rig = AwayRig()
        rig.managed = true
        rig.controller.refresh()
        XCTAssertEqual(rig.controller.machine.phase, .off)
        XCTAssertFalse(rig.monitor.isRunning)
        let readout = rig.controller.readout(available: true)
        XCTAssertTrue(readout.enabled)
        XCTAssertEqual(readout.phase, .off)
        XCTAssertEqual(readout.unavailable, .managed)

        let disabled = AwayRig()
        disabled.managed = true
        disabled.host.conditions.enabled = false
        disabled.controller.refresh()
        XCTAssertNil(disabled.controller.readout(available: true).unavailable, "No reason shown while it is off by choice")
    }

    func testTurningOffAtTheMacReleasesWithoutLockingWhilePresent() {
        let rig = AwayRig()
        rig.controller.refresh()
        rig.controller.turnOffAtMac()
        XCTAssertEqual(rig.locker.requests, 0)
        XCTAssertFalse(rig.controller.wantsCover)
        XCTAssertFalse(rig.controller.holdsDisplayAwake)
        XCTAssertFalse(rig.monitor.isRunning)
    }

    func testQuitLocksOnlyWhenArmedAndWaitsForConfirmation() {
        let off = AwayRig()
        off.host.conditions.sharingActive = false
        off.controller.refresh()
        XCTAssertFalse(off.controller.prepareForQuit { _ in XCTFail("No Away quit to wait for") })
        XCTAssertEqual(off.locker.requests, 0)

        let armed = AwayRig()
        armed.controller.refresh()
        XCTAssertTrue(armed.monitor.isRunning)
        XCTAssertTrue(armed.ticker.isRunning)
        var reply: Bool?
        XCTAssertTrue(armed.controller.prepareForQuit { reply = $0 })
        XCTAssertEqual(armed.locker.requests, 1)
        XCTAssertTrue(armed.host.messages.contains("Lock requested for this Mac: quit"))
        XCTAssertFalse(armed.monitor.isRunning)
        XCTAssertTrue(armed.ticker.isRunning)
        XCTAssertNil(reply)

        armed.controller.refresh()
        XCTAssertFalse(armed.monitor.isRunning, "Teardown refreshes must not restart watching")
        XCTAssertTrue(armed.ticker.isRunning)
        XCTAssertEqual(armed.locker.requests, 1)
        armed.locker.locked = true
        armed.clock = 0.5; armed.ticker.fire()
        XCTAssertEqual(reply, true)
        XCTAssertFalse(armed.ticker.isRunning)
    }

    func testUncoveredArmedQuitAlsoCancelsWhenLockCannotBeConfirmed() {
        let rig = AwayRig()
        rig.controller.refresh()
        var allowed: Bool?
        XCTAssertTrue(rig.controller.prepareForQuit { allowed = $0 })
        rig.clock = 2; rig.ticker.fire()
        XCTAssertEqual(allowed, false)
        XCTAssertEqual(rig.controller.machine.phase, .armedPresent)
        XCTAssertTrue(rig.monitor.isRunning)
        XCTAssertTrue(rig.ticker.isRunning)
    }

    func testCoveredQuitTimeoutCancelsAndNextQuitCanRetry() {
        let rig = AwayRig()
        rig.controller.refresh(); rig.controller.coverNow()
        rig.locker.postSucceeds = false
        var replies: [Bool] = []
        XCTAssertTrue(rig.controller.prepareForQuit { replies.append($0) })
        XCTAssertTrue(rig.controller.wantsCover)
        rig.clock = 2; rig.ticker.fire()
        XCTAssertEqual(replies, [false])
        XCTAssertTrue(rig.controller.wantsCover)
        XCTAssertTrue(rig.monitor.isRunning)
        XCTAssertEqual(rig.controller.machine.phase, .lockFailed(.quit))
        XCTAssertTrue(rig.controller.prepareForQuit { replies.append($0) })
        XCTAssertEqual(rig.locker.requests, 2)
        rig.locker.locked = true
        rig.clock = 2.5; rig.ticker.fire()
        XCTAssertEqual(replies, [false, true])
        XCTAssertFalse(rig.controller.wantsCover)
    }

    func testUnverifiedHostLockNotificationCannotUncover() {
        let rig = AwayRig()
        rig.controller.refresh(); rig.controller.coverNow()
        rig.host.conditions.screenLocked = true
        rig.controller.refresh()
        XCTAssertTrue(rig.controller.wantsCover)
        rig.locker.locked = true
        rig.controller.refresh()
        XCTAssertFalse(rig.controller.wantsCover)
    }

    func testRecoveryAndBothMonitorsAreRequiredToArm() {
        let noRecovery = AwayRig()
        noRecovery.host.conditions.recoveryRunning = false
        noRecovery.controller.refresh()
        XCTAssertEqual(noRecovery.controller.machine.phase, .off)
        XCTAssertEqual(noRecovery.controller.readout(available: true).unavailable, .needsRecovery)
        XCTAssertFalse(noRecovery.monitor.isRunning)
        let noMonitor = AwayRig()
        noMonitor.monitor.canStart = false
        noMonitor.controller.refresh()
        XCTAssertEqual(noMonitor.controller.machine.phase, .off)
        XCTAssertEqual(noMonitor.controller.readout(available: true).unavailable, .needsInputMonitoring)
        XCTAssertTrue(noMonitor.host.messages.contains("Couldn’t install both local-input monitors; Away mode unavailable"))
    }

    func testCoveredDisableOrRecoveryLossKeepsCoverUntilLocked() {
        for disabling in [true, false] {
            let rig = AwayRig()
            rig.controller.refresh(); rig.controller.coverNow()
            if disabling { rig.host.conditions.enabled = false; rig.controller.turnOffAtMac() }
            else { rig.host.conditions.recoveryRunning = false }
            rig.controller.refresh()
            XCTAssertEqual(rig.locker.requests, 1)
            XCTAssertTrue(rig.controller.wantsCover)
            rig.clock = 2; rig.ticker.fire()
            XCTAssertTrue(rig.controller.wantsCover)
            rig.controller.turnOffAtMac()
            XCTAssertTrue(rig.controller.wantsCover)
        }
    }

    func testRelaunchLocksFirst() {
        let rig = AwayRig()
        rig.host.conditions = AwayConditions()
        rig.controller.lockFirstAfterRelaunch()
        XCTAssertEqual(rig.locker.requests, 1)
        XCTAssertTrue(rig.controller.wantsCover)
        XCTAssertEqual(rig.controller.protocolState, .covered)
        XCTAssertTrue(rig.controller.lockRequestedByFarside)
        XCTAssertTrue(rig.host.messages.contains("Lock requested for this Mac: relaunchedAfterExit"))
        XCTAssertTrue(rig.ticker.isRunning, "The lock timeout still needs ticks")

        rig.controller.refresh()
        XCTAssertTrue(rig.controller.wantsCover, "A refresh before the lock lands keeps the cover")
    }

    func testAuthorityFenceAndCoverStatePrecedeInjectedShortcutAndSurviveFailedQuit() {
        let rig = AwayRig()
        rig.controller.refresh(); rig.controller.coverNow()
        var events: [String] = []
        rig.host.beforeLock = { events.append("fence") }
        rig.locker.onRequest = { events.append("shortcut"); XCTAssertTrue(rig.controller.wantsCover) }
        XCTAssertTrue(rig.controller.prepareForQuit { allowed in XCTAssertFalse(allowed) })
        XCTAssertEqual(events, ["fence", "shortcut"])
        XCTAssertTrue(rig.monitor.isRunning, "Covered quit retains both monitors while confirmation is pending")
        rig.clock = 2; rig.ticker.fire()
        XCTAssertTrue(rig.monitor.isRunning)
        XCTAssertTrue(rig.controller.wantsCover)
    }

    func testUncommittedCoverIsRefusedBeforeItCanBePresented() {
        let rig = AwayRig()
        rig.controller.refresh(); rig.controller.coverNow()
        rig.controller.refuseUncommittedCover()
        XCTAssertEqual(rig.controller.machine.phase, .off)
        XCTAssertFalse(rig.controller.wantsCover)
        XCTAssertFalse(rig.monitor.isRunning)
        XCTAssertEqual(rig.locker.requests, 0)
    }

    func testLocalInputNotifiesAtMostOncePerFiveSeconds() {
        let rig = AwayRig()
        rig.controller.refresh()
        let before = rig.host.changes
        for step in 0..<50 {
            rig.clock = 3 + TimeInterval(step) * 0.1
            rig.monitor.fire()
            if step % 5 == 4 { rig.controller.tick() }
        }
        XCTAssertEqual(rig.controller.machine.phase, .armedPresent)
        XCTAssertLessThanOrEqual(rig.host.changes - before, 1)
    }

    func testTickerStopsWhenDisabledAndOff() {
        let rig = AwayRig()
        rig.host.conditions.enabled = false
        rig.controller.refresh()
        XCTAssertFalse(rig.ticker.isRunning)
        XCTAssertEqual(rig.ticker.starts, 0)

        let armed = AwayRig()
        armed.controller.refresh()
        XCTAssertTrue(armed.ticker.isRunning)
        armed.host.conditions.enabled = false
        armed.controller.refresh()
        XCTAssertEqual(armed.controller.machine.phase, .off)
        XCTAssertFalse(armed.ticker.isRunning)
        XCTAssertFalse(armed.monitor.isRunning)
        XCTAssertEqual(armed.locker.requests, 0)
    }

    func testReadoutCountdownUsesTheWallClock() {
        let rig = AwayRig()
        rig.wall = Date(timeIntervalSince1970: 0)
        rig.clock = 0; rig.controller.refresh()
        rig.clock = 20
        let readout = rig.controller.readout(available: true)
        XCTAssertEqual(readout.phase, .armed)
        XCTAssertEqual(readout.coversAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(readout.batteryEndsAt)
        XCTAssertNil(readout.unavailable)
    }
}

final class AwayPreferencesTests: XCTestCase {
    func testAwayPreferencesDefaultOffAndPersist() throws {
        let suite = "farside.away-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertFalse(preferences.awayMode)
        XCTAssertFalse(preferences.awayIntroShown)

        preferences.awayMode = true
        preferences.awayIntroShown = true
        let reread = HostPreferences(defaults: defaults)
        XCTAssertTrue(reread.awayMode)
        XCTAssertTrue(reread.awayIntroShown)
        XCTAssertTrue(defaults.bool(forKey: "awayModeWhileSharing"))
        XCTAssertTrue(defaults.bool(forKey: "awayModeIntroShown"))
    }
}

private extension AwayConditions {
    static let ready = AwayConditions(enabled: true, sharingWanted: true, sharingActive: true, accessibility: true,
                                      recoveryRunning: true, inputMonitoring: true)
}

@MainActor
private final class AwayRig {
    let locker = FakeAwayLocker()
    let power = FakeAwayPower()
    let monitor = FakeAwayMonitor()
    let ticker = FakeAwayTicker()
    let host = FakeAwayHost()
    var managed = false
    var clock: TimeInterval = 0
    var wall = Date(timeIntervalSince1970: 1_000_000)

    lazy var controller: AwayModeController = {
        let controller = AwayModeController(dependencies: .init(
            locker: locker,
            power: power,
            isManaged: { [unowned self] in self.managed },
            inputMonitor: monitor,
            ticker: ticker,
            now: { [unowned self] in self.clock },
            wallClock: { [unowned self] in self.wall }))
        controller.host = host
        return controller
    }()
}

@MainActor
private final class FakeAwayLocker: HostScreenLocking {
    var requests = 0
    var locked = false
    var postSucceeds = true
    var onRequest: (() -> Void)?

    func requestLock() -> Bool {
        requests += 1
        onRequest?()
        return postSucceeds
    }

    func isScreenLocked() -> Bool { locked }
}

private final class FakeAwayPower: HostPowerSourceReading {
    var current = HostPowerSnapshot()
    func snapshot() -> HostPowerSnapshot { current }
}

@MainActor
private final class FakeAwayMonitor: AwayInputMonitoring {
    var canStart = true
    private(set) var isRunning = false
    private var onLocalInput: (@MainActor () -> Void)?

    func start(onLocalInput: @escaping @MainActor () -> Void) {
        isRunning = canStart
        self.onLocalInput = onLocalInput
    }

    func stop() {
        isRunning = false
        onLocalInput = nil
    }

    func fire() {
        guard isRunning else { return }
        onLocalInput?()
    }
}

@MainActor
private final class FakeAwayTicker: AwayTicking {
    private(set) var isRunning = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var interval: TimeInterval?
    private var callback: (@MainActor () -> Void)?

    func start(interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        isRunning = true
        starts += 1
        self.interval = interval
        callback = fire
    }

    func stop() {
        isRunning = false
        stops += 1
        callback = nil
    }

    func fire() { callback?() }
}

@MainActor
private final class FakeAwayHost: AwayModeHost {
    var conditions = AwayConditions.ready
    var beforeLock: (() -> Void)?
    func awayWillRequestLock() { beforeLock?() }
    private(set) var changes = 0
    private(set) var messages: [String] = []

    func awayConditions() -> AwayConditions { conditions }
    func awayStateChanged() { changes += 1 }
    func awayRecord(_ message: String) { messages.append(message) }
}
