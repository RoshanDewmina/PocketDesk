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
        XCTAssertEqual(log.navigation.count, 2)
        XCTAssertEqual(log.navigation.map(\.factor).reduce(1, *), 1.8, accuracy: 0.0001)
        XCTAssertEqual(log.zoomEnds, 1)
        XCTAssertTrue(log.points.isEmpty, "Zooming the view never moves the Mac pointer")
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertTrue(log.scrollPhases.isEmpty)
        XCTAssertTrue(log.moves.isEmpty)
        XCTAssertEqual(log.dragBegins, 0)
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

/// The press highlight's touch-down signal (`PocketDeskPressHighlight`): once per pressing touch after the finger has
/// stayed still and alone for `pressDelay` (or a direct slide pressed), never for pointer travel, scrolls, pinches or
/// View mode, and nothing at all without a receiver.
final class PressFeedbackGestureTests: XCTestCase {
    func testOneSignalPerStillTouchAndNoneForMovesOrTheClick() {
        let log = CommandLog()
        var direct: [PressFeedback] = []
        let input = engine(log, direct: true) { direct.append($0) }
        input.update([touch(1, 50, 50)], at: 1)
        input.update([touch(1, 53, 51)], at: 1.03)
        XCTAssertEqual(direct, [], "Nothing before the finger has rested")
        input.tick(at: 1.045)
        input.update([], at: 1.06)
        input.update([touch(2, 300, 300)], at: 2)
        input.update([touch(2, 340, 300)], at: 2.02)
        input.update([touch(2, 380, 300)], at: 2.04)
        input.update([], at: 2.06)
        XCTAssertEqual(direct, [.began(CGPoint(x: 50, y: 50)), .began(CGPoint(x: 300, y: 300))],
                       "A direct tap and a direct slide both press; moving never repeats or withdraws it")
        XCTAssertEqual(log.trace, ["pointTo", "click1", "pointTo", "dragBegan1", "pointTo", "pointTo", "dragEnded"],
                       "The Mac gets exactly the commands it got before")

        var trackpad: [PressFeedback] = []
        let pad = engine(CommandLog(), direct: false) { trackpad.append($0) }
        pad.update([touch(1, 50, 50)], at: 1)
        pad.tick(at: 1.045)
        pad.update([], at: 1.06)
        pad.update([touch(2, 50, 50)], at: 3)
        pad.update([touch(2, 80, 50)], at: 3.02)
        pad.tick(at: 3.05)
        pad.update([], at: 3.1)
        pad.update([touch(3, 50, 50)], at: 5)
        pad.update([], at: 5.03)
        XCTAssertEqual(trackpad, [.began(nil)], "Quick pointer travel and a quick tap never flash")
        pad.update([touch(4, 50, 50)], at: 7)
        pad.tick(at: 7.045)
        pad.update([touch(4, 90, 50)], at: 7.06)
        pad.update([], at: 7.1)
        XCTAssertEqual(trackpad, [.began(nil), .began(nil), .withdrawn], "Travel after the rest withdraws it once")
    }

    func testScrollPinchThreeFingersLoupeAndViewModeNeverKeepAHighlight() {
        for direct in [true, false] {
            var events: [PressFeedback] = []
            let input = engine(CommandLog(), direct: direct) { events.append($0) }
            input.update([touch(1, 100, 100)], at: 1)
            input.update([touch(1, 100, 100), touch(2, 160, 100)], at: 1.03)
            input.tick(at: 1.05)
            input.update([touch(1, 100, 140), touch(2, 160, 140)], at: 1.1)
            input.update([], at: 1.2)
            input.update([touch(3, 100, 100), touch(4, 160, 100)], at: 2)
            input.update([touch(3, 80, 100), touch(4, 200, 100)], at: 2.1)
            input.update([], at: 2.2)
            input.update([touch(5, 100, 100), touch(6, 130, 100), touch(7, 160, 100)], at: 3)
            input.update([], at: 3.1)
            XCTAssertEqual(events, [], "A scroll's first finger, a pinch and three fingers never highlight")

            input.update([touch(8, 100, 100)], at: 4)
            input.tick(at: 4.045)
            input.update([touch(8, 100, 100), touch(9, 160, 100)], at: 4.06)
            input.update([touch(8, 100, 140), touch(9, 160, 140)], at: 4.1)
            input.update([], at: 4.2)
            input.update([touch(10, 100, 100)], at: 5)
            input.tick(at: 5.045)
            input.update([touch(10, 100, 100), touch(11, 130, 100), touch(12, 160, 100)], at: 5.06)
            input.update([], at: 5.1)
            let began = PressFeedback.began(direct ? CGPoint(x: 100, y: 100) : nil)
            XCTAssertEqual(events, [began, .withdrawn, began, .withdrawn],
                           "A late second or third finger withdraws the highlight at once")
        }

        var loupe: [PressFeedback] = []
        let precise = engine(CommandLog(), direct: true) { loupe.append($0) }
        precise.configure(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 1,
                          doubleClickInterval: 0.5, direct: true, precision: .always)
        precise.update([touch(1, 100, 100)], at: 1)
        precise.tick(at: 1.045)
        precise.update([], at: 1.06)
        XCTAssertEqual(loupe, [], "The Precision Tap loupe is its own feedback")

        var viewing: [PressFeedback] = []
        let view = engine(CommandLog(), direct: false, panMode: true) { viewing.append($0) }
        view.update([touch(1, 100, 100)], at: 1)
        view.tick(at: 1.045)
        view.update([], at: 1.06)
        let viewOnly = engine(CommandLog(), direct: true, enabled: false) { viewing.append($0) }
        viewOnly.update([touch(1, 100, 100)], at: 1)
        viewOnly.tick(at: 1.045)
        viewOnly.update([], at: 1.06)
        XCTAssertEqual(viewing, [], "View mode and a view-only session press nothing")
    }

    func testRejectedPointCancelAndNoReceiverSendNothingExtra() {
        let log = CommandLog()
        log.rejectPoint = { $0.y > 500 }
        var events: [PressFeedback] = []
        let input = engine(log, direct: true) { events.append($0) }
        input.update([touch(1, 100, 600)], at: 1)
        input.tick(at: 1.045)
        input.update([], at: 1.06)
        XCTAssertEqual(events, [], "A letterbox band has no Mac point and no highlight")
        input.update([touch(2, 100, 100)], at: 2)
        input.tick(at: 2.045)
        input.cancel()
        input.cancel()
        XCTAssertEqual(events, [.began(CGPoint(x: 100, y: 100)), .withdrawn], "A cancel withdraws once")

        let silentLog = CommandLog()
        let silent = engine(silentLog, direct: true, receiver: nil)
        silent.update([touch(1, 50, 50)], at: 1)
        silent.tick(at: 1.045)
        silent.update([], at: 1.06)
        XCTAssertEqual(silentLog.trace, ["pointTo", "click1"])
    }

    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ log: CommandLog, direct: Bool, enabled: Bool = true, panMode: Bool = false,
                        receiver: ((PressFeedback) -> Void)?) -> NativeGestureEngine {
        let input = NativeGestureEngine(enabled: enabled, panMode: panMode, revision: 1, sensitivity: 1,
                                        pointerScale: 1, doubleClickInterval: 0.5, direct: direct,
                                        onCommand: { log.record($0) })
        input.clipboardGesturesEnabled = { true }
        input.onPressFeedback = receiver
        return input
    }
}
