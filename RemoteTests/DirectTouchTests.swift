import Foundation
import CoreGraphics
import XCTest

/// Direct touch: the finger is the pointer. These cover the touch arbitration only; mapping a
/// canvas point to the Mac is `DirectTouchMappingTests`.
final class DirectTouchEngineTests: XCTestCase {
    func testTapMovesThePointerUnderTheFingerThenClicksThere() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 120, 300)], at: 1)
        XCTAssertEqual(log.points, [CGPoint(x: 120, y: 300)], "The pointer jumps on touch-down")
        input.update([touch(1, 124, 303)], at: 1.05)
        input.update([], at: 1.1)
        XCTAssertEqual(log.trace, ["pointTo", "click1"])
        XCTAssertTrue(log.moves.isEmpty, "Direct touch never sends relative motion")
    }

    func testDoubleTapLandsOnTheFirstTapAndCountsTwo() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 200, 200)], at: 1)
        input.update([], at: 1.05)
        input.update([touch(2, 214, 209)], at: 1.25)
        input.update([], at: 1.3)
        XCTAssertEqual(log.clicks, [1, 2])
        XCTAssertEqual(log.points, [CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 200)],
                       "The second tap snaps to the first so the Mac sees one place")
        input.update([touch(3, 200, 200)], at: 1.45)
        input.update([], at: 1.5)
        XCTAssertEqual(log.clicks, [1, 2, 1], "A third tap starts a new click")
    }

    func testFarOrLateSecondTapIsAnotherSingleClick() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 100, 100)], at: 1)
        input.update([], at: 1.05)
        input.update([touch(2, 160, 100)], at: 1.2)
        input.update([], at: 1.25)
        input.update([touch(3, 160, 100)], at: 2.5)
        input.update([], at: 2.55)
        XCTAssertEqual(log.clicks, [1, 1, 1])
        XCTAssertEqual(log.points.map(\.x), [100, 160, 160])
    }

    func testSlidePressesWhereTheTouchLandedAndFollowsTheFinger() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 50, 50)], at: 1)
        input.update([touch(1, 55, 52)], at: 1.02)
        XCTAssertEqual(log.dragBegins, 0, "Small jitter is still a tap")
        input.update([touch(1, 80, 60)], at: 1.05)
        input.update([touch(1, 140, 90)], at: 1.1)
        input.update([], at: 1.15)
        XCTAssertEqual(log.trace, ["pointTo", "dragBegan1", "pointTo", "pointTo", "dragEnded"])
        XCTAssertEqual(log.points, [CGPoint(x: 50, y: 50), CGPoint(x: 80, y: 60), CGPoint(x: 140, y: 90)])
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testTouchAndHoldPressesWithoutMovingAndLiftReleases() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 300, 400)], at: 1)
        input.tick(at: 1.3)
        XCTAssertEqual(log.dragBegins, 0)
        input.tick(at: 1.51)
        XCTAssertEqual(log.dragCounts, [1], "Holding still presses the button, like touch-and-hold on a screen")
        input.update([touch(1, 360, 420)], at: 1.6)
        input.update([], at: 1.7)
        XCTAssertEqual(log.trace, ["pointTo", "dragBegan1", "pointTo", "dragEnded"])
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testDoubleTapThenSlideDragsWithCountTwoFromTheFirstTap() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 100, 100)], at: 1)
        input.update([], at: 1.04)
        input.update([touch(2, 104, 102)], at: 1.2)
        input.update([touch(2, 140, 102)], at: 1.3)
        input.update([], at: 1.35)
        XCTAssertEqual(log.clicks, [1])
        XCTAssertEqual(log.dragCounts, [2], "Double-tap-drag selects by word on the Mac")
        XCTAssertEqual(log.points.first, CGPoint(x: 100, y: 100))
        XCTAssertEqual(log.points.last, CGPoint(x: 140, y: 102))
    }

    func testLetterboxTouchNeitherClicksNorDrags() {
        let log = CommandLog()
        log.rejectPoint = { $0.y < 80 }
        let input = engine(log)
        input.update([touch(1, 100, 40)], at: 1)
        input.update([touch(1, 140, 40)], at: 1.05)
        input.tick(at: 1.8)
        input.update([], at: 1.9)
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertEqual(log.dragBegins, 0)
        XCTAssertTrue(log.points.isEmpty)
    }

    func testTwoFingersScrollWhatIsUnderThemAndTapRightClicksThere() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 100, 200), touch(2, 140, 200)], at: 1)
        input.update([touch(1, 100, 230), touch(2, 140, 230)], at: 1.05)
        input.update([touch(1, 100, 260), touch(2, 140, 260)], at: 1.1)
        input.update([], at: 1.15)
        XCTAssertEqual(log.trace, ["pointTo", "scroll-began", "scroll-changed", "scroll-ended"])
        XCTAssertEqual(log.points, [CGPoint(x: 120, y: 200)], "The pointer stays put while scrolling")

        let tap = CommandLog()
        let second = engine(tap)
        second.update([touch(1, 300, 500), touch(2, 330, 520)], at: 2)
        second.update([], at: 2.1)
        XCTAssertEqual(tap.trace, ["pointTo", "right"])
        XCTAssertEqual(tap.points, [CGPoint(x: 315, y: 510)])
    }

    func testTwoFingerTapOverLetterboxDoesNotRightClickElsewhere() {
        let log = CommandLog()
        log.rejectPoint = { _ in true }
        let input = engine(log)
        input.update([touch(1, 10, 10), touch(2, 30, 10)], at: 1)
        input.update([], at: 1.1)
        XCTAssertEqual(log.secondary, 0)
    }

    func testPinchStaysLocalZoom() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 100, 100), touch(2, 200, 100)], at: 1)
        input.update([touch(1, 80, 100), touch(2, 220, 100)], at: 1.05)
        input.update([touch(1, 60, 100), touch(2, 240, 100)], at: 1.1)
        input.update([], at: 1.15)
        XCTAssertGreaterThan(log.zooms, 0)
        XCTAssertEqual(log.zoomEnds, 1)
        XCTAssertTrue(log.points.isEmpty, "Zooming the view never moves the Mac pointer")
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testSwitchingModesMidDragReleasesOnce() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 50, 50)], at: 1)
        input.update([touch(1, 90, 50)], at: 1.05)
        XCTAssertEqual(log.dragBegins, 1)
        input.configure(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 1,
                        doubleClickInterval: 0.5, direct: false)
        XCTAssertEqual(log.dragEnds, 1)
        input.update([touch(1, 120, 50)], at: 1.1)
        input.update([], at: 1.15)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertTrue(log.moves.isEmpty, "The surviving finger must lift before it drives the new mode")
        XCTAssertEqual(log.points.count, 2)
    }

    func testViewOnlyAndViewModeNeverPointOrClick() {
        for (enabled, pan) in [(false, false), (true, true)] {
            let log = CommandLog()
            let input = engine(log, enabled: enabled, panMode: pan)
            input.update([touch(1, 50, 50)], at: 1)
            input.update([], at: 1.05)
            input.update([touch(2, 50, 50)], at: 1.6)
            input.update([touch(2, 90, 50)], at: 1.7)
            input.update([], at: 1.8)
            XCTAssertTrue(log.points.isEmpty)
            XCTAssertTrue(log.clicks.isEmpty)
            XCTAssertEqual(log.dragBegins, 0)
        }
    }

    func testTrackpadModeNeverPointsDirectly() {
        let log = CommandLog()
        let input = NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1,
                                        pointerScale: 1, doubleClickInterval: 0.5,
                                        onCommand: { log.record($0) })
        input.update([touch(1, 50, 50)], at: 1)
        input.update([], at: 1.05)
        input.update([touch(2, 0, 0), touch(3, 20, 0)], at: 2)
        input.update([touch(2, 0, 20), touch(3, 20, 20)], at: 2.05)
        input.update([], at: 2.1)
        input.update([touch(4, 0)], at: 3)
        input.tick(at: 3.9)
        input.update([], at: 4)
        XCTAssertTrue(log.points.isEmpty)
        XCTAssertEqual(log.dragBegins, 0, "Only a second tap holds in trackpad mode")
        XCTAssertEqual(log.clicks, [1])
    }

    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ log: CommandLog, enabled: Bool = true, panMode: Bool = false) -> NativeGestureEngine {
        NativeGestureEngine(enabled: enabled, panMode: panMode, revision: 1, sensitivity: 1,
                            pointerScale: 1, doubleClickInterval: 0.5, direct: true,
                            onCommand: { log.record($0) })
    }
}

