import XCTest
import AppKit
import CoreGraphics

/// `moveTo`, `middle`, triple clicks and hardware modifier flags: the host side of direct touch
/// and hardware pointer passthrough.
final class AbsolutePointerProtocolTests: XCTestCase {
    func testNewPointerActionsValidateOnlyWithSaneFields() throws {
        let move = RemoteAction(action: "moveTo", x: 812.25, y: 40.5, epoch: 3,
                                interaction: NativeInteraction(token: "t"), pointerSync: PointerSync(move: 9))
        XCTAssertNoThrow(try move.validate())
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(move))
        XCTAssertEqual(decoded.x, 812.25)
        XCTAssertEqual(decoded.pointerSync?.move, 9)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNoThrow(try RemoteAction(action: "moveTo", x: 0, y: 0, modifiers: ["shift"]).validate())
        XCTAssertNoThrow(try RemoteAction(action: "middle", interaction: NativeInteraction(token: "t", clickCount: 1)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "click", modifiers: ["command", "shift"],
                                          interaction: NativeInteraction(token: "t", clickCount: 3)).validate())

        let invalid = [
            RemoteAction(action: "moveTo", x: -1, y: 5),
            RemoteAction(action: "moveTo", x: 5, y: -0.5),
            RemoteAction(action: "moveTo", x: 20_001, y: 5),
            RemoteAction(action: "moveTo", x: .infinity, y: 5),
            RemoteAction(action: "moveTo", pointerSync: PointerSync(move: 0)),
            RemoteAction(action: "moveTo", pointerSync: PointerSync(overlay: true)),
            RemoteAction(action: "middle", interaction: NativeInteraction(token: "t", clickCount: 2)),
            RemoteAction(action: "moveTo", modifiers: ["function"])
        ]
        for action in invalid {
            XCTAssertThrowsError(try action.validate(), "\(action.action) \(action.x) \(action.y)")
        }
    }

    func testHostAdvertisesTheNewCapabilities() {
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.absolutePointer))
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.middleButton))
        XCTAssertLessThanOrEqual(SessionFeature.host.count, 32, "The current capture validator allows at most 32 features")
        XCTAssertNoThrow(try RemoteAction(action: "capture", features: SessionFeature.host).validate())
    }
}

final class AbsolutePointerDriverTests: XCTestCase {
    /// A second display left of and above the main one, as macOS arranges global coordinates.
    private let display = CGRect(x: -1920, y: -200, width: 1920, height: 1080)

