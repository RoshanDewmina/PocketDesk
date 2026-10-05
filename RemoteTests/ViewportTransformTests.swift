import Foundation
import CoreGraphics
import XCTest

final class ViewportTransformTests: XCTestCase {
    func testBetaFocusDoublesPortraitFitWithoutForcingDeepFillCrop() throws {
        let view = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
            canvasSize: CGSize(width: 390, height: 844), mode: .fit)
        let anchor = CGPoint(x: view.contentRect.midX, y: view.contentRect.midY)
        let focus = try XCTUnwrap(view.focused(anchoredAt: anchor))
        XCTAssertEqual(focus.scale, view.scale * 2, accuracy: 0.000_001)
        XCTAssertLessThan(focus.scale, view.fillScale)
        XCTAssertEqual(focus.sourcePoint(fromView: anchor), view.sourcePoint(fromView: anchor))
    }

    func testBetaFocusReturnIsExactAfterManualPanAndPinchForFitAndPannedFill() throws {
        for mode in ViewportMode.allCases {
            var before = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
                canvasSize: CGSize(width: 844, height: 390), mode: mode, zoom: 1.3)
            before.pan(by: CGSize(width: 30, height: -20))
            var bookmark = ViewportFocusReturn()
            var focused = try XCTUnwrap(bookmark.destination(from: before, anchoredAt: CGPoint(x: 350, y: 195)))
            focused.pan(by: CGSize(width: -55, height: 25))
            focused.setZoom(focused.zoom * 1.1, anchoredAt: CGPoint(x: 400, y: 195))
            let restored = try XCTUnwrap(bookmark.restoreDestination(for: focused))
            XCTAssertEqual(restored.mode, before.mode)
            XCTAssertEqual(restored.zoom, before.zoom)
            XCTAssertEqual(restored.offset, before.offset)
            XCTAssertEqual(restored.contentRect, before.contentRect)
            bookmark.clear()
            XCTAssertFalse(bookmark.canRestore)
        }
    }

    func testBetaFocusRejectsLetterboxAndBoundsCornersAndMaximumZoom() throws {
        let view = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
            canvasSize: CGSize(width: 390, height: 844), mode: .fit)
        var bookmark = ViewportFocusReturn()
        XCTAssertNil(bookmark.destination(from: view, anchoredAt: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(bookmark.canRestore)
        let focused = try XCTUnwrap(bookmark.destination(from: view, anchoredAt: view.contentRect.origin))
        XCTAssertGreaterThanOrEqual(focused.visibleSourceRect.minX, 0)
        XCTAssertGreaterThanOrEqual(focused.visibleSourceRect.minY, 0)
        XCTAssertLessThanOrEqual(focused.visibleSourceRect.maxX, view.sourceSize.width)
        XCTAssertLessThanOrEqual(focused.visibleSourceRect.maxY, view.sourceSize.height)
        let maxed = ViewportTransform(sourceSize: view.sourceSize, canvasSize: view.canvasSize, mode: .fit, zoom: view.zoomRange.upperBound)
        XCTAssertNil(maxed.focused(anchoredAt: CGPoint(x: maxed.safeRect.midX, y: maxed.safeRect.midY)))
    }

    func testBetaReturnInvalidatesOnSourceRotationOrKeyboardGeometryReplacement() throws {
        let view = ViewportTransform(sourceSize: CGSize(width: 1000, height: 500),
            canvasSize: CGSize(width: 500, height: 500), mode: .fit)
        for change in 0..<3 {
            var bookmark = ViewportFocusReturn()
            var focused = try XCTUnwrap(bookmark.destination(from: view, anchoredAt: CGPoint(x: 250, y: 250)))
            switch change {
            case 0: focused.resize(sourceSize: CGSize(width: 1001, height: 500), canvasSize: view.canvasSize)
            case 1: focused.resize(sourceSize: view.sourceSize, canvasSize: CGSize(width: 700, height: 350))
            default: focused.updateSafeInsets(ViewportInsets(bottom: 200))
            }
            XCTAssertNil(bookmark.restoreDestination(for: focused))
            XCTAssertFalse(bookmark.canRestore)
        }
    }

    func testBetaCameraSamplesRoundTripAndKeepsEndpointFramingDuringInterruptibleReturn() throws {
        var from = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
            canvasSize: CGSize(width: 844, height: 390), mode: .fill, zoom: 1.2)
        from.pan(by: CGSize(width: -20, height: 10))
        let target = try XCTUnwrap(from.focused(anchoredAt: CGPoint(x: 400, y: 190)))
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let sample = try XCTUnwrap(from.interpolated(to: target, progress: t))
            let anchor = CGPoint(x: sample.safeRect.midX, y: sample.safeRect.midY)
            let source = try XCTUnwrap(sample.sourcePoint(fromView: anchor))
            XCTAssertEqual(sample.viewPoint(fromSource: source).x, anchor.x, accuracy: 0.000_001)
            XCTAssertEqual(sample.viewPoint(fromSource: source).y, anchor.y, accuracy: 0.000_001)
            XCTAssertGreaterThanOrEqual(sample.scale, from.scale)
            XCTAssertLessThanOrEqual(sample.scale, target.scale)
            if step == 9 {
                let reverse = try XCTUnwrap(sample.interpolated(to: from, progress: 0))
                XCTAssertEqual(reverse.contentRect, sample.contentRect, "Retargeting starts at the current sampled picture")
            }
        }
        XCTAssertEqual(from.interpolated(to: target, progress: 1)?.contentRect, target.contentRect)
        var rotated = target
        rotated.resize(sourceSize: from.sourceSize, canvasSize: CGSize(width: 390, height: 844))
        XCTAssertNil(from.interpolated(to: rotated, progress: 0.5))
    }

    func testDoubleTapZoomKeepsTappedContentThenReturnsToSafeFit() {
        var view = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
                                     canvasSize: CGSize(width: 390, height: 844), mode: .fill)
        let anchor = CGPoint(x: 150, y: 400)
        let source = view.sourcePoint(fromView: anchor)!
        let oldScale = view.scale
        view.toggleZoom(anchoredAt: anchor)
        XCTAssertEqual(view.scale, oldScale * 2, accuracy: 0.001)
        XCTAssertEqual(view.viewPoint(fromSource: source).x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(view.viewPoint(fromSource: source).y, anchor.y, accuracy: 0.001)
        view.pan(by: CGSize(width: 20, height: -15))
        XCTAssertEqual(view.viewPoint(fromSource: source).x, anchor.x + 20, accuracy: 0.001)
        XCTAssertEqual(view.viewPoint(fromSource: source).y, anchor.y - 15, accuracy: 0.001)
        view.toggleZoom(anchoredAt: anchor)
        XCTAssertEqual(view.mode, .fit)
        XCTAssertTrue(view.safeRect.contains(view.contentRect))
    }

    func testDoubleTapOnFitLetterboxDoesNotJumpTheView() {
        var view = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
                                     canvasSize: CGSize(width: 390, height: 844), mode: .fit)
        let oldRect = view.contentRect
        view.toggleZoom(anchoredAt: CGPoint(x: 50, y: 20))
        XCTAssertEqual(view.contentRect, oldRect)
    }

    func testCornersRoundTripThroughLetterboxedContent() {
        let transform = ViewportTransform(
            sourceSize: CGSize(width: 1_920, height: 1_080),
            canvasSize: CGSize(width: 390, height: 844),
            mode: .fit
        )

        XCTAssertEqual(transform.fitScale, 390 / 1_920, accuracy: 0.000_001)
        XCTAssertEqual(transform.sourcePoint(fromView: transform.contentRect.origin), CGPoint())
        XCTAssertEqual(
            transform.sourcePoint(fromView: CGPoint(x: transform.contentRect.maxX, y: transform.contentRect.maxY)),
            CGPoint(x: 1_920, y: 1_080)
        )
        XCTAssertEqual(transform.viewPoint(fromSource: CGPoint(x: 1_920, y: 1_080)), CGPoint(x: transform.contentRect.maxX, y: transform.contentRect.maxY))
    }

    func testInverseRejectsLetterboxBarsAndInvalidGeometryIsSafe() {
        let transform = ViewportTransform(
            sourceSize: CGSize(width: 1_920, height: 1_080),
            canvasSize: CGSize(width: 390, height: 844),
            mode: .fit
        )

        XCTAssertNil(transform.sourcePoint(fromView: CGPoint(x: 195, y: 0)))
        XCTAssertNil(transform.sourcePoint(fromView: CGPoint(x: 195, y: 843)))

        let invalid = ViewportTransform(
            sourceSize: CGSize(width: CGFloat.nan, height: 100),
            canvasSize: CGSize(width: 100, height: 100),
            zoom: CGFloat.infinity,
            offset: CGPoint(x: CGFloat.infinity, y: CGFloat.nan)
        )
        XCTAssertEqual(invalid.sourceSize, CGSize())
        XCTAssertEqual(invalid.zoom, 1)
        XCTAssertEqual(invalid.contentRect, CGRect())
        XCTAssertNil(invalid.sourcePoint(fromView: CGPoint()))
    }

    func testZoomKeepsMidpointSourceAnchorWhenItCanRemainVisible() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 500, height: 500),
            mode: .fit
        )
        let midpoint = CGPoint(x: 250, y: 250)
        let anchoredSource = transform.sourcePoint(fromView: midpoint)

        transform.setZoom(2, anchoredAt: midpoint)

        XCTAssertEqual(transform.zoom, 2)
        XCTAssertEqual(transform.sourcePoint(fromView: midpoint), anchoredSource)
        XCTAssertEqual(transform.viewPoint(fromSource: anchoredSource!), midpoint)
    }

    func testPanClampsAndFitRecentersLetterboxedDimension() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 100, height: 100),
            canvasSize: CGSize(width: 200, height: 100),
            mode: .fit,
            zoom: 3
        )

        transform.pan(by: CGSize(width: 1_000, height: 1_000))
        XCTAssertEqual(transform.offset, CGPoint(x: 50, y: 100))
        transform.pan(by: CGSize(width: -2_000, height: -2_000))
        XCTAssertEqual(transform.offset, CGPoint(x: -50, y: -100))

        transform.fit()
        XCTAssertEqual(transform.zoom, 1)
        XCTAssertEqual(transform.offset, CGPoint())
        XCTAssertEqual(transform.contentRect, CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    func testResizePreservesNormalizedCenterFocalPoint() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 1_000),
            canvasSize: CGSize(width: 500, height: 400),
            mode: .fit,
            zoom: 2,
            offset: CGPoint(x: 40, y: -40)
        )

        let originalCenter = CGPoint(x: 250, y: 200)
        let originalFocalPoint = transform.sourcePoint(fromView: originalCenter)!
        XCTAssertEqual(originalFocalPoint.x / transform.sourceSize.width, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(originalFocalPoint.y / transform.sourceSize.height, 0.55, accuracy: 0.000_001)

        transform.resize(
            sourceSize: CGSize(width: 1_000, height: 1_000),
            canvasSize: CGSize(width: 400, height: 500)
        )

        let resizedFocalPoint = transform.sourcePoint(fromView: CGPoint(x: 200, y: 250))!
        XCTAssertEqual(resizedFocalPoint.x / transform.sourceSize.width, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(resizedFocalPoint.y / transform.sourceSize.height, 0.55, accuracy: 0.000_001)
    }

    func testDefaultFillCoversPortraitAndLandscapeWithoutDistortion() {
        for canvas in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let transform = ViewportTransform(
                sourceSize: CGSize(width: 1_920, height: 1_080),
                canvasSize: canvas
            )
            XCTAssertEqual(transform.mode, .fill)
            XCTAssertEqual(transform.scale, transform.fillScale, accuracy: 0.000_001)
            XCTAssertLessThanOrEqual(transform.contentRect.minX, 0.000_001)
            XCTAssertLessThanOrEqual(transform.contentRect.minY, 0.000_001)
            XCTAssertGreaterThanOrEqual(transform.contentRect.maxX + 0.000_001, canvas.width)
            XCTAssertGreaterThanOrEqual(transform.contentRect.maxY + 0.000_001, canvas.height)
            XCTAssertEqual(
                transform.contentRect.width / transform.contentRect.height,
                1_920.0 / 1_080.0, accuracy: 0.000_001
            )
            XCTAssertNotNil(transform.sourcePoint(fromView: CGPoint(x: 0, y: 0)))
            XCTAssertNotNil(transform.sourcePoint(fromView: CGPoint(x: canvas.width, y: canvas.height)))
            XCTAssertNil(transform.sourcePoint(fromView: CGPoint(x: -1, y: canvas.height / 2)))
        }
    }

    func testFitShowsWholeDisplayAtExactAspectRatioAndModeToggleResetsZoom() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_920, height: 1_080),
            canvasSize: CGSize(width: 390, height: 844)
        )
        transform.fit()
        XCTAssertEqual(transform.mode, .fit)
        XCTAssertEqual(transform.scale, 390 / 1_920, accuracy: 0.000_001)
        XCTAssertEqual(transform.contentRect.width, 390, accuracy: 0.000_001)
        XCTAssertEqual(transform.contentRect.height, 219.375, accuracy: 0.000_001)
        XCTAssertEqual(transform.contentRect.width / transform.contentRect.height,
                       1_920.0 / 1_080.0, accuracy: 0.000_001)
        XCTAssertNil(transform.sourcePoint(fromView: CGPoint(x: 195, y: 0)))
        transform.setZoom(2, anchoredAt: CGPoint(x: 195, y: 422))
        transform.fill()
        XCTAssertEqual(transform.mode, .fill)
        XCTAssertEqual(transform.zoom, 1)
        XCTAssertEqual(transform.offset, CGPoint())
    }

    func testFillPanClampsAtEveryCanvasEdge() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 300, height: 600)
        )
        transform.pan(by: CGSize(width: 10_000, height: 10_000))
        XCTAssertEqual(transform.offset.x, 450, accuracy: 0.000_001)
        XCTAssertEqual(transform.offset.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(transform.contentRect.minX, 0, accuracy: 0.000_001)
        transform.pan(by: CGSize(width: -20_000, height: -20_000))
        XCTAssertEqual(transform.offset.x, -450, accuracy: 0.000_001)
        XCTAssertEqual(transform.contentRect.maxX, 300, accuracy: 0.000_001)
    }

    func testRotationPreservesManualFillFocalPointButRecentersBaseline() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 400, height: 800)
        )
        transform.setZoom(1.5, anchoredAt: CGPoint(x: 200, y: 400))
        transform.pan(by: CGSize(width: 100, height: -80))
        let before = transform.sourcePoint(fromView: CGPoint(x: 200, y: 400))!
        let normalized = CGPoint(x: before.x / 1_000, y: before.y / 500)
        transform.resize(sourceSize: CGSize(width: 1_000, height: 500),
                         canvasSize: CGSize(width: 800, height: 400))
        let after = transform.sourcePoint(fromView: CGPoint(x: 400, y: 200))!
        XCTAssertEqual(after.x / 1_000, normalized.x, accuracy: 0.000_001)
        XCTAssertEqual(after.y / 500, normalized.y, accuracy: 0.000_001)

        transform.fill()
        transform.resize(sourceSize: CGSize(width: 1_000, height: 500),
                         canvasSize: CGSize(width: 400, height: 800))
        XCTAssertEqual(transform.offset, CGPoint())
        XCTAssertEqual(transform.mode, .fill)
        XCTAssertEqual(transform.contentRect.midX, 200, accuracy: 0.000_001)
        XCTAssertEqual(transform.contentRect.midY, 400, accuracy: 0.000_001)
    }

    func testRevealPansBothAxesInFillWithoutChangingZoom() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 400, height: 800)
        )
        transform.setZoom(1.5, anchoredAt: CGPoint(x: 200, y: 400))
        let initialScale = transform.scale

        XCTAssertTrue(transform.reveal(
            sourcePoint: CGPoint(x: 800, y: 450),
            in: CGRect(x: 0, y: 0, width: 400, height: 800)
        ))
        let revealed = transform.viewPoint(fromSource: CGPoint(x: 800, y: 450))
        XCTAssertEqual(revealed.x, 368, accuracy: 0.000_001)
        XCTAssertEqual(revealed.y, 768, accuracy: 0.000_001)
        XCTAssertEqual(transform.zoom, 1.5)
        XCTAssertEqual(transform.scale, initialScale)
        XCTAssertFalse(transform.reveal(
            sourcePoint: CGPoint(x: 800, y: 450),
            in: CGRect(x: 0, y: 0, width: 400, height: 800)
        ))
    }

    func testRevealDoesNothingWhenPointIsAlreadyInsideCentralRegion() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 400, height: 800),
            zoom: 1.5
        )
        let before = transform.offset
        XCTAssertFalse(transform.reveal(
            sourcePoint: CGPoint(x: 500, y: 250),
            in: CGRect(x: 0, y: 0, width: 400, height: 800)
        ))
        XCTAssertEqual(transform.offset, before)
    }

    func testRevealCanClearOpenDockWithoutChangingManualPanBounds() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_440, height: 900),
            canvasSize: CGSize(width: 390, height: 844),
            mode: .fill, zoom: 1.6,
            safeInsets: ViewportInsets(top: 50, bottom: 34)
        )
        let visible = CGRect(x: 0, y: 50, width: 390, height: 598)
        let point = CGPoint(x: 720, y: 800)
        XCTAssertTrue(transform.reveal(sourcePoint: point, in: visible, margin: 32))
        XCTAssertLessThanOrEqual(transform.viewPoint(fromSource: point).y,
                                 visible.maxY - 32 + 0.001)
        XCTAssertEqual(transform.zoom, 1.6)

        transform.pan(by: CGSize(width: 0, height: -10_000))
        XCTAssertEqual(transform.contentRect.minY, transform.safeRect.maxY - transform.contentRect.height,
                       accuracy: 0.001, "Manual panning retains the safe-area clamp")
    }

    func testLandscapeFitOverviewDoesNotMoveBehindOpenDock() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_920, height: 1_080),
            canvasSize: CGSize(width: 844, height: 390), mode: .fit,
            safeInsets: ViewportInsets(top: 0, left: 59, bottom: 21, right: 59)
        )
        let baseline = transform.contentRect
        let aboveDock = CGRect(x: 59, y: 0, width: 726, height: 220)
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: 960, y: 1_000), in: aboveDock))
        XCTAssertEqual(transform.contentRect, baseline, "A fitted overview stays inside the safe area")
    }

    func testRevealRespectsSafeUsableRectAndCapsMarginForTinyRect() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 400, height: 800),
            zoom: 1.5
        )
        XCTAssertTrue(transform.reveal(
            sourcePoint: CGPoint(x: 620, y: 390),
            in: CGRect(x: 30, y: 80, width: 340, height: 620)
        ))
        let revealed = transform.viewPoint(fromSource: CGPoint(x: 620, y: 390))
        XCTAssertEqual(revealed.x, 338, accuracy: 0.000_001)
        XCTAssertEqual(revealed.y, 668, accuracy: 0.000_001)

        transform.fill()
        XCTAssertTrue(transform.reveal(
            sourcePoint: CGPoint(x: 600, y: 250),
            in: CGRect(x: 190, y: 390, width: 20, height: 20)
        ))
        XCTAssertEqual(transform.viewPoint(fromSource: CGPoint(x: 600, y: 250)).x,
                       205, accuracy: 0.000_001)
    }

    func testRevealClampsAtSourceEdgeAndRejectsInvalidCoordinates() {
        var transform = ViewportTransform(
            sourceSize: CGSize(width: 1_000, height: 500),
            canvasSize: CGSize(width: 400, height: 800),
            zoom: 1.5
        )
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(transform.reveal(sourcePoint: CGPoint(x: 1_000, y: 500), in: canvas))
        XCTAssertEqual(transform.offset.x, -1_000, accuracy: 0.000_001)
        XCTAssertEqual(transform.offset.y, -200, accuracy: 0.000_001)
        XCTAssertEqual(transform.viewPoint(fromSource: CGPoint(x: 1_000, y: 500)),
                       CGPoint(x: 400, y: 800))
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: 1_000, y: 500), in: canvas))

        let before = transform.offset
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: -1, y: 100), in: canvas))
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: 1_001, y: 100), in: canvas))
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: CGFloat.nan, y: 100), in: canvas))
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: 500, y: 250),
                                        in: CGRect(x: 500, y: 0, width: 100, height: 100)))
        XCTAssertFalse(transform.reveal(sourcePoint: CGPoint(x: 500, y: 250),
                                        in: canvas, margin: .nan))
        XCTAssertEqual(transform.offset, before)
    }

    // MARK: - Safe-area aware Fill and Fit

    private let desktop = CGSize(width: 1_440, height: 900)
    private let portrait = CGSize(width: 402, height: 874)
    private let landscape = CGSize(width: 874, height: 402)
    private let portraitInsets = ViewportInsets(top: 62, left: 0, bottom: 34, right: 0)
    private let landscapeInsets = ViewportInsets(top: 0, left: 62, bottom: 21, right: 62)
    private let keyboardInsets = ViewportInsets(top: 62, left: 0, bottom: 34 + 336 + 104, right: 0)

    private func assertInside(_ rect: CGRect, _ bounds: CGRect, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let e: CGFloat = 0.000_1
        XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - e, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - e, message, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + e, message, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + e, message, file: file, line: line)
    }

    func testFitKeepsWholeDesktopInsideSafeAreaForEveryEdge() {
        for (canvas, insets) in [(portrait, portraitInsets), (landscape, landscapeInsets), (portrait, keyboardInsets)] {
            let transform = ViewportTransform(sourceSize: desktop, canvasSize: canvas, mode: .fit, safeInsets: insets)
            let safe = transform.safeRect
            XCTAssertEqual(safe, CGRect(x: insets.left, y: insets.top,
                                        width: canvas.width - insets.left - insets.right,
                                        height: canvas.height - insets.top - insets.bottom))
            assertInside(transform.contentRect, safe,
                         "Fit must never place the desktop under a display corner, the sensor housing or the keyboard")
            XCTAssertEqual(transform.contentRect.width / transform.contentRect.height, 1.6, accuracy: 0.000_1)
            let touchesWidth = abs(transform.contentRect.width - safe.width) < 0.001
            let touchesHeight = abs(transform.contentRect.height - safe.height) < 0.001
            XCTAssertTrue(touchesWidth || touchesHeight, "Fit uses the largest size that fits the safe area")
            XCTAssertEqual(transform.contentRect.midX, safe.midX, accuracy: 0.000_1)
            XCTAssertEqual(transform.contentRect.midY, safe.midY, accuracy: 0.000_1)
        }
    }

    func testFillCoversWholeCanvasEdgeToEdgeWithInsets() {
        for (canvas, insets) in [(portrait, portraitInsets), (landscape, landscapeInsets)] {
            let transform = ViewportTransform(sourceSize: desktop, canvasSize: canvas, safeInsets: insets)
            XCTAssertEqual(transform.mode, .fill)
            XCTAssertTrue(transform.isAtBaseline)
            let rect = transform.contentRect
            XCTAssertLessThanOrEqual(rect.minX, 0.000_1)
            XCTAssertLessThanOrEqual(rect.minY, 0.000_1)
            XCTAssertGreaterThanOrEqual(rect.maxX, canvas.width - 0.000_1)
            XCTAssertGreaterThanOrEqual(rect.maxY, canvas.height - 0.000_1)
            XCTAssertEqual(rect.midX, canvas.width / 2, accuracy: 0.000_1, "Fill crops symmetrically")
        }
    }

    func testEveryDesktopCornerCanBeRevealedInsideSafeAreaInFill() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1_440, y: 0),
                       CGPoint(x: 0, y: 900), CGPoint(x: 1_440, y: 900)]
        for (canvas, insets) in [(portrait, portraitInsets), (landscape, landscapeInsets), (portrait, keyboardInsets)] {
            for zoom: CGFloat in [1, 1.7, 3] {
                for corner in corners {
                    var transform = ViewportTransform(sourceSize: desktop, canvasSize: canvas, safeInsets: insets)
                    transform.setZoom(zoom, anchoredAt: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
                    _ = transform.reveal(sourcePoint: corner, in: transform.safeRect, margin: 0)
                    let point = transform.viewPoint(fromSource: corner)
                    assertInside(CGRect(origin: point, size: .zero), transform.safeRect,
                                 "Corner \(corner) at zoom \(zoom) in \(canvas) must be reachable")
                }
            }
        }
    }

    func testPanningFillBringsMenuBarAndDockClearOfSensorHousingAndHomeIndicator() {
        var transform = ViewportTransform(sourceSize: desktop, canvasSize: landscape, safeInsets: landscapeInsets)
        transform.pan(by: CGSize(width: 10_000, height: 10_000))
        XCTAssertEqual(transform.contentRect.minX, 62, accuracy: 0.000_1, "Left edge clears the sensor housing")
        XCTAssertEqual(transform.contentRect.minY, 0, accuracy: 0.000_1, "The menu bar reaches the top safe edge")
        transform.pan(by: CGSize(width: -20_000, height: -20_000))
        XCTAssertEqual(transform.contentRect.maxX, 874 - 62, accuracy: 0.000_1)
        XCTAssertEqual(transform.contentRect.maxY, 402 - 21, accuracy: 0.000_1, "The Dock clears the home indicator")

        var upright = ViewportTransform(sourceSize: desktop, canvasSize: portrait, safeInsets: portraitInsets)
        upright.pan(by: CGSize(width: 0, height: 10_000))
        XCTAssertEqual(upright.contentRect.minY, 62, accuracy: 0.000_1, "The menu bar can move below the Dynamic Island")
        XCTAssertNotNil(upright.sourcePoint(fromView: CGPoint(x: 201, y: 62.5)))
        upright.pan(by: CGSize(width: 0, height: -20_000))
        XCTAssertEqual(upright.contentRect.maxY, 874 - 34, accuracy: 0.000_1)
    }

    func testKeyboardInsetKeepsFocusVisibleAndRestoresExactlyWhenClosed() {
        var transform = ViewportTransform(sourceSize: desktop, canvasSize: portrait, safeInsets: portraitInsets)
        transform.setZoom(1.4, anchoredAt: CGPoint(x: 201, y: 451))
        transform.pan(by: CGSize(width: -30, height: 0))
        let before = transform
        let oldCenter = CGPoint(x: transform.safeRect.midX, y: transform.safeRect.midY)
        let focus = transform.sourcePoint(fromView: oldCenter)!

        transform.updateSafeInsets(keyboardInsets)
        let newCenter = CGPoint(x: transform.safeRect.midX, y: transform.safeRect.midY)
        let moved = transform.viewPoint(fromSource: focus)
        XCTAssertEqual(moved.x, newCenter.x, accuracy: 0.001)
        XCTAssertEqual(moved.y, newCenter.y, accuracy: 0.001, "What you were looking at stays centred above the keyboard")
        XCTAssertEqual(transform.zoom, before.zoom)

        transform.updateSafeInsets(portraitInsets)
        XCTAssertEqual(transform.offset, before.offset, "Closing the keyboard returns to the same view")
        XCTAssertEqual(transform.zoom, before.zoom)

        var baseline = ViewportTransform(sourceSize: desktop, canvasSize: portrait, safeInsets: portraitInsets)
        baseline.updateSafeInsets(keyboardInsets)
        baseline.updateSafeInsets(portraitInsets)
        XCTAssertTrue(baseline.isAtBaseline, "An untouched Fill view survives a keyboard round trip")
    }

    func testFitShrinksAboveKeyboardAndReturns() {
        var transform = ViewportTransform(sourceSize: desktop, canvasSize: landscape, mode: .fit, safeInsets: landscapeInsets)
        let resting = transform.contentRect
        transform.updateSafeInsets(ViewportInsets(top: 0, left: 62, bottom: 250, right: 62))
        assertInside(transform.contentRect, transform.safeRect, "Fit stays whole above the keyboard")
        XCTAssertLessThan(transform.contentRect.height, resting.height)
        transform.updateSafeInsets(landscapeInsets)
        XCTAssertEqual(transform.contentRect, resting)
    }

    func testPinchingFillDownSettlesToFitAndSmallPinchSpringsBack() {
        var transform = ViewportTransform(sourceSize: desktop, canvasSize: landscape, safeInsets: landscapeInsets)
        let center = CGPoint(x: 437, y: 190)
        XCTAssertLessThan(transform.zoomRange.lowerBound, 1, "Fill can be pinched toward the Fit size")
        transform.setZoom(0.97, anchoredAt: center)
        XCTAssertFalse(transform.settleZoom())
        XCTAssertEqual(transform.mode, .fill)
        XCTAssertEqual(transform.zoom, 1, "A small pinch springs back to Fill")

        transform.setZoom(transform.zoomRange.lowerBound, anchoredAt: center)
        XCTAssertTrue(transform.settleZoom())
        XCTAssertEqual(transform.mode, .fit)
        XCTAssertTrue(transform.isAtBaseline)
        assertInside(transform.contentRect, transform.safeRect, "Settled Fit shows the whole desktop")
    }

    func testPinchingFitOutToFillSizeSwitchesToFillButOtherZoomsStay() {
        var transform = ViewportTransform(sourceSize: desktop, canvasSize: landscape, mode: .fit, safeInsets: landscapeInsets)
        let center = CGPoint(x: 437, y: 190)
        transform.setZoom(1.1, anchoredAt: center)
        XCTAssertFalse(transform.settleZoom())
        XCTAssertEqual(transform.mode, .fit)
        XCTAssertEqual(transform.zoom, 1.1, accuracy: 0.000_1)

        transform.setZoom(transform.fillScale / transform.fitScale, anchoredAt: center)
        XCTAssertTrue(transform.settleZoom())
        XCTAssertEqual(transform.mode, .fill)
        XCTAssertTrue(transform.isAtBaseline)
    }

    func testModeToggleAndIPadResizeUseActualBounds() {
        var transform = ViewportTransform(sourceSize: desktop, canvasSize: CGSize(width: 820, height: 1_180),
                                          safeInsets: ViewportInsets(top: 24, bottom: 20))
        XCTAssertEqual(transform.mode.toggled, .fit)
        transform.setMode(transform.mode.toggled)
        XCTAssertEqual(transform.mode, .fit)
        transform.resize(sourceSize: desktop, canvasSize: CGSize(width: 507, height: 1_180),
                         safeInsets: ViewportInsets(top: 24, bottom: 20))
        assertInside(transform.contentRect, transform.safeRect, "Narrow split-view windows still fit the whole desktop")
        XCTAssertEqual(transform.contentRect.width, 507, accuracy: 0.000_1)
    }
}

