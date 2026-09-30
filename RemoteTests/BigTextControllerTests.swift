import CoreGraphics
import XCTest

@MainActor
final class ControllerFakeSwitcher: DisplayModeSwitching {
    var modesByDisplay: [CGDirectDisplayID: [DisplayModeInfo]] = [:]
    var currentByDisplay: [CGDirectDisplayID: DisplayModeInfo] = [:]
    var online: Set<CGDirectDisplayID> = [1, 2]
    var applied: [(DisplayModeInfo, CGDirectDisplayID)] = []
    var result: DisplayModeApplyResult = .applied
    var onApply: ((DisplayModeInfo, CGDirectDisplayID) -> Void)?

    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? { currentByDisplay[display] }
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo] { modesByDisplay[display] ?? [] }
    func onlineDisplays() -> Set<CGDirectDisplayID> { online }
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult {
        applied.append((mode, display))
        if result == .applied { currentByDisplay[display] = mode; onApply?(mode, display) }
        return result
    }
}

final class ControllerFakeKeeper: BigTextWindowKeeping, @unchecked Sendable {
    var hasSnapshot = false
    var snapshots = 0, settled = 0, restores = 0, discards = 0
    func snapshot(within bounds: CGRect, pids: [pid_t]) async { snapshots += 1; hasSnapshot = true }
    func recordSettled() async { settled += 1 }
    func restore() async -> Int { restores += 1; hasSnapshot = false; return 1 }
    func discard() { discards += 1; hasSnapshot = false }
}

@MainActor
final class ControllerFakeHost: BigTextHost {
    var quiesces = 0, resumes: [CGDirectDisplayID] = [], replies: [(CGDirectDisplayID, BigTextError?)] = []
    var foreign = 0, stateChanges = 0
    func bigTextQuiesce() { quiesces += 1 }
    func bigTextResume(display: CGDirectDisplayID) async -> Bool { resumes.append(display); return true }
    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?) { replies.append((display, error)) }
    func bigTextForeignChange() { foreign += 1 }
    func bigTextStateChanged() { stateChanges += 1 }
    func bigTextDisplayBounds(_ display: CGDirectDisplayID) -> CGRect { CGRect(x: 0, y: 0, width: 1470, height: 956) }
    func bigTextRunningAppPIDs() -> [pid_t] { [10] }
}

@MainActor
final class BigTextControllerTests: XCTestCase {
    private func mode(_ w: Int, _ h: Int, id: Int32) -> DisplayModeInfo {
        DisplayModeInfo(ioModeID: id, width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2, refreshRate: 60, usableForDesktopGUI: true)
    }
    private lazy var base = mode(1470, 956, id: 1)
    private lazy var large = mode(1280, 832, id: 2)
    private lazy var larger = mode(1024, 665, id: 3)

    private var clock: TimeInterval = 0
    private var switcher: ControllerFakeSwitcher!
    private var keeper: ControllerFakeKeeper!
    private var host: ControllerFakeHost!
    private var controller: BigTextController!

