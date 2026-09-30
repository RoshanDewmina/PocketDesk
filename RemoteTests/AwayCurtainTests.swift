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
        XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: true), .down, "macOS's own lock covers the Mac")
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
        XCTAssertFalse(HostLaunchAssessment.assess(previous: clean, ledger: nil, hangNote: nil, bootSession: "boot",
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

    func testReporterPersistsTheAwayCoverAndClearsItOnCleanExit() throws {
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
        XCTAssertEqual(written.awayCoverUp, false)
        XCTAssertTrue(written.cleanExit)
        let afterQuit = HostWatchdogReporter(files: files, executablePath: executable,
                                             bootSession: "boot-A", pid: 999_982, arguments: [], uptime: { 70 })
        XCTAssertFalse(afterQuit.assessment.lockFirst, "A clean quit never locks on relaunch")
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
