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
            case 2:
                input.tick(at: 1.35)
                XCTAssertEqual(stops, 0, "A held finger keeps camera follow alive for a valid probe reply")
                input.update([], at: 1.36)
            default: input.cancel()
            }
            XCTAssertEqual(stops, 1)
            input.cancel()
            XCTAssertEqual(stops, 1, "Stopping an ended movement is idempotent")
        }
    }

    func testViewDoubleTapZoomsWithoutAnyMacClick() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 100, 100)], at: 1)
        input.update([], at: 1.05)
        input.update([touch(2, 102, 101)], at: 1.2)
        input.update([], at: 1.25)
        XCTAssertEqual(log.zoomToggles, [CGPoint(x: 102, y: 101)])
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertEqual(log.dragBegins, 0)
    }

    func testViewTwoFingerPanCanBecomePinchWithoutLifting() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 0), touch(2, 100)], at: 1)
        input.update([touch(1, 10), touch(2, 110)], at: 1.1)
        input.update([touch(1, 0), touch(2, 140)], at: 1.2)
        input.update([touch(2, 140)], at: 1.3)
        input.update([touch(2, 180)], at: 1.4)
        input.update([], at: 1.5)
        XCTAssertEqual(log.navigation.count, 2)
        XCTAssertEqual(log.navigation[0].factor, 1, accuracy: 0.001)
        XCTAssertEqual(log.navigation[0].translation.width, 10, accuracy: 0.001)
        XCTAssertEqual(log.navigation[1].factor, 1.4, accuracy: 0.001)
        XCTAssertEqual(log.navigation[1].anchor.x, 60, accuracy: 0.001)
        XCTAssertEqual(log.navigation[1].translation.width, 10, accuracy: 0.001)
        XCTAssertEqual(log.zoomEnds, 1)
        XCTAssertTrue(log.scrollPhases.isEmpty)
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testThreeFingerDirectionsFireOnceAndDoNotLeakAfterUnevenLift() {
        let paths: [(CGFloat, CGFloat, NativeSwipeDirection)] = [(-80,0,.left),(80,0,.right),(0,-80,.up),(0,80,.down)]
        for (dx,dy,direction) in paths {
            let log = CommandLog(); let input = engine(log)
            input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
            input.update([touch(1, 100+dx, 100+dy), touch(2, 130+dx, 100+dy), touch(3, 160+dx, 100+dy)], at: 1.2)
            input.update([touch(1, 100+dx*2, 100+dy*2), touch(2, 130+dx*2, 100+dy*2), touch(3, 160+dx*2, 100+dy*2)], at: 1.3)
            input.update([touch(1, 100)], at: 1.4)
            input.update([], at: 1.5)
            XCTAssertEqual(log.workspaceSwipes, [direction])
            XCTAssertTrue(log.clicks.isEmpty)
            XCTAssertTrue(log.scrollPhases.isEmpty)
            XCTAssertTrue(log.moves.isEmpty)
        }
    }

    func testThreeFingerGestureRequiresControlAndRejectsIncoherentMovement() {
        for (enabled, pan) in [(false,false), (true,true)] {
            let log = CommandLog(); let input = engine(log, enabled: enabled, panMode: pan)
            input.update([touch(1, 0), touch(2, 30), touch(3, 60)], at: 1)
            input.update([touch(1, 90), touch(2, 120), touch(3, 150)], at: 1.2)
            input.update([], at: 1.3)
            XCTAssertTrue(log.workspaceSwipes.isEmpty)
        }
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0), touch(2, 30), touch(3, 60)], at: 1)
        input.update([touch(1, 210), touch(2, 30), touch(3, 60)], at: 1.2)
        input.update([], at: 1.3)
        XCTAssertTrue(log.workspaceSwipes.isEmpty, "One moving finger is not a workspace swipe")
    }

    func testAddingThirdFingerAfterScrollingCannotSwitchSpaces() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0), touch(2, 30)], at: 1)
        input.update([touch(1, 0, 20), touch(2, 30, 20)], at: 1.1)
        input.update([touch(1, 0, 20), touch(2, 30, 20), touch(3, 60, 20)], at: 1.15)
        input.update([touch(1, 90, 20), touch(2, 120, 20), touch(3, 150, 20)], at: 1.25)
        input.update([], at: 1.3)
        XCTAssertTrue(log.workspaceSwipes.isEmpty)
        XCTAssertEqual(log.scrollPhases, ["began", "cancelled"])
    }

    func testRevisionCancelsPendingWorkspaceSwipe() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0), touch(2, 30), touch(3, 60)], at: 1)
        input.configure(enabled: true, panMode: false, revision: 2, sensitivity: 1, pointerScale: 1, doubleClickInterval: 0.5)
        input.update([touch(1, 90), touch(2, 120), touch(3, 150)], at: 1.2)
        input.update([], at: 1.3)
        XCTAssertTrue(log.workspaceSwipes.isEmpty)
    }

    func testStaggeredThreeFingerLandingWithDriftStillFiresEveryDirection() {
        let paths: [(CGFloat, CGFloat, NativeSwipeDirection)] = [(-80,0,.left),(80,0,.right),(0,-80,.up),(0,80,.down)]
        for secondAndThirdTogether in [true, false] {
            for (dx, dy, direction) in paths {
                let log = CommandLog(); let input = engine(log)
                input.update([touch(1, 100, 300)], at: 1)
                input.update([touch(1, 106, 300)], at: 1.03)
                if !secondAndThirdTogether {
                    input.update([touch(1, 106, 300), touch(2, 140, 290)], at: 1.06)
                }
                input.update([touch(1, 106, 300), touch(2, 140, 290), touch(3, 175, 305)], at: 1.1)
                input.update([touch(1, 106+dx, 300+dy), touch(2, 140+dx, 290+dy), touch(3, 175+dx, 305+dy)], at: 1.25)
                input.update([], at: 1.3)
                XCTAssertEqual(log.workspaceSwipes, [direction],
                               "first finger drifted 6 pt, then \(secondAndThirdTogether ? "two fingers landed together" : "one at a time")")
                XCTAssertTrue(log.clicks.isEmpty)
            }
        }
    }

    func testTwoFingersThatBarelyStartedScrollingCanBecomeASwipe() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300), touch(2, 140, 300)], at: 1)
        input.update([touch(1, 106, 300), touch(2, 146, 300)], at: 1.04)
        input.update([touch(1, 106, 300), touch(2, 146, 300), touch(3, 180, 300)], at: 1.08)
        input.update([touch(1, 186, 300), touch(2, 226, 300), touch(3, 260, 300)], at: 1.25)
        input.update([], at: 1.3)
        XCTAssertEqual(log.workspaceSwipes, [.right])
        XCTAssertEqual(log.scrollPhases, ["began", "cancelled"], "The 6 pt scroll is closed, not left open")
    }

    func testThirdFingerAfterTheLandingWindowCannotSwitchSpaces() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300), touch(2, 140, 300)], at: 1)
        input.update([touch(1, 100, 300), touch(2, 140, 300), touch(3, 180, 300)], at: 1.3)
        input.update([touch(1, 180, 300), touch(2, 220, 300), touch(3, 260, 300)], at: 1.45)
        input.update([], at: 1.5)
        XCTAssertTrue(log.workspaceSwipes.isEmpty)
    }

    func testScrollThatStartsWithASmallSplayIsNotTakenForAPinch() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0, 100), touch(2, 60, 100)], at: 1)
        input.update([touch(1, 0, 92), touch(2, 64, 92)], at: 1.02)
        input.update([touch(1, 0, 84), touch(2, 66, 84)], at: 1.04)
        input.update([touch(1, 0, 70), touch(2, 66, 70)], at: 1.06)
        input.update([], at: 1.1)
        XCTAssertEqual(log.zooms, 0)
        XCTAssertEqual(log.scrollPhases.first, "began")
        XCTAssertEqual(log.scrollPhases.last, "ended")

        let pinchLog = CommandLog(); let pinch = engine(pinchLog)
        pinch.update([touch(1, 0, 100), touch(2, 60, 100)], at: 2)
        pinch.update([touch(1, -6, 101), touch(2, 67, 99)], at: 2.02)
        pinch.update([], at: 2.1)
        XCTAssertEqual(pinchLog.zooms, 1, "Fingers moving apart still pinch")
        XCTAssertTrue(pinchLog.scrollPhases.isEmpty)
    }

    func testCloseFingersCanScroll() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0, 100), touch(2, 30, 100)], at: 1)
        input.update([touch(1, 0, 94), touch(2, 33, 94)], at: 1.02)
        input.update([touch(1, 0, 80), touch(2, 33, 80)], at: 1.04)
        input.update([], at: 1.1)
        XCTAssertEqual(log.zooms, 0, "A 3 pt splay on a 30 pt span is 10% but not a pinch")
        XCTAssertEqual(log.scrollPhases, ["began", "changed", "ended"])
    }

    func testScrollDistanceIsInMacPointsAtTheCurrentZoom() {
        let log = CommandLog(); let input = engine(log, scale: 0.5)
        input.update([touch(1, 0, 100), touch(2, 40, 100)], at: 1)
        input.update([touch(1, 0, 110), touch(2, 40, 110)], at: 1.02)
        input.update([touch(1, 0, 120), touch(2, 40, 120)], at: 1.04)
        input.update([], at: 1.1)
        XCTAssertEqual(log.scrollDeltas.reduce(0) { $0 + $1.height }, 40, accuracy: 0.001,
                       "20 pt of finger travel over a half-size picture scrolls 40 Mac points")
    }

    func testRestingFingersKeepTheScrollStreamAliveUntilTheyMoveAgain() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0, 100), touch(2, 40, 100)], at: 1)
        input.update([touch(1, 0, 110), touch(2, 40, 110)], at: 1.02)
        input.tick(at: 1.2)
        input.tick(at: 1.28)
        input.tick(at: 1.4)
        input.tick(at: 1.54)
        input.update([touch(1, 0, 120), touch(2, 40, 120)], at: 1.6)
        input.tick(at: 1.7)
        input.update([], at: 1.72)
        XCTAssertEqual(log.scrollPhases, ["began", "changed", "changed", "changed", "ended"])
        XCTAssertEqual(log.scrollDeltas.map(\.height), [10, 0, 0, 10, 0], "Keep-alives carry no distance")
    }

    // MARK: Touch-down landing roll

    /// A finger landing at 120 Hz: it rolls `roll` points (most of it early, as the pad
    /// flattens) over `frames` samples, then rests for `rest` samples.
    private func land(_ input: NativeGestureEngine, id: UInt64, at start: TimeInterval, x: CGFloat,
                      roll: CGFloat, frames: Int = 5, rest: Int = 20) -> TimeInterval {
        var time = start
        for index in 0...(frames + rest) {
            let fraction = CGFloat(min(index, frames)) / CGFloat(frames)
            let eased = 1 - (1 - fraction) * (1 - fraction)
            time = start + Double(index) / 120
            input.update([touch(id, x + roll * eased, 300 + roll * 0.3 * eased)], at: time)
        }
        return time
    }

    /// Frame-analysed on Roshan's phone (29 Sep, 240 fps clip): at a touch-down ~150 ms after a
    /// tap, the pointer jumped most of a small button's width in ~60 ms with no deliberate slide.
    /// The landing roll crossed the 4 pt motion threshold and was sent in one burst through the
    /// speed gain. It must be absorbed, and the touch must still click.
    func testLandingRollDoesNotMoveThePointerAndStillClicks() {
        for scale in [CGFloat(1), 0.27] {
            let log = CommandLog(); let input = engine(log, scale: scale)
            input.update([touch(1, 100, 300)], at: 1)
            input.update([], at: 1.02)
            let end = land(input, id: 2, at: 1.17, x: 160, roll: 7)
            input.update([], at: end + 0.01)
            XCTAssertTrue(log.moves.isEmpty, "A 7 pt landing roll moved the pointer \(log.moves) at view scale \(scale)")
            XCTAssertEqual(log.clicks, [1, 1], "Both touches are clicks")
        }
    }

    func testSlideAfterALandingRollStartsSmoothly() {
        let log = CommandLog(); let input = engine(log)
        var time = land(input, id: 1, at: 1, x: 100, roll: 7, rest: 2)
        for step in 1...36 {
            time += 1.0 / 120
            input.update([touch(1, 107 + CGFloat(step) * 30 / 36, 302.1)], at: time)
        }
        input.update([], at: time + 0.01)
        let largest = log.moves.map { hypot($0.width, $0.height) }.max() ?? 0
        XCTAssertLessThan(largest, 1.5, "No burst when the slide starts: \(log.moves.prefix(3))")
        let travel = log.moves.reduce(0) { $0 + $1.width }
        XCTAssertGreaterThan(travel, 12, "The slide itself still moves the pointer")
        XCTAssertLessThan(travel, 20, "…but the roll before it adds nothing")
    }

    func testQuickFlickStillMovesFromTheFirstFrames() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300)], at: 1)
        for step in 1...6 { input.update([touch(1, 100 + CGFloat(step) * 6, 300)], at: 1 + Double(step) / 120) }
        input.update([], at: 1.06)
        XCTAssertFalse(log.moves.isEmpty, "36 pt in 50 ms is deliberate, not a roll")
        XCTAssertGreaterThan(log.moves.reduce(0) { $0 + $1.width }, 30, "Only the 8 pt landing slop is left out")
    }

    func testDoubleTapHoldDragStartsWithoutAJump() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300)], at: 1)
        input.update([], at: 1.04)
        // Second touch 150 ms later, 3 pt away, rolls 7 pt and rests: a double-tap-and-hold.
        let start = 1.19
        for index in 0...5 {
            let eased = 1 - pow(1 - CGFloat(index) / 5, 2)
            input.update([touch(2, 103 + 7 * eased, 300)], at: start + Double(index) / 120)
        }
        input.tick(at: start + 0.25)
        XCTAssertEqual(log.dragBegins, 1)
        input.update([touch(2, 110.2, 300)], at: start + 0.26)
        let atStart = log.moves.map { hypot($0.width, $0.height) }.max() ?? 0
        XCTAssertLessThan(atStart, 1, "The held item does not jump by the landing roll: \(log.moves)")
        input.update([touch(2, 130.2, 300)], at: start + 0.36)
        input.update([], at: start + 0.4)
        XCTAssertGreaterThan(log.moves.reduce(0) { $0 + $1.width }, 5, "Sliding then drags it")
        XCTAssertEqual(log.dragEnds, 1)
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

