import CoreGraphics
import XCTest

@MainActor
final class ControllerFakeSwitcher: DisplayModeSwitching {
    var modesByDisplay: [CGDirectDisplayID: [DisplayModeInfo]] = [:]
    var currentByDisplay: [CGDirectDisplayID: DisplayModeInfo] = [:]
    var online: Set<CGDirectDisplayID> = [1, 2]
    var framesByDisplay: [CGDirectDisplayID: CGRect] = [:]
    var applied: [(DisplayModeInfo, CGDirectDisplayID)] = []
    var result: DisplayModeApplyResult = .applied
    var onApply: ((DisplayModeInfo, CGDirectDisplayID) -> Void)?

    func currentMode(of display: CGDirectDisplayID) -> DisplayModeInfo? { currentByDisplay[display] }
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo] { modesByDisplay[display] ?? [] }
    func onlineDisplays() -> Set<CGDirectDisplayID> { online }
    func bounds(of display: CGDirectDisplayID) -> CGRect {
        if let frame = framesByDisplay[display] { return frame }
        let mode = currentByDisplay[display]
        return CGRect(x: display == 1 ? 0 : 1470, y: 0, width: mode?.width ?? 0, height: mode?.height ?? 0)
    }
    func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID) -> DisplayModeApplyResult {
        applied.append((mode, display))
        if result == .applied { currentByDisplay[display] = mode; onApply?(mode, display) }
        return result
    }
}

final class ControllerFakeKeeper: BigTextWindowKeeping, @unchecked Sendable {
    var hasSnapshot = false
    var snapshots = 0, settled = 0, restores = 0, discards = 0
    var onSnapshot: (@MainActor () async -> Void)?
    var onSettled: (@MainActor () async -> Void)?
    var onPrepareStep: (@MainActor () async -> Void)?
    func snapshot(within bounds: CGRect, pids: [pid_t]) async { snapshots += 1; hasSnapshot = true; await onSnapshot?() }
    func prepareStep() async { await onPrepareStep?() }
    func recordSettled() async { settled += 1; await onSettled?() }
    func restore() async -> Int { restores += 1; hasSnapshot = false; return 1 }
    func discard() { discards += 1; hasSnapshot = false }
}

