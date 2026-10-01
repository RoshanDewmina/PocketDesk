import XCTest
import AppKit

@MainActor
final class AwayCurtainTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("away-watchdog-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAwayCoverNeedsNoSessionAndSurvivesEveryLiftTrigger() {
        var inputs = PrivacyCurtainInputs(); inputs.awayCovered = true
        XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: false), .up, "No phone, no preference")
        for change in [{ (i: inout PrivacyCurtainInputs) in i.captureHealthy = false; i.unhealthyFor = 99 },
                       { $0.locallyDismissed = true }, { $0.raiseFailed = true }, { $0.phonePaused = true },
                       { $0.accessibilityGranted = false }] {
            var i = inputs; change(&i)
            XCTAssertEqual(PrivacyCurtainPolicy.desired(i, currentlyUp: true), .up)
        }
        inputs.screenLocked = true
        XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: true), .up, "A hint cannot retire the verified cover owner")
    }

    func testSharingCurtainBehaviourIsUnchangedWithoutAway() {
        XCTAssertEqual(PrivacyCurtainPolicy.desired(PrivacyCurtainInputs(), currentlyUp: true), .down)
    }

    func testEscapeCannotLiftTheAwayCover() async {
        let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
        _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }), settle: .zero, verifyAfter: .zero)
        curtain.escapeLiftEnabled = false
        for t in [0.0, 0.1, 0.2] { XCTAssertFalse(curtain.handleKeyDown(keyCode: 53, timestamp: t, isRepeat: false, injected: false)) }
        XCTAssertEqual(curtain.phase, .up)
        curtain.lift()
    }

    func testScreenChangeNotifiesInsteadOfLiftingWhenAsked() async {
        let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
        _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }), settle: .zero, verifyAfter: .zero)
        var notified = 0
        curtain.liftsOnScreenChange = false
        curtain.onScreensChanged = { notified += 1 }
        curtain.handleScreenParametersChanged()
        XCTAssertEqual(curtain.phase, .up); XCTAssertEqual(notified, 1)
        curtain.liftsOnScreenChange = true
        curtain.handleScreenParametersChanged()
        XCTAssertEqual(curtain.phase, .down)
    }

    func testStyleChangesWithoutReraising() async {
        let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
        _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }), settle: .zero, verifyAfter: .zero)
        let ids = curtain.windowIDs
        curtain.setStyle(.away)
        XCTAssertEqual(curtain.style, .away); XCTAssertEqual(curtain.windowIDs, ids); XCTAssertEqual(curtain.phase, .up)
        curtain.lift()
    }

    func testOldRecordWithoutAwayFieldDecodes() throws {
        let record = HostRunRecord(pid: 1, launchID: "a", bootSession: "b", executablePath: "/x", startedAt: Date(),
                                   heartbeatUptime: 1, heartbeatAt: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "awayCoverUp")
        let decoded = try JSONDecoder().decode(HostRunRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.awayCoverUp)
    }

    func testUnexpectedExitWhileCoveredLocksFirst() {
        var previous = HostRunRecord(pid: 1, launchID: "a", bootSession: "boot", executablePath: "/x", startedAt: Date(),
                                     heartbeatUptime: 1, heartbeatAt: Date())
        previous.awayCoverUp = true
        XCTAssertTrue(HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: "boot",
                                                  previousProcessAlive: false, safeModeArgument: false).lockFirst)
        var clean = previous; clean.cleanExit = true
        XCTAssertTrue(HostLaunchAssessment.assess(previous: clean, ledger: nil, hangNote: nil, bootSession: "boot",
                                                   previousProcessAlive: false, safeModeArgument: false).lockFirst)
        XCTAssertFalse(HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: "other",
                                                   previousProcessAlive: false, safeModeArgument: false).lockFirst,
                       "After a restart macOS asks for the password anyway")
        XCTAssertFalse(HostLaunchAssessment.assess(previous: previous, ledger: nil, hangNote: nil, bootSession: "boot",
                                                   previousProcessAlive: true, safeModeArgument: false).lockFirst)
        var uncovered = previous; uncovered.awayCoverUp = false
        XCTAssertFalse(HostLaunchAssessment.assess(previous: uncovered, ledger: nil, hangNote: nil, bootSession: "boot",
                                                   previousProcessAlive: false, safeModeArgument: false).lockFirst)
    }

    func testReporterRetainsUnconfirmedCoverOnCleanExitAndNextLaunchLocksFirst() throws {
        let files = WatchdogFiles(directory: directory)
        let executable = "/Applications/A.app/Contents/MacOS/A"
        let reporter = HostWatchdogReporter(files: files, executablePath: executable,
                                            bootSession: "boot-A", pid: 999_980, arguments: [], uptime: { 50 })
        reporter.start()
        XCTAssertEqual(reporter.currentHeartbeatInterval, HostWatchdogReporter.heartbeatInterval)

        reporter.setAwayCoverUp(true)
        XCTAssertEqual(reporter.record.awayCoverUp, true)
        XCTAssertFalse(reporter.record.curtainUp, "The Away cover is recorded separately from the sharing curtain")
        XCTAssertEqual(reporter.currentHeartbeatInterval, HostWatchdogReporter.curtainHeartbeatInterval)
        let flushed = expectation(description: "record flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(WatchdogStore.read(HostRunRecord.self, from: files.hostRecord)?.awayCoverUp, true)

        // Simulate a crash while covered: the next launch in this boot must lock first.
        let relaunched = HostWatchdogReporter(files: files, executablePath: executable,
                                              bootSession: "boot-A", pid: 999_981, arguments: [], uptime: { 60 })
        XCTAssertTrue(relaunched.assessment.lockFirst)

        reporter.markCleanExit()
        let written = try XCTUnwrap(WatchdogStore.read(HostRunRecord.self, from: files.hostRecord))
        XCTAssertEqual(written.awayCoverUp, true)
        XCTAssertTrue(written.cleanExit)
        let afterQuit = HostWatchdogReporter(files: files, executablePath: executable,
                                             bootSession: "boot-A", pid: 999_982, arguments: [], uptime: { 70 })
        XCTAssertTrue(afterQuit.assessment.lockFirst, "An unconfirmed cover survives even a clean quit")
        reporter.setAwayCoverUp(false)
        reporter.markCleanExit()
        let afterConfirmed = HostWatchdogReporter(files: files, executablePath: executable,
            bootSession: "boot-A", pid: 999_983, arguments: [], uptime: { 80 })
        XCTAssertFalse(afterConfirmed.assessment.lockFirst)
    }

    func testAwayCoverIsOpaqueBeforeStalledOrFailedExclusionCompletes() async {
        let window = Self.testWindow()
        let curtain = PrivacyCurtainController(makeWindows: { [window] })
        curtain.setStyle(.away)
        let entered = expectation(description: "exclusion entered")
        var resume: CheckedContinuation<Bool, Never>?
        let result = await curtain.raise(hooks: .init(exclude: { _ in
            entered.fulfill()
            return await withCheckedContinuation { resume = $0 }
        }, signature: { XCTFail("Away must not await capture verification"); return nil }))
        XCTAssertEqual(result, .raised)
        XCTAssertEqual(curtain.phase, .up)
        XCTAssertEqual(window.alphaValue, 1)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(window.alphaValue, 1)
        resume?.resume(returning: false)
        await Task.yield()
        XCTAssertEqual(curtain.phase, .up, "Failed exclusion must not uncover Away mode")
        curtain.lift()
    }

    func testAwayTakesOverAStalledSharingRaiseWithoutWaiting() async {
        let window = Self.testWindow()
        let curtain = PrivacyCurtainController(makeWindows: { [window] })
        let entered = expectation(description: "sharing exclusion entered")
        var resume: CheckedContinuation<Bool, Never>?
        let raise = Task { @MainActor in
            await curtain.raise(hooks: .init(exclude: { _ in
                entered.fulfill()
                return await withCheckedContinuation { resume = $0 }
            }, signature: { nil }))
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(window.alphaValue, 0)
        curtain.setStyle(.away)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(curtain.phase, .up)
        resume?.resume(returning: false)
        let sharingResult = await raise.value
        XCTAssertEqual(sharingResult, .cancelled)
        XCTAssertEqual(curtain.phase, .up)
        curtain.lift()
    }

    func testScreenChangeRefitsEveryAwayWindowBeforeTheLockCallback() async {
        var current = [Self.testWindow()]
        let curtain = PrivacyCurtainController(makeWindows: { current })
        curtain.setStyle(.away)
        curtain.liftsOnScreenChange = false
        _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }))
        let old = current
        current = [Self.testWindow(), Self.testWindow()]
        var notified = 0
        curtain.onScreensChanged = {
            notified += 1
            XCTAssertEqual(curtain.windowIDs.count, 2)
            XCTAssertTrue(current.allSatisfy { $0.alphaValue == 1 })
            XCTAssertEqual(curtain.phase, .up)
        }
        curtain.handleScreenParametersChanged()
        XCTAssertEqual(notified, 1)
        XCTAssertTrue(old.allSatisfy { !$0.isVisible })
        curtain.lift()
    }

    func testHangLocksCoveredMatchingRunBeforeExitingUsingOnlyInjectedActions() throws {
        let files = WatchdogFiles(directory: directory)
        let reporter = HostWatchdogReporter(files: files, executablePath: "/x", bootSession: "boot", pid: 999_980,
                                            arguments: [], uptime: { 0 })
        reporter.start(); reporter.setAwayCoverUp(true)
        let calls = HangCalls()
        let handler = HostWatchdogReporter.hangHandler(files: files, launchID: reporter.record.launchID, bootSession: "boot",
                                                      requestLock: { calls.add("lock"); return true },
                                                      isLocked: { true }, wait: { _ in XCTFail("Already confirmed") },
                                                      terminate: { calls.add("exit") })
        XCTAssertTrue(handler(4))
        XCTAssertEqual(calls.values, ["lock", "exit"])
        XCTAssertEqual(WatchdogStore.read(HostHangNote.self, from: files.hangNote)?.stalledSeconds, 4)
        let stale = HangCalls()
        HostWatchdogReporter.hangHandler(files: files, launchID: "old", bootSession: "boot",
            requestLock: { stale.add("lock"); return true }, terminate: { stale.add("exit") })(4)
        XCTAssertEqual(stale.values, [], "A mismatching run cannot be terminated")
        reporter.setAwayCoverUp(false)
        let uncovered = HangCalls()
        HostWatchdogReporter.hangHandler(files: files, launchID: reporter.record.launchID, bootSession: "boot",
            requestLock: { uncovered.add("lock"); return true }, terminate: { uncovered.add("exit") })(4)
        XCTAssertEqual(uncovered.values, ["exit"])
        reporter.markCleanExit()
    }

    func testUnconfirmedHangRetainsCoverAndDoesNotExitWithBoundedInjectedWait() throws {
        let files = WatchdogFiles(directory: directory)
        let reporter = HostWatchdogReporter(files: files, executablePath: "/x", bootSession: "boot", pid: 999_980,
                                            arguments: [], uptime: { 0 })
        reporter.start()
        XCTAssertTrue(reporter.setAwayCoverUp(true))
        let calls = HangCalls()
        let handler = HostWatchdogReporter.hangHandler(files: files, launchID: reporter.record.launchID,
            bootSession: "boot", requestLock: { calls.add("lock"); return true }, isLocked: { false },
            wait: { seconds in calls.add("wait"); XCTAssertEqual(seconds, 0.1) }, terminate: { calls.add("exit") })
        XCTAssertFalse(handler(4))
        XCTAssertEqual(calls.values.filter { $0 == "wait" }.count, 20)
        XCTAssertFalse(calls.values.contains("exit"))
        XCTAssertEqual(WatchdogStore.read(HostRunRecord.self, from: files.hostRecord)?.awayCoverUp, true)
        XCTAssertNil(WatchdogStore.read(HostHangNote.self, from: files.hangNote))
        reporter.markCleanExit()
    }

    func testFailedMarkerWriteDoesNotCommitCover() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obstruction = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: obstruction)
        let reporter = HostWatchdogReporter(files: WatchdogFiles(directory: obstruction), executablePath: "/x",
            bootSession: "boot", pid: 999_980, arguments: [], uptime: { 0 })
        XCTAssertFalse(reporter.setAwayCoverUp(true))
        XCTAssertNotEqual(reporter.record.awayCoverUp, true)
    }

    func testSharingCanaryCompletionCannotLowerPromotedAwayCover() async {
        let window = Self.testWindow()
        let curtain = PrivacyCurtainController(makeWindows: { [window] })
        let verifying = expectation(description: "signature before cover")
        var readings = 0
        let task = Task { @MainActor in await curtain.raise(hooks: .init(exclude: { _ in true }, signature: {
            readings += 1
            if readings == 1 { verifying.fulfill() }
            return CaptureLumaSignature(samples: Array(repeating: readings == 1 ? 200 : 0, count: 64))
        }), settle: .zero, verifyAfter: .milliseconds(50)) }
        await fulfillment(of: [verifying], timeout: 2)
        curtain.setStyle(.away)
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(curtain.phase, .up)
        XCTAssertEqual(window.alphaValue, 1)
        curtain.lift()
    }

    func testExternalWatchdogCannotRemoveAnAliveAwayCover() {
        var record = HostRunRecord(pid: 42, launchID: "run", bootSession: "boot",
            executablePath: "/Applications/F.app/Contents/MacOS/F", startedAt: Date(), heartbeatUptime: 1, heartbeatAt: Date())
        record.awayCoverUp = true
        var ledger = WatchdogLedger(bootSession: "boot")
        let observation = WatchdogObservation(record: record, ownedBundlePath: "/Applications/F.app",
            recordProcessAlive: true, bootSession: "boot", now: Date(), uptime: 1000)
        XCTAssertEqual(WatchdogPolicy().decide(observation, ledger: &ledger), .idle)
    }

    func testOwnBigTextNotificationRefitsAwayWithoutStartingForeignTopologyLock() async {
        let curtain = PrivacyCurtainController(makeWindows: { [Self.testWindow()] })
        curtain.setStyle(.away); curtain.liftsOnScreenChange = false
        curtain.ownsScreenChange = { true }
        curtain.onScreensChanged = { XCTFail("Own verified mode change is not foreign topology") }
        _ = await curtain.raise(hooks: .init(exclude: { _ in true }, signature: { nil }))
        let old = curtain.windowIDs
        curtain.prepareForDisplayChange(coverage: CGRect(x: -30000, y: -30000, width: 40, height: 40))
        curtain.handleScreenParametersChanged()
        XCTAssertEqual(curtain.phase, .up)
        XCTAssertNotEqual(curtain.windowIDs, old)
        curtain.lift()
    }

    /// Tiny and far off-screen, like PrivacyCurtainControllerTests: the real curtain is never shown.
    static func testWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 8, height: 8),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        return window
    }
}

private final class HangCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    func add(_ call: String) { lock.lock(); defer { lock.unlock() }; calls.append(call) }
}