final class CommandLog {
    var zoomToggles: [CGPoint] = []
    var navigation: [(factor: CGFloat, anchor: CGPoint, translation: CGSize)] = []
    var workspaceSwipes: [NativeSwipeDirection] = []
    var clicks: [Int] = []
    var secondary = 0
    var middle = 0
    var moves: [CGSize] = []
    var points: [CGPoint] = []
    var scrollPhases: [String] = []
    var scrollDeltas: [CGSize] = []
    var zooms = 0
    var zoomEnds = 0
    var pans = 0
    var dragBegins = 0
    var dragCounts: [Int] = []
    var dragEnds = 0
    var acceptDrag = true
    /// Rejects `pointTo` for points matching this predicate, as a letterbox band would.
    var rejectPoint: (CGPoint) -> Bool = { _ in false }
    /// Every command in order, for checking that the pointer moves before it clicks.
    var trace: [String] = []

    func record(_ command: NativeGestureCommand) -> Bool {
        switch command {
        case .zoomToggle(let anchor): zoomToggles.append(anchor); trace.append("zoomToggle")
        case .navigate(let factor, let anchor, let translation): navigation.append((factor, anchor, translation)); trace.append("navigate")
        case .workspaceSwipe(let direction): workspaceSwipes.append(direction); trace.append("workspace")
        case .click(let count): clicks.append(count); trace.append("click\(count)")
        case .secondaryClick: secondary += 1; trace.append("right")
        case .middleClick: middle += 1; trace.append("middle")
        case .move(let delta): moves.append(delta); trace.append("move")
        case .pointTo(let point):
            guard !rejectPoint(point) else { trace.append("pointTo-rejected"); return false }
            points.append(point); trace.append("pointTo")
        case .scroll(let delta, let phase, _): scrollPhases.append(phase); scrollDeltas.append(delta); trace.append("scroll-\(phase)")
        case .zoom: zooms += 1; trace.append("zoom")
        case .zoomEnded: zoomEnds += 1; trace.append("zoomEnded")
        case .pan: pans += 1; trace.append("pan")
        case .dragBegan(_, let count): dragBegins += 1; dragCounts.append(count); trace.append("dragBegan\(count)"); return acceptDrag
        case .dragEnded: dragEnds += 1; trace.append("dragEnded")
        }
        return true
    }
}
