import XCTest
import ScreenCaptureKit

final class CaptureApprovalTests: XCTestCase {
    private func streamError(_ code: SCStreamError.Code) -> Error {
        NSError(domain: SCStreamErrorDomain, code: code.rawValue)
    }

    func testSystemStoppedAndDeclinedCapturesNeedApprovalAndNothingElseDoes() {
        XCTAssertEqual(CaptureStopReason.classify(streamError(.systemStoppedStream)), .needsApproval)
        XCTAssertEqual(CaptureStopReason.classify(streamError(.userDeclined)), .needsApproval)
        XCTAssertEqual(CaptureStopReason.classify(CaptureNotCapturingError()), .needsApproval,
                       "macOS 27 saying the stream is not capturing is never treated as success")
        XCTAssertEqual(SCStreamError.Code.systemStoppedStream.rawValue, -3821)
        XCTAssertEqual(SCStreamError.Code.userDeclined.rawValue, -3801)
        XCTAssertEqual(CaptureStopReason.classify(streamError(.userStopped)), .failed)
        XCTAssertEqual(CaptureStopReason.classify(streamError(.failedToStart)), .failed)
        XCTAssertEqual(CaptureStopReason.classify(NSError(domain: NSCocoaErrorDomain, code: -3821)), .failed,
                       "Only ScreenCaptureKit's own codes count")
    }

    func testApprovalChecksBackOffToAMinuteAndCanBeHurried() {
        var approval = HostCaptureApproval()
        XCTAssertFalse(approval.isPending)
        XCTAssertFalse(approval.isDue(at: 1_000))
        approval.begin(at: 100)
        XCTAssertTrue(approval.isPending)
        XCTAssertFalse(approval.isDue(at: 104))
        XCTAssertTrue(approval.isDue(at: 105))
        var now: TimeInterval = 105
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            approval.checkFailed(at: now)
            let next = approval.nextCheckAt ?? 0
            waits.append(next - now)
            now = next
        }
        XCTAssertEqual(waits, [10, 20, 40, 60, 60, 60])
        approval.checkSoon(at: now + 1)
        XCTAssertTrue(approval.isDue(at: now + 1), "Someone at the Mac gets an immediate check")
        approval.begin(at: now + 2)
        XCTAssertEqual(approval.pendingSince, 100, "A repeat stop keeps when approval was first needed")
        approval.clear()
        XCTAssertFalse(approval.isPending)
        XCTAssertFalse(approval.isDue(at: .greatestFiniteMagnitude))
    }

    func testTheMacSaysApprovalIsNeededOnlyWhileItWantsToShareWithAPairedPhone() {
        var inputs = HostStatus.Inputs(screenRecording: .granted, hasPairedPhone: true, wantsSharing: true,
                                       captureApprovalPending: true)
        XCTAssertEqual(HostStatus.resolve(inputs), .captureNeedsApproval)
        XCTAssertEqual(HostStatus.captureNeedsApproval.title, "Screen recording needs approval on this Mac")
        XCTAssertTrue(HostStatus.captureNeedsApproval.needsAttention)
        XCTAssertEqual(HostMarkState(status: .captureNeedsApproval), .attention)

        inputs.wantsSharing = false
        XCTAssertEqual(HostStatus.resolve(inputs), .paused)
        inputs.wantsSharing = true
        inputs.screenRecording = .denied
        XCTAssertEqual(HostStatus.resolve(inputs), .needsScreenRecording, "A missing grant is the stronger reason")
        inputs.screenRecording = .granted
        inputs.connected = true
        inputs.controlEffective = true
        XCTAssertEqual(HostStatus.resolve(inputs), .controlling)
    }

    func testThePopoverNamesTheStateAndTheExactSteps() {
        var state = HostViewState()
        state.status = .captureNeedsApproval
        state.appListName = "PocketDesk Host"
        state.macOSMajor = 27
        let presentation = HostPopoverPresentation.make(for: state)
        XCTAssertEqual(presentation.title, "Screen recording needs approval on this Mac")
        XCTAssertLessThanOrEqual(presentation.headline.count, 34)
        XCTAssertEqual(presentation.mood, .attention)
        XCTAssertEqual(presentation.actions, [.tryAgain, .openScreenRecording])
        let message = try? XCTUnwrap(presentation.message)
        XCTAssertTrue(message?.contains("In Screen & System Audio Recording, switch on “PocketDesk Host”.") == true)
        XCTAssertTrue(message?.contains("shares again by itself") == true)

        let connection = HostReadyCheck.checks(for: state).first { $0.id == .connection }
        XCTAssertEqual(connection?.result, .fail)
        XCTAssertEqual(connection?.fix, .openSettings(.screenRecording))
    }
}