    override func setUp() async throws {
        try await super.setUp()
        clock = 0
        switcher = ControllerFakeSwitcher()
        switcher.modesByDisplay = [1: [base, large, larger], 2: [base, large]]
        switcher.currentByDisplay = [1: base, 2: base]
        switcher.onApply = { [unowned self] _, display in
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
        keeper = ControllerFakeKeeper()
        host = ControllerFakeHost()
        controller = BigTextController(switcher: switcher, windows: keeper, now: { [unowned self] in self.clock },
                                       sleep: { [unowned self] seconds in self.clock += seconds; await Task.yield() })
        controller.host = host
    }

    private func apply(_ width: Double, display: CGDirectDisplayID = 1) async {
        controller.request(display: display, looksLikeWidth: width, allowed: true, accessibilityGranted: true)
        await controller.drain()
    }

    private var errors: [BigTextError?] { host.replies.map { $0.1 } }
    private var appliedModes: [DisplayModeInfo] { switcher.applied.map { $0.0 } }

    func testApplyQuiescesChangesSnapshotsAndResumes() async {
        await apply(1300)
        XCTAssertEqual(appliedModes, [large], "the nearest offered step")
        XCTAssertEqual(host.quiesces, 1)
        XCTAssertEqual(host.resumes, [1])
        XCTAssertEqual(errors, [nil])
        XCTAssertEqual(controller.phase, .applied)
        XCTAssertEqual(controller.baseline, base)
        XCTAssertEqual(controller.current, large)
        XCTAssertEqual(keeper.snapshots, 1)
        XCTAssertEqual(keeper.settled, 1)
    }

    func testChangingIsReportedWhileTheModeSwitches() async {
        var sawChanging = false
        switcher.onApply = { [unowned self] _, display in
            sawChanging = self.controller.isChanging
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertTrue(sawChanging, "the screen observers defer to Big Text during its own change")
        XCTAssertFalse(controller.isChanging)
    }

    func testUnsupportedWidthIsRefusedWithoutTouchingTheDisplay() async {
        await apply(700)
        XCTAssertTrue(switcher.applied.isEmpty)
        XCTAssertEqual(host.quiesces, 0)
        XCTAssertEqual(errors, [.unsupported])
    }

    func testSavedWidthAtOrAboveTheMacsSizeIsASilentNoOp() async {
        await apply(1470)
        XCTAssertTrue(switcher.applied.isEmpty)
        XCTAssertEqual(errors, [nil])
    }

    func testDisabledAndMissingAccessibilityRefuse() async {
        controller.request(display: 1, looksLikeWidth: 1280, allowed: false, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: false)
        await controller.drain()
        XCTAssertEqual(errors, [.disabled, .noAccessibility])
        XCTAssertTrue(switcher.applied.isEmpty)
    }

    func testForeignChangeForgetsBaselineAndStopsTheSession() async {
        switcher.onApply = { [unowned self] _, _ in
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        await apply(1280)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertTrue(host.resumes.isEmpty, "the session stops as it does today")
        XCTAssertNil(controller.baseline)
        XCTAssertNil(controller.current)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(keeper.discards, 1)
    }

    func testForeignChangeIsNeverOverwrittenWhenTheSessionEnds() async {
        await apply(1280)
        let chosen = mode(1024, 665, id: 9)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = chosen
            self.controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        }
        await apply(1024)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertNil(controller.baseline)
        let changes = switcher.applied.count
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.applied.count, changes, "the person's own choice stays")
        XCTAssertEqual(switcher.currentByDisplay[1], chosen)
        XCTAssertFalse(controller.isEngaged)
    }

    func testResolutionChosenWhileAppliedIsKeptAtSessionEnd() async {
        await apply(1280)
        let chosen = mode(1024, 665, id: 9)
        switcher.currentByDisplay[1] = chosen
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(appliedModes, [large], "the stop can arrive before the reconfiguration callback")
        XCTAssertEqual(switcher.currentByDisplay[1], chosen)
        XCTAssertNil(controller.baseline)
        XCTAssertEqual(keeper.restores, 0)
        XCTAssertFalse(controller.isEngaged)
    }

    func testResolutionChangeReportedWhileAppliedForgetsTheBaseline() async {
        await apply(1280)
        switcher.currentByDisplay[1] = mode(1024, 665, id: 9)
        controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        XCTAssertNil(controller.baseline)
        XCTAssertFalse(controller.isEngaged)
        XCTAssertEqual(keeper.discards, 1)
    }

    func testTimeoutIsTreatedAsForeign() async {
        switcher.onApply = { [unowned self] _, _ in self.switcher.currentByDisplay[1] = self.base }
        await apply(1280)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertGreaterThan(clock, OwnChangeRecognizer.timeout)
    }

    func testApplyFailureRepliesFailedAndKeepsTheMacsSize() async {
        switcher.result = .failed(1001)
        await apply(1280)
        XCTAssertEqual(errors, [.failed])
        XCTAssertEqual(host.resumes, [1], "the stream comes back at the unchanged size")
        XCTAssertNil(controller.current)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(keeper.discards, 1)
    }

    func testLatestRequestWins() async {
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1024, allowed: true, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true)
        await controller.drain()
        XCTAssertEqual(appliedModes, [large], "the superseded 1024 never ran and 1280 is already current")
        XCTAssertEqual(host.replies.filter { $0.1 == .busy }.count, 1)
    }