/// Three-finger tap is the middle mouse button, in both touch modes. It must never fire from a
/// workspace swipe, a slow press, moving fingers or a fourth finger.
final class MiddleClickGestureTests: XCTestCase {
    func testThreeFingerTapMiddleClicksInTrackpadMode() {
        let log = CommandLog()
        let input = engine(log, direct: false)
        input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
        input.update([touch(1, 102, 101), touch(2, 131, 99), touch(3, 161, 102)], at: 1.1)
        input.update([], at: 1.2)
        XCTAssertEqual(log.trace, ["middle"])
    }

    func testDirectThreeFingerTapClicksAtTheCentroid() {
        let log = CommandLog()
        let input = engine(log, direct: true)
        input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 130)], at: 1)
        input.update([], at: 1.15)
        XCTAssertEqual(log.trace, ["pointTo", "middle"])
        XCTAssertEqual(log.points, [CGPoint(x: 130, y: 110)])
    }

    func testStaggeredLandingAndUnevenLiftStillCount() {
        let log = CommandLog()
        let input = engine(log, direct: false)
        input.update([touch(1, 100, 100)], at: 1)
        input.update([touch(1, 100, 100), touch(2, 130, 100)], at: 1.05)
        input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1.1)
        input.update([touch(2, 130, 100), touch(3, 160, 100)], at: 1.25)
        input.update([touch(3, 160, 100)], at: 1.3)
        input.update([], at: 1.35)
        XCTAssertEqual(log.middle, 1)
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertEqual(log.secondary, 0)
    }

    func testSwipeSlowPressMovementAndFourthFingerDoNotMiddleClick() {
        let swipe = CommandLog()
        let a = engine(swipe, direct: false)
        a.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
        a.update([touch(1, 20, 100), touch(2, 50, 100), touch(3, 80, 100)], at: 1.1)
        a.update([], at: 1.2)
        XCTAssertEqual(swipe.workspaceSwipes, [.left])
        XCTAssertEqual(swipe.middle, 0)

        let slow = CommandLog()
        let b = engine(slow, direct: false)
        b.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
        b.update([], at: 1.6)
        XCTAssertEqual(slow.middle, 0)

        let moving = CommandLog()
        let c = engine(moving, direct: false)
        c.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
        c.update([touch(1, 100, 125), touch(2, 130, 100), touch(3, 160, 100)], at: 1.1)
        c.update([], at: 1.2)
        XCTAssertEqual(moving.middle, 0)

        let four = CommandLog()
        let d = engine(four, direct: false)
        d.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
        d.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100), touch(4, 190, 100)], at: 1.05)
        d.update([], at: 1.1)
        XCTAssertEqual(four.middle, 0)
    }

    func testViewModeAndViewOnlyNeverMiddleClick() {
        for (enabled, pan) in [(false, false), (true, true)] {
            let log = CommandLog()
            let input = NativeGestureEngine(enabled: enabled, panMode: pan, revision: 1, sensitivity: 1,
                                            pointerScale: 1, doubleClickInterval: 0.5,
                                            onCommand: { log.record($0) })
            input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
            input.update([], at: 1.1)
            XCTAssertEqual(log.middle, 0)
        }
    }

    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ log: CommandLog, direct: Bool) -> NativeGestureEngine {
        NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1,
                            pointerScale: 1, doubleClickInterval: 0.5, direct: direct,
                            onCommand: { log.record($0) })
    }
}
