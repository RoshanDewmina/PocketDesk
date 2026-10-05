import CoreImage
import Vision
import WebRTC

/// Copies pixels once, while the presenter owns the exact admitted frame. The returned CGImage
/// is eagerly rendered and owns no decoder buffer. Vision receives only this bounded copy.
enum FrozenTextSnapshot {
    static let maximumPixels: CGFloat = 4_000_000
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func normalizedCrop(visible: CGRect, placement: CGRect) -> CGRect? {
        guard placement.width > 0, placement.height > 0,
              [visible.minX, visible.minY, visible.width, visible.height, placement.minX, placement.minY, placement.width, placement.height].allSatisfy(\.isFinite) else { return nil }
        let area = visible.intersection(placement)
        guard !area.isNull, !area.isEmpty else { return nil }
        return CGRect(x: (area.minX-placement.minX)/placement.width, y: (area.minY-placement.minY)/placement.height,
                      width: area.width/placement.width, height: area.height/placement.height)
    }
    static func copy(_ frame: RTCVideoFrame, crop: CGRect) -> CGImage? {
        guard let buffer = frame.buffer as? RTCCVPixelBuffer,
              [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              crop.minX >= 0, crop.minY >= 0, crop.maxX <= 1, crop.maxY <= 1, !crop.isEmpty else { return nil }
        let width = CVPixelBufferGetWidth(buffer.pixelBuffer), height = CVPixelBufferGetHeight(buffer.pixelBuffer)
        let visible = CGRect(x: Int(buffer.cropX), y: Int(buffer.cropY), width: Int(buffer.cropWidth), height: Int(buffer.cropHeight))
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              visible.minX >= 0, visible.minY >= 0, visible.maxX <= CGFloat(width), visible.maxY <= CGFloat(height), !visible.isEmpty else { return nil }
        let native = CGRect(x: visible.minX, y: CGFloat(height)-visible.maxY, width: visible.width, height: visible.height)
        var image = CIImage(cvPixelBuffer: buffer.pixelBuffer).cropped(to: native)
            .transformed(by: CGAffineTransform(translationX: -native.minX, y: -native.minY))
        switch frame.rotation.rawValue {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        let extent = image.extent
        let area = CGRect(x: extent.minX + crop.minX*extent.width, y: extent.minY + (1-crop.maxY)*extent.height,
                          width: crop.width*extent.width, height: crop.height*extent.height)
        image = image.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
        let scale = min(1, sqrt(maximumPixels / max(1, area.width*area.height)))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: floor(area.width*scale), height: floor(area.height*scale))
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        return context.createCGImage(image, from: bounds, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).sorted { a, b in
            if abs(a.boundingBox.midY-b.boundingBox.midY) > 0.015 { return a.boundingBox.midY > b.boundingBox.midY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return String(lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(65_536))
    }
}
