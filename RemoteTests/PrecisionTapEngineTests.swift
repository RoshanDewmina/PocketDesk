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

    func testTrackpadModeNeverOpensTheLoupe() {
        let log = CommandLog()
        let input = engine(log, precision: .always, direct: false)
        input.update([touch(1, 10, 10)], at: 1)
        input.tick(at: 2)
        input.update([], at: 2.1)
        XCTAssertTrue(log.precision.isEmpty)
    }
}
