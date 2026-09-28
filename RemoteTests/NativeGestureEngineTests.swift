import Foundation
import CoreGraphics
import XCTest

final class NativeGestureEngineTests: XCTestCase {
    func testFollowMotionEndsOnLiftMultitouchPauseAndCancellation() {
        for ending in 0..<4 {
            let log = CommandLog()
            let input = engine(log)
            var stops = 0
            input.onPointerMotionEnded = { stops += 1 }
            input.update([touch(1, 0)], at: 1)
            input.update([touch(1, 20)], at: 1.05)
            switch ending {
            case 0: input.update([], at: 1.06)
            case 1: input.update([touch(1, 20), touch(2, 40)], at: 1.06)
            case 2: input.tick(at: 1.14)
            default: input.cancel()
            }
            XCTAssertEqual(stops, 1)
            input.cancel()
            XCTAssertEqual(stops, 1, "Stopping an ended movement is idempotent")
        }
    }

    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ commands: CommandLog, enabled: Bool = true,
                        panMode: Bool = false, scale: CGFloat = 1) -> NativeGestureEngine {
        NativeGestureEngine(enabled: enabled, panMode: panMode, revision: 1,
                            sensitivity: 1, pointerScale: scale,
                            doubleClickInterval: 0.5,
                            onCommand: { commands.record($0) })
    }

    func testPointerMotionCannotBecomeClickAndHasNoClutchJump() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 20)], at: 1.05)
        input.update([], at: 1.06)
        input.update([touch(2, 100)], at: 2)
        input.update([touch(2, 110)], at: 2.05)
        input.update([], at: 2.06)
        XCTAssertEqual(log.clicks, [])
        XCTAssertEqual(log.moves.count, 2)
        XCTAssertTrue(log.moves.allSatisfy { $0.width > 0 && $0.width < 60 })
    }

    func testImmediateSingleThenSecondTapCountTwo() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 10)], at: 1)
        input.update([], at: 1.04)
        input.update([touch(2, 12)], at: 1.2)
        input.update([], at: 1.25)
        input.update([touch(3, 12)], at: 1.35)
        input.update([], at: 1.4)
        XCTAssertEqual(log.clicks, [1, 2, 1])
    }

    func testStaggeredSecondaryAndNoPrimaryAfterPinchOrScroll() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 0), touch(2, 20)], at: 1.05)
        input.update([touch(2, 20)], at: 1.10)
        input.update([], at: 1.15)
        XCTAssertEqual(log.secondary, 1)
        XCTAssertEqual(log.clicks, [])

        input.update([touch(3, 0), touch(4, 20)], at: 2)
        input.update([touch(3, -8), touch(4, 28)], at: 2.02)
        input.update([touch(4, 28)], at: 2.04)
        input.update([], at: 2.06)
        XCTAssertEqual(log.zooms, 1)
        XCTAssertEqual(log.secondary, 1)
        XCTAssertEqual(log.clicks, [])

        input.update([touch(5, 0), touch(6, 20)], at: 3)
        input.update([touch(5, 0, 10), touch(6, 20, 10)], at: 3.02)
        input.update([touch(6, 20, 10)], at: 3.04)
        input.update([], at: 3.06)
        XCTAssertEqual(log.scrollPhases, ["began", "ended"])
        XCTAssertEqual(log.clicks, [])
    }

    func testRemainingFingerMovementInvalidatesSecondary() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0), touch(2, 20)], at: 1)
        input.update([touch(2, 20)], at: 1.02)
        input.update([touch(2, 40)], at: 1.04)
        input.update([], at: 1.06)
        XCTAssertEqual(log.secondary, 0)
    }

    func testPinchOwnershipSurvivesFingerReplacementUntilAllLift() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0), touch(2, 20)], at: 1)
        input.update([touch(1, -8), touch(2, 28)], at: 1.02)
        input.update([touch(2, 28)], at: 1.04)
        input.update([touch(2, 28), touch(3, 40)], at: 1.06)
        input.update([touch(3, 40)], at: 1.08)
        input.update([], at: 1.1)
        XCTAssertEqual(log.zooms, 1)
        XCTAssertEqual(log.zoomEnds, 1, "A pinch settles exactly once, however its fingers lift")
        XCTAssertEqual(log.secondary, 0)
        XCTAssertEqual(log.clicks, [])
    }

    func testDoubleTapHoldDragsAndReleasesOnceOnEndOrCancellation() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([], at: 1.02)
        input.update([touch(2, 0)], at: 1.12)
        input.tick(at: 1.35)
        input.update([touch(2, 15)], at: 1.38)
        input.update([], at: 1.4)
        XCTAssertEqual(log.clicks, [1])
        XCTAssertEqual(log.dragBegins, 1)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.moves.count, 1)

        input.update([touch(3, 0)], at: 2)
        input.update([], at: 2.02)
        input.update([touch(4, 0)], at: 2.12)
        input.tick(at: 2.35)
        input.cancel()
        input.update([], at: 2.4)
        XCTAssertEqual(log.dragBegins, 2)
        XCTAssertEqual(log.dragEnds, 2)
        XCTAssertEqual(log.clicks, [1, 1])
    }

    func testRejectedDragBeginCannotEmitMoveOrRelease() {
        let log = CommandLog()
        log.acceptDrag = false
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([], at: 1.02)
        input.update([touch(2, 0)], at: 1.1)
        input.tick(at: 1.35)
        input.update([touch(2, 20)], at: 1.4)
        input.update([], at: 1.5)
        XCTAssertEqual(log.dragBegins, 1)
        XCTAssertEqual(log.dragEnds, 0)
        XCTAssertEqual(log.moves.count, 0)
        XCTAssertEqual(log.clicks, [1])
    }

    func testRevisionCancelsDragAndRequiresAllFingersToLift() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([], at: 1.02)
        input.update([touch(2, 0)], at: 1.1)
        input.tick(at: 1.35)
        input.configure(enabled: true, panMode: false, revision: 2,
                        sensitivity: 1, pointerScale: 1, doubleClickInterval: 0.5)
        input.update([touch(2, 20)], at: 1.4)
        input.update([], at: 1.5)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.clicks, [1])
        XCTAssertEqual(log.moves.count, 0)
    }

    func testGainUsesVelocityAndScaleIndependentOfCallbackRate() {
        func travel(steps: Int, scale: CGFloat = 1) -> CGFloat {
            let log = CommandLog()
            let input = engine(log, scale: scale)
            input.update([touch(1, 0)], at: 1)
            for i in 1...steps {
                input.update([touch(1, CGFloat(i) * 80 / CGFloat(steps))],
                             at: 1 + Double(i) * 0.2 / Double(steps))
            }
            input.update([], at: 1.21)
            return log.moves.reduce(0) { $0 + $1.width }
        }
        XCTAssertEqual(travel(steps: 4), travel(steps: 20), accuracy: 0.04)
        XCTAssertEqual(travel(steps: 20, scale: 2) * 2, travel(steps: 20), accuracy: 0.04)
    }

    func testPanModeAndViewOnlySuppressRemoteInput() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 20)], at: 1.1)
        input.update([], at: 1.2)
        XCTAssertEqual(log.pans, 1)
        XCTAssertEqual(log.clicks, [])
        XCTAssertEqual(log.moves.count, 0)
    }
}

private final class CommandLog {
    var clicks: [Int] = []
    var secondary = 0
    var moves: [CGSize] = []
    var scrollPhases: [String] = []
    var zooms = 0
    var zoomEnds = 0
    var pans = 0
    var dragBegins = 0
    var dragEnds = 0
    var acceptDrag = true

    func record(_ command: NativeGestureCommand) -> Bool {
        switch command {
        case .click(let count): clicks.append(count)
        case .secondaryClick: secondary += 1
        case .move(let delta): moves.append(delta)
        case .scroll(_, let phase, _): scrollPhases.append(phase)
        case .zoom: zooms += 1
        case .zoomEnded: zoomEnds += 1
        case .pan: pans += 1
        case .dragBegan: dragBegins += 1; return acceptDrag
        case .dragEnded: dragEnds += 1
        }
        return true
    }
}