final class InputAccessCacheTests: XCTestCase {
    func testReadsNeverAskMacOSAndARefreshReportsOnlyChanges() {
        var probes = 0
        var answer = HostInputAccess(postEvents: .granted, accessibility: .granted)
        var cache = HostInputAccessCache(probe: { probes += 1; return answer })
        XCTAssertEqual(probes, 1)
        for _ in 0..<1_000 { XCTAssertTrue(cache.current.postEvents.isGranted) }
        XCTAssertEqual(probes, 1, "Input events read the cached value")

        XCTAssertFalse(cache.refresh())
        answer.accessibility = .denied
        XCTAssertTrue(cache.refresh())
        XCTAssertEqual(cache.current, HostInputAccess(postEvents: .granted, accessibility: .denied))
        XCTAssertEqual(probes, 3)
    }

    func testControlFollowsPostEventsNotAccessibility() {
        XCTAssertTrue(HostControlPolicy.isEnabled(userConsent: true, accessibilityPermission: .granted, captureHealthy: true))
        XCTAssertFalse(HostControlPolicy.isEnabled(userConsent: true, accessibilityPermission: .denied, captureHealthy: true))
        var state = HostViewState()
        state.allowControl = true
        state.accessibility = .granted
        state.focusAccessibility = .denied
        XCTAssertFalse(state.controlNeedsAccessibility, "Control works with post-event access alone")
        state.privacyCurtain = true
        XCTAssertTrue(state.curtainNeedsAccessibility, "Only the curtain and focus features need AX")
    }

    func testDiagnosticsReportBothRightsAndNeverInputMonitoring() {
        var snapshot = HostDiagnosticsSnapshot()
        snapshot.postEvents = "allowed"
        snapshot.accessibility = "not allowed"
        snapshot.captureApproval = "waiting for approval on this Mac"
        snapshot.menuBarIcon = "hidden"
        snapshot.permissionsTurnedOffByUpdate = ["Screen & System Audio Recording"]
        let report = HostDiagnosticsReport.render(snapshot)
        XCTAssertTrue(report.contains("Post events (control): allowed"))
        XCTAssertTrue(report.contains("Accessibility (focus features): not allowed"))
        XCTAssertTrue(report.contains("Input Monitoring: never requested"))
        XCTAssertTrue(report.contains("Screen capture approval: waiting for approval on this Mac"))
        XCTAssertTrue(report.contains("Menu bar icon: hidden"))
        XCTAssertTrue(report.contains("Turned off by a macOS update: Screen & System Audio Recording"))
    }
}

final class UpgradeRegrantTests: XCTestCase {
    private let v26 = "Version 26.4 (Build 25E100)"
    private let v27 = "Version 27.0 (Build 27A266)"

    func testFirstLaunchAndTheSameOSNeverBlameAnUpdate() {
        let first = HostUpgradeRegrant.evaluate(record: nil, osVersion: v26, screenRecording: false, control: false)
        XCTAssertEqual(first.missing, [])
        let revoked = HostUpgradeRegrant.evaluate(
            record: HostOSPermissionRecord(osVersion: v26, screenRecording: true, control: true),
            osVersion: v26, screenRecording: false, control: true)
        XCTAssertEqual(revoked.missing, [], "Turned off on the same macOS: the person did it")
        XCTAssertEqual(revoked.record, HostOSPermissionRecord(osVersion: v26, screenRecording: false, control: true))
    }

