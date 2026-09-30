import CoreVideo
import WebRTC

/// Local receipt IDs never stand for unique host captures. BenchMarker remains the unique-source evidence.
struct VideoFrameEnvelope {
    let receiptID: UUID
    let identity: VideoPresentationIdentity
    let frame: RTCVideoFrame
    let arrivalMs: Double
    let marker: BenchMarker?
    let originalSource: Bool

    struct Pixels {
        let buffer: CVPixelBuffer
        let crop: CGRect
        let conversion: VideoColorConversion?
        let bgra: Bool
        let transfer: VideoColorTransfer
    }

    var pixels: Pixels? {
        guard let cv = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let buffer = cv.pixelBuffer
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let crop = CGRect(x: Int(cv.cropX), y: Int(cv.cropY), width: Int(cv.cropWidth), height: Int(cv.cropHeight))
        guard VideoPixelGeometry(bufferSize: CGSize(width: width, height: height), crop: crop,
                                 rotation: Int(frame.rotation.rawValue)) != nil else { return nil }
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        // Do not guess transfer, primaries or matrix for unspecified/HDR/interpolated pool buffers.
        guard attachment(kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_709_2 as String else { return nil }
        let transfer: VideoColorTransfer
        if attachment(kCVImageBufferTransferFunctionKey) == (kCVImageBufferTransferFunction_ITU_R_709_2 as String) { transfer = .bt709 }
        else if attachment(kCVImageBufferTransferFunctionKey) == (kCVImageBufferTransferFunction_sRGB as String) { transfer = .srgb }
        else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA {
            return Pixels(buffer: buffer, crop: crop, conversion: nil, bgra: true, transfer: transfer)
        }
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              [width, height, Int(crop.minX), Int(crop.minY), Int(crop.width), Int(crop.height)].allSatisfy({ $0 % 2 == 0 }) else { return nil }
        let matrix: VideoColorMatrix
        let attachedMatrix = attachment(kCVImageBufferYCbCrMatrixKey)
        if attachedMatrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { matrix = .bt709 }
        else if attachedMatrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { matrix = .bt601 }
        else { return nil }
        return Pixels(buffer: buffer, crop: crop,
                      conversion: VideoColorConversion(matrix: matrix, fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), bgra: false, transfer: transfer)
    }
}
