import Foundation
import CoreGraphics
import XCTest

final class ViewportTransformTests: XCTestCase {
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