/// G4 viewport capture: what the phone asks the Mac to capture, where a cropped stream's frames are drawn,
/// and that the Mac point under a finger is the one the frame shows there. Expected values come from the
/// definitions of Fit, Fill and a region's placement, not from the helpers under test.
final class ViewportCaptureGeometryTests: XCTestCase {
    private struct Device {
        let name: String
        let canvas: CGSize
        let insets: ViewportInsets
        let displayScale: CGFloat
    }

    private let devices = [
        Device(name: "iPhone portrait", canvas: CGSize(width: 402, height: 874),
               insets: ViewportInsets(top: 62, bottom: 34), displayScale: 3),
        Device(name: "iPhone landscape", canvas: CGSize(width: 874, height: 402),
               insets: ViewportInsets(left: 62, bottom: 21, right: 62), displayScale: 3),
        Device(name: "iPad portrait", canvas: CGSize(width: 834, height: 1210),
               insets: ViewportInsets(top: 24, bottom: 20), displayScale: 2),
        Device(name: "iPad landscape", canvas: CGSize(width: 1210, height: 834),
               insets: ViewportInsets(top: 24, bottom: 20), displayScale: 2)
    ]
    private let displays = [CGSize(width: 1470, height: 956), CGSize(width: 1920, height: 1080),
                            CGSize(width: 2560, height: 1440)]
    private let macBookAir = CGSize(width: 1470, height: 956)

