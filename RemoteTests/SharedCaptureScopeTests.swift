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
            for action in ["release", "heartbeat", "pause", "resume", "viewOnly"] {
                XCTAssertTrue(SharedCaptureScopePolicy.permits(action, kind: kind), action)
            }
            let features = SharedCaptureScopePolicy.features(SessionFeature.host + [SessionFeature.couch, SessionFeature.displayScale], kind: kind)
            XCTAssertEqual(Set(features), [SessionFeature.captureScope, SessionFeature.backgroundPause,
                                          SessionFeature.lowDataPolicy, SessionFeature.ladder, SessionFeature.macVitals, SessionFeature.liveViewOnly, SessionFeature.videoLTR, SessionFeature.videoRefinement, SessionFeature.exactVideoTiming])
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
        let clock = ScopeFixtureClock(9)
        let lease = CaptureScopeLease(validUntil: 10, clock: { clock.now })
        var frames = 0
        XCTAssertTrue(lease.performIfValid { frames += 1 })
        clock.set(11)
        XCTAssertFalse(lease.performIfValid { frames += 1 }, "A fresh native frame cannot bypass stale target evidence")
        XCTAssertFalse(lease.performIfValid { frames += 1 }, "An idle resend cannot bypass stale target evidence")
        lease.invalidate()
        lease.renew(until: 100)
        XCTAssertFalse(lease.performIfValid { frames += 1 }, "Late inventory completion cannot revive a revoked stream")
        XCTAssertEqual(frames, 1)
    }

    func testDeliverySamplesFreshDeadlineAfterWaitingForLeaseLock() {
        let clock = ScopeFixtureClock(9)
        let lease = CaptureScopeLease(validUntil: 10, clock: { clock.now })
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let waiting = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            lease.performIfValid { holding.signal(); _ = release.wait(timeout: .now() + 3) }
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 3), .success)
        let sampledBeforeQueueWait = clock.now
        XCTAssertLessThan(sampledBeforeQueueWait, 10)
        DispatchQueue.global().async {
            waiting.signal()
            XCTAssertFalse(lease.performIfValid { XCTFail("Delayed frame was delivered using stale inventory time") })
            done.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 0.01), .timedOut, "The second delivery waits on the actual lease lock")
        clock.set(11)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
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
            old.performIfValid { delivering.signal(); _ = finishDelivery.wait(timeout: .now() + 3) }
        }
        XCTAssertEqual(delivering.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async { revokeStarted.signal(); old.invalidate(); revoked.signal() }
        XCTAssertEqual(revokeStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.05), .timedOut, "Revoke must wait for in-progress peer delivery")
        captureQueue.async {
            _ = queuedMayRun.wait(timeout: .now() + 3)
            XCTAssertFalse(old.performIfValid { XCTFail("Queued frame escaped its closed stream") })
            queuedOld.signal()
        }
        finishDelivery.signal()
        XCTAssertEqual(revoked.wait(timeout: .now() + 3), .success)
        queuedMayRun.signal()
        XCTAssertEqual(queuedOld.wait(timeout: .now() + 3), .success)
        old.invalidate()
        XCTAssertTrue(replacement.performIfValid {}, "An old stop cannot invalidate a replacement stream")
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

private final class ScopeFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: TimeInterval) { lock.lock(); value = next; lock.unlock() }
}
