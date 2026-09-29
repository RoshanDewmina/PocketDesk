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

    func testRestingScrollKeepAliveHoldsTheStreamWithoutPostingAndSilenceStillExpires() {
        let recorder = NativeInputRecorder()
        let driver = configuredDriver(recorder)
        XCTAssertTrue(driver.handle(scroll("a", "began", y: 4), upgraded: true, now: 0).accepted)
        XCTAssertTrue(driver.handle(scroll("a", "changed"), upgraded: true, now: 0.4).accepted)
        XCTAssertTrue(driver.handle(scroll("a", "changed"), upgraded: true, now: 0.8).accepted)
        XCTAssertTrue(driver.handle(scroll("a", "changed", y: 6), upgraded: true, now: 1.2).accepted,
                      "A scroll resumed after a pause continues its stream")
        XCTAssertEqual(recorder.scrolls.map { $0.1 }, [4, 6], "Keep-alives post nothing to the Mac")
        XCTAssertTrue(driver.handle(scroll("a", "ended"), upgraded: true, now: 1.3).accepted)

        XCTAssertTrue(driver.handle(scroll("b", "began", y: 2), upgraded: true, now: 5).accepted)
        XCTAssertFalse(driver.handle(scroll("b", "changed"), upgraded: true, now: 5.6).accepted,
                       "A phone that goes silent still loses its stream after 0.5 s")
        XCTAssertFalse(driver.handle(scroll("b", "changed", y: 3), upgraded: true, now: 5.7).accepted)
    }

    func testLaggingCursorDoesNotLoseMotionOrPullClicksBack() {
        // WindowServer applies each posted event only when the next one arrives (one event late).
        let recorder = NativeInputRecorder()
        recorder.lagsByOneEvent = true
        let driver = configuredDriver(recorder)
        var now = 10.0
        for _ in 1...10 {
            now += 1.0 / 120.0
            XCTAssertTrue(driver.handle(action("move", count: 1, x: 5), upgraded: true, now: now).accepted)
        }
        XCTAssertEqual(driver.lastPoint, CGPoint(x: 150, y: 100), "Ten moves of five land fifty away, not on a stale base")
        XCTAssertEqual(recorder.mouseEvents.last?.point, CGPoint(x: 150, y: 100))
        now += 0.05
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true, now: now).accepted)
        XCTAssertEqual(recorder.mouseEvents.suffix(2).map(\.point), [CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 100)],
                       "A tap right after a move clicks where the move went, not where the cursor still reads")

        // A physical mouse moved the cursor somewhere the driver never posted: trust it.
        recorder.pointer = CGPoint(x: 20, y: 30)
        now += 0.01
        XCTAssertTrue(driver.handle(action("move", count: 1, x: 5), upgraded: true, now: now).accepted)
        XCTAssertEqual(driver.lastPoint, CGPoint(x: 25, y: 30))

        // After a pause the cursor is read again even if it sits on an old post.
        recorder.lagsByOneEvent = false
        recorder.pointer = CGPoint(x: 150, y: 100)
        now += RemoteInputDriver.pointerChainWindow + 0.01
        XCTAssertTrue(driver.handle(action("move", count: 1, x: 5), upgraded: true, now: now).accepted)
        XCTAssertEqual(driver.lastPoint, CGPoint(x: 155, y: 100))
    }

    func testNewGeometryOrSessionDiscardsThePreviousPointerChain() {
        for geometryChange in [false, true] {
            let recorder = NativeInputRecorder()
            let driver = configuredDriver(recorder)
            XCTAssertTrue(driver.handle(action("move", count: 1, x: 10), upgraded: true, now: 10).accepted)
            XCTAssertEqual(driver.lastPoint.x, 110)
            // WindowServer still reports the old position while the session or geometry changes.
            if geometryChange {
                driver.configure(bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
            } else {
                driver.resetNativeSequence()
            }
            XCTAssertEqual(driver.nextPointerBase(now: 10.01), recorder.pointer)
            XCTAssertTrue(driver.handle(action("move", count: 1, x: 5), upgraded: true, now: 10.01).accepted)
            XCTAssertEqual(driver.lastPoint.x, 105, "A previous stream cannot supply the new stream's base")
        }
    }

    func testTheNextPointerBaseIsWhatTheDriverWillUseAndRecordsNothing() {
        let recorder = NativeInputRecorder()
        recorder.lagsByOneEvent = true
        let driver = configuredDriver(recorder)
        var now = 10.0
        for _ in 1...4 {
            now += 1.0 / 120.0
            XCTAssertTrue(driver.handle(action("move", count: 1, x: 5), upgraded: true, now: now).accepted)
        }
        now += 0.01
        XCTAssertNotEqual(recorder.pointer, driver.lastPoint, "The cursor still lags the posted point")
        XCTAssertEqual(driver.nextPointerBase(now: now), driver.lastPoint, "While chaining, the base is the last post")
        XCTAssertEqual(driver.nextPointerBase(now: now), driver.lastPoint, "Asking twice changes nothing")
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true, now: now).accepted)
        XCTAssertEqual(recorder.mouseEvents.last?.point, CGPoint(x: 120, y: 100))

        now += RemoteInputDriver.pointerChainWindow + 0.01
        recorder.lagsByOneEvent = false
        recorder.pointer = CGPoint(x: 40, y: 50)
        XCTAssertEqual(driver.nextPointerBase(now: now), CGPoint(x: 40, y: 50), "A moved cursor is read again")
    }

    /// The E2E fence clamps moves into the Test Pad and checks clicks against the base the driver
    /// will post from, so a lagging cursor can never walk a fenced click out of the pad.
    func testTheE2EFenceJudgesTheDriversOwnBaseUnderLag() throws {
        let recorder = NativeInputRecorder()
        recorder.lagsByOneEvent = true
        let driver = configuredDriver(recorder)
        let pad = CGRect(x: 60, y: 60, width: 70, height: 80)
        var now = 10.0
        for _ in 1...20 {
            now += 1.0 / 120.0
            let base = try XCTUnwrap(driver.nextPointerBase(now: now))
            let environment = HostE2EFenceEnvironment(testPadRunning: true, testPadFrontmost: true, testPadContent: pad,
                                                      pointer: base, coveringOwner: nil)
            var move = action("move", count: 1, x: 5)
            switch HostE2EInputFence.decide(move, held: false, allowSpaceKeys: false, environment: environment) {
            case .allow: break
            case .adjust(let dx, let dy): move.x = dx; move.y = dy
            case .reject(let reason): XCTFail(reason); return
            }
            XCTAssertTrue(driver.handle(move, upgraded: true, now: now, pointerSnapshot: base).accepted)
            XCTAssertTrue(pad.insetBy(dx: HostE2EInputFence.edgeInset, dy: HostE2EInputFence.edgeInset)
                .contains(driver.lastPoint), "Posted \(driver.lastPoint) stays in the pad")
        }
        now += 0.01
        let base = try XCTUnwrap(driver.nextPointerBase(now: now))
        let environment = HostE2EFenceEnvironment(testPadRunning: true, testPadFrontmost: true, testPadContent: pad,
                                                  pointer: base, coveringOwner: nil)
        XCTAssertEqual(HostE2EInputFence.decide(action("click", count: 1), held: false, allowSpaceKeys: false,
                                                environment: environment), .allow)
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true, now: now, pointerSnapshot: base).accepted)
        XCTAssertTrue(pad.contains(recorder.mouseEvents.last!.point), "The click lands where the fence judged it")
    }

    func testFencedPointerSnapshotSurvivesWindowServerMovementBeforeInjection() throws {
        for name in ["move", "click", "dragDown"] {
            let recorder = NativeInputRecorder()
            let driver = configuredDriver(recorder)
            let pad = CGRect(x: 60, y: 60, width: 70, height: 80)
            let base = try XCTUnwrap(driver.nextPointerBase(now: 10))
            let environment = HostE2EFenceEnvironment(testPadRunning: true, testPadFrontmost: true,
                testPadContent: pad, pointer: base, coveringOwner: nil)
            let input = action(name, count: 1, hold: name == "dragDown" ? "snapshot-hold" : nil,
                               x: name == "move" ? 5 : 0)
            XCTAssertEqual(HostE2EInputFence.decide(input, held: false, allowSpaceKeys: false,
                                                   environment: environment), .allow)
            // A physical move or delayed WindowServer event lands outside the pad after admission.
            recorder.pointer = CGPoint(x: 190, y: 190)
            XCTAssertTrue(driver.handle(input, upgraded: true, now: 10, pointerSnapshot: base).accepted)
            let expected = CGPoint(x: name == "move" ? 105 : 100, y: 100)
            XCTAssertEqual(recorder.mouseEvents.last?.point, expected)
            XCTAssertTrue(pad.contains(try XCTUnwrap(recorder.mouseEvents.last?.point)))
        }
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
    /// Simulates WindowServer applying a posted pointer event only when the next one is posted.
    var lagsByOneEvent = false
    private var pendingPointer: CGPoint?

    var sink: RemoteInputEventSink {
        RemoteInputEventSink(
            pointerLocation: { [weak self] in self?.pointer ?? .zero },
            mouseSequence: { [weak self] events in
                guard let self else { return true }
                self.mouseEvents.append(contentsOf: events)
                if self.lagsByOneEvent, let last = events.last {
                    if let pending = self.pendingPointer { self.pointer = pending }
                    self.pendingPointer = last.point
                }
                return true
            },
            scroll: { [weak self] _, x, y in self?.scrolls.append((x, y)); return true },
            scrollDetailed: { [weak self] _, x, y, _ in self?.scrolls.append((x, y)); return true },
            text: { _ in true },
            key: { _, _ in true }
        )
    }
}
