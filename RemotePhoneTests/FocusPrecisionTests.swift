import XCTest
@testable import PocketDeskRemote

final class FocusPrecisionTests: XCTestCase {
    private let display = CGSize(width: 1440, height: 900)

    private func target(_ rect: CGRect, anchor: CGPoint? = nil, epoch: UInt64 = 3, refresh: Bool = false,
                        revision: UInt64 = 1) -> FocusTarget {
        var geometry = FocusGeometry(displayWidth: display.width, displayHeight: display.height,
                                     x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        geometry.anchorX = anchor.map { Double($0.x) }
        geometry.anchorY = anchor.map { Double($0.y) }
        return FocusTarget(geometry, sourceSize: display, epoch: epoch, refresh: refresh, revision: revision)!
    }

    private func keyboardViewport() -> ViewportTransform {
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 393, height: 852), mode: .fill,
                                     safeInsets: ViewportInsets(top: 59, bottom: 34))
        view.setZoom(1.6, anchoredAt: CGPoint(x: 196, y: 426))
        view.updateSafeInsets(ViewportInsets(top: 59, bottom: 336))
        return view
    }

    private func usable(_ view: ViewportTransform) -> CGRect {
        PointerFollowLayout.usableRect(safeRect: view.safeRect, canvasFrame: CGRect(x: 0, y: 0, width: 393, height: 852),
                                       dockFrame: CGRect(x: 0, y: 410, width: 393, height: 106))
    }

    // MARK: - Keyboard reveal

    func testFocusedFieldIsRevealedAboveTheKeyboardAtTheCurrentZoom() {
        var reveal = KeyboardFocusReveal()
        let field = CGRect(x: 640, y: 760, width: 150, height: 30)
        reveal.receive(target(field), at: 10)
        reveal.keyboard(open: true, at: 10.1)
        var view = keyboardViewport()
        let zoom = view.zoom
        XCTAssertTrue(reveal.apply(to: &view, usable: usable(view), epoch: 3))
        XCTAssertEqual(view.zoom, zoom)
        XCTAssertTrue(usable(view).contains(view.viewRect(fromSource: field)))
    }

    func testStaleEpochAndOldTargetsAreNeverRevealed() {
        var reveal = KeyboardFocusReveal()
        reveal.receive(target(CGRect(x: 640, y: 760, width: 150, height: 30), epoch: 3), at: 10)
        reveal.keyboard(open: true, at: 10.1)
        var view = keyboardViewport()
        XCTAssertFalse(reveal.apply(to: &view, usable: usable(view), epoch: 4), "A new capture epoch voids the rect")

        var late = KeyboardFocusReveal()
        late.receive(target(CGRect(x: 640, y: 760, width: 150, height: 30)), at: 10)
        late.keyboard(open: true, at: 13)
        XCTAssertNil(late.revealRect(epoch: 3, span: CGSize(width: 200, height: 100)),
                     "A rect from a click long before the keyboard opened belongs to another moment")

        XCTAssertNil(FocusTarget(FocusGeometry(displayWidth: 1920, displayHeight: 1080, x: 1, y: 1, width: 10, height: 10),
                                 sourceSize: display, epoch: 3, refresh: false, revision: 1),
                     "A rect measured on another display size is rejected")
    }

    func testManualPanWinsUntilTheNextClickOrKeyboardClose() {
        var reveal = KeyboardFocusReveal()
        let span = CGSize(width: 200, height: 100)
        reveal.receive(target(CGRect(x: 640, y: 760, width: 100, height: 30)), at: 10)
        reveal.keyboard(open: true, at: 10)
        XCTAssertNotNil(reveal.revealRect(epoch: 3, span: span))
        reveal.userMovedViewport()
        XCTAssertNil(reveal.revealRect(epoch: 3, span: span), "Manual pan always wins")
        reveal.receive(target(CGRect(x: 10, y: 10, width: 100, height: 30), refresh: true, revision: 2), at: 11)
        XCTAssertNil(reveal.revealRect(epoch: 3, span: span), "Typing never overrides a manual pan")
        reveal.receive(target(CGRect(x: 20, y: 20, width: 100, height: 30), revision: 3), at: 12)
        XCTAssertEqual(reveal.revealRect(epoch: 3, span: span), CGRect(x: 20, y: 20, width: 100, height: 30),
                       "A fresh click is a new deliberate target")
        reveal.keyboard(open: false, at: 13)
        XCTAssertNil(reveal.target)
        XCTAssertFalse(reveal.manualOverride)
    }

    func testRefreshOnlyMovesAnExistingTarget() {
        var reveal = KeyboardFocusReveal()
        reveal.keyboard(open: true, at: 1)
        reveal.receive(target(CGRect(x: 5, y: 5, width: 50, height: 20), refresh: true), at: 1.1)
        XCTAssertNil(reveal.target, "Typing into an unknown field never starts a reveal")
        reveal.receive(target(CGRect(x: 5, y: 5, width: 50, height: 20)), at: 1.2)
        reveal.receive(target(CGRect(x: 5, y: 40, width: 50, height: 60), refresh: true, revision: 2), at: 1.3)
        XCTAssertEqual(reveal.target?.rect, CGRect(x: 5, y: 40, width: 50, height: 60))
    }

    func testRefreshProbeReplyNeverOpensTheKeyboardButIsAccepted() {
        var gate = TextFocusProbeGate()
        let probe = gate.begin(epoch: 2, at: 5, refresh: true)
        XCTAssertEqual(gate.pending?.refresh, true)
        XCTAssertTrue(gate.consume(probe: probe, editable: true, responseEpoch: 2, currentEpoch: 2, at: 5.2, allowed: true))
        let stale = gate.begin(epoch: 2, at: 6)
        XCTAssertFalse(gate.consume(probe: stale, editable: true, responseEpoch: 1, currentEpoch: 2, at: 6.1, allowed: true),
                       "A reply from an older geometry epoch is rejected")
    }

    // MARK: - Precision Tap

    private func loupeViewport() -> ViewportTransform {
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 393, height: 852), mode: .fill)
        view.setZoom(1.2, anchoredAt: CGPoint(x: 196, y: 426))
        return view
    }

    func testLiftClicksTheExactPointTheLoupeShows() throws {
        let view = loupeViewport()
        var tap = try XCTUnwrap(PrecisionTap(finger: CGPoint(x: 200, y: 400), in: view))
        tap.move(to: CGPoint(x: 220, y: 380), in: view)
        XCTAssertEqual(tap.target, CGPoint(x: 210, y: 390), "The target moves at half the finger's speed")
        let source = try XCTUnwrap(tap.sourceTarget(in: view))
        XCTAssertEqual(view.viewPoint(fromSource: source).x, 210, accuracy: 0.001)
        let loupe = try XCTUnwrap(LoupeGeometry.make(target: source, scale: view.scale, region: nil, displaySize: display))
        XCTAssertEqual(loupe.crosshair.x, LoupeGeometry.diameter / 2, accuracy: 0.001)
        XCTAssertEqual(loupe.crosshair.y, LoupeGeometry.diameter / 2, accuracy: 0.001)
        let shownX = loupe.crop.minX * display.width + loupe.crosshair.x / LoupeGeometry.diameter * loupe.span
        let shownY = loupe.crop.minY * display.height + loupe.crosshair.y / LoupeGeometry.diameter * loupe.span
        XCTAssertEqual(shownX, source.x, accuracy: 0.001)
        XCTAssertEqual(shownY, source.y, accuracy: 0.001)
        XCTAssertEqual(loupe.span * view.scale * LoupeGeometry.magnification, LoupeGeometry.diameter, accuracy: 0.001)
    }

    func testSlidingAwayOrOffTheCanvasCancels() throws {
        let view = loupeViewport()
        var tap = try XCTUnwrap(PrecisionTap(finger: CGPoint(x: 200, y: 400), in: view))
        tap.move(to: CGPoint(x: 200, y: 400 + PrecisionTap.cancelTravel + 1), in: view)
        XCTAssertTrue(tap.cancelArmed)
        XCTAssertNil(tap.sourceTarget(in: view))
        tap.move(to: CGPoint(x: 210, y: 405), in: view)
        XCTAssertFalse(tap.cancelArmed, "Sliding back re-arms the click")
        tap.move(to: CGPoint(x: -5, y: 405), in: view)
        XCTAssertTrue(tap.cancelArmed)
        XCTAssertNil(PrecisionTap(finger: CGPoint(x: 200, y: -10), in: view), "No loupe outside the picture")
    }

    func testLoupeNearTheDisplayEdgeMovesTheCrosshairNotTheCrop() throws {
        let loupe = try XCTUnwrap(LoupeGeometry.make(target: CGPoint(x: 2, y: 898), scale: 1, region: nil,
                                                     displaySize: display))
        XCTAssertEqual(loupe.crop.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(loupe.crop.maxY, 1, accuracy: 0.0001)
        XCTAssertLessThan(loupe.crosshair.x, LoupeGeometry.diameter / 2)
        XCTAssertGreaterThan(loupe.crosshair.y, LoupeGeometry.diameter / 2)
        XCTAssertEqual(loupe.crosshair.x / LoupeGeometry.diameter * loupe.span, 2, accuracy: 0.001)
    }

    func testCroppedCaptureMapsTheLoupeIntoTheRegionsFrames() throws {
        let region = CaptureRegion(epoch: 5, x: 400, y: 300, width: 600, height: 400, outputWidth: 1200, outputHeight: 800)
        let target = CGPoint(x: 700, y: 500)
        let loupe = try XCTUnwrap(LoupeGeometry.make(target: target, scale: 2, region: region, displaySize: display))
        let span = LoupeGeometry.diameter / (2 * LoupeGeometry.magnification)
        XCTAssertEqual(loupe.crop.minX, (700 - span / 2 - 400) / 600, accuracy: 0.0001)
        XCTAssertEqual(loupe.crop.minY, (500 - span / 2 - 300) / 400, accuracy: 0.0001)
        XCTAssertEqual(loupe.crop.width, span / 600, accuracy: 0.0001)
        XCTAssertNil(LoupeGeometry.make(target: CGPoint(x: 100, y: 100), scale: 2, region: region, displaySize: display),
                     "A point the cropped frames do not cover has nothing to magnify")
        let pixels = try XCTUnwrap(LoupeGeometry.pixelCrop(loupe.crop, baseX: 0, baseY: 0, baseWidth: 1200, baseHeight: 800))
        XCTAssertEqual(pixels.x % 2, 0)
        XCTAssertEqual(pixels.y % 2, 0)
        XCTAssertLessThanOrEqual(pixels.x + pixels.width, 1200)
    }

    func testLoupeSitsAboveTheFingerAndFlipsBelowNearTheTop() {
        let safe = CGRect(x: 0, y: 59, width: 393, height: 759)
        let above = LoupeGeometry.placement(finger: CGPoint(x: 200, y: 500), safe: safe)
        XCTAssertLessThan(above.y, 500 - LoupeGeometry.diameter / 2)
        let below = LoupeGeometry.placement(finger: CGPoint(x: 5, y: 100), safe: safe)
        XCTAssertGreaterThan(below.y, 100)
        XCTAssertGreaterThanOrEqual(below.x - LoupeGeometry.diameter / 2, safe.minX)
    }
    func testReadingLensStaysInsidePictureAndLeavesRoomForControls() {
        for safe in [CGRect(x: 0, y: 59, width: 393, height: 700), CGRect(x: 59, y: 0, width: 720, height: 320),
                     CGRect(x: 0, y: 200, width: 393, height: 300)] {
            let diameter = ReadingLensLayout.diameter(in: safe)
            for proposed in [CGPoint(x: -1000, y: -1000), CGPoint(x: 10000, y: 10000)] {
                let center = ReadingLensLayout.center(proposed, in: safe, diameter: diameter)
                XCTAssertGreaterThanOrEqual(center.x - diameter / 2, safe.minX)
                XCTAssertLessThanOrEqual(center.x + diameter / 2, safe.maxX)
                XCTAssertGreaterThanOrEqual(center.y - diameter / 2, safe.minY)
                XCTAssertLessThanOrEqual(center.y + diameter / 2 + 50, safe.maxY)
            }
        }
        XCTAssertEqual(ReadingLensLayout.diameter(in: CGRect(x: 0, y: 0, width: 50, height: 50)), 0)
    }

    func testPrecisionRefractionKeepsTargetInUndistortedCenter() {
        XCTAssertTrue(PrecisionGlassPolicy.permitsRefraction(crosshair: CGPoint(x: 66, y: 66), diameter: 132))
        XCTAssertFalse(PrecisionGlassPolicy.permitsRefraction(crosshair: CGPoint(x: 2, y: 130), diameter: 132))
        XCTAssertFalse(PrecisionGlassPolicy.permitsRefraction(crosshair: CGPoint(x: 66, y: 112), diameter: 132))
    }

    func testReadingLensCanSampleNarrowCaptureAtDisplayEdge() throws {
        let region = CaptureRegion(epoch: 1, x: 0, y: 0, width: 200, height: 200, outputWidth: 400, outputHeight: 400)
        let target = ReadingLensLayout.sampleTarget(CGPoint(x: 500, y: 300), region: region, displaySize: display)
        XCTAssertEqual(target, CGPoint(x: 200, y: 200))
        let geometry = try XCTUnwrap(LoupeGeometry.make(target: target, scale: 0.3, region: region,
                                                       displaySize: display, diameter: 220, magnification: 2))
        XCTAssertGreaterThan(geometry.crop.width, 0)
        XCTAssertLessThanOrEqual(geometry.crop.maxX, 1)
        XCTAssertLessThanOrEqual(geometry.crop.maxY, 1)
    }

}
