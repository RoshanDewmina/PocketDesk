import UIKit
import XCTest
@testable import PocketDeskRemote

@MainActor
final class BackdropOverlayTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(UIColor.gray.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        return try XCTUnwrap(context.makeImage())
    }

    private func crop(_ epoch: UInt64, x: Double) -> CaptureRegion {
        CaptureRegion(epoch: epoch, x: x, y: 200, width: 600, height: 500, outputWidth: 1200, outputHeight: 1000)
    }

    private func coverage(_ region: CaptureRegion, scale: CGFloat) throws -> BackdropCoverage {
        try XCTUnwrap(BackdropComposite.coverage(bounds: CGRect(x: 0, y: 0, width: 1920 * scale, height: 1243 * scale),
            crisp: CGRect(x: region.x * scale, y: region.y * scale, width: region.width * scale, height: region.height * scale),
            visible: CGRect(x: region.x * scale, y: region.y * scale, width: 300, height: 400), cropped: true, featherPoints: 8))
    }

    func testTheBackdropIsBilinearAndAMovedCropFadesTheOldCoverageOutThenDropsIt() throws {
        let view = BackdropOverlayView(frame: .zero)
        let picture = try image(), scale: CGFloat = 1.5
        let first = crop(1, x: 300), second = crop(2, x: 700)
        view.apply(image: picture, coverage: try coverage(first, scale: scale), region: first, scale: scale, featherPoints: 8, at: 10)
        XCTAssertEqual(view.imageLayer.magnificationFilter, .linear)
        XCTAssertNotNil(view.imageLayer.contents)
        XCTAssertNotNil(view.imageLayer.mask)
        XCTAssertEqual(view.imageLayer.frame, CGRect(x: 450, y: 300, width: 300, height: 400), "only the visible part is drawn")
        XCTAssertEqual(view.imageLayer.contentsRect.minX, 450 / 2880, accuracy: 0.0001)
        XCTAssertEqual(view.imageLayer.contentsRect.height, 400 / 1864.5, accuracy: 0.0001)
        XCTAssertTrue(view.fadingMasks.isEmpty, "entering a crop fades nothing")

        view.apply(image: picture, coverage: try coverage(second, scale: scale), region: second, scale: scale, featherPoints: 8, at: 10.05)
        XCTAssertEqual(view.fadingMasks.count, 1)
        let fading = try XCTUnwrap(view.fadingMasks.first)
        XCTAssertEqual(fading.entry.region, first)
        XCTAssertEqual(fading.layer.opacity, 0, "the model value is the end of the fade")
        XCTAssertEqual(fading.layer.animation(forKey: "fade")?.duration, BackdropFade.duration)

        view.apply(image: picture, coverage: try coverage(second, scale: scale), region: second, scale: scale, featherPoints: 8, at: 10.1)
        XCTAssertEqual(view.fadingMasks.count, 1, "still fading")
        view.apply(image: picture, coverage: try coverage(second, scale: scale), region: second, scale: scale, featherPoints: 8, at: 10.25)
        XCTAssertTrue(view.fadingMasks.isEmpty)
        XCTAssertNil(fading.layer.superlayer)
    }
}
