import XCTest
import AppKit
import ScreenCaptureKit

final class HostLifecycleTests: XCTestCase {
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
