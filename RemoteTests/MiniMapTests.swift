import XCTest
import CoreGraphics

final class MiniMapLayoutTests: XCTestCase {
    private let display = CGSize(width: 1470, height: 956)

    func testOverviewKeepsTheDisplayAspectInsideItsBox() {
        let layout = MiniMapLayout(sourceSize: display, fitting: CGSize(width: 220, height: 150))!
        XCTAssertEqual(layout.mapSize.width, 220)
        XCTAssertEqual(layout.mapSize.height, 143, "956 × 220 / 1470 rounds to 143")
        let tall = MiniMapLayout(sourceSize: CGSize(width: 1080, height: 1920), fitting: CGSize(width: 220, height: 150))!
        XCTAssertEqual(tall.mapSize.height, 150)
        XCTAssertEqual(tall.mapSize.width, 84)
        XCTAssertNil(MiniMapLayout(sourceSize: .zero, fitting: CGSize(width: 10, height: 10)))
        XCTAssertNil(MiniMapLayout(sourceSize: display, fitting: .zero))
    }

    func testViewportRectangleMatchesWhatTheCanvasShows() {
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 1210, height: 834), mode: .fit,
                                     safeInsets: ViewportInsets(top: 24, bottom: 20))
        XCTAssertFalse(view.isCropped, "Fit at 1× shows the whole display: no mini map")
        XCTAssertEqual(view.visibleSourceRect.width, display.width, accuracy: 0.001)
        view.setZoom(2, anchoredAt: CGPoint(x: 605, y: 417))
        XCTAssertTrue(view.isCropped)
        let visible = view.visibleSourceRect
        // At 2× the canvas shows exactly what it spans divided by the scale.
        XCTAssertEqual(visible.width, min(display.width, 1210 / view.scale), accuracy: 0.001)
        XCTAssertEqual(visible.height, min(display.height, 834 / view.scale), accuracy: 0.001)
        let layout = MiniMapLayout(sourceSize: display, fitting: CGSize(width: 220, height: 150))!
        let rect = layout.viewportRect(for: visible)
        XCTAssertEqual(rect.minX, visible.minX * layout.scaleX, accuracy: 0.001)
        XCTAssertEqual(rect.width, visible.width * layout.scaleX, accuracy: 0.001)
        XCTAssertTrue(CGRect(origin: .zero, size: layout.mapSize).insetBy(dx: -0.01, dy: -0.01).contains(rect))
    }

    func testTinyViewportStaysGrabbable() {
        let layout = MiniMapLayout(sourceSize: display, fitting: CGSize(width: 150, height: 96))!
        let rect = layout.viewportRect(for: CGRect(x: 700, y: 400, width: 10, height: 8))
        XCTAssertGreaterThanOrEqual(rect.width, 6)
        XCTAssertGreaterThanOrEqual(rect.height, 6)
        XCTAssertEqual(rect.midX, 705 * layout.scaleX, accuracy: 0.001, "Enlarging keeps it centred")
    }

    func testDraggingTheRectangleMovesTheViewTheSameWayOverTheDisplay() {
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 1210, height: 834), mode: .fill)
        view.setZoom(2.5, anchoredAt: CGPoint(x: 605, y: 417))
        let layout = MiniMapLayout(sourceSize: display, fitting: CGSize(width: 220, height: 150))!
        let before = view.visibleSourceRect
        let drag = CGSize(width: 10, height: -6)
        view.pan(by: layout.canvasPan(forMapDrag: drag, viewportScale: view.scale))
        let after = view.visibleSourceRect
        XCTAssertEqual(after.minX - before.minX, drag.width / layout.scaleX, accuracy: 0.01)
        XCTAssertEqual(after.minY - before.minY, drag.height / layout.scaleY, accuracy: 0.01)
        XCTAssertEqual(layout.canvasPan(forMapDrag: drag, viewportScale: .nan), .zero)
    }

    func testTapToJumpCentresTheTappedPointWithinPanLimits() {
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 1210, height: 834), mode: .fill,
                                     safeInsets: ViewportInsets(top: 24, bottom: 20))
        view.setZoom(2, anchoredAt: CGPoint(x: 605, y: 417))
        let layout = MiniMapLayout(sourceSize: display, fitting: CGSize(width: 220, height: 150))!
        let target = layout.sourcePoint(forMapPoint: CGPoint(x: 110, y: 70))
        view.center(onSourcePoint: target)
        let centre = view.sourcePoint(fromView: CGPoint(x: 605, y: 24 + (834 - 44) / 2))!
        XCTAssertEqual(centre.x, target.x, accuracy: 0.01)
        XCTAssertEqual(centre.y, target.y, accuracy: 0.01)

        view.center(onSourcePoint: CGPoint(x: 0, y: 0))
        XCTAssertEqual(view.visibleSourceRect.minX, 0, accuracy: 0.01, "Jumping to a corner stops at the edge")
        XCTAssertEqual(view.visibleSourceRect.minY, 0, accuracy: 0.01)
        XCTAssertEqual(layout.sourcePoint(forMapPoint: CGPoint(x: -40, y: 900)), CGPoint(x: 0, y: display.height))
    }
}

final class MiniMapVisibilityTests: XCTestCase {
    func testAppearsOnMovementAndFadesAfterLingerUnlessTouched() {
        var state = MiniMapVisibility()
        XCTAssertFalse(state.shown)
        XCTAssertTrue(state.viewportChanged(eligible: true))
        XCTAssertTrue(state.shown)
        XCTAssertFalse(state.touch(true, eligible: true), "No fade while a finger is on it")
        state.lingerExpired()
        XCTAssertTrue(state.shown)
        XCTAssertTrue(state.touch(false, eligible: true), "Lifting the finger starts the fade timer")
        state.lingerExpired()
        XCTAssertFalse(state.shown)
    }

    func testIneligibleViewsNeverShowIt() {
        var state = MiniMapVisibility()
        XCTAssertFalse(state.viewportChanged(eligible: false))
        XCTAssertFalse(state.shown)
        _ = state.viewportChanged(eligible: true)
        state.eligibilityChanged(false)
        XCTAssertFalse(state.shown, "The dock, keyboard or a sheet hides it at once")
        XCTAssertFalse(state.touching)
    }
}