    func testMoveToPlacesThePointerOnTheCapturedDisplayExactly() {
        let recorder = PointerRecorder(start: CGPoint(x: -100, y: 100))
        let driver = configured(recorder)
        let outcome = driver.handle(action("moveTo", x: 812.25, y: 40.5), upgraded: true)
        XCTAssertTrue(outcome.accepted)
        XCTAssertEqual(recorder.events.last?.type, .mouseMoved)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: -1920 + 812.25, y: -200 + 40.5))
        XCTAssertEqual(driver.lastPoint, CGPoint(x: -1107.75, y: -159.5))
    }

    func testMoveToClampsInsideTheDisplayAndRejectsNegativeInput() {
        let recorder = PointerRecorder(start: CGPoint(x: -100, y: 100))
        let driver = configured(recorder)
        XCTAssertTrue(driver.handle(action("moveTo", x: 5_000, y: 5_000), upgraded: true).accepted)
        let point = recorder.events.last!.point
        XCTAssertLessThan(point.x, display.maxX)
        XCTAssertLessThan(point.y, display.maxY)
        XCTAssertEqual(point.x, display.maxX, accuracy: 0.001)
        let count = recorder.events.count
        XCTAssertFalse(driver.handle(action("moveTo", x: -3, y: 10), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.count, count)
    }

    func testMoveToDuringAHoldDragsOnlyForTheExactHold() {
        let recorder = PointerRecorder(start: CGPoint(x: -1500, y: 0))
        let driver = configured(recorder)
        XCTAssertTrue(driver.handle(action("moveTo", x: 100, y: 100), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("dragDown", count: 1, hold: "h1"), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.type, .leftMouseDown)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: -1820, y: -100), "The press lands where the pointer was placed")
        XCTAssertFalse(driver.handle(action("moveTo", x: 300, y: 300, count: 1, hold: "stale"), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("moveTo", x: 300, y: 320, count: 1, hold: "h1"), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.type, .leftMouseDragged)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: -1620, y: 120))
        var lease = RemoteInputLease(duration: 2)
        lease.begin(at: 0)
        lease.record(action: "moveTo", accepted: true, at: 1.5)
        XCTAssertEqual(lease.deadline, 3.5, "Absolute drag motion renews the hold lease like relative motion")
        XCTAssertTrue(driver.handle(action("dragUp", count: 1, hold: "h1"), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.type, .leftMouseUp)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: -1620, y: 120))
    }

    func testMiddleClickUsesTheCentreButtonAtThePointer() {
        let recorder = PointerRecorder(start: CGPoint(x: -1000, y: 300))
        let driver = configured(recorder)
        let outcome = driver.handle(action("middle", count: 1), upgraded: true)
        XCTAssertTrue(outcome.accepted)
        XCTAssertEqual(outcome.clickPoint, CGPoint(x: -1000, y: 300))
        XCTAssertEqual(recorder.events.map(\.type), [.otherMouseDown, .otherMouseUp])
        XCTAssertEqual(recorder.events.map(\.button), [.center, .center])
        XCTAssertFalse(driver.handle(action("middle", count: 2), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("dragDown", count: 1, hold: "h"), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("middle", count: 1), upgraded: true).accepted,
                       "A held left button is never mixed with another button")
    }

    func testTripleClickContinuesOnlyADoubleAtTheSamePlace() {
        let recorder = PointerRecorder(start: CGPoint(x: -1000, y: 300))
        let driver = configured(recorder)
        XCTAssertFalse(driver.handle(action("click", count: 3), upgraded: true).accepted, "No triple without a double")
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("click", count: 3), upgraded: true).accepted, "No triple straight after a single")
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("click", count: 2), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("click", count: 3), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.suffix(2).map(\.count), [3, 3])

        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("click", count: 2), upgraded: true).accepted)
        XCTAssertTrue(driver.handle(action("moveTo", x: 400, y: 400), upgraded: true).accepted)
        XCTAssertFalse(driver.handle(action("click", count: 3), upgraded: true).accepted,
                       "Moving away starts a new click sequence")
    }

    func testHardwareModifiersReachPointerEventsButNotCleanup() {
        let recorder = PointerRecorder(start: CGPoint(x: -1000, y: 300))
        let driver = configured(recorder)
        XCTAssertTrue(driver.handle(action("click", count: 1, modifiers: ["command", "shift"]), upgraded: true).accepted)
        XCTAssertTrue(recorder.events.suffix(2).allSatisfy { $0.flags == [.maskCommand, .maskShift] })
        XCTAssertTrue(driver.handle(action("moveTo", x: 10, y: 10, modifiers: ["option"]), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.flags, .maskAlternate)
        XCTAssertTrue(driver.handle(action("dragDown", count: 1, hold: "h", modifiers: ["option"]), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.flags, .maskAlternate)
        XCTAssertTrue(driver.release())
        XCTAssertEqual(recorder.events.last?.flags, [], "Cleanup never invents modifier state")
        XCTAssertTrue(driver.handle(action("click", count: 1), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.flags, [])
    }

    func testRelativeMoveIsUnchanged() {
        let recorder = PointerRecorder(start: CGPoint(x: -1000, y: 300))
        let driver = configured(recorder)
        XCTAssertTrue(driver.handle(action("move", x: 12.5, y: -4), upgraded: true).accepted)
        XCTAssertEqual(recorder.events.last?.point, CGPoint(x: -987.5, y: 296))
    }

    private func configured(_ recorder: PointerRecorder) -> RemoteInputDriver {
        let driver = RemoteInputDriver(eventSink: recorder.sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: display)
        return driver
    }

    private func action(_ name: String, x: Double = 0, y: Double = 0, count: Int? = nil,
                        hold: String? = nil, modifiers: [String] = []) -> RemoteAction {
        RemoteAction(action: name, x: x, y: y, modifiers: modifiers,
                     interaction: NativeInteraction(hold: hold, clickCount: count))
    }
}

final class AbsolutePointerPredictionTests: XCTestCase {
    func testWarpJumpsAtOnceAndReplaysAheadOfOlderSamples() {
        var predictor = PointerPredictor(bounds: CGSize(width: 1440, height: 900))
        predictor.receive(point: CGPoint(x: 100, y: 100), applied: 0, at: 0)
        let warp = predictor.reserveOrdinal()
        predictor.applyLocalWarp(ordinal: warp, to: CGPoint(x: 900, y: 600))
        XCTAssertEqual(predictor.displayed(at: 0), CGPoint(x: 900, y: 600))
        XCTAssertFalse(predictor.correcting(at: 0), "A warp is exact: no blended correction")
        predictor.applyLocalMove(ordinal: predictor.reserveOrdinal(), delta: CGSize(width: 5, height: 0))
        XCTAssertEqual(predictor.displayed(at: 0), CGPoint(x: 905, y: 600))
        // A sample from before the warp arrives late: the pending warp still wins.
        predictor.receive(point: CGPoint(x: 102, y: 100), applied: 0, at: 0.02)
        XCTAssertEqual(predictor.displayed(at: 0.02), CGPoint(x: 905, y: 600))
        predictor.receive(point: CGPoint(x: 905, y: 600), applied: 2, at: 0.05)
        XCTAssertEqual(predictor.pendingCount, 0)
        XCTAssertEqual(predictor.displayed(at: 0.05), CGPoint(x: 905, y: 600))
    }

    func testWarpClampsToTheDisplayAndDrawsWithoutAPriorSample() {
        var predictor = PointerPredictor(bounds: CGSize(width: 100, height: 50))
        predictor.applyLocalWarp(ordinal: predictor.reserveOrdinal(), to: CGPoint(x: 400, y: -5))
        let shown = predictor.displayed(at: 0)!
        XCTAssertEqual(shown.y, 0)
        XCTAssertLessThan(shown.x, 100)
        XCTAssertGreaterThan(shown.x, 99.99)
    }
}

private final class PointerRecorder {
    var pointer: CGPoint
    var events: [RemoteInputEventSink.MouseEvent] = []

    init(start: CGPoint) { pointer = start }

    var sink: RemoteInputEventSink {
        RemoteInputEventSink(
            pointerLocation: { [weak self] in self?.pointer ?? .zero },
            mouseSequence: { [weak self] events in
                self?.events.append(contentsOf: events)
                if let last = events.last { self?.pointer = last.point }
                return true
            },
            scroll: { _, _, _ in true },
            scrollDetailed: { _, _, _, _ in true },
            text: { _ in true },
            key: { _, _ in true }
        )
    }
}
