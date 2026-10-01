import CoreGraphics
import CoreVideo
import WebRTC

/// A normalized derivative crop stays inside the actual decoded buffer's existing crop.
/// It borrows the same pixels; it does not decode, convert, infer authority or count a new source.
enum VideoFrameCrop {
    static func apply(_ crop: CGRect, to frame: RTCVideoFrame) -> RTCVideoFrame? {
        guard [crop.origin.x, crop.origin.y, crop.width, crop.height].allSatisfy({ $0.isFinite }),
              crop.minX >= 0, crop.minY >= 0, crop.width > 0, crop.height > 0,
              crop.maxX <= 1, crop.maxY <= 1,
              let buffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let width = CVPixelBufferGetWidth(buffer.pixelBuffer), height = CVPixelBufferGetHeight(buffer.pixelBuffer)
        let bx = Int(buffer.cropX), by = Int(buffer.cropY), bw = Int(buffer.cropWidth), bh = Int(buffer.cropHeight)
        guard width >= 2, height >= 2, width <= 4096, height <= 4096,
              bx >= 0, by >= 0, bw >= 2, bh >= 2, bx + bw <= width, by + bh <= height,
              [bx, by, bw, bh].allSatisfy({ $0 % 2 == 0 }) else { return nil }
        func even(_ value: CGFloat) -> Int { Int(value / 2) * 2 }
        let x = min(even(crop.minX * CGFloat(bw)), bw - 2)
        let y = min(even(crop.minY * CGFloat(bh)), bh - 2)
        let cw = min(max(2, even(crop.width * CGFloat(bw))), bw - x)
        let ch = min(max(2, even(crop.height * CGFloat(bh))), bh - y)
        let pixels = RTCCVPixelBuffer(pixelBuffer: buffer.pixelBuffer, adaptedWidth: Int32(cw), adaptedHeight: Int32(ch),
            cropWidth: Int32(cw), cropHeight: Int32(ch), cropX: Int32(bx + x), cropY: Int32(by + y))
        let result = RTCVideoFrame(buffer: pixels, rotation: frame.rotation, timeStampNs: frame.timeStampNs)
        result.timeStamp = frame.timeStamp
        return result
    }
}
