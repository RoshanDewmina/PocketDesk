import Foundation
import CoreVideo
import CoreImage
import CoreGraphics

/// Adds a footer outside captured content; never writes into a ScreenCaptureKit-owned buffer.
final class BrowserFrameMarker {
    private let context = CIContext(options: [.cacheIntermediates: false])
    static func crc32c(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0x82f63b78 : 0) } }
        return ~crc
    }
    static func bits(token: [UInt8]) -> [UInt8] {
        precondition(token.count == 16)
        let crc = crc32c([1] + token)
        let bytes: [UInt8] = [0x50,0x44,0x42,0x31,1] + token + [UInt8(crc >> 24),UInt8((crc >> 16) & 255),UInt8((crc >> 8) & 255),UInt8(crc & 255)]
        return bytes.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
    }
    func mark(_ source: CVPixelBuffer) throws -> (CVPixelBuffer, String) {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard width >= 88, width <= 4096, height <= 4096 else { throw RemoteError.invalidMessage }
        var target: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height + 48, kCVPixelFormatType_32BGRA, attributes, &target) == kCVReturnSuccess, let target else { throw RemoteError.invalidMessage }
        // Convert YUV capture at its original geometry, then copy scanlines. Drawing
        // into a taller Quartz context changes its origin and can flip/offset content.
        var content = source
        if CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_32BGRA {
            var converted: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &converted) == kCVReturnSuccess, let converted else { throw RemoteError.invalidMessage }
            context.render(CIImage(cvPixelBuffer: source), to: converted)
            content = converted
        }
        CVPixelBufferLockBaseAddress(content, .readOnly); defer { CVPixelBufferUnlockBaseAddress(content, .readOnly) }
        CVPixelBufferLockBaseAddress(target, []); defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let address = CVPixelBufferGetBaseAddress(target), let sourceAddress = CVPixelBufferGetBaseAddress(content) else { throw RemoteError.invalidMessage }
        for row in 0..<height {
            memcpy(address.advanced(by: row * CVPixelBufferGetBytesPerRow(target)), sourceAddress.advanced(by: row * CVPixelBufferGetBytesPerRow(content)), width * 4)
        }
        let tokenBytes = Array(try SecureRandom.bytes().prefix(16))
        let bits = Self.bits(token: tokenBytes)
        let base = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(target)
        for row in height..<(height + 48) {
            for col in 0..<width {
                let index = row * stride + col * 4
                var value: UInt8 = 0
                let mx = col - (width - 88) - 4, my = row - height - 4
                if mx >= 0, mx < 80, my >= 0, my < 40 { value = bits[(my / 4) * 20 + mx / 4] == 1 ? 255 : 0 }
                base[index] = value; base[index+1] = value; base[index+2] = value; base[index+3] = 255
            }
        }
        return (target, tokenBytes.map { String(format: "%02x", $0) }.joined())
    }
}