@MainActor
final class ControllerFakeHost: BigTextHost {
    var quiesces = 0, resumes: [CGDirectDisplayID] = [], replies: [(CGDirectDisplayID, BigTextError?)] = []
    var replyIDs: [String?] = []
    var onResume: (() async -> Void)?
    var foreign = 0, stateChanges = 0
    var resumeVerifies = true
    func bigTextQuiesce() { quiesces += 1 }
    func bigTextResume(display: CGDirectDisplayID) async -> Bool { resumes.append(display); await onResume?(); return resumeVerifies }
    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?, requestID: String?) { replies.append((display, error)); replyIDs.append(requestID) }
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
        observerStops = 0
        observerRefits = 0
        switcher = ControllerFakeSwitcher()
        switcher.modesByDisplay = [1: [base, large, larger], 2: [base, large]]
        switcher.currentByDisplay = [1: base, 2: base]
        observeOwnChanges()
        keeper = ControllerFakeKeeper()
        host = ControllerFakeHost()
        controller = BigTextController(switcher: switcher, windows: keeper, now: { [unowned self] in self.clock },
                                       sleep: { [unowned self] seconds in self.clock += seconds; await Task.yield() })
        controller.host = host
    }

    private func observeOwnChanges() {
        switcher.onApply = { [unowned self] _, display in
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
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

    func testForeignEventDuringOurChangeStopsTheSessionAndStillRestores() async {
        switcher.onApply = { [unowned self] _, _ in
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        await apply(1280)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertTrue(host.resumes.isEmpty, "the session stops as it does today")
        XCTAssertEqual(controller.baseline, base, "the display still has our mode, so it is still ours to restore")
        XCTAssertEqual(controller.current, large)
        XCTAssertGreaterThanOrEqual(keeper.discards, 1, "foreign apply discards its window plan")
        switcher.onApply = { [unowned self] _, display in
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(appliedModes, [large, base], "a monitor plugged in mid-change never leaves the Mac on Big Text")
        XCTAssertNil(controller.baseline)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.foreign, 1, "the restore is recognised as our own change")
        XCTAssertEqual(keeper.restores, 1)
        XCTAssertFalse(controller.isEngaged)
    }

    func testSleepAfterSuccessfulApplyKeepsOwnershipUntilModeIsReadable() async {
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = nil
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.removeFlag]))
        }
        await apply(1280)
        XCTAssertEqual(controller.baseline, base)
        XCTAssertEqual(controller.current, large)
        switcher.currentByDisplay[1] = large
        observeOwnChanges()
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
    }

    func testForeignEventDuringALaterStepKeepsThePreviousStepToRestore() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = self.large
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        await apply(1024)
        XCTAssertEqual(host.foreign, 1)
        XCTAssertEqual(controller.baseline, base, "the display is still on our previous step")
        XCTAssertEqual(controller.current, large)
        XCTAssertGreaterThanOrEqual(keeper.discards, 1, "foreign apply discards its window plan")
        observeOwnChanges()
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
    }

    func testForeignEventDuringRestoreKeepsTheBaselineWhileOurModeRemains() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = self.large
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(controller.baseline, base, "a monitor plugged in mid-restore must not strand the Mac on Big Text")
        XCTAssertEqual(controller.current, large)
        XCTAssertTrue(controller.restorePending)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.isEngaged)
        XCTAssertEqual(keeper.discards, 0)
        observeOwnChanges()
        controller.retryPendingRestore()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base, "wake or unlock restores it")
        XCTAssertEqual(keeper.restores, 1)
        XCTAssertFalse(controller.isEngaged)
    }

    func testForeignEventDuringOffForThisSessionLeavesTheRestoreToTheSessionEnd() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = self.large
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        await apply(0)
        XCTAssertEqual(host.foreign, 1, "the session stops as for any change we did not make")
        XCTAssertEqual(controller.baseline, base)
        XCTAssertTrue(controller.restorePending)
        observeOwnChanges()
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
    }

    func testForeignEventDuringRestoreForgetsOnceOurModeIsGone() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base, "the restore landed alongside the new monitor")
        XCTAssertNil(controller.baseline)
        XCTAssertFalse(controller.restorePending)
        XCTAssertFalse(controller.isEngaged)

        observeOwnChanges()
        await apply(1280)
        let chosen = mode(1024, 665, id: 9)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = chosen
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], chosen, "a mode we did not set is never restored over")
        XCTAssertNil(controller.baseline)
        XCTAssertFalse(controller.isEngaged)
    }

    func testUnverifiedResumeAfterApplyRepliesFailed() async {
        host.resumeVerifies = false
        await apply(1280)
        XCTAssertEqual(errors, [.failed], "the host treats the unverified display list as foreign and stops")
        XCTAssertEqual(controller.current, large, "the mode is still ours to restore at session end")
        XCTAssertEqual(controller.baseline, base)
    }

    func testUnverifiedResumeAfterOffForThisSessionRepliesFailed() async {
        await apply(1280)
        host.resumeVerifies = false
        await apply(0)
        XCTAssertEqual(errors, [nil, .failed])
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
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

    func testUnreadableModeDuringSleepRestoreKeepsTheBaselineForWake() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = nil
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.removeFlag]))
        }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertEqual(controller.baseline, base, "an unreadable sleeping display is not a foreign chosen resolution")
        XCTAssertTrue(controller.restorePending)
        switcher.currentByDisplay[1] = large
        observeOwnChanges()
        controller.retryPendingRestore()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
    }

    func testRestoreTimeoutKeepsBaselineUntilWakeRetry() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in self.switcher.currentByDisplay[1] = self.large }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertGreaterThan(clock, OwnChangeRecognizer.timeout)
        XCTAssertEqual(controller.baseline, base)
        XCTAssertTrue(controller.restorePending)
        observeOwnChanges()
        controller.retryPendingRestore()
        await controller.drain()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
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

    func testTerminationDuringAFirstChangeRestoresTheModeAlreadySwitched() async {
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.onApply = nil
            self.controller.restoreForTermination()
        }
        await apply(1280)
        XCTAssertEqual(appliedModes, [large, base], "quit arrived before the change was recognised")
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
    }

    func testTerminationDuringALaterStepRestoresTheModeAlreadySwitched() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.onApply = nil
            self.controller.restoreForTermination()
        }
        await apply(1024)
        XCTAssertEqual(appliedModes, [large, larger, base])
        XCTAssertEqual(switcher.currentByDisplay[1], base)
        XCTAssertFalse(controller.isEngaged)
    }

    func testTerminationNeverRestoresOverAModeThePersonChose() async {
        await apply(1280)
        switcher.currentByDisplay[1] = mode(1024, 665, id: 9)
        controller.restoreForTermination()
        XCTAssertEqual(appliedModes, [large])
        XCTAssertFalse(controller.isEngaged)
    }

    func testTerminationAfterAForeignRestoreStillRestores() async {
        await apply(1280)
        switcher.onApply = { [unowned self] _, _ in
            self.switcher.currentByDisplay[1] = self.large
            self.controller.observe(DisplayReconfigurationEvent(display: 3, flags: [.addFlag]))
        }
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        observeOwnChanges()
        controller.restoreForTermination()
        XCTAssertEqual(switcher.currentByDisplay[1], base)
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

    func testManualChoiceDuringSnapshotNeverCallsApply() async {
        let chosen = mode(1024, 665, id: 99)
        keeper.onSnapshot = { [unowned self] in
            await Task.yield()
            self.switcher.currentByDisplay[1] = chosen
            self.controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertTrue(appliedModes.isEmpty)
        XCTAssertEqual(switcher.currentByDisplay[1], chosen)
        XCTAssertNil(controller.baseline)
        XCTAssertFalse(keeper.hasSnapshot)
        XCTAssertEqual(errors, [.failed])
        XCTAssertEqual(host.foreign, 1)
    }

    func testManuallyPickingTheRequestedModeDuringSnapshotDoesNotGiveUsOwnership() async {
        keeper.onSnapshot = { [unowned self] in
            await Task.yield()
            self.switcher.currentByDisplay[1] = self.large
            self.controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertTrue(appliedModes.isEmpty)
        XCTAssertNil(controller.baseline)
        XCTAssertNil(controller.current)
        controller.sessionEnded(.sessionEnded)
        await controller.drain()
        XCTAssertTrue(appliedModes.isEmpty, "a target we never applied cannot be ours to restore")
    }

    func testManualChoiceDuringSettleIsNotAdoptedAsSuccess() async {
        let chosen = mode(1024, 665, id: 99)
        controller = BigTextController(switcher: switcher, windows: keeper, now: { [unowned self] in self.clock },
            sleep: { [unowned self] seconds in
                self.clock += seconds
                await Task.yield()
                self.switcher.currentByDisplay[1] = chosen
                self.controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
            })
        controller.host = host
        await apply(1280)
        XCTAssertEqual(appliedModes, [large])
        XCTAssertNil(controller.baseline)
        XCTAssertTrue(host.resumes.isEmpty)
        XCTAssertEqual(errors, [.failed])
    }

    func testManualChoiceDuringWindowRecordingIsNotAdoptedAsSuccess() async {
        let chosen = mode(1024, 665, id: 99)
        keeper.onSettled = { [unowned self] in
            await Task.yield()
            self.switcher.currentByDisplay[1] = chosen
            self.controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertNil(controller.baseline)
        XCTAssertFalse(keeper.hasSnapshot)
        XCTAssertTrue(host.resumes.isEmpty)
        XCTAssertEqual(errors, [.failed])
    }

    func testForeignChoiceDuringResumeIsNotRepliedSuccess() async {
        host.onResume = { [unowned self] in
            await Task.yield()
            self.switcher.currentByDisplay[1] = self.mode(1024, 665, id: 99)
        }
        await apply(1280)
        XCTAssertEqual(errors, [.failed])
        XCTAssertNil(controller.baseline)
        XCTAssertFalse(controller.ownsLiveConfiguration)
    }

    func testOtherDisplayModeChangeWithSameTopologyIsForeign() async {
        switcher.onApply = { [unowned self] _, display in
            self.switcher.currentByDisplay[2] = self.large
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
            self.controller.observe(DisplayReconfigurationEvent(display: 2, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertEqual(errors, [.failed])
        XCTAssertTrue(host.resumes.isEmpty)
        XCTAssertEqual(switcher.currentByDisplay[2], large)
        XCTAssertFalse(controller.ownsLiveConfiguration)
    }

    func testUnreadableOtherDisplayPreventsAnUnownedConfigurationCall() async {
        switcher.currentByDisplay[2] = nil
        await apply(1280)
        XCTAssertTrue(appliedModes.isEmpty)
        XCTAssertEqual(errors, [.failed])
        XCTAssertNil(controller.baseline)
    }

    func testUnexpectedArrangementIsForeignWithoutCallback() async {
        switcher.onApply = { [unowned self] _, display in
            self.switcher.framesByDisplay[2] = CGRect(x: 2000, y: 40, width: 1470, height: 956)
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
        }
        await apply(1280)
        XCTAssertEqual(errors, [.failed])
        XCTAssertTrue(host.resumes.isEmpty)
        XCTAssertFalse(controller.ownsLiveConfiguration)
    }

    // Exercises the exact observer boundary used by HostModel with lifecycle callbacks.
    private var observerStops = 0
    private var observerRefits = 0
    private func notifyScreenParametersChanged() {
        controller.handleScreenChangeNotification(
            refit: { self.observerRefits += 1 },
            foreign: {
                self.observerStops += 1
                self.controller.sessionEnded(.sessionEnded)
            })
    }

    private func installPendingObserverChange(unreadable: Bool, settle: Bool) {
        switcher.onApply = { [unowned self] mode, display in
            self.switcher.framesByDisplay[display] = CGRect(x: 0, y: 0, width: mode.width, height: mode.height)
            self.switcher.currentByDisplay[display] = unreadable ? nil : self.base
            self.controller.observe(DisplayReconfigurationEvent(display: display, flags: [.setModeFlag]))
            XCTAssertEqual(self.controller.screenChangeVerdict, .pending)
            XCTAssertFalse(self.controller.ownsLiveConfiguration, "pending cannot authorize input/capture resume")
            self.notifyScreenParametersChanged()
        }
        controller = BigTextController(switcher: switcher, windows: keeper, now: { [unowned self] in self.clock },
            sleep: { [unowned self] seconds in
                self.clock += seconds
                await Task.yield()
                self.notifyScreenParametersChanged()
                if settle { self.switcher.currentByDisplay[1] = self.large }
            })
        controller.host = host
    }

    func testUnreadableTargetObserverDefersStopUntilOwnedCompletion() async {
        installPendingObserverChange(unreadable: true, settle: true)
        await apply(1280)
        XCTAssertEqual(observerStops, 0, "no baseline restore is queued by the pending observer")
        XCTAssertGreaterThan(observerRefits, 0, "prepared coverage is refit while capture/input stay quiesced")
        XCTAssertEqual(host.quiesces, 1)
        XCTAssertEqual(host.resumes, [1])
        XCTAssertEqual(appliedModes, [large])
        XCTAssertEqual(errors, [nil])
        XCTAssertTrue(controller.ownsLiveConfiguration)
    }

    func testTransitionalTargetObserverDefersStopUntilOwnedCompletion() async {
        installPendingObserverChange(unreadable: false, settle: true)
        await apply(1280)
        XCTAssertEqual(observerStops, 0)
        XCTAssertGreaterThan(observerRefits, 0)
        XCTAssertEqual(host.resumes, [1])
        XCTAssertEqual(errors, [nil])
    }

    func testPendingObserverTimeoutStopsWithoutResumingInput() async {
        installPendingObserverChange(unreadable: true, settle: false)
        await apply(1280)
        XCTAssertGreaterThan(clock, OwnChangeRecognizer.timeout)
        XCTAssertGreaterThan(observerStops, 0)
        XCTAssertGreaterThan(observerRefits, 0)
        XCTAssertTrue(host.resumes.isEmpty)
        XCTAssertEqual(errors, [.failed])
        XCTAssertEqual(host.foreign, 1)
        XCTAssertTrue(controller.restorePending, "unreadable owned mode retains a baseline for later retry")
    }

    func testPendingTargetDoesNotHideOtherDisplayChangeFromObserver() async {
        switcher.onApply = { [unowned self] mode, display in
            self.switcher.framesByDisplay[display] = CGRect(x: 0, y: 0, width: mode.width, height: mode.height)
            self.switcher.currentByDisplay[display] = nil
            self.switcher.currentByDisplay[2] = self.large
            XCTAssertEqual(self.controller.screenChangeVerdict, .foreign)
            self.notifyScreenParametersChanged()
        }
        await apply(1280)
        XCTAssertEqual(observerStops, 1)
        XCTAssertEqual(observerRefits, 0)
        XCTAssertTrue(host.resumes.isEmpty)
        XCTAssertEqual(errors, [.failed])
        XCTAssertEqual(switcher.currentByDisplay[2], large)
    }

    func testDelayedCompletedCallbackDuringNextPreparationIsIgnoredOnlyForUnchangedConfiguration() async {
        await apply(1280)
        keeper.onPrepareStep = { [unowned self] in
            await Task.yield()
            self.controller.observe(DisplayReconfigurationEvent(display: 1, flags: [.setModeFlag]))
            self.notifyScreenParametersChanged()
        }
        await apply(1024)
        XCTAssertEqual(observerStops, 0)
        XCTAssertEqual(observerRefits, 1)
        XCTAssertEqual(appliedModes, [large, larger])
        XCTAssertEqual(errors, [nil, nil])
        XCTAssertEqual(host.resumes, [1, 1])
    }

    func testEveryOwnedStepRecordsExpectedWindowGeometry() async {
        await apply(1280)
        await apply(1024)
        XCTAssertEqual(keeper.snapshots, 1)
        XCTAssertEqual(keeper.settled, 2)
    }

    func testRepliesCarryRunningAndSupersededRequestIDs() async {
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true, requestID: "a")
        controller.request(display: 1, looksLikeWidth: 1024, allowed: true, accessibilityGranted: true, requestID: "b")
        controller.request(display: 1, looksLikeWidth: 1280, allowed: true, accessibilityGranted: true, requestID: "c")
        await controller.drain()
        XCTAssertEqual(host.replyIDs, ["b", "a", "c"])
        XCTAssertEqual(errors, [.busy, nil, nil])
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
