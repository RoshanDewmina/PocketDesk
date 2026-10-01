import XCTest
import AppKit
import ScreenCaptureKit

final class HostLifecycleTests: XCTestCase {
    func testFirstNewResolutionFrameBeforeCompletionCanRefreshAnIdleDesktop() {
        let before = region(width: 2560, height: 1656)
        let after = region(width: 1920, height: 1232)
        // The new .complete output arrives first. Then the configuration completion runs,
        // followed by fresh .idle status: there need not be another changed desktop frame.
        var cached: CapturePixelDimensions? = CapturePixelDimensions(width: 1920, height: 1232)
        if CaptureFrameCachePolicy.shouldDiscard(
            cachedDimensions: cached, frameArrivedDuringUpdate: true,
            cachedDisplayTime: 1100, updateRequestedAt: 1000, previous: before, next: after
        ) { cached = nil }
        var health = CaptureHealthState()
        health.observe(.idle, at: 1)
        let idleRefresh = health.isHealthy(at: 1.4) ? cached : nil
        XCTAssertEqual(idleRefresh, CapturePixelDimensions(width: 1920, height: 1232),
                       "Keep the first new-size frame when completion follows output")
        XCTAssertFalse(health.isHealthy(at: 1.801), "Retaining a frame must not extend source freshness")
    }

    func testNewResolutionMatchingAnOlderCacheIsNotEvidenceOfNewOutput() {
        // An A→B→A size cycle may leave A in the cache when B produced no frame. Matching
        // the requested size alone cannot make that historical A frame current again.
        XCTAssertTrue(CaptureFrameCachePolicy.shouldDiscard(
            cachedDimensions: CapturePixelDimensions(width: 1280, height: 816), frameArrivedDuringUpdate: false,
            cachedDisplayTime: 1100, updateRequestedAt: 1000,
            previous: region(width: 1920, height: 1232), next: region(width: 1280, height: 816)))
    }

    func testDelayedPreRequestFrameCannotResurrectAnOlderCropWithMatchingNewSize() {
        // A prior crop Y produced A. After switching to crop X at size B, an A→B→A
        // resolution update for X receives Y's delayed A callback before completion.
        // Its callback arrival and dimensions match, but its display event predates X's request.
        let before = region(width: 1920, height: 1232), after = region(width: 1280, height: 816)
        let matchingSize = CapturePixelDimensions(width: 1280, height: 816)
        for displayTime: UInt64 in [900, 0] {
            XCTAssertTrue(CaptureFrameCachePolicy.shouldDiscard(
                cachedDimensions: matchingSize, frameArrivedDuringUpdate: true,
                cachedDisplayTime: displayTime, updateRequestedAt: 1000, previous: before, next: after),
                "Delayed or timestamp-unknown output cannot prove current source coverage")
        }
        XCTAssertFalse(CaptureFrameCachePolicy.shouldDiscard(
            cachedDimensions: matchingSize, frameArrivedDuringUpdate: true,
            cachedDisplayTime: 1100, updateRequestedAt: 1000, previous: before, next: after),
            "A post-request display event at the new size can be retained for the unchanged source")
    }

    func testConfigurationCompletionRejectsOldSizedAndMissingFrames() {
        let before = region(width: 1920, height: 1232), after = region(width: 1280, height: 816)
        for cached in [CapturePixelDimensions(width: 1920, height: 1232), nil] {
            XCTAssertTrue(CaptureFrameCachePolicy.shouldDiscard(
                cachedDimensions: cached, frameArrivedDuringUpdate: true,
                cachedDisplayTime: 1100, updateRequestedAt: 1000, previous: before, next: after))
        }
    }

    func testChangedCropCannotReuseAFrameFromDimensionsAlone() {
        let before = CaptureRegion(epoch: 1, x: 10, y: 20, width: 600, height: 400,
                                   outputWidth: 1200, outputHeight: 800)
        for output in [CapturePixelDimensions(width: 1200, height: 800), CapturePixelDimensions(width: 900, height: 600)] {
            let moved = CaptureRegion(epoch: 1, x: 30, y: 20, width: 600, height: 400,
                                      outputWidth: output.width, outputHeight: output.height)
            XCTAssertTrue(CaptureFrameCachePolicy.shouldDiscard(
                cachedDimensions: output, frameArrivedDuringUpdate: true,
                cachedDisplayTime: 1100, updateRequestedAt: 1000, previous: before, next: moved),
                          "Even a new-sized buffer cannot identify a changed source rectangle")
        }
    }

