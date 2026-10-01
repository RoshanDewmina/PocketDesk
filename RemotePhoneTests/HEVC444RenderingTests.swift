import XCTest
import CoreVideo
import WebRTC
@testable import PocketDeskRemote

final class HEVC444RenderingTests: XCTestCase {
    func testFullResolutionChromaUsesExactGeometryAndDeclaredRange() throws {
        for format in [kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange] {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let identity = VideoPresentationIdentity(hostRecordID: "record", ownerPairID: "grant", sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 1)
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._90, timeStampNs: 1)
            let envelope = VideoFrameEnvelope(receiptID: UUID(), identity: identity, frame: frame, arrivalMs: 1, marker: nil, originalSource: true)
            let rendered = try XCTUnwrap(envelope.pixels)
            XCTAssertEqual(CVPixelBufferGetWidthOfPlane(rendered.buffer, 1), 64)
            XCTAssertEqual(CVPixelBufferGetHeightOfPlane(rendered.buffer, 1), 64)
            XCTAssertFalse(rendered.bgra)
            XCTAssertNotNil(DecodedLuma(RTCCVPixelBuffer(pixelBuffer: buffer)), "Original luma marker metrics read plane zero without toI420 conversion")
            XCTAssertEqual(try XCTUnwrap(rendered.conversion).yOffset, format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange ? 0 : 16.0 / 255, accuracy: 0.00001)
            let cropped = RTCCVPixelBuffer(pixelBuffer: buffer, adaptedWidth: 16, adaptedHeight: 12,
                cropWidth: 32, cropHeight: 24, cropX: 8, cropY: 10)
            let compatibility = try XCTUnwrap(HEVC444PixelTransfer.compatibilityFrameBuffer(cropped))
            XCTAssertEqual(compatibility.width, 16); XCTAssertEqual(compatibility.height, 12)
            XCTAssertEqual(compatibility.cropX, 8); XCTAssertEqual(compatibility.cropY, 10)
            XCTAssertEqual(compatibility.cropWidth, 32); XCTAssertEqual(compatibility.cropHeight, 24)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(compatibility.pixelBuffer), kCVPixelFormatType_32BGRA)
            CVBufferRemoveAttachment(buffer, kCVImageBufferColorPrimariesKey)
            XCTAssertNil(envelope.pixels, "Missing color retains existing unknown-color fallback without a presentation receipt")
        }
    }
}
