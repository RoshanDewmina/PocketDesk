import XCTest

final class WatchdogPolicyTests: XCTestCase {
    private let bundle = "/Applications/PocketDesk Host.app"
    private let boot = "boot-A"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ launch: String, clean: Bool = false, heartbeat: TimeInterval = 100,
                        curtainUp: Bool = false, boot: String? = nil, path: String? = nil,
                        reset: Date? = nil) -> HostRunRecord {
        HostRunRecord(pid: 4242, launchID: launch, bootSession: boot ?? self.boot,
                      executablePath: path ?? bundle + "/Contents/MacOS/PocketDeskRemoteHost",
                      startedAt: start, heartbeatUptime: heartbeat, heartbeatAt: start,
                      cleanExit: clean, curtainUp: curtainUp, crashLoopResetAt: reset)
    }

    private func dead(_ record: HostRunRecord?, at offset: TimeInterval, uptime: TimeInterval = 110,
                      hangKill: Bool = false, note: String? = nil) -> WatchdogObservation {
        WatchdogObservation(record: record, ownedBundlePath: bundle, recordProcessAlive: false,
                            bootSession: boot, now: start.addingTimeInterval(offset), uptime: uptime,
                            hangKillIssued: hangKill, hangNoteLaunchID: note)
    }

    private func alive(_ record: HostRunRecord, uptime: TimeInterval, traced: Bool = false) -> WatchdogObservation {
        WatchdogObservation(record: record, ownedBundlePath: bundle, recordProcessAlive: true,
                            recordProcessTraced: traced, bootSession: boot, now: start, uptime: uptime)
    }

    func testCrashRelaunchesOnceAndCleanQuitDoesNothing() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger()
        XCTAssertEqual(policy.decide(dead(record("L1"), at: 0), ledger: &ledger), .relaunch(.crash))
        XCTAssertEqual(policy.decide(dead(record("L1"), at: 1), ledger: &ledger), .idle,
                       "One exit is handled once, however many polls see it")
        XCTAssertEqual(ledger.relaunches, 1)

        var clean = WatchdogLedger()
        XCTAssertEqual(policy.decide(dead(record("L2", clean: true), at: 0), ledger: &clean), .idle,
                       "Quit from the menu, or SIGTERM, is respected")
        XCTAssertEqual(policy.decide(dead(nil, at: 0), ledger: &clean), .idle)
    }

    func testThreeCrashesInFiveMinutesStopRelaunchingAndSurfaceSafeMode() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger()
        XCTAssertEqual(policy.decide(dead(record("L1"), at: 0), ledger: &ledger), .relaunch(.crash))
        XCTAssertEqual(policy.decide(dead(record("L2"), at: 60), ledger: &ledger), .relaunch(.crash))
        XCTAssertEqual(policy.decide(dead(record("L3"), at: 120), ledger: &ledger), .relaunchSafeMode(.crash),
                       "The third crash opens Farside once with sharing paused, to explain why it stopped")
        XCTAssertNotNil(ledger.stoppedAt)
        XCTAssertTrue(ledger.isStopped(inBoot: boot))
        XCTAssertEqual(policy.decide(dead(record("L4"), at: 130), ledger: &ledger), .stopped(.crash),
                       "While stopped, nothing is relaunched, even the safe-mode instance")
        XCTAssertEqual(policy.decide(dead(record("L5"), at: 900), ledger: &ledger), .stopped(.crash))
    }

    func testCrashesSpreadBeyondTheWindowKeepRelaunching() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger()
        for (index, offset) in [0.0, 200, 400, 600, 800].enumerated() {
            XCTAssertEqual(policy.decide(dead(record("L\(index)"), at: offset), ledger: &ledger), .relaunch(.crash))
        }
        XCTAssertLessThanOrEqual(ledger.unexpectedExits.count, 2, "Only exits inside the window count")
    }

    func testResumingAfterAStopClearsTheCrashLoop() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger()
        for (index, offset) in [0.0, 10, 20].enumerated() { _ = policy.decide(dead(record("L\(index)"), at: offset), ledger: &ledger) }
        XCTAssertNotNil(ledger.stoppedAt)
        let resumed = record("L9", reset: start.addingTimeInterval(60))
        XCTAssertEqual(policy.decide(alive(resumed, uptime: 101), ledger: &ledger), .idle)
        XCTAssertNil(ledger.stoppedAt, "The person resumed at the Mac")
        XCTAssertEqual(policy.decide(dead(resumed, at: 70), ledger: &ledger), .relaunch(.crash))
    }

    func testANewBootStartsAFreshLedgerAndIgnoresOldRecords() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger(bootSession: "boot-OLD", unexpectedExits: [start, start], stoppedAt: start)
        XCTAssertEqual(policy.decide(dead(record("L1", boot: "boot-OLD"), at: 0), ledger: &ledger), .idle,
                       "A record left before a restart is not a crash in this boot")
        XCTAssertEqual(ledger.bootSession, boot)
        XCTAssertNil(ledger.stoppedAt)
        XCTAssertTrue(ledger.unexpectedExits.isEmpty)
    }

    func testStaleHeartbeatEndsAHungHostAndTheNextExitCountsAsAHang() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger()
        let running = record("L1", heartbeat: 100)
        XCTAssertEqual(policy.decide(alive(running, uptime: 140), ledger: &ledger), .idle)
        XCTAssertEqual(policy.decide(alive(running, uptime: 146), ledger: &ledger), .terminateHung(pid: 4242))
        XCTAssertEqual(policy.decide(alive(running, uptime: 200, traced: true), ledger: &ledger), .idle,
                       "A host paused in a debugger is never killed")
        XCTAssertEqual(policy.decide(dead(running, at: 5, hangKill: true), ledger: &ledger), .relaunch(.hang))

        let curtained = record("L2", heartbeat: 100, curtainUp: true)
        XCTAssertEqual(policy.decide(alive(curtained, uptime: 107), ledger: &ledger), .terminateHung(pid: 4242),
                       "A frozen host must not leave the Mac's screen covered")

        var noted = WatchdogLedger()
        XCTAssertEqual(policy.decide(dead(record("L3"), at: 0, note: "L3"), ledger: &noted), .relaunch(.hang),
                       "The in-process watchdog's note labels its own exit")
    }

    func testOnlyTheHelpersOwnCopyIsSupervised() {
        let policy = WatchdogPolicy()
        var ledger = WatchdogLedger()
        let devBuild = record("L1", path: "/Users/me/DerivedData/Debug/PocketDeskRemoteHost.app/Contents/MacOS/PocketDeskRemoteHost")
        XCTAssertEqual(policy.decide(dead(devBuild, at: 0), ledger: &ledger), .idle)

        var other = dead(record("L2"), at: 0)
        other.otherInstanceRunning = true
        XCTAssertEqual(policy.decide(other, ledger: &ledger), .idle, "Someone already reopened Farside")

        var closing = dead(record("L3"), at: 0)
        closing.shuttingDown = true
        XCTAssertEqual(policy.decide(closing, ledger: &ledger), .idle, "Never relaunch during shutdown or logout")
    }

    func testLaunchAssessment() {
        let previous = record("L1")
        let crashed = HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: boot,
                                                  previousProcessAlive: false, safeModeArgument: false)
        XCTAssertTrue(crashed.recoveredFromUnexpectedExit)
        XCTAssertEqual(crashed.previousExit, .crash)
        XCTAssertFalse(crashed.safeMode)

        let hung = HostLaunchAssessment.assess(previous: previous, ledger: nil,
                                               hangNote: HostHangNote(launchID: "L1", at: start, stalledSeconds: 12),
                                               bootSession: boot, previousProcessAlive: false, safeModeArgument: false)
        XCTAssertEqual(hung.previousExit, .hang)

        let quit = HostLaunchAssessment.assess(previous: record("L1", clean: true), ledger: nil, hangNote: nil,
                                               bootSession: boot, previousProcessAlive: false, safeModeArgument: false)
        XCTAssertFalse(quit.recoveredFromUnexpectedExit)

        let rebooted = HostLaunchAssessment.assess(previous: record("L1", boot: "boot-OLD"), ledger: nil, hangNote: nil,
                                                   bootSession: boot, previousProcessAlive: false, safeModeArgument: false)
        XCTAssertFalse(rebooted.recoveredFromUnexpectedExit, "A Mac restart is not reported as a Farside crash")

        let stopped = WatchdogLedger(bootSession: boot, stoppedAt: start)
        XCTAssertTrue(HostLaunchAssessment.assess(previous: previous, ledger: stopped, hangNote: nil, bootSession: boot,
                                                  previousProcessAlive: false, safeModeArgument: false).safeMode,
                      "Opened by hand after a crash-loop stop: stay paused and explain")
        XCTAssertFalse(HostLaunchAssessment.assess(previous: record("L1", reset: start.addingTimeInterval(1)), ledger: stopped,
                                                   hangNote: nil, bootSession: boot, previousProcessAlive: false,
                                                   safeModeArgument: false).safeMode)
        XCTAssertTrue(HostLaunchAssessment.assess(previous: nil, ledger: nil, hangNote: nil, bootSession: boot,
                                                  previousProcessAlive: false, safeModeArgument: true).safeMode)
    }

    func testFilesAreScopedToOneCopyOfTheApp() {
        let support = URL(fileURLWithPath: "/tmp/support")
        let installed = WatchdogFiles.forHost(bundleIdentifier: "com.roshan.PocketDesk.RemoteHost",
                                              bundlePath: "/Applications/PocketDesk Host.app", applicationSupport: support)
        let trailing = WatchdogFiles.forHost(bundleIdentifier: "com.roshan.PocketDesk.RemoteHost",
                                             bundlePath: "/Applications/PocketDesk Host.app/", applicationSupport: support)
        let dev = WatchdogFiles.forHost(bundleIdentifier: "com.roshan.PocketDesk.RemoteHost",
                                        bundlePath: "/tmp/DerivedData/PocketDeskRemoteHost.app", applicationSupport: support)
        XCTAssertEqual(installed, trailing)
        XCTAssertNotEqual(installed, dev)
        XCTAssertTrue(installed.hostRecord.path.hasPrefix("/tmp/support/com.roshan.PocketDesk.RemoteHost/Watchdog/"))

        XCTAssertEqual(WatchdogFiles.hostBundlePath(forHelperExecutable: "/Applications/PocketDesk Host.app/Contents/MacOS/FarsideWatchdog"),
                       "/Applications/PocketDesk Host.app")
        XCTAssertNil(WatchdogFiles.hostBundlePath(forHelperExecutable: "/usr/local/bin/FarsideWatchdog"))
        XCTAssertTrue(WatchdogFiles.isInside("/Applications/A.app/Contents/MacOS/A", bundle: "/Applications/A.app"))
        XCTAssertFalse(WatchdogFiles.isInside("/Applications/A.app2/Contents/MacOS/A", bundle: "/Applications/A.app"))
    }
}

