import XCTest
import AppKit

final class NativeInputSafetyTests: XCTestCase {
    func testFreshnessIsHostClockBoundAndCannotDowngradeAfterUpgrade() {
        var gate = NativeInputFreshness()
        let legacy = RemoteAction(action: "click", epoch: 7)
        XCTAssertEqual(gate.admit(legacy, epoch: 7, now: 10), .legacy)

        let capability = gate.capability(epoch: 7, now: 10, doubleClickInterval: 0.5)
        var upgraded = legacy
        upgraded.interaction = NativeInteraction(token: capability.token, clickCount: 1)
        XCTAssertEqual(gate.admit(upgraded, epoch: 7, now: 10.99), .upgraded)
        XCTAssertEqual(gate.admit(legacy, epoch: 7, now: 10.99), .terminate)
        XCTAssertEqual(gate.admit(upgraded, epoch: 7, now: 11), .terminate)
        XCTAssertEqual(gate.admit(upgraded, epoch: 8, now: 10.2), .terminate)
        gate.expireTokens()
        XCTAssertEqual(gate.admit(RemoteAction(action: "click", epoch: 8), epoch: 8, now: 12), .terminate,
                       "A geometry epoch change must preserve the upgraded-peer requirement")
        let nextCapability = gate.capability(epoch: 8, now: 12, doubleClickInterval: 0.5)
        let next = RemoteAction(action: "click", epoch: 8,
                                interaction: NativeInteraction(token: nextCapability.token, clickCount: 1))
        XCTAssertEqual(gate.admit(next, epoch: 8, now: 12.1), .upgraded)
        gate.invalidate()
        XCTAssertEqual(gate.admit(upgraded, epoch: 7, now: 10.2), .terminate)
    }

    func testReleaseBoundaryCannotDropNewerHoldOrEpochAndAcceptsExpiredTokenForExactHold() {
        var gate = NativeInputFreshness()
        let legacyRelease = RemoteAction(action: "release", epoch: 1)
        XCTAssertTrue(gate.acceptsRelease(legacyRelease, epoch: 2, activeHold: nil),
                      "Legacy cleanup keeps its original behavior before upgrade")
        let capability = gate.capability(epoch: 2, now: 0, doubleClickInterval: 0.5)
        let firstAction = RemoteAction(
            action: "dragDown", epoch: 2,
            interaction: NativeInteraction(token: capability.token, hold: "new-hold", clickCount: 1)
        )
        XCTAssertEqual(gate.admit(firstAction, epoch: 2, now: 0.1), .upgraded)
        XCTAssertFalse(gate.acceptsRelease(legacyRelease, epoch: 2, activeHold: "new-hold"))

        let oldHold = RemoteAction(
            action: "release", epoch: 2,
            interaction: NativeInteraction(token: capability.token, hold: "old-hold")
        )
        XCTAssertFalse(gate.acceptsRelease(oldHold, epoch: 2, activeHold: "new-hold"))
        let oldEpoch = RemoteAction(
            action: "release", epoch: 1,
            interaction: NativeInteraction(token: capability.token, hold: "new-hold")
        )
        XCTAssertFalse(gate.acceptsRelease(oldEpoch, epoch: 2, activeHold: "new-hold"))

        let exactRelease = RemoteAction(
            action: "release", epoch: 2,
            interaction: NativeInteraction(token: "expired", hold: "new-hold")
        )
        XCTAssertTrue(gate.acceptsRelease(exactRelease, epoch: 2, activeHold: "new-hold"),
                      "Exact scoped cleanup still works after token expiry")
        XCTAssertFalse(gate.acceptsRelease(exactRelease, epoch: 2, activeHold: nil))

        let notice = gate.releaseNotice(epoch: 2, releasedHold: "old-hold")
        XCTAssertEqual(notice?.epoch, 2)
        XCTAssertEqual(notice?.interaction?.hold, "old-hold")
        XCTAssertNil(gate.releaseNotice(epoch: 2, releasedHold: nil))
        XCTAssertNotEqual(notice?.interaction?.hold, "new-hold",
                          "A late host notice must carry the released identity, not current state")
        let rejected = RemoteAction(
            action: "dragDown", epoch: 2,
            interaction: NativeInteraction(token: capability.token, hold: "attempted", clickCount: 1)
        )
        XCTAssertEqual(gate.rejectedDragDownNotice(rejected, activeHold: "existing")?.interaction?.hold,
                       "attempted")
        XCTAssertNil(gate.rejectedDragDownNotice(rejected, activeHold: "attempted"),
                     "A duplicate down must not clear the actual active hold")
    }

