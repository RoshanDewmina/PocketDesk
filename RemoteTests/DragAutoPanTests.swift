import XCTest
import CoreGraphics

/// D34 amendment: follow also applies while a click is held (drag auto-pan).
final class DragAutoPanTests: XCTestCase {
    private let usable = CGRect(x: 0, y: 0, width: 390, height: 844)

    private func fillViewport() -> ViewportTransform {
        ViewportTransform(sourceSize: CGSize(width: 1440, height: 900), canvasSize: CGSize(width: 390, height: 844), mode: .fill)
    }

    func testNoPanOutsideTheEdgeBand() {
        XCTAssertEqual(DragAutoPan.translation(pointer: CGPoint(x: 195, y: 422), usable: usable, dt: 1.0 / 60), .zero)
        XCTAssertEqual(DragAutoPan.translation(pointer: CGPoint(x: 390 - 73, y: 422), usable: usable, dt: 1.0 / 60), .zero)
    }

    func testSpeedRampsWithDepthAndPointsTowardTheEdge() {
        let dt = 1.0 / 60
        let shallow = DragAutoPan.translation(pointer: CGPoint(x: 390 - 60, y: 422), usable: usable, dt: dt)
        let deep = DragAutoPan.translation(pointer: CGPoint(x: 390 - 10, y: 422), usable: usable, dt: dt)
        let edge = DragAutoPan.translation(pointer: CGPoint(x: 390, y: 422), usable: usable, dt: dt)
        XCTAssertLessThan(shallow.width, 0, "near the right edge the picture moves left")
        XCTAssertLessThan(deep.width, shallow.width)
        XCTAssertEqual(edge.width, -DragAutoPan.maxSpeed * CGFloat(dt), accuracy: 0.001)
        let left = DragAutoPan.translation(pointer: CGPoint(x: 5, y: 422), usable: usable, dt: dt)
        XCTAssertGreaterThan(left.width, 0)
        XCTAssertEqual(DragAutoPan.translation(pointer: CGPoint(x: 5, y: 422), usable: usable, dt: 0), .zero)
    }

    func testHeldDragKeepsThePointerOnScreenAndMovesTheMacPointWithThePicture() throws {
        var viewport = fillViewport()
        let scale = viewport.scale
        let screen = CGPoint(x: 385, y: 400)
        let start = try XCTUnwrap(viewport.sourcePoint(fromView: screen))
        let moved = try XCTUnwrap(DragAutoPan.step(&viewport, pointerSource: start, usable: usable, dt: 1.0 / 60))
        XCTAssertGreaterThan(moved.x, start.x)
        XCTAssertEqual(moved.y, start.y, accuracy: 0.001)
        XCTAssertEqual(viewport.scale, scale, "auto-pan never zooms")
        let drawn = viewport.viewPoint(fromSource: moved)
        XCTAssertEqual(drawn.x, screen.x, accuracy: 0.001, "the pointer stays where the finger put it")
        XCTAssertEqual(drawn.y, screen.y, accuracy: 0.001)
    }

    func testAutoPanStopsAtTheSourceEdge() throws {
        var viewport = fillViewport()
        var pointer = try XCTUnwrap(viewport.sourcePoint(fromView: CGPoint(x: 388, y: 400)))
        var ticks = 0
        while let next = DragAutoPan.step(&viewport, pointerSource: pointer, usable: usable, dt: 1.0 / 60) {
            pointer = next
            ticks += 1
            XCTAssertLessThan(ticks, 1000)
        }
        XCTAssertGreaterThan(ticks, 0)
        XCTAssertEqual(viewport.contentRect.maxX, 390, accuracy: 0.01)
        XCTAssertLessThanOrEqual(pointer.x, 1440)
    }

    func testAxisWithNoCroppingDoesNotMove() throws {
        var viewport = fillViewport()
        let start = try XCTUnwrap(viewport.sourcePoint(fromView: CGPoint(x: 195, y: 840)))
        XCTAssertNil(DragAutoPan.step(&viewport, pointerSource: start, usable: usable, dt: 1.0 / 60),
                     "the whole source height already fits, so the bottom band has nothing to reveal")
    }
}