    func testOneDimensionChangeCanIdentifyNewOutputWithoutChangingSourceCoverage() {
        let before = region(width: 1280, height: 816), after = region(width: 1278, height: 816)
        XCTAssertFalse(CaptureFrameCachePolicy.shouldDiscard(
            cachedDimensions: CapturePixelDimensions(width: 1278, height: 816), frameArrivedDuringUpdate: true,
            cachedDisplayTime: 1100, updateRequestedAt: 1000,
            previous: before, next: after))
    }

    private func region(width: Int, height: Int) -> CaptureRegion {
        CaptureRegion(epoch: 0, x: 0, y: 0, width: 1280, height: 832, outputWidth: width, outputHeight: height)
    }

    func testCaptureHealthUsesSourceStatusAndExpires() {
        var health = CaptureHealthState()
        XCTAssertFalse(health.isHealthy(at: 0))

        health.observe(.complete, at: 1)
        XCTAssertTrue(health.isHealthy(at: 1.8))
        XCTAssertFalse(health.isHealthy(at: 1.801))

        health.observe(.idle, at: 2)
        XCTAssertTrue(health.isHealthy(at: 2.4), "An unchanged desktop is a healthy idle source")

        for status: SCFrameStatus in [.blank, .suspended, .started, .stopped] {
            health.observe(status, at: 3)
            XCTAssertFalse(health.isHealthy(at: 3), "\(status) must fail closed")
        }
    }

    /// Device test, 1 Oct 2026: ScreenCaptureKit sent ~36 idle statuses a second for about 9 s of a
    /// still screen, then nothing; the refresh stopped, the phone saw no frame for 2 s and paused
    /// control. Health ticks every 0.4 s as in `RemoteCapture.start()`.
    private func stillScreen(seconds: Double, idleStatusUntil: Double, last: SCFrameStatus = .idle,
                             streamCapturing: Bool?) -> (healthyTicks: [Bool], sends: [Double]) {
        var health = CaptureHealthState()
        var nextStatus = 0.0
        var lastSentAt = 0.0
        var healthyTicks: [Bool] = []
        var sends: [Double] = []
        for tick in 1...Int(seconds / 0.4) {
            let now = Double(tick) * 0.4
            while nextStatus <= min(now, idleStatusUntil) {
                health.observe(nextStatus + 1 / 36 > idleStatusUntil ? last : .idle, at: nextStatus)
                nextStatus += 1 / 36
            }
            let healthy = health.isHealthy(at: now, streamCapturing: streamCapturing)
            healthyTicks.append(healthy)
            if CaptureIdleRefresh.isDue(healthy: healthy, hasFrame: true, now: now, lastSentAt: lastSentAt) {
                lastSentAt = now
                sends.append(now)
            }
        }
        return (healthyTicks, sends)
    }

    func testAStillScreenStaysHealthyAndKeepsRefreshingAfterIdleStatusStops() {
        let still = stillScreen(seconds: 30, idleStatusUntil: 9, streamCapturing: true)
        XCTAssertTrue(still.healthyTicks.allSatisfy { $0 }, "the stream says it is capturing; nothing changed")
        let gaps = zip(still.sends.dropFirst(), still.sends).map { $0 - $1 }
        XCTAssertLessThan(gaps.max() ?? .infinity, 2, "inside the phone's 2 s freshness limit")
        for second in 0..<29 {
            let inSecond = still.sends.filter { $0 > Double(second) && $0 <= Double(second + 1) }.count
            XCTAssertGreaterThanOrEqual(inSecond, 1, "second \(second): at least 1 refresh frame a second")
        }
    }