    func testAnUpdateThatDropsGrantsIsNamedUntilTheyAreBack() {
        let before = HostOSPermissionRecord(osVersion: v26, screenRecording: true, control: true)
        let updated = HostUpgradeRegrant.evaluate(record: before, osVersion: v27, screenRecording: false, control: false)
        XCTAssertEqual(updated.missing, [.screenRecording, .accessibility])
        XCTAssertEqual(updated.record.updatedFrom, v26)

        let relaunched = HostUpgradeRegrant.evaluate(record: updated.record, osVersion: v27,
                                                     screenRecording: true, control: false)
        XCTAssertEqual(relaunched.missing, [.accessibility], "A relaunch keeps the notice for what is still off")

        let done = HostUpgradeRegrant.evaluate(record: relaunched.record, osVersion: v27,
                                               screenRecording: true, control: true)
        XCTAssertEqual(done.missing, [])
        XCTAssertEqual(done.record, HostOSPermissionRecord(osVersion: v27, screenRecording: true, control: true))
    }

    func testAnUpdateThatKeepsGrantsSaysNothing() {
        let before = HostOSPermissionRecord(osVersion: v26, screenRecording: true, control: false)
        let updated = HostUpgradeRegrant.evaluate(record: before, osVersion: v27, screenRecording: true, control: false)
        XCTAssertEqual(updated.missing, [])
        XCTAssertNil(updated.record.updatedFrom)
    }

    func testSetupCopyNamesThePanesAsThatMacOSDoes() {
        XCTAssertNil(HostCaptureApprovalCopy.afterUpdate([], macOSMajor: 27))
        XCTAssertEqual(HostCaptureApprovalCopy.afterUpdate([.screenRecording, .accessibility], macOSMajor: 27),
                       "macOS was updated and turned off Screen & System Audio Recording and Device Control and Data Access. Switch them back on below.")
        XCTAssertEqual(HostCaptureApprovalCopy.afterUpdate([.accessibility], macOSMajor: 26),
                       "macOS was updated and turned off Accessibility. Switch it back on below.")
    }

    func testRecordRoundTripsThroughPreferences() {
        let suite = "TrustPackTests.record"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertNil(preferences.osPermissionRecord)
        let record = HostOSPermissionRecord(osVersion: v27, screenRecording: true, control: false, updatedFrom: v26)
        preferences.osPermissionRecord = record
        XCTAssertEqual(HostPreferences(defaults: defaults).osPermissionRecord, record)
        XCTAssertTrue(preferences.menuBarIconShown, "The icon is shown until the person removes it")
        preferences.menuBarIconShown = false
        XCTAssertFalse(HostPreferences(defaults: defaults).menuBarIconShown)
    }
}

final class MenuBarIconPolicyTests: XCTestCase {
    func testAHiddenIconAlwaysReopensToSettings() {
        XCTAssertEqual(HostMenuBarIconPolicy.reopenDestination(needsSetup: false, iconShown: false), .settings)
        XCTAssertEqual(HostMenuBarIconPolicy.reopenDestination(needsSetup: true, iconShown: false), .settings,
                       "Settings holds Show in menu bar, the way back")
        XCTAssertEqual(HostMenuBarIconPolicy.reopenDestination(needsSetup: true, iconShown: true), .setup)
        XCTAssertEqual(HostMenuBarIconPolicy.reopenDestination(needsSetup: false, iconShown: true), .settings)
    }

    func testTheSettingsRowSaysSharingContinues() {
        XCTAssertTrue(HostMenuBarIconCopy.subtitle(shown: false).contains("keeps running and sharing"))
        var state = HostViewState()
        state.menuBarIconShown = false
        state.status = .ready
        XCTAssertEqual(HostMarkState(status: state.status), .idle, "Hiding the icon changes no sharing state")
    }
}
