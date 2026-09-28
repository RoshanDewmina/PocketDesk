import XCTest

final class HostPermissionStateTests: XCTestCase {
    func testDeniedScreenRecordingRejectsEnumeratedDisplays() {
        let result = HostPermissionRefreshResult.resolve(
            screenRecordingGranted: false,
            accessibilityGranted: true,
            displayEnumeration: HostDisplayEnumeration.success([7, 8])
        )

        XCTAssertEqual(result.screenRecording, .denied)
        XCTAssertEqual(result.accessibility, .granted)
        XCTAssertEqual(result.displayStatus, .permissionDenied)
        XCTAssertTrue(result.displays.isEmpty, "A stale enumeration must not survive a denied permission check")
    }

    func testFailedAndEmptyEnumerationBothDiscardPreviousDisplays() {
        let failed: HostPermissionRefreshResult<Int> = .resolve(
            screenRecordingGranted: true,
            accessibilityGranted: false,
            displayEnumeration: .failure
        )
        XCTAssertEqual(failed.displayStatus, .failed)
        XCTAssertTrue(failed.displays.isEmpty)

        let empty: HostPermissionRefreshResult<Int> = .resolve(
            screenRecordingGranted: true,
            accessibilityGranted: false,
            displayEnumeration: .success([])
        )
        XCTAssertEqual(empty.displayStatus, .unavailable)
        XCTAssertTrue(empty.displays.isEmpty)
    }

    func testOnlyNewestRefreshGenerationCanApply() {
        var generations = HostPermissionRefreshGeneration()
        let first = generations.begin()
        let second = generations.begin()

        XCTAssertFalse(generations.accepts(first))
        XCTAssertTrue(generations.accepts(second))

        generations.invalidate()
        XCTAssertFalse(generations.accepts(second))
    }

    func testControlNeedsConsentPermissionAndHealthyCapture() {
        XCTAssertFalse(HostControlPolicy.isEnabled(
            userConsent: false,
            accessibilityPermission: .granted,
            captureHealthy: true
        ))
        XCTAssertFalse(HostControlPolicy.isEnabled(
            userConsent: true,
            accessibilityPermission: .denied,
            captureHealthy: true
        ))
        XCTAssertFalse(HostControlPolicy.isEnabled(
            userConsent: true,
            accessibilityPermission: .granted,
            captureHealthy: false
        ))
        XCTAssertTrue(HostControlPolicy.isEnabled(
            userConsent: true,
            accessibilityPermission: .granted,
            captureHealthy: true
        ))
    }

    func testControlConsentIsAStandingChoiceStillGatedByPermission() {
        var consent = HostControlConsentState()
        XCTAssertTrue(consent.isAllowed, "Control is on by default once a phone is approved")

        consent.setAllowed(false)
        XCTAssertFalse(consent.isAllowed)
        XCTAssertFalse(HostControlPolicy.isEnabled(
            userConsent: HostControlConsentState().isAllowed,
            accessibilityPermission: .denied,
            captureHealthy: true
        ), "Default consent never bypasses the macOS Accessibility grant")
    }
}