    func testDelayedIndependentSinglesDoNotBecomeDoubleClick() {
        let recorder = NativeInputRecorder()
        let driver = configuredDriver(recorder)
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertEqual(recorder.mouseEvents.map(\.count), [1, 1, 1, 1])
        XCTAssertTrue(driver.handle(action("click", count: 2), upgraded: true).accepted)
        XCTAssertEqual(recorder.mouseEvents.suffix(2).map(\.count), [2, 2])
        XCTAssertFalse(driver.handle(action("right", count: 2), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("click", count: 3), upgraded: true).accepted,
                      "A hardware triple click continues the double at the same place")
        XCTAssertFalse(driver.handle(action("click", count: 3), upgraded: true).accepted,
                       "A triple cannot repeat without a new double")
    }

    func testSecondTouchDragKeepsCountAndExactHoldIdentity() {
        let recorder = NativeInputRecorder()
        let driver = configuredDriver(recorder)
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("dragDown", count: 2, hold: "hold-a"), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("move", count: 2, hold: "old", x: 5), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("move", count: 2, hold: "hold-a", x: 5), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("dragUp", count: 2, hold: "old"), upgraded: true).accepted)
        XCTAssertTrue(driver.held)
        XCTAssertTrue(driver.handle(action("dragUp", count: 2, hold: "hold-a"), upgraded: true).accepted)
        XCTAssertEqual(recorder.mouseEvents.map(\.count), [1, 1, 2, 2, 2])
        XCTAssertFalse(driver.release(), "A completed drag must not emit another mouse-up")
        XCTAssertEqual(recorder.mouseEvents.filter { $0.type == .leftMouseUp }.count, 2)
        XCTAssertFalse(driver.handle(action("dragDown", count: 1, hold: "hold-a"), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("holdRenew", count: 2, hold: "hold-a"), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("dragDown", count: 1, hold: "hold-b"), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("dragUp", count: 2, hold: "hold-a"), upgraded: true).accepted)
        XCTAssertTrue(driver.held, "A late old hold must not release the new hold")
        XCTAssertTrue(driver.handle(action("dragUp", count: 1, hold: "hold-b"), upgraded: true).accepted)
    }

    func testStationaryRenewalExtendsOnlyActiveLease() {
        let recorder = NativeInputRecorder()
        let driver = configuredDriver(recorder)
        var lease = RemoteInputLease(duration: 2)
        let down = driver.handle(action("dragDown", count: 1, hold: "active"), upgraded: true, now: 0)
        lease.record(action: "dragDown", accepted: down.accepted, at: 0)
        let wrong = driver.handle(action("holdRenew", count: 1, hold: "old"), upgraded: true, now: 1.75)
        lease.record(action: "holdRenew", accepted: wrong.accepted, at: 1.75)
        XCTAssertEqual(lease.deadline, 2)
        let renewal = driver.handle(action("holdRenew", count: 1, hold: "active"), upgraded: true, now: 1.75)
        lease.record(action: "holdRenew", accepted: renewal.accepted, at: 1.75)
        XCTAssertEqual(lease.deadline, 3.75)
        XCTAssertFalse(lease.isExpired(at: 3.74))
        XCTAssertTrue(lease.isExpired(at: 3.75))
        XCTAssertTrue(driver.release())
        lease.cancel()
        XCTAssertFalse(driver.handle(action("holdRenew", count: 1, hold: "active"), upgraded: true, now: 4).accepted)
        XCTAssertNil(lease.deadline)
    }

    func testFractionalScrollAndLateOldStreamAreRejected() {
        let recorder = NativeInputRecorder()
        let driver = configuredDriver(recorder)
        XCTAssertTrue(driver.handle(scroll("a", "began", x: 0.25, y: -0.125), upgraded: true, now: 0).accepted)
        XCTAssertTrue(driver.handle(scroll("a", "changed", x: 0.125, y: -0.25), upgraded: true, now: 0.1).accepted)
        XCTAssertTrue(driver.handle(scroll("b", "began", x: 0.5, y: 0.375), upgraded: true, now: 0.2).accepted)
        XCTAssertFalse(driver.handle(scroll("a", "ended"), upgraded: true, now: 0.3).accepted)
        XCTAssertTrue(driver.handle(scroll("b", "ended"), upgraded: true, now: 0.3).accepted)
        XCTAssertFalse(driver.handle(scroll("b", "changed", y: 5), upgraded: true, now: 0.4).accepted)
        XCTAssertEqual(recorder.scrolls.map { $0.0 }, [0.25, 0.125, 0.5, 0])
        XCTAssertEqual(recorder.scrolls.map { $0.1 }, [-0.125, -0.25, 0.375, 0])
        XCTAssertTrue(driver.handle(scroll("c", "began"), upgraded: true, now: 1).accepted)
        XCTAssertFalse(driver.handle(scroll("c", "changed", y: 5), upgraded: true, now: 1.51).accepted)
    }

    func testRetiredIdentityWindowDoesNotExhaustLongSession() {
        let recorder = NativeInputRecorder()
        let driver = configuredDriver(recorder)
        for index in 0...1025 {
            let hold = "hold-\(index)"
            XCTAssertTrue(driver.handle(action("dragDown", count: 1, hold: hold), upgraded: true).accepted)
            XCTAssertTrue(driver.handle(action("dragUp", count: 1, hold: hold), upgraded: true).accepted)
            let stream = "scroll-\(index)"
            XCTAssertTrue(driver.handle(scroll(stream, "began", y: 0.25), upgraded: true,
                                        now: Double(index)).accepted)
            XCTAssertTrue(driver.handle(scroll(stream, "ended"), upgraded: true,
                                        now: Double(index) + 0.1).accepted)
        }
        XCTAssertFalse(driver.handle(action("dragDown", count: 1, hold: "hold-1025"), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(scroll("scroll-1025", "began"), upgraded: true, now: 1026).accepted)
        XCTAssertTrue(driver.handle(action("dragDown", count: 1, hold: "hold-1026"), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("dragUp", count: 1, hold: "hold-1026"), upgraded: true).accepted)
    }

    private func configuredDriver(_ recorder: NativeInputRecorder) -> RemoteInputDriver {
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        return driver
    }

    private func action(_ name: String, count: Int, hold: String? = nil, x: Double = 0) -> RemoteAction {
        RemoteAction(action: name, x: x, interaction: NativeInteraction(hold: hold, clickCount: count))
    }

    private func scroll(_ stream: String, _ phase: String, x: Double = 0, y: Double = 0) -> RemoteAction {
        RemoteAction(action: "scroll", x: x, y: y, interaction: NativeInteraction(phase: phase, stream: stream))
    }
}

private final class NativeInputRecorder {
    var pointer = CGPoint(x: 100, y: 100)
    var mouseEvents: [RemoteInputEventSink.MouseEvent] = []
    var scrolls: [(Double, Double)] = []

    var sink: RemoteInputEventSink {
        RemoteInputEventSink(
            pointerLocation: { [weak self] in self?.pointer ?? .zero },
            mouseSequence: { [weak self] events in self?.mouseEvents.append(contentsOf: events); return true },
            scroll: { [weak self] _, x, y in self?.scrolls.append((x, y)); return true },
            scrollDetailed: { [weak self] _, x, y, _ in self?.scrolls.append((x, y)); return true },
            text: { _ in true },
            key: { _, _ in true }
        )
    }
}