final class HangWatchdogTests: XCTestCase {
    func testOnlyAnUnansweredProbeCountsAsAStall() {
        var detector = MainThreadStallDetector()
        XCTAssertTrue(detector.needsProbe)
        detector.probeSent(at: 10)
        XCTAssertFalse(detector.isStalled(at: 13.9, threshold: 4))
        XCTAssertTrue(detector.isStalled(at: 14, threshold: 4))
        detector.probeAnswered()
        XCTAssertFalse(detector.isStalled(at: 100, threshold: 4),
                       "A late check after an answered probe (App Nap, timer coalescing) is not a hang")
        detector.probeSent(at: 100)
        detector.probeSent(at: 103)
        XCTAssertEqual(detector.stall(at: 104), 4, "Re-posting never resets an outstanding probe")
    }

    func testThresholdsFollowCurtainAndRecovery() {
        XCTAssertEqual(HangWatchdogPolicy.threshold(curtainUp: true, recoveryEnabled: false), 4)
        XCTAssertEqual(HangWatchdogPolicy.threshold(curtainUp: false, recoveryEnabled: true), 12)
        XCTAssertNil(HangWatchdogPolicy.threshold(curtainUp: false, recoveryEnabled: false),
                     "Without recovery or a curtain, a slow main thread is left alone")
    }