    func testOnlyAnIdleSourceThatStillCapturesOutlivesItsStatus() {
        let stopped = stillScreen(seconds: 12, idleStatusUntil: 9, streamCapturing: false)
        XCTAssertFalse(stopped.healthyTicks.last ?? true, "a stream that says it stopped fails closed")
        XCTAssertFalse(stopped.sends.contains { $0 > 9.8 }, "and nothing is refreshed")
        let unknown = stillScreen(seconds: 12, idleStatusUntil: 9, streamCapturing: nil)
        XCTAssertFalse(unknown.healthyTicks.last ?? true, "before macOS 27 the status alone decides, as before")
        let changed = stillScreen(seconds: 12, idleStatusUntil: 9, last: .complete, streamCapturing: true)
        XCTAssertFalse(changed.healthyTicks.last ?? true,
                       "silence right after a new frame is not a still screen; only an idle status says nothing changed")

        for status: SCFrameStatus in [.blank, .suspended, .started, .stopped] {
            var health = CaptureHealthState()
            health.observe(.idle, at: 0)
            health.observe(status, at: 1)
            XCTAssertFalse(health.isHealthy(at: 1, streamCapturing: true), "\(status) must fail closed")
            XCTAssertFalse(health.isHealthy(at: 5, streamCapturing: true), "\(status) must stay closed")
        }
        var future = CaptureHealthState()
        future.observe(.idle, at: 5)
        XCTAssertFalse(future.isHealthy(at: 4, streamCapturing: true), "a clock running backwards is not proof")
        XCTAssertFalse(CaptureIdleRefresh.isDue(healthy: true, hasFrame: false, now: 10, lastSentAt: 0),
                       "no frame of the current region, nothing to refresh")
    }

    func testCaptureOwnershipMakesOldCleanupStale() {
        var ownership = ScopedCaptureOwner()
        let first = ownership.begin()
        let second = ownership.begin()
        XCTAssertFalse(ownership.owns(first))
        XCTAssertTrue(ownership.owns(second))

        ownership.invalidate()
        XCTAssertFalse(ownership.owns(second), "Cleanup from an old capture cannot own a newer stream")
    }

    func testCapturePreflightFailureInvalidatesStartBeforeScheduling() {
        let actions = [
            RemoteAction(action: "geometry"),
            RemoteAction(action: "viewing"),
            RemoteAction(action: "capture")
        ]
        var current = true
        var sent: [String] = []
        var scheduledStarts = 0

        let passed = CaptureStartPreflight.send(
            actions,
            whileCurrent: { current },
            using: { action in
                sent.append(action.action)
                if action.action == "viewing" {
                    current = false
                    return false
                }
                return true
            }
        )
        if passed { scheduledStarts += 1 }

        XCTAssertFalse(passed)
        XCTAssertEqual(sent, ["geometry", "viewing"])
        XCTAssertEqual(scheduledStarts, 0, "A synchronous send failure must not leave a stale capture start")
    }

    func testHoldLeaseOnlyUsesAcceptedDragAndMoveActivity() {
        var lease = RemoteInputLease(duration: 2)
        lease.record(action: "heartbeat", accepted: true, at: 0)
        XCTAssertNil(lease.deadline)

        lease.record(action: "dragDown", accepted: true, at: 1)
        XCTAssertEqual(lease.deadline, 3)
        lease.record(action: "heartbeat", accepted: true, at: 2)
        lease.record(action: "move", accepted: false, at: 2.5)
        XCTAssertEqual(lease.deadline, 3)

        lease.record(action: "move", accepted: true, at: 2.75)
        XCTAssertEqual(lease.deadline, 4.75)
        XCTAssertFalse(lease.isExpired(at: 4.749))
        XCTAssertTrue(lease.isExpired(at: 4.75))
        XCTAssertEqual(lease.deadline, 4.75, "Expiry remains pending until mouse-up succeeds")
        lease.cancel()
        XCTAssertNil(lease.deadline)
    }

    func testEpochRejectsStaleInputButAlwaysAcceptsReleaseAndHeartbeat() {
        var epoch = RemoteInputEpoch()
        let first = epoch.beginSession()
        XCTAssertTrue(epoch.accepts(RemoteAction(action: "move", epoch: first)))

        let second = epoch.beginSession()
        XCTAssertFalse(epoch.accepts(RemoteAction(action: "move", epoch: first)))
        XCTAssertTrue(epoch.accepts(RemoteAction(action: "move", epoch: second)))
        XCTAssertTrue(epoch.accepts(RemoteAction(action: "release", epoch: first)))
        XCTAssertTrue(epoch.accepts(RemoteAction(action: "heartbeat", epoch: first)))
    }

    func testEveryPostedMousePositionIsClampedAndDisplayChangeReleasesHold() {
        let recorder = InputRecorder()
        recorder.pointer = CGPoint(x: -10_000, y: 10_000)
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 80)
        driver.configure(bounds: bounds)

        XCTAssertTrue(driver.handle(RemoteAction(action: "click")).accepted)
        XCTAssertTrue(driver.handle(RemoteAction(action: "scroll", x: 20_000, y: -20_000)).accepted)
        XCTAssertEqual(driver.handle(RemoteAction(action: "dragDown")).holdEvent, .began)
        XCTAssertTrue(driver.held)

