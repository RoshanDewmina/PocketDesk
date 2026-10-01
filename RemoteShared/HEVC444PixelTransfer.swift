import CoreVideo
import VideoToolbox
import WebRTC

/// Only admitted BGRA carries original chroma. Never upsample a 4:2:0 frame and label it full color.
enum HEVC444PixelTransfer {
    static func scaledBGRA(_ source: RTCCVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let input = source.pixelBuffer
        let crop = CGRect(x: Int(source.cropX), y: Int(source.cropY), width: Int(source.cropWidth), height: Int(source.cropHeight))
        guard CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA,
              width > 0, height > 0, width <= 4096, height <= 4096,
              crop.minX >= 0, crop.minY >= 0, crop.width > 0, crop.height > 0,
              crop.maxX <= CGFloat(CVPixelBufferGetWidth(input)), crop.maxY <= CGFloat(CVPixelBufferGetHeight(input)),
              sdr(input) else { return nil }
        // Own the cropped source rather than mutating clean-aperture attachments on shared capture.
        guard let cropped = make(width: Int(crop.width), height: Int(crop.height), format: kCVPixelFormatType_32BGRA),
              CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        guard CVPixelBufferLockBaseAddress(cropped, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(cropped, []) }
        guard let src = CVPixelBufferGetBaseAddress(input), let dst = CVPixelBufferGetBaseAddress(cropped) else { return nil }
        for row in 0..<Int(crop.height) {
            memcpy(dst.advanced(by: row * CVPixelBufferGetBytesPerRow(cropped)),
                src.advanced(by: (Int(crop.minY) + row) * CVPixelBufferGetBytesPerRow(input) + Int(crop.minX) * 4), Int(crop.width) * 4)
        }
        if let attachments = CVBufferCopyAttachments(input, .shouldPropagate) { CVBufferSetAttachments(cropped, attachments, .shouldPropagate) }
        CVBufferRemoveAttachment(cropped, kCVImageBufferCleanApertureKey)
        if Int(crop.width) == width && Int(crop.height) == height { return cropped }
        return transfer(cropped, width: width, height: height, format: kCVPixelFormatType_32BGRA)
    }
    static func fullColor(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA, sdr(input) else { return nil }
        return transfer(input, width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input), format: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
    }
    static func compatibilityFrameBuffer(_ source: RTCCVPixelBuffer) -> RTCCVPixelBuffer? {
        guard source.width > 0, source.height > 0, source.cropX >= 0, source.cropY >= 0,
              source.cropWidth > 0, source.cropHeight > 0,
              Int(source.cropX) + Int(source.cropWidth) <= CVPixelBufferGetWidth(source.pixelBuffer),
              Int(source.cropY) + Int(source.cropHeight) <= CVPixelBufferGetHeight(source.pixelBuffer),
              let pixels = compatibilityBGRA(source.pixelBuffer) else { return nil }
        return RTCCVPixelBuffer(pixelBuffer: pixels, adaptedWidth: source.width, adaptedHeight: source.height,
            cropWidth: source.cropWidth, cropHeight: source.cropHeight, cropX: source.cropX, cropY: source.cropY)
    }
    static func compatibilityBGRA(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard isFullColor(input), sdr(input),
              CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String else { return nil }
        return transfer(input, width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input), format: kCVPixelFormatType_32BGRA)
    }
    static func isFullColor(_ pixels: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        return [kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange].contains(format) &&
            CVPixelBufferGetPlaneCount(pixels) == 2 && CVPixelBufferGetWidthOfPlane(pixels, 1) == CVPixelBufferGetWidth(pixels) &&
            CVPixelBufferGetHeightOfPlane(pixels, 1) == CVPixelBufferGetHeight(pixels)
    }
    private static func sdr(_ input: CVPixelBuffer) -> Bool {
        let primaries = CVBufferCopyAttachment(input, kCVImageBufferColorPrimariesKey, nil) as? String
        let transfer = CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil) as? String
        return primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String &&
            [kCVImageBufferTransferFunction_ITU_R_709_2 as String, kCVImageBufferTransferFunction_sRGB as String].contains(transfer ?? "")
    }
    private static func make(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output) == kCVReturnSuccess else { return nil }
        return output
    }
    private static func transfer(_ input: CVPixelBuffer, width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        guard let output = make(width: width, height: height, format: format) else { return nil }
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr, let transfer else { return nil }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        for (key, value) in [(kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal),
            (kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            guard VTSessionSetProperty(transfer, key: key, value: value) == noErr else { return nil }
        }
        guard VTPixelTransferSessionTransferImage(transfer, from: input, to: output) == noErr else { return nil }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return output
    }
}
