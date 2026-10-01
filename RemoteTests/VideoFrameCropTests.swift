import XCTest
import CoreVideo
import WebRTC

final class VideoFrameCropTests: XCTestCase {
    private func frame(format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> RTCVideoFrame {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 128, 96, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels), adaptedWidth: 32, adaptedHeight: 24,
            cropWidth: 64, cropHeight: 48, cropX: 16, cropY: 8)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._90, timeStampNs: 123456)
        frame.timeStamp = 321
        return frame
    }
    func testDerivativePreservesBorrowedPixelsRotationTimestampAndExistingCrop() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange] {
            let source = try frame(format: format)
            let cropped = try XCTUnwrap(VideoFrameCrop.apply(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5), to: source))
            let buffer = try XCTUnwrap(cropped.buffer as? RTCCVPixelBuffer)
            XCTAssertTrue(buffer.pixelBuffer === (source.buffer as! RTCCVPixelBuffer).pixelBuffer)
            XCTAssertEqual(buffer.cropX, 32); XCTAssertEqual(buffer.cropY, 32)
            XCTAssertEqual(buffer.cropWidth, 32); XCTAssertEqual(buffer.cropHeight, 24)
            XCTAssertEqual(cropped.rotation, ._90); XCTAssertEqual(cropped.timeStampNs, 123456); XCTAssertEqual(cropped.timeStamp, 321)
        }
    }
    func testMalformedNormalizedCropCannotTrapOrExpandBeyondOriginalPixels() throws {
        let source = try frame()
        for crop in [CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0, width: 1.1, height: 1),
                     CGRect(x: 0, y: 0, width: 0, height: 1), CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1),
                     CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1)] { XCTAssertNil(VideoFrameCrop.apply(crop, to: source)) }
        let tiny = try XCTUnwrap(VideoFrameCrop.apply(CGRect(x: 0.99, y: 0.99, width: 0.01, height: 0.01), to: source).flatMap { $0.buffer as? RTCCVPixelBuffer })
        XCTAssertEqual(tiny.cropWidth, 2); XCTAssertEqual(tiny.cropHeight, 2)
        XCTAssertLessThanOrEqual(tiny.cropX + tiny.cropWidth, 80); XCTAssertLessThanOrEqual(tiny.cropY + tiny.cropHeight, 56)
    }
}