        recorder.pointer = CGPoint(x: 1_000, y: -1_000)
        XCTAssertEqual(driver.handle(RemoteAction(action: "move", x: 20_000, y: -20_000)).holdEvent, .refreshed)
        driver.configure(bounds: CGRect(x: 200, y: 300, width: 50, height: 50))
        XCTAssertFalse(driver.held)
        XCTAssertEqual(recorder.mouseEvents.last?.type, .leftMouseUp)

        for event in recorder.mouseEvents {
            XCTAssertGreaterThanOrEqual(event.point.x, bounds.minX)
            XCTAssertLessThan(event.point.x, bounds.maxX)
            XCTAssertGreaterThanOrEqual(event.point.y, bounds.minY)
            XCTAssertLessThan(event.point.y, bounds.maxY)
        }
        for point in recorder.scrollPoints {
            XCTAssertGreaterThanOrEqual(point.x, bounds.minX)
            XCTAssertLessThan(point.x, bounds.maxX)
            XCTAssertGreaterThanOrEqual(point.y, bounds.minY)
            XCTAssertLessThan(point.y, bounds.maxY)
        }
    }

    func testTextRequiresRequestIDAndBothSizeLimitsBeforeInjection() {
        let recorder = InputRecorder()
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true

        let accepted = driver.handle(RemoteAction(
            action: "text",
            text: String(repeating: "a", count: 1024),
            key: String(repeating: "r", count: 32)
        ))
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.textRequestID, String(repeating: "r", count: 32))
        XCTAssertEqual(recorder.texts.count, 1)

        let tooManyUTF16 = driver.handle(RemoteAction(
            action: "text",
            text: String(repeating: "a", count: 1025),
            key: "utf16-limit"
        ))
        XCTAssertFalse(tooManyUTF16.accepted)

        let tooLongRequest = driver.handle(RemoteAction(
            action: "text",
            text: "hello",
            key: String(repeating: "q", count: 33)
        ))
        XCTAssertFalse(tooLongRequest.accepted)
        XCTAssertEqual(recorder.texts.count, 1, "Rejected text must never be posted")

        driver.enabled = false
        XCTAssertFalse(driver.handle(RemoteAction(action: "text", text: "hello", key: "denied")).accepted)
        XCTAssertEqual(recorder.texts.count, 1)
    }

    func testFailedMouseUpKeepsHoldOwnershipForRetry() {
        let recorder = InputRecorder()
        recorder.pointer = CGPoint(x: 50, y: 50)
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertTrue(driver.handle(RemoteAction(action: "dragDown")).accepted)
        let holdID = driver.holdID
        recorder.failedMouseSequences = 1
        XCTAssertFalse(driver.release())
        XCTAssertTrue(driver.held)
        XCTAssertEqual(driver.holdID, holdID)

        XCTAssertTrue(driver.release())
        XCTAssertFalse(driver.held)
        XCTAssertNil(driver.holdID)
        XCTAssertEqual(recorder.mouseEvents.map(\.type), [.leftMouseDown, .leftMouseUp])
    }

    func testClickSequenceFailurePostsNoPartialMouseEvents() {
        let recorder = InputRecorder()
        recorder.pointer = CGPoint(x: 50, y: 50)
        recorder.failedMouseSequences = 1
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertFalse(driver.handle(RemoteAction(action: "double")).accepted)
        XCTAssertTrue(recorder.mouseEvents.isEmpty)
        XCTAssertFalse(driver.held)
    }
}

private final class InputRecorder {
    var pointer = CGPoint.zero
    var mouseEvents: [RemoteInputEventSink.MouseEvent] = []
    var scrollPoints: [CGPoint] = []
    var texts: [[UniChar]] = []
    var failedMouseSequences = 0

    var sink: RemoteInputEventSink {
        RemoteInputEventSink(
            pointerLocation: { [weak self] in self?.pointer ?? .zero },
            mouseSequence: { [weak self] events in
                guard let self else { return false }
                if self.failedMouseSequences > 0 {
                    self.failedMouseSequences -= 1
                    return false
                }
                self.mouseEvents.append(contentsOf: events)
                return true
            },
            scroll: { [weak self] point, _, _ in
                self?.scrollPoints.append(point)
                return true
            },
            text: { [weak self] characters in
                self?.texts.append(characters)
                return true
            },
            key: { _, _ in true }
        )
    }
}
