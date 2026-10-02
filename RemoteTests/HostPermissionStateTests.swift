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

    func testPostingGrantExpiresWithoutMainActorRefresh() {
        let snapshot = HostPostingGrantSnapshot(enabled: true)
        XCTAssertFalse(snapshot.isGranted(at: 10))
        snapshot.update(.granted, at: 10)
        XCTAssertTrue(snapshot.isGranted(at: 10))
        XCTAssertTrue(snapshot.isGranted(at: 10.499))
        XCTAssertFalse(snapshot.isGranted(at: 10.5))
        XCTAssertFalse(snapshot.isGranted(at: 11))
    }

    func testPostingGrantRevocationAndInvalidTimesDenyImmediately() {
        let snapshot = HostPostingGrantSnapshot(enabled: true)
        snapshot.update(.granted, at: 10)
        XCTAssertFalse(snapshot.isGranted(at: 9))
        XCTAssertFalse(snapshot.isGranted(at: .nan))
        XCTAssertFalse(snapshot.isGranted(at: .infinity))
        snapshot.update(.denied, at: 10.1)
        XCTAssertFalse(snapshot.isGranted(at: 10.1))
        snapshot.update(.granted, at: .nan)
        XCTAssertFalse(snapshot.isGranted(at: 10.2))
        snapshot.update(.unchecked, at: 10.3)
        XCTAssertFalse(snapshot.isGranted(at: 10.3))
    }

    func testEqualPermissionRefreshRenewsPostingObservation() {
        let snapshot = HostPostingGrantSnapshot(enabled: true)
        var now: TimeInterval = 10
        var cache = HostInputAccessCache(probe: { .init(postEvents: .granted, accessibility: .denied) },
                                        postingGrant: snapshot, clock: { now })
        XCTAssertTrue(snapshot.isGranted(at: 10))
        XCTAssertFalse(snapshot.isGranted(at: 10.5))
        now = 10.6
        XCTAssertFalse(cache.refresh(), "An unchanged grant need not republish UI state")
        XCTAssertTrue(snapshot.isGranted(at: 10.6), "An unchanged grant must renew posting freshness")
    }

    func testSlowPermissionProbeCannotPublishFreshLookingOldGrant() {
        let snapshot = HostPostingGrantSnapshot(enabled: true)
        var now: TimeInterval = 10
        _ = HostInputAccessCache(probe: {
            now += 1
            return .init(postEvents: .granted, accessibility: .granted)
        }, postingGrant: snapshot, clock: { now })
        XCTAssertFalse(snapshot.isGranted(at: now), "Freshness starts before the probe, not after a stall")
    }

    func testPermissionRefreshPublishesDeniedPostingObservation() {
        let snapshot = HostPostingGrantSnapshot(enabled: true)
        var access = HostInputAccess(postEvents: .granted, accessibility: .granted)
        var now: TimeInterval = 10
        var cache = HostInputAccessCache(probe: { access }, postingGrant: snapshot, clock: { now })
        access.postEvents = .denied
        now = 10.1
        XCTAssertTrue(cache.refresh())
        XCTAssertEqual(cache.current.postEvents, .denied)
        XCTAssertFalse(snapshot.isGranted(at: now))
    }

    func testPostingSnapshotRollbackCallsLiveProbeAndEnabledPathDoesNot() {
        let snapshot = HostPostingGrantSnapshot(enabled: true)
        snapshot.update(.granted, at: 10)
        var probes = 0
        XCTAssertTrue(snapshot.allowsPosting(at: 10, legacyProbe: { probes += 1; return false }))
        XCTAssertFalse(snapshot.allowsPosting(at: 11, legacyProbe: { probes += 1; return true }))
        XCTAssertEqual(probes, 0)
        let rollback = HostPostingGrantSnapshot(enabled: false)
        XCTAssertTrue(rollback.allowsPosting(at: 10, legacyProbe: { probes += 1; return true }))
        XCTAssertFalse(rollback.allowsPosting(at: 10, legacyProbe: { probes += 1; return false }))
        XCTAssertEqual(probes, 2)
    }
}