    func testWatchdogThreadReportsAStuckMainThread() {
        let fired = expectation(description: "hang reported")
        fired.assertForOverFulfill = false
        let watchdog = HostHangWatchdog(interval: 0.05) { stall in
            XCTAssertGreaterThanOrEqual(stall, 4)
            fired.fulfill()
        }
        watchdog.update(curtainUp: true, recoveryEnabled: false)
        watchdog.start()
        // Block the main thread past the curtain threshold; the watchdog thread must notice.
        Thread.sleep(forTimeInterval: 4.6)
        wait(for: [fired], timeout: 2)
        watchdog.update(curtainUp: false, recoveryEnabled: false)
    }
}

@MainActor
final class WatchdogReporterTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testRecordLifecycleAndRecoveryAssessment() throws {
        let files = WatchdogFiles(directory: directory)
        let first = HostWatchdogReporter(files: files, executablePath: "/Applications/A.app/Contents/MacOS/A",
                                         bootSession: "boot-A", pid: 999_990, arguments: [], uptime: { 50 })
        XCTAssertFalse(first.assessment.recoveredFromUnexpectedExit)
        first.start()
        first.markCleanExit()
        let written = try XCTUnwrap(WatchdogStore.read(HostRunRecord.self, from: files.hostRecord))
        XCTAssertTrue(written.cleanExit)
        XCTAssertEqual(written.launchID, first.record.launchID)

