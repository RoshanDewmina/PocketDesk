import XCTest

final class SharedCaptureScopeTests: XCTestCase {
    func testMissingNarrowTargetNeverUsesAvailableDisplay() {
        for kind: CaptureScopeFrame.Kind in [.application, .window] {
            XCTAssertFalse(SharedCaptureScopePolicy.targetIsAvailable(kind: kind,
                displayPresent: true, exactProcessInstance: true, selectedWindowPresent: false))
            XCTAssertFalse(SharedCaptureScopePolicy.targetIsAvailable(kind: kind,
                displayPresent: true, exactProcessInstance: false, selectedWindowPresent: true),
                "A replacement process with a recycled PID is not the selected application instance")
            XCTAssertFalse(SharedCaptureScopePolicy.targetIsAvailable(kind: kind,
                displayPresent: false, exactProcessInstance: true, selectedWindowPresent: true))
            XCTAssertTrue(SharedCaptureScopePolicy.targetIsAvailable(kind: kind,
                displayPresent: true, exactProcessInstance: true, selectedWindowPresent: true))
        }
    }

    func testNarrowScopeRejectsLegacyAndUpgradedAuthority() {
        let forbidden = ["viewing", "move", "moveTo", "click", "dragDown", "holdRenew", "text", "key",
                         "clipboard", "file", "curtain", "wake", "display", "displays", "displayScale", "mode"]
        for kind: CaptureScopeFrame.Kind in [.application, .window] {
            for action in forbidden { XCTAssertFalse(SharedCaptureScopePolicy.permits(action, kind: kind), action) }
            for action in ["release", "heartbeat", "pause", "resume"] {
                XCTAssertTrue(SharedCaptureScopePolicy.permits(action, kind: kind), action)
            }
            let features = SharedCaptureScopePolicy.features(SessionFeature.host + [SessionFeature.couch, SessionFeature.displayScale], kind: kind)
            XCTAssertEqual(Set(features), [SessionFeature.captureScope, SessionFeature.backgroundPause,
                                          SessionFeature.ladder, SessionFeature.macVitals])
        }
    }

    func testAnnotationValidatesBeforeExtensionEarlyReturnsAndOldPeersStayCompatible() throws {
        let frame = CaptureScopeFrame(epoch: 7, kind: .window, label: "Shared window", viewOnly: true)
        let action = RemoteAction(action: "capture", captureScope: frame)
        try action.validate()
        XCTAssertEqual(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action)).captureScope, frame)
        XCTAssertNil(try JSONDecoder().decode(RemoteAction.self, from: Data(#"{"action":"capture","x":0,"y":0,"text":"","key":"","modifiers":[],"epoch":1}"#.utf8)).captureScope)
        for name in ["file", "pause", "mode", "displays", "heartbeat"] {
            XCTAssertThrowsError(try RemoteAction(action: name, captureScope: frame).validate(), name)
        }
        for invalid in [CaptureScopeFrame(epoch: 0, kind: .window, label: "Shared window", viewOnly: true),
                        CaptureScopeFrame(epoch: 1, kind: .application, label: "App", viewOnly: false),
                        CaptureScopeFrame(epoch: 1, kind: .display, label: "Display", viewOnly: true),
                        CaptureScopeFrame(epoch: 1, kind: .window, label: String(repeating: "x", count: 129), viewOnly: true),
                        CaptureScopeFrame(epoch: 1, kind: .window, label: "Window\n", viewOnly: true)] {
            XCTAssertThrowsError(try RemoteAction(action: "capture", captureScope: invalid).validate())
        }
    }

    func testLostInventoryStopsFreshAndCachedFramesAndCannotReviveAfterRevoke() {
        let lease = CaptureScopeLease(validUntil: 10)
        var frames = 0
        XCTAssertTrue(lease.performIfValid(at: 9) { frames += 1 })
        XCTAssertFalse(lease.performIfValid(at: 11) { frames += 1 }, "A fresh native frame cannot bypass stale target evidence")
        XCTAssertFalse(lease.performIfValid(at: 11) { frames += 1 }, "An idle resend cannot bypass stale target evidence")
        lease.invalidate()
        lease.renew(until: 100)
        XCTAssertFalse(lease.performIfValid(at: 12) { frames += 1 }, "Late inventory completion cannot revive a revoked stream")
        XCTAssertEqual(frames, 1)
    }

    func testScopeTransitionWaitsForDeliveryAndDropsAlreadyQueuedOldFrame() {
        let old = CaptureScopeLease()
        let replacement = CaptureScopeLease()
        let delivering = DispatchSemaphore(value: 0)
        let finishDelivery = DispatchSemaphore(value: 0)
        let revoked = DispatchSemaphore(value: 0)
        let revokeStarted = DispatchSemaphore(value: 0)
        let queuedOld = DispatchSemaphore(value: 0)
        let queuedMayRun = DispatchSemaphore(value: 0)
        let captureQueue = DispatchQueue(label: "test.scope.capture")
        captureQueue.async {
            old.performIfValid(at: 1) { delivering.signal(); _ = finishDelivery.wait(timeout: .now() + 3) }
        }
        XCTAssertEqual(delivering.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async { revokeStarted.signal(); old.invalidate(); revoked.signal() }
        XCTAssertEqual(revokeStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.05), .timedOut, "Revoke must wait for in-progress peer delivery")
        captureQueue.async {
            _ = queuedMayRun.wait(timeout: .now() + 3)
            XCTAssertFalse(old.performIfValid(at: 2) { XCTFail("Queued frame escaped its closed stream") })
            queuedOld.signal()
        }
        finishDelivery.signal()
        XCTAssertEqual(revoked.wait(timeout: .now() + 3), .success)
        queuedMayRun.signal()
        XCTAssertEqual(queuedOld.wait(timeout: .now() + 3), .success)
        old.invalidate()
        XCTAssertTrue(replacement.performIfValid(at: 2) {}, "An old stop cannot invalidate a replacement stream")
    }

    func testRelaunchRequiresFreshOwnerSelectionEvenWithSavedSharingConsent() throws {
        let suite = "farside.scope.fixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertTrue(preferences.sharingMayResumeWithoutScopeSelection)
        preferences.sharingEnabled = true
        preferences.captureScopeRequiresSelection = true
        let relaunched = HostPreferences(defaults: defaults)
        XCTAssertFalse(relaunched.sharingMayResumeWithoutScopeSelection)
        relaunched.captureScopeRequiresSelection = false // explicit owner Entire display selection
        XCTAssertTrue(relaunched.sharingMayResumeWithoutScopeSelection)
    }
}