    // MARK: What the phone asks for

    func testWholeDisplayRectIsTheDisplayInPoints() {
        XCTAssertEqual(ViewportTransform.wholeDisplayRect(for: CGSize(width: 2560, height: 1440)),
                       CGRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(ViewportTransform.wholeDisplayRect(for: .zero), .zero)
        XCTAssertEqual(ViewportTransform.wholeDisplayRect(for: CGSize(width: -1, height: 900)), .zero)
        XCTAssertEqual(ViewportTransform.wholeDisplayRect(for: CGSize(width: CGFloat.nan, height: 900)), .zero)
        XCTAssertEqual(ViewportTransform.wholeDisplayRect(for: CGSize(width: 1440, height: CGFloat.infinity)), .zero)
    }

    func testFitAndBaselineFillAskForTheWholeDisplayAtTheirOnScreenPixels() throws {
        for device in devices {
            for display in displays {
                for mode in [ViewportMode.fit, .fill] {
                    let context = "\(device.name) \(mode) \(display)"
                    var view = ViewportTransform(sourceSize: display, canvasSize: device.canvas, mode: mode,
                                                 safeInsets: device.insets)
                    view.baselineFillCrop = true
                    let safe = safeRect(device)
                    let scale = mode == .fit
                        ? min(safe.width / display.width, safe.height / display.height)
                        : max(device.canvas.width / display.width, device.canvas.height / display.height)
                    let request = try XCTUnwrap(view.captureRequest(displayScale: device.displayScale), context)
                    let visible = view.visibleSourceRect
                    let share = visible.width * visible.height / (display.width * display.height)
                    var stock = view
                    stock.baselineFillCrop = false
                    XCTAssertTrue(stock.requestsWholeDisplay, "with the key off every baseline asks for the whole display, \(context)")
                    if mode == .fill, share < ViewportTransform.wholeDisplayShare {
                        XCTAssertFalse(view.requestsWholeDisplay, "under half on screen asks for its rect, \(context)")
                        XCTAssertTrue(CGRect(origin: .zero, size: display).contains(request.rect), context)
                        XCTAssertEqual(Double(request.pixelWidth), Double(device.canvas.width * device.displayScale),
                                       accuracy: 0.500_001, context)
                        XCTAssertEqual(Double(request.pixelHeight), Double(device.canvas.height * device.displayScale),
                                       accuracy: 0.500_001, context)
                    } else {
                        XCTAssertTrue(view.requestsWholeDisplay, context)
                        XCTAssertEqual(request.rect, CGRect(origin: .zero, size: display), context)
                        XCTAssertEqual(Double(request.pixelWidth), Double(display.width * scale * device.displayScale),
                                       accuracy: 0.500_001, context)
                        XCTAssertEqual(Double(request.pixelHeight), Double(display.height * scale * device.displayScale),
                                       accuracy: 0.500_001, context)
                    }
                    XCTAssertEqual(request.displaySize, display, context)
                    XCTAssertEqual(request.zoom, Double(scale * device.displayScale), accuracy: 0.000_051, context)
                    XCTAssertNoThrow(try request.region(epoch: 1).validate(), context)
                }
            }
        }
    }

    func testPortraitFillAsksForItsVisibleRectAndLandscapeFillForTheWholeDisplay() throws {
        let display = CGSize(width: 1920, height: 1243)
        var portrait = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 402, height: 874), mode: .fill,
                                         safeInsets: ViewportInsets(top: 62, bottom: 34))
        XCTAssertTrue(portrait.requestsWholeDisplay, "off by default until the device check")
        portrait.baselineFillCrop = true
        XCTAssertFalse(portrait.requestsWholeDisplay, "30 % of the display at 2.1 px per point")
        let request = try XCTUnwrap(portrait.captureRequest(displayScale: 3))
        XCTAssertEqual(Double(request.rect.width), 402 / Double(portrait.scale), accuracy: 0.02)
        XCTAssertEqual(Double(request.rect.height), 1243, accuracy: 0.02)
        XCTAssertEqual(request.zoom, Double(portrait.scale * 3), accuracy: 0.000_051)
        var landscape = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 874, height: 402), mode: .fill,
                                          safeInsets: ViewportInsets(left: 62, bottom: 21, right: 62))
        landscape.baselineFillCrop = true
        XCTAssertTrue(landscape.requestsWholeDisplay, "71 % of the display: the whole display, as before")
        var zoomedOut = portrait
        zoomedOut.setZoom(0.8, anchoredAt: CGPoint(x: 201, y: 437))
        XCTAssertFalse(zoomedOut.requestsWholeDisplay, "still under half on screen")
    }

    func testZoomedFillAsksForExactlyTheVisiblePartAtTheScreensPixels() throws {
        for device in devices {
            for display in displays {
                for zoom: CGFloat in [1.5, 2, 3] {
                    let context = "\(device.name) \(display) \(zoom)×"
                    var view = ViewportTransform(sourceSize: display, canvasSize: device.canvas, mode: .fill,
                                                 safeInsets: device.insets)
                    view.setZoom(zoom, anchoredAt: CGPoint(x: device.canvas.width * 0.37,
                                                           y: device.canvas.height * 0.61))
                    let content = view.contentRect
                    XCTAssertLessThanOrEqual(content.minX, 0, "zoomed Fill still covers the canvas, \(context)")
                    XCTAssertLessThanOrEqual(content.minY, 0, context)
                    XCTAssertGreaterThanOrEqual(content.maxX, device.canvas.width, context)
                    XCTAssertGreaterThanOrEqual(content.maxY, device.canvas.height, context)
                    let request = try XCTUnwrap(view.captureRequest(displayScale: device.displayScale), context)
                    XCTAssertFalse(view.requestsWholeDisplay, context)
                    let expected = CGRect(x: -content.minX / view.scale, y: -content.minY / view.scale,
                                          width: device.canvas.width / view.scale,
                                          height: device.canvas.height / view.scale)
                    assertRect(request.rect, expected, accuracy: 1 / ViewportTransform.captureQuantum + 1e-9, context)
                    XCTAssertTrue(CGRect(origin: .zero, size: display).contains(request.rect), context)
                    XCTAssertEqual(Double(request.pixelWidth), Double(device.canvas.width * device.displayScale),
                                   accuracy: 1, "a zoomed view asks for the screen's own pixels, \(context)")
                    XCTAssertEqual(Double(request.pixelHeight), Double(device.canvas.height * device.displayScale),
                                   accuracy: 1, context)
                    XCTAssertEqual(request.zoom, Double(view.scale * device.displayScale), accuracy: 0.000_051, context)
                    XCTAssertNoThrow(try request.region(epoch: 2).validate(), context)

                    let corner = CGPoint(x: device.canvas.width, y: device.canvas.height)
                    let topLeft = try XCTUnwrap(DirectTouchMapping.sourcePoint(for: .zero, in: view), context)
                    let bottomRight = try XCTUnwrap(DirectTouchMapping.sourcePoint(for: corner, in: view), context)
                    let tolerance = 2 / DirectTouchMapping.quantum
                    XCTAssertEqual(topLeft.x, request.rect.minX, accuracy: tolerance, "moveTo convention, \(context)")
                    XCTAssertEqual(topLeft.y, request.rect.minY, accuracy: tolerance, context)
                    XCTAssertEqual(bottomRight.x, request.rect.maxX, accuracy: tolerance, context)
                    XCTAssertEqual(bottomRight.y, request.rect.maxY, accuracy: tolerance, context)
                }
            }
        }
    }

    func testFitZoomedOnOneAxisKeepsTheOtherAxisWhole() throws {
        let device = devices[0]
        let display = CGSize(width: 1920, height: 1080)
        var view = ViewportTransform(sourceSize: display, canvasSize: device.canvas, mode: .fit,
                                     safeInsets: device.insets)
        let safe = safeRect(device)
        view.setZoom(2, anchoredAt: CGPoint(x: safe.midX, y: safe.midY))
        let scale = 2 * min(safe.width / display.width, safe.height / display.height)
        XCTAssertEqual(view.scale, scale, accuracy: 1e-12)
        XCTAssertLessThan(display.height * scale, device.canvas.height, "the picture is shorter than the screen")
        let request = try XCTUnwrap(view.captureRequest(displayScale: 3))
        XCTAssertEqual(request.rect.minY, 0)
        XCTAssertEqual(request.rect.height, 1080)
        XCTAssertEqual(request.rect.width, device.canvas.width / scale, accuracy: 1 / ViewportTransform.captureQuantum)
        XCTAssertEqual(request.rect.midX, 960, accuracy: 1 / ViewportTransform.captureQuantum)
        XCTAssertEqual(request.pixelWidth, 1206)
        XCTAssertEqual(Double(request.pixelHeight), Double(1080 * scale * 3), accuracy: 0.500_001)
    }

    func testPinchedFillBelowItsSizeAsksForTheWholeDisplayEvenWhileCropped() throws {
        let device = devices[1]
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: device.canvas, mode: .fill,
                                     safeInsets: device.insets)
        view.setZoom(0.8, anchoredAt: CGPoint(x: 437, y: 201))
        XCTAssertEqual(view.zoom, 0.8, accuracy: 1e-12)
        XCTAssertTrue(view.isCropped, "the display is still taller than the landscape screen")
        let request = try XCTUnwrap(view.captureRequest(displayScale: 3))
        XCTAssertEqual(request.rect, CGRect(origin: .zero, size: macBookAir))
        XCTAssertEqual(Double(request.pixelWidth), Double(macBookAir.width * view.scale * 3), accuracy: 0.500_001)
    }

    func testRotationAsksAgainForTheNewScreen() throws {
        let portrait = devices[0], landscape = devices[1]
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: portrait.canvas, mode: .fill,
                                     safeInsets: portrait.insets)
        let safe = safeRect(portrait)
        view.setZoom(2, anchoredAt: CGPoint(x: safe.midX, y: safe.midY))
        let tall = try XCTUnwrap(view.captureRequest(displayScale: 3))
        view.resize(sourceSize: macBookAir, canvasSize: landscape.canvas, safeInsets: landscape.insets)
        let wide = try XCTUnwrap(view.captureRequest(displayScale: 3))
        XCTAssertEqual(tall.rect.width / tall.rect.height, 402.0 / 874.0, accuracy: 0.01)
        XCTAssertEqual(wide.rect.width / wide.rect.height, 874.0 / 402.0, accuracy: 0.01)
        XCTAssertEqual(Double(tall.pixelWidth), 1206, accuracy: 1)
        XCTAssertEqual(Double(tall.pixelHeight), 2622, accuracy: 1)
        XCTAssertEqual(Double(wide.pixelWidth), 2622, accuracy: 1)
        XCTAssertEqual(Double(wide.pixelHeight), 1206, accuracy: 1)
        for request in [tall, wide] {
            XCTAssertTrue(CGRect(origin: .zero, size: macBookAir).contains(request.rect))
            XCTAssertNoThrow(try request.region(epoch: 3).validate())
        }
    }

    func testNoRequestWithoutADisplayACanvasOrAScale() {
        let screen = CGSize(width: 402, height: 874)
        XCTAssertNil(ViewportTransform(sourceSize: macBookAir, canvasSize: .zero).captureRequest(displayScale: 3))
        XCTAssertNil(ViewportTransform(sourceSize: .zero, canvasSize: screen).captureRequest(displayScale: 3))
        let view = ViewportTransform(sourceSize: macBookAir, canvasSize: screen)
        for scale: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertNil(view.captureRequest(displayScale: scale), "display scale \(scale)")
        }
        XCTAssertNotNil(view.captureRequest(displayScale: 3))
    }

    func testNonIntegerScalesStayInsideTheDisplayOnTheQuantum() throws {
        let display = CGSize(width: 1512.5, height: 982.25)
        for device in devices {
            for displayScale: CGFloat in [2, 2.608, 3, 3.0001] {
                for zoom: CGFloat in [1.37, 2.71] {
                    for mode in [ViewportMode.fit, .fill] {
                        let context = "\(device.name) \(mode) \(zoom)× @\(displayScale)"
                        var view = ViewportTransform(sourceSize: display, canvasSize: device.canvas, mode: mode,
                                                     safeInsets: device.insets)
                        view.setZoom(zoom, anchoredAt: CGPoint(x: device.canvas.width * 0.21 + 0.3,
                                                               y: device.canvas.height * 0.83 - 0.7))
                        let request = try XCTUnwrap(view.captureRequest(displayScale: displayScale), context)
                        XCTAssertTrue(CGRect(origin: .zero, size: display).contains(request.rect), context)
                        if !view.requestsWholeDisplay {
                            for edge in [request.rect.minX, request.rect.minY, request.rect.maxX, request.rect.maxY] {
                                let steps = edge * ViewportTransform.captureQuantum
                                XCTAssertEqual(steps, steps.rounded(), "1/64 pt steps, \(context)")
                            }
                        }
                        let pixelsPerPoint = Double(view.scale * displayScale)
                        XCTAssertEqual(Double(request.pixelWidth), Double(request.rect.width) * pixelsPerPoint,
                                       accuracy: 0.500_001, context)
                        XCTAssertEqual(Double(request.pixelHeight), Double(request.rect.height) * pixelsPerPoint,
                                       accuracy: 0.500_001, context)
                        XCTAssertEqual(request.zoom, pixelsPerPoint, accuracy: 0.000_051, context)
                        XCTAssertNoThrow(try request.region(epoch: 9).validate(), context)
                    }
                }
            }
        }
    }

    func testExtremeDisplaysStillMakeAValidRegion() throws {
        let screen = CGSize(width: 402, height: 874)
        var strip = ViewportTransform(sourceSize: CGSize(width: 20_000, height: 1_000), canvasSize: screen,
                                      mode: .fill)
        strip.baselineFillCrop = false
        let wide = try XCTUnwrap(strip.captureRequest(displayScale: 3))
        XCTAssertEqual(wide.pixelWidth, 16_384, "52,440 px is capped to the largest size the Mac accepts")
        XCTAssertEqual(wide.pixelHeight, 2_622)
        XCTAssertNoThrow(try wide.region(epoch: 1).validate())
        strip.baselineFillCrop = true
        let cropped = try XCTUnwrap(strip.captureRequest(displayScale: 3))
        XCTAssertFalse(strip.requestsWholeDisplay, "2 % of the strip is on screen")
        XCTAssertEqual(cropped.pixelWidth, 1_206, "its visible rect at the screen's pixels")
        XCTAssertNoThrow(try cropped.region(epoch: 1).validate())

        let huge = ViewportTransform(sourceSize: CGSize(width: 16_000, height: 9_000), canvasSize: screen, mode: .fit)
        let small = try XCTUnwrap(huge.captureRequest(displayScale: 1))
        XCTAssertEqual(small.zoom, ViewportRegion.zoomRange.lowerBound, "0.025 px per point is raised to the minimum")
        XCTAssertEqual(small.pixelWidth, 402)
        XCTAssertNoThrow(try small.region(epoch: 1).validate())
    }

    // MARK: Where the frames are drawn

    func testWholeDisplayCaptureKeepsTodaysPlacement() {
        let whole = CaptureRegion(epoch: 0, x: 100, y: 50, width: 10, height: 10, outputWidth: 64, outputHeight: 64)
        for device in devices {
            for mode in [ViewportMode.fit, .fill] {
                for zoom: CGFloat in [1, 2.2] {
                    var view = ViewportTransform(sourceSize: macBookAir, canvasSize: device.canvas, mode: mode,
                                                 safeInsets: device.insets)
                    view.setZoom(zoom, anchoredAt: CGPoint(x: device.canvas.width * 0.3,
                                                           y: device.canvas.height * 0.4))
                    let context = "\(device.name) \(mode) \(zoom)×"
                    let container = CGRect(origin: .zero, size: view.contentRect.size)
                    XCTAssertEqual(view.framePlacement(for: nil), view.contentRect, context)
                    XCTAssertEqual(view.framePlacement(for: whole), view.contentRect,
                                   "epoch 0 is the whole display whatever its rect says, \(context)")
                    XCTAssertEqual(view.picturePlacement(for: nil), container, context)
                    XCTAssertEqual(view.picturePlacement(for: whole), container, context)
                }
            }
        }
    }

    func testCroppedFramesLandWhereTheirRegionBelongs() {
        let device = devices[1]
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: device.canvas, mode: .fill,
                                     safeInsets: device.insets)
        view.setZoom(2.4, anchoredAt: CGPoint(x: 300.5, y: 180.25))
        let region = CaptureRegion(epoch: 12, x: 300.5, y: 120.25, width: 735, height: 478,
                                   outputWidth: 1784, outputHeight: 1161)
        let content = view.contentRect
        let scale = content.width / macBookAir.width
        let expected = CGRect(x: content.minX + 300.5 * scale, y: content.minY + 120.25 * scale,
                              width: 735 * scale, height: 478 * scale)
        assertRect(view.framePlacement(for: region), expected, accuracy: 1e-9, "on the canvas")
        assertRect(view.picturePlacement(for: region), expected.offsetBy(dx: -content.minX, dy: -content.minY),
                   accuracy: 1e-9, "in the picture container")
        assertRect(view.viewRect(fromSource: region.rect), expected, accuracy: 1e-9, "viewRect")
        assertRect(view.sourceRect(fromView: expected), region.rect, accuracy: 1e-9, "round trip")

        let full = CaptureRegion(epoch: 3, x: 0, y: 0, width: 1470, height: 956, outputWidth: 2622, outputHeight: 1705)
        assertRect(view.framePlacement(for: full), content, accuracy: 1e-9, "a whole-display region with an epoch")
        XCTAssertEqual(view.viewRect(fromSource: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)), .zero)
        XCTAssertEqual(view.sourceRect(fromView: CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1)), .zero)
    }

    func testTheMacPointUnderAFingerIsTheOneTheFrameShowsThere() {
        let fractions = [
            CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.5),
            CGRect(x: 0.6, y: 0.55, width: 0.4, height: 0.45),
            CGRect(x: -0.02, y: -0.03, width: 0.4, height: 0.3),
            CGRect(x: 0.1, y: 0.1, width: 0.001, height: 0.001),
            CGRect(x: 0, y: 0, width: 1, height: 1)
        ]
        let output = CGSize(width: 1784, height: 1161)
        let display = macBookAir
        for device in devices {
            for mode in [ViewportMode.fit, .fill] {
                for zoom: CGFloat in [1, 2.5] {
                    var view = ViewportTransform(sourceSize: display, canvasSize: device.canvas, mode: mode,
                                                 safeInsets: device.insets)
                    view.setZoom(zoom, anchoredAt: CGPoint(x: device.canvas.width * 0.45,
                                                           y: device.canvas.height * 0.55))
                    for fraction in fractions {
                        let rect = CGRect(x: fraction.minX * display.width, y: fraction.minY * display.height,
                                          width: fraction.width * display.width,
                                          height: fraction.height * display.height)
                        let region = CaptureRegion(epoch: 21, x: Double(rect.minX), y: Double(rect.minY),
                                                   width: Double(rect.width), height: Double(rect.height),
                                                   outputWidth: Int(output.width), outputHeight: Int(output.height))
                        let context = "\(device.name) \(mode) \(zoom)× region \(fraction)"
                        let frame = view.framePlacement(for: region)
                        let shown = frame.intersection(CGRect(origin: .zero, size: device.canvas))
                        guard !shown.isNull, shown.width > 0, shown.height > 0 else { continue }
                        for i in 0...8 {
                            for j in 0...8 {
                                let touch = CGPoint(x: shown.minX + shown.width * CGFloat(i) / 8,
                                                    y: shown.minY + shown.height * CGFloat(j) / 8)
                                // The frame is stretched over its placement, so this pixel is under the finger…
                                let pixel = CGPoint(x: (touch.x - frame.minX) / frame.width * output.width,
                                                    y: (touch.y - frame.minY) / frame.height * output.height)
                                // …and it shows this Mac point.
                                let shows = CGPoint(x: rect.minX + pixel.x / output.width * rect.width,
                                                    y: rect.minY + pixel.y / output.height * rect.height)
                                let inside = shows.x > 1e-6 && shows.x < display.width - 1e-6
                                    && shows.y > 1e-6 && shows.y < display.height - 1e-6
                                guard let hit = DirectTouchMapping.sourcePoint(for: touch, in: view) else {
                                    XCTAssertFalse(inside, "a touch on the Mac picture must land, \(context) \(touch)")
                                    continue
                                }
                                let tolerance = 1 / DirectTouchMapping.quantum + 1e-6
                                XCTAssertEqual(hit.x, shows.x, accuracy: tolerance, "\(context) \(touch)")
                                XCTAssertEqual(hit.y, shows.y, accuracy: tolerance, "\(context) \(touch)")
                                let pointer = view.viewPoint(fromSource: shows)
                                XCTAssertEqual(pointer.x, touch.x, accuracy: 1e-6, "pointer under finger, \(context)")
                                XCTAssertEqual(pointer.y, touch.y, accuracy: 1e-6, "pointer under finger, \(context)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testAnOldFrameMovesWithThePanUntilTheMacEchoesAnother() throws {
        let device = devices[1]
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: device.canvas, mode: .fill,
                                     safeInsets: device.insets)
        view.setZoom(2, anchoredAt: CGPoint(x: 437, y: 201))
        let asked = try XCTUnwrap(view.captureRequest(displayScale: 3))
        let margin: CGFloat = 40
        let echoed = CaptureRegion(epoch: 1, x: Double(asked.rect.minX - margin), y: Double(asked.rect.minY - margin),
                                   width: Double(asked.rect.width + 2 * margin),
                                   height: Double(asked.rect.height + 2 * margin),
                                   outputWidth: 2862, outputHeight: 1446)
        let before = view.framePlacement(for: echoed)
        let offset = view.offset
        view.pan(by: CGSize(width: -60, height: 25))
        XCTAssertEqual(view.offset.x - offset.x, -60, accuracy: 1e-9)
        XCTAssertEqual(view.offset.y - offset.y, 25, accuracy: 1e-9)
        let after = view.framePlacement(for: echoed)
        XCTAssertEqual(after.minX, before.minX - 60, accuracy: 1e-9, "the frame moves with the picture")
        XCTAssertEqual(after.minY, before.minY + 25, accuracy: 1e-9)
        XCTAssertEqual(after.width, before.width, accuracy: 1e-9)
        XCTAssertEqual(after.height, before.height, accuracy: 1e-9)
        let asking = try XCTUnwrap(view.captureRequest(displayScale: 3))
        XCTAssertNotEqual(asking.rect, asked.rect, "the phone now asks for another region")
        XCTAssertNotEqual(after, view.viewRect(fromSource: asking.rect), "but frames stay on the region they show")
    }

    func testPlacementFollowsTheEchoedRectWhateverItsEpoch() {
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: devices[2].canvas, mode: .fill,
                                     safeInsets: devices[2].insets)
        view.setZoom(1.9, anchoredAt: CGPoint(x: 400, y: 600))
        let older = CaptureRegion(epoch: 5, x: 100, y: 80, width: 600, height: 400,
                                  outputWidth: 1800, outputHeight: 1200)
        var newer = older
        newer.epoch = 9
        XCTAssertEqual(view.framePlacement(for: older), view.framePlacement(for: newer))
        var moved = older
        moved.x = 140
        XCTAssertEqual(view.framePlacement(for: moved).minX - view.framePlacement(for: older).minX, 40 * view.scale,
                       accuracy: 1e-9)
        var whole = older
        whole.epoch = 0
        XCTAssertEqual(view.framePlacement(for: whole), view.contentRect)
    }

    func testRegionEdgesLandExactlyOnThePictureEdges() {
        let display = CGSize(width: 1512.5, height: 982.25)
        for device in devices {
            var view = ViewportTransform(sourceSize: display, canvasSize: device.canvas, mode: .fill,
                                         safeInsets: device.insets)
            view.setZoom(1.73, anchoredAt: CGPoint(x: device.canvas.width * 0.6, y: device.canvas.height * 0.3))
            let content = view.contentRect
            let corner = CaptureRegion(epoch: 4, x: 1512.5 - 100.25, y: 982.25 - 50.5, width: 100.25, height: 50.5,
                                       outputWidth: 301, outputHeight: 152)
            let placed = view.framePlacement(for: corner)
            XCTAssertEqual(placed.maxX, content.maxX, accuracy: 1e-9, device.name)
            XCTAssertEqual(placed.maxY, content.maxY, accuracy: 1e-9, device.name)
            let origin = CaptureRegion(epoch: 4, x: 0, y: 0, width: 1, height: 1, outputWidth: 3, outputHeight: 3)
            XCTAssertEqual(view.framePlacement(for: origin).origin, content.origin, device.name)
            XCTAssertEqual(view.framePlacement(for: origin).width, view.scale, accuracy: 1e-12, "one point, one scale")
        }
    }

    func testMiniMapPlacementScalesEachAxisOnItsOwn() {
        let map = CGRect(x: 0, y: 0, width: 150, height: 97.5)
        let rect = CGRect(x: 367.5, y: 239, width: 735, height: 478)
        let placed = ViewportTransform.placement(of: rect, displaySize: macBookAir, in: map)
        XCTAssertEqual(placed.minX, 37.5, accuracy: 1e-9)
        XCTAssertEqual(placed.width, 75, accuracy: 1e-9)
        XCTAssertEqual(placed.minY, 239 * 97.5 / 956, accuracy: 1e-9)
        XCTAssertEqual(placed.height, 478 * 97.5 / 956, accuracy: 1e-9)
        XCTAssertEqual(ViewportTransform.placement(of: rect, displaySize: .zero, in: map), .zero)
        XCTAssertEqual(ViewportTransform.placement(of: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                                                   displaySize: macBookAir, in: map), .zero)
    }

    // MARK: Helpers

    private func safeRect(_ device: Device) -> CGRect {
        CGRect(x: device.insets.left, y: device.insets.top,
               width: device.canvas.width - device.insets.left - device.insets.right,
               height: device.canvas.height - device.insets.top - device.insets.bottom)
    }

    private func assertRect(_ rect: CGRect, _ expected: CGRect, accuracy: CGFloat, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, "\(context) minX", file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, "\(context) minY", file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, "\(context) width", file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, "\(context) height", file: file, line: line)
    }
}
