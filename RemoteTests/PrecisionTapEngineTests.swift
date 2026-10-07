import Foundation
import CoreGraphics
import XCTest

final class PrecisionTapEngineTests: XCTestCase {
    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ log: CommandLog, precision: PrecisionTapTrigger, direct: Bool = true) -> NativeGestureEngine {
        let input = NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 1,
                                        doubleClickInterval: 0.5, direct: direct, onCommand: { log.record($0) })
        input.configure(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 1,
                        doubleClickInterval: 0.5, direct: direct, precision: precision)
        return input
    }

    func testHoldOpensLoupeBeforeDragAndLiftEndsItWithoutAnEngineClick() {
        let log = CommandLog()
        let input = engine(log, precision: .hold)
        input.update([touch(1, 100, 100)], at: 1)
        input.tick(at: 1.2)
        XCTAssertTrue(log.precision.isEmpty)
        input.tick(at: 1.31)
        XCTAssertEqual(log.precision, [.began])
        input.tick(at: 1.6)
        XCTAssertEqual(log.dragBegins, 0, "The loupe replaces touch-and-hold drag")
        input.update([touch(1, 130, 110)], at: 1.7)
        input.update([], at: 1.8)
        XCTAssertEqual(log.precision, [.began, .moved, .ended])
        XCTAssertEqual(log.precisionPoints.last, CGPoint(x: 130, y: 110))
        XCTAssertTrue(log.clicks.isEmpty, "The view decides the click from the loupe's target")
    }

    func testSlideBeforeTheHoldStillDrags() {
        let log = CommandLog()
        let input = engine(log, precision: .hold)
        input.update([touch(1, 100, 100)], at: 1)
        input.update([touch(1, 140, 100)], at: 1.1)
        input.tick(at: 1.5)
        input.update([], at: 1.6)
        XCTAssertEqual(log.dragBegins, 1)
        XCTAssertTrue(log.precision.isEmpty)
    }

    func testQuickTapStillClicksAndSecondFingerCancelsTheLoupe() {
        let log = CommandLog()
        let input = engine(log, precision: .hold)
        input.update([touch(1, 50, 50)], at: 1)
        input.update([], at: 1.1)
        XCTAssertEqual(log.clicks, [1])

        input.update([touch(2, 300, 300)], at: 3)
        input.tick(at: 3.4)
        input.update([touch(2, 300, 300), touch(3, 360, 300)], at: 3.5)
        XCTAssertEqual(log.precision, [.began, .cancelled])
        input.update([], at: 3.6)
        XCTAssertEqual(log.precision, [.began, .cancelled], "A cancelled loupe never ends as a lift")
    }

    func testEveryTapModeOpensAtOnceAndDeclinedLoupeFallsBackToDrag() {
        let log = CommandLog()
        let input = engine(log, precision: .always)
        input.update([touch(1, 10, 10)], at: 1)
        XCTAssertEqual(log.precision, [.began])
        input.update([], at: 1.05)
        XCTAssertEqual(log.precision, [.began, .ended])
        XCTAssertTrue(log.clicks.isEmpty)

        let declined = CommandLog()
        declined.acceptPrecision = false
        let hold = engine(declined, precision: .hold)
        hold.update([touch(4, 10, 10)], at: 5)
        hold.tick(at: 5.31)
        hold.tick(at: 5.4)
        XCTAssertEqual(declined.precision, [.began], "A declined loupe is not retried every tick")
        hold.tick(at: 5.51)
        XCTAssertEqual(declined.dragBegins, 1)
    }

    // MARK: Aim, then drag (PocketDeskHoldShowsLoupe)

    private func aiming(_ log: CommandLog, chosen: PrecisionTapTrigger = .off,
                        target: CGPoint? = nil) -> NativeGestureEngine {
        let input = NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 0.5,
                                        doubleClickInterval: 0.5, direct: true, onCommand: { log.record($0) })
        input.configure(enabled: true, panMode: false, revision: 1, sensitivity: 1, pointerScale: 0.5,
                        doubleClickInterval: 0.5, direct: true, precision: HoldShowsLoupeSwitch.trigger(chosen, on: true))
        input.loupeRestPresses = true
        input.precisionTarget = { target }
        return input
    }

    func testTheSwitchMakesAStillHoldOpenTheLoupeWhateverPrecisionTapIsSetTo() {
        XCTAssertFalse(HoldShowsLoupeSwitch.isOn, "off by default")
        XCTAssertEqual(HoldShowsLoupeSwitch.trigger(.off, on: false), .off)
        XCTAssertEqual(HoldShowsLoupeSwitch.trigger(.off, on: true), .hold)
        XCTAssertEqual(HoldShowsLoupeSwitch.trigger(.hold, on: true), .hold)
        XCTAssertEqual(HoldShowsLoupeSwitch.trigger(.always, on: true), .always)
    }

    func testARestingLoupePressesWhereItAimsAndTheDragFollowsTheFingersTravel() {
        let log = CommandLog()
        let input = aiming(log, target: CGPoint(x: 105.5, y: 102.5))
        input.update([touch(1, 100, 100)], at: 1)
        XCTAssertEqual(log.trace, ["pointTo"])
        input.tick(at: 1.31)
        XCTAssertEqual(log.precision, [.began])
        input.tick(at: 1.6)
        XCTAssertEqual(log.dragBegins, 0, "no press while the loupe is fresh")
        input.update([touch(1, 110, 104)], at: 1.7)
        input.update([touch(1, 111, 105)], at: 1.75)
        input.tick(at: 2.19)
        XCTAssertEqual(log.precision, [.began, .moved, .moved], "aiming restarts the rest; jitter does not")
        input.tick(at: 2.21)
        XCTAssertEqual(log.precision, [.began, .moved, .moved, .pressed, .cancelled])
        XCTAssertEqual(log.precisionPoints[3], CGPoint(x: 111, y: 105))
        XCTAssertEqual(Array(log.trace.suffix(3)), ["precision-pressed", "dragBegan1", "precision-cancelled"],
                       "the receiver places the pointer on the target before the button goes down, then the loupe closes")
        input.update([touch(1, 131, 95)], at: 2.3)
        input.update([touch(1, 141, 95)], at: 2.35)
        XCTAssertEqual(log.points.suffix(2), [CGPoint(x: 125.5, y: 92.5), CGPoint(x: 135.5, y: 92.5)],
                       "the pressed target follows the finger at its offset, never jumping under the finger")
        XCTAssertTrue(log.moves.isEmpty)
        input.tick(at: 3)
        XCTAssertEqual(log.dragBegins, 1, "one press per hold")
        input.update([], at: 3.1)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.precision, [.began, .moved, .moved, .pressed, .cancelled], "a pressed loupe never ends as a click")
        XCTAssertTrue(log.clicks.isEmpty)

        input.update([touch(2, 300, 300)], at: 5)
        input.update([touch(2, 340, 300)], at: 5.05)
        input.update([touch(2, 360, 300)], at: 5.1)
        input.update([], at: 5.2)
        XCTAssertEqual(log.dragBegins, 2, "a slide before the hold still drags at once")
        XCTAssertEqual(log.points.suffix(2), [CGPoint(x: 340, y: 300), CGPoint(x: 360, y: 300)],
                       "an ordinary drag follows the finger's position as before")
    }

    func testALiftBeforeTheRestStillClicksThroughTheLoupe() {
        let log = CommandLog()
        let input = aiming(log)
        input.update([touch(1, 100, 100)], at: 1)
        input.tick(at: 1.31)
        input.update([touch(1, 106, 100)], at: 1.5)
        input.tick(at: 1.79)
        input.update([], at: 1.8)
        XCTAssertEqual(log.precision, [.began, .moved, .ended])
        XCTAssertEqual(log.dragBegins, 0)
    }

    func testARefusedPressWaitsForAnotherRestAndASecondFingerReleasesTheButton() {
        let log = CommandLog()
        log.acceptPress = false
        let input = aiming(log)
        input.update([touch(1, 100, 100)], at: 1)
        input.tick(at: 1.31)
        input.tick(at: 1.82)
        input.tick(at: 1.9)
        XCTAssertEqual(log.precision, [.began, .pressed], "a loupe set to cancel is not pressed every tick")
        log.acceptPress = true
        input.tick(at: 2.33)
        XCTAssertEqual(log.precision, [.began, .pressed, .pressed, .cancelled])
        XCTAssertEqual(log.dragBegins, 1)
        input.update([touch(1, 100, 100), touch(2, 200, 100)], at: 2.4)
        XCTAssertEqual(log.dragEnds, 1, "a second finger cancels the drag and lets the button go")
        input.update([], at: 2.5)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.precision, [.began, .pressed, .pressed, .cancelled])

        let refused = CommandLog()
        refused.acceptDrag = false
        let declined = aiming(refused)
        declined.update([touch(3, 50, 50)], at: 4)
        declined.tick(at: 4.31)
        declined.tick(at: 4.82)
        declined.update([touch(3, 60, 50)], at: 4.9)
        declined.tick(at: 5.5)
        declined.update([], at: 5.6)
        XCTAssertEqual(refused.precision, [.began, .pressed, .moved, .ended],
                       "a Mac that refuses the drag keeps the loupe, and the lift still clicks through it")
        XCTAssertEqual(refused.dragBegins, 1, "no second press")
        XCTAssertEqual(refused.dragEnds, 0)
    }

    func testEveryTapLoupesAndTheSwitchOffNeverPressOnARest() {
        let always = CommandLog()
        let input = aiming(always, chosen: .always)
        input.update([touch(1, 10, 10)], at: 1)
        input.tick(at: 3)
        input.update([], at: 3.1)
        XCTAssertEqual(always.precision, [.began, .ended])
        XCTAssertEqual(always.dragBegins, 0)

        let chosen = CommandLog()
        let touchAndHold = aiming(chosen, chosen: .hold)
        touchAndHold.update([touch(3, 10, 10)], at: 4)
        touchAndHold.tick(at: 4.31)
        touchAndHold.tick(at: 4.82)
        XCTAssertEqual(chosen.precision, [.began, .pressed, .cancelled], "with the switch, Touch and hold also aims then drags")

        let off = CommandLog()
        let hold = engine(off, precision: .hold)
        XCTAssertFalse(hold.loupeRestPresses)
        hold.update([touch(2, 10, 10)], at: 5)
        hold.tick(at: 5.31)
        hold.tick(at: 7)
        hold.update([], at: 7.1)
        XCTAssertEqual(off.precision, [.began, .ended], "Touch and hold keeps lift-to-click only")
        XCTAssertEqual(off.dragBegins, 0)
    }

    func testTrackpadModeNeverOpensTheLoupe() {
        let log = CommandLog()
        let input = engine(log, precision: .always, direct: false)
        input.update([touch(1, 10, 10)], at: 1)
        input.tick(at: 2)
        input.update([], at: 2.1)
        XCTAssertTrue(log.precision.isEmpty)
    }
}
