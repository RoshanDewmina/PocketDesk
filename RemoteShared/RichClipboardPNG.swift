import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

struct RichClipboardPNG {
    let data: Data
    let metadata: RichImageMetadata
    /// PNG properties queries can initialize a decoder. Bound the mandatory first IHDR
    /// directly before invoking ImageIO at all; ImageIO subsequently verifies the image.
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    static func preflightPNG(_ data: Data) throws {
        guard data.starts(with: pngSignature) else { return } // Explicitly selected other raster formats use ImageIO metadata checks.
        guard data.count >= 33 else { throw ClipboardStatus.invalid }
        let header = Array(data.prefix(33))
        func uint32(_ offset: Int) -> UInt32 {
            (UInt32(header[offset]) << 24) | (UInt32(header[offset + 1]) << 16)
                | (UInt32(header[offset + 2]) << 8) | UInt32(header[offset + 3])
        }
        guard uint32(8) == 13, Array(header[12..<16]) == [73, 72, 68, 82],
              header[26] == 0, header[27] == 0, header[28] <= 1 else { throw ClipboardStatus.invalid }
        let width = Int(uint32(16)), height = Int(uint32(20)), depth = header[24], color = header[25]
        let allowedDepth = [UInt8(0), 3].contains(color) ? [UInt8(1), 2, 4, 8].contains(depth) : depth == 8
        guard (1...RichClipboardLimits.dimension).contains(width), (1...RichClipboardLimits.dimension).contains(height),
              width <= RichClipboardLimits.pixels / height,
              width <= RichClipboardLimits.decodedBytes / 4 / height,
              [UInt8(0), 2, 3, 4, 6].contains(color), allowedDepth else { throw ClipboardStatus.tooLarge }
    }
    /// Metadata is checked before pixel allocation. Only one raster image is accepted. The
    /// transformed thumbnail normalizes orientation; encoding a new PNG strips source metadata.
    static func normalize(_ data: Data) throws -> RichClipboardPNG {
        guard !data.isEmpty, data.count <= RichClipboardLimits.encodedBytes else { throw ClipboardStatus.tooLarge }
        try preflightPNG(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int, (1...8).contains(depth),
              let model = properties[kCGImagePropertyColorModel] as? String, ["RGB", "Gray"].contains(model),
              (1...RichClipboardLimits.dimension).contains(width), (1...RichClipboardLimits.dimension).contains(height),
              width <= RichClipboardLimits.pixels / height else { throw ClipboardStatus.tooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= RichClipboardLimits.pixels / image.height,
              image.bytesPerRow <= RichClipboardLimits.decodedBytes / image.height else { throw ClipboardStatus.invalid }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw ClipboardStatus.invalid }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), result.length <= RichClipboardLimits.encodedBytes else { throw ClipboardStatus.tooLarge }
        let png = result as Data
        return RichClipboardPNG(data: png, metadata: RichImageMetadata(bytes: png.count, width: image.width, height: image.height, digest: ClipboardDigest.hex(png)))
    }
    static func validateIncoming(_ data: Data, expected: RichImageMetadata) throws -> RichClipboardPNG {
        try expected.validate()
        guard data.count == expected.bytes, data.starts(with: pngSignature), ClipboardDigest.hex(data) == expected.digest else { throw ClipboardStatus.invalid }
        try preflightPNG(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier else { throw ClipboardStatus.invalid }
        let value = try normalize(data)
        guard value.metadata.width == expected.width, value.metadata.height == expected.height else { throw ClipboardStatus.invalid }
        return value
    }
}

/// The bulk engine verifies SHA-256 before commit. Commit only validates bytes here; it never
/// mutates a pasteboard or persists a file. The endpoint performs a fresh, explicit clipboard commit.
final class RichClipboardSink: FileByteSink {
    private let lock = NSLock()
    private let expected: RichImageMetadata
    private var bytes = Data()
    private var verified: RichClipboardPNG?
    init(expected: RichImageMetadata) { self.expected = expected }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= expected.bytes - bytes.count else { throw FileTransferStatus.tooLarge }
        bytes.append(data)
    }
    func commit() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        verified = try RichClipboardPNG.validateIncoming(bytes, expected: expected)
        bytes = Data()
        return URL(string: "farside-rich://verified")! // Receipt token, never a filesystem path.
    }
    func take() -> RichClipboardPNG? { lock.lock(); defer { lock.unlock() }; defer { verified = nil }; return verified }
    func discard() { lock.lock(); defer { lock.unlock() }; bytes = Data(); verified = nil }
}
