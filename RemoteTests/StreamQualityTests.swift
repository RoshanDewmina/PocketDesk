import XCTest
import CoreGraphics

final class StreamQualityTests: XCTestCase {
    func testRetinaSourceUsesPhysicalPixelsAndModeCap() {
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: size, pointPixelScale: 2,
                                                    quality: .balanced),
                       CapturePixelDimensions(width: 1920, height: 1080))
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: size, pointPixelScale: 2,
                                                    quality: .sharp),
                       CapturePixelDimensions(width: 2560, height: 1440))
    }

    func testSharperCapsLargeLandscapeAndPortraitSourcesAt2560WithoutChangingAspect() {
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: CGSize(width: 1842, height: 1192),
                                                    pointPixelScale: 2, quality: .sharp),
                       CapturePixelDimensions(width: 2560, height: 1656))
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: CGSize(width: 1200, height: 1800),
                                                    pointPixelScale: 2, quality: .sharp),
                       CapturePixelDimensions(width: 1706, height: 2560))
    }

    func testNeverUpscalesSmallerSourceAndPreservesPortraitRatio() {
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: CGSize(width: 1280, height: 720),
                                                    pointPixelScale: 1, quality: .sharp),
                       CapturePixelDimensions(width: 1280, height: 720))
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: CGSize(width: 1500, height: 2000),
                                                    pointPixelScale: 2, quality: .balanced),
                       CapturePixelDimensions(width: 1440, height: 1920))
    }

    func testOddSourceDimensionsRoundDownToEvenWithoutUpscaling() {
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: CGSize(width: 1000.5, height: 500.5),
                                                    pointPixelScale: 2, quality: .sharp),
                       CapturePixelDimensions(width: 2000, height: 1000))
        XCTAssertEqual(CapturePixelDimensions.fitted(contentSize: CGSize(width: 3001, height: 2001),
                                                    pointPixelScale: 1, quality: .balanced),
                       CapturePixelDimensions(width: 1920, height: 1280))
    }

    func testInvalidSourcesFailClosed() {
        for size in [CGSize.zero, CGSize(width: 0.5, height: 100),
                     CGSize(width: CGFloat.infinity, height: 100),
                     CGSize(width: -10, height: 100)] {
            XCTAssertNil(CapturePixelDimensions.fitted(contentSize: size, pointPixelScale: 2,
                                                       quality: .balanced))
        }
        for scale in [0.0, -1.0, .nan, .infinity] {
            XCTAssertNil(CapturePixelDimensions.fitted(contentSize: CGSize(width: 100, height: 100),
                                                       pointPixelScale: scale, quality: .sharp))
        }
    }
}