    func testSupersededOffRequestIsAnsweredBusy() async {
        await apply(1280)
        controller.request(display: 1, looksLikeWidth: 1024, allowed: true, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 0, allowed: true, accessibilityGranted: true)
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true)
        await controller.drain()
        XCTAssertEqual(errors, [nil, .busy, nil, nil], "every request is answered; busy goes out as soon as it is superseded")
        XCTAssertEqual(appliedModes, [large, larger, large])
    }

    func testSessionEndRestoresModeAndWindowsWithoutResuming() async {
        await apply(1280)
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.applied.last?.0, base)
        XCTAssertEqual(keeper.restores, 1)
        XCTAssertEqual(host.resumes, [1], "only the apply resumed; the session is over")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isEngaged)
    }

    func testOffForThisSessionRestoresAndResumes() async {
        await apply(1280)
        await apply(0)
        XCTAssertEqual(switcher.applied.last?.0, base)
        XCTAssertEqual(host.resumes, [1, 1])
        XCTAssertEqual(host.replies.count, 2)
        XCTAssertEqual(host.replies.last?.1, nil)
    }

    func testFailedOffForThisSessionKeepsBigTextWithoutAPendingRestore() async {
        await apply(1280)
        switcher.result = .failed(1001)
        await apply(0)
        XCTAssertEqual(errors, [nil, .failed])
        XCTAssertEqual(host.resumes, [1, 1])
        XCTAssertEqual(controller.phase, .applied)
        XCTAssertEqual(controller.current, large)
        XCTAssertFalse(controller.restorePending, "the session is still live; it restores when it ends")
    }

    func testFailedRestoreStaysPendingUntilRetried() async {
        await apply(1280)
        switcher.result = .failed(1001)
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertTrue(controller.restorePending)
        XCTAssertTrue(controller.isEngaged)
        switcher.result = .applied
        controller.retryPendingRestore()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.restorePending)
    }

    func testDisconnectGraceRestoresUnlessTheSessionResumes() async {
        await apply(1280)
        controller.connectionLost()
        controller.sessionResumed()
        await controller.drain()
        XCTAssertEqual(controller.current, large, "a quick reconnect keeps Big Text")
        controller.connectionLost()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertGreaterThanOrEqual(clock, BigTextController.disconnectGrace)
    }

    func testTerminationDuringTheGraceCancelsTheDelayedRestore() async {
        await apply(1280)
        controller.connectionLost()
        controller.restoreForTermination()
        await controller.drain()
        XCTAssertEqual(appliedModes, [large, base], "one synchronous restore, none from the grace")
        XCTAssertFalse(controller.isEngaged)
    }

    func testTerminationRestoresSynchronously() async {
        await apply(1280)
        controller.restoreForTermination()
        XCTAssertEqual(switcher.applied.last?.0, base, "no await: quit must stay prompt")
        XCTAssertFalse(controller.isEngaged)
    }

    func testApplyingOnAnotherDisplayRestoresTheFirst() async {
        await apply(1280, display: 1)
        await apply(1280, display: 2)
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertEqual(switcher.currentByDisplay[2], large)
        XCTAssertEqual(controller.display, 2)
    }

    func testAnotherDisplayIsRefusedWhileTheFirstCannotBeRestored() async {
        await apply(1280, display: 1)
        switcher.result = .failed(1001)
        await apply(1280, display: 2)
        XCTAssertEqual(errors, [nil, .failed])
        XCTAssertEqual(controller.display, 1, "the first display's baseline is kept for the retry")
        XCTAssertEqual(controller.baseline, base)
        XCTAssertTrue(controller.restorePending)
    }

    func testDescribeFillsScaleFields() async {
        await apply(1280)
        let described = BigTextController.describe(DisplayDescriptor(id: 1, name: "Built-in", width: 1280, height: 832),
                                                   offer: controller.offer(for: 1))
        XCTAssertEqual(described.scaleBaselineWidth, 1470, "the baseline stays the Mac's own size while applied")
        XCTAssertEqual(described.scaleCurrentWidth, 1280)
        XCTAssertEqual(described.scaleSteps?.map(\.width), [1280, 1024])
        XCTAssertNoThrow(try described.validate())
    }
}
