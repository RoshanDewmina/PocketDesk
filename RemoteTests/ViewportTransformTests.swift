import Foundation
import CoreGraphics
import XCTest

final class ViewportTransformTests: XCTestCase {
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
}