        let afterQuit = HostWatchdogReporter(files: files, executablePath: "/Applications/A.app/Contents/MacOS/A",
                                             bootSession: "boot-A", pid: 999_991, arguments: [], uptime: { 60 })
        XCTAssertFalse(afterQuit.assessment.recoveredFromUnexpectedExit, "A clean quit is not a recovery")
        afterQuit.start()
        afterQuit.setCurtainUp(true)
        // Simulate a crash: the process vanishes without markCleanExit.
        let crashedRecord = afterQuit.record
        XCTAssertTrue(crashedRecord.curtainUp)
        let expectation = expectation(description: "record flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let relaunched = HostWatchdogReporter(files: files, executablePath: "/Applications/A.app/Contents/MacOS/A",
                                              bootSession: "boot-A", pid: 999_992,
                                              arguments: [WatchdogLaunchArgument.recovered], uptime: { 70 })
        XCTAssertTrue(relaunched.assessment.recoveredFromUnexpectedExit)
        XCTAssertEqual(relaunched.assessment.previousExit, .crash)
        XCTAssertFalse(relaunched.assessment.safeMode)

        let safe = HostWatchdogReporter(files: files, executablePath: "/Applications/A.app/Contents/MacOS/A",
                                        bootSession: "boot-A", pid: 999_993,
                                        arguments: [WatchdogLaunchArgument.recovered, WatchdogLaunchArgument.safeMode],
                                        uptime: { 80 })
        XCTAssertTrue(safe.assessment.safeMode)
        safe.requestCrashLoopReset()
        XCTAssertFalse(safe.record.safeMode)
        XCTAssertNotNil(safe.record.crashLoopResetAt)
        afterQuit.markCleanExit()
    }

    func testHangNoteIsWrittenForTheHelper() throws {
        let files = WatchdogFiles(directory: directory)
        let note = HostHangNote(launchID: "L7", at: Date(), stalledSeconds: 12.5)
        XCTAssertTrue(WatchdogStore.write(note, to: files.hangNote))
        XCTAssertEqual(WatchdogStore.read(HostHangNote.self, from: files.hangNote)?.launchID, "L7")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, "Watchdog state is private to the user")
    }
}

final class RetryScheduleTests: XCTestCase {
    func testDefaultBackoffIsUnchangedAndTheCapBoundsTheSessionLossWindow() {
        let base: UInt64 = 500_000_000
        XCTAssertEqual((1...5).map { RetrySchedule.delay(attempt: $0, base: base, maximum: nil) },
                       [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000])
        let capped = (1...24).map { RetrySchedule.delay(attempt: $0, base: base, maximum: 4_000_000_000) }
        XCTAssertEqual(capped.max(), 4_000_000_000)
        let total = Double(capped.reduce(0, +)) / 1e9
        XCTAssertGreaterThan(total, 80, "A relaunched Mac app has well over a minute to come back")
        XCTAssertLessThan(total, 100)
        XCTAssertEqual(RetrySchedule.delay(attempt: 80, base: base, maximum: nil), base << 32,
                       "The exponent is bounded")
        XCTAssertEqual(RetrySchedule.delay(attempt: 3, base: UInt64.max / 2, maximum: nil), UInt64.max,
                       "Overflow saturates instead of trapping")
    }
}
