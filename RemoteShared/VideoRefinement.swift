import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import CryptoKit

struct VideoRefinementIdentity: Codable, Equatable {
    let generation: String
    let geometryEpoch: UInt64
    let scopeEpoch: UInt64
    let content: String
    let width: Int, height: Int
    let x: Int, y: Int, roiWidth: Int, roiHeight: Int
    let transfer: String
    func validate() throws {
        guard InputCausalEnvelope.validID(generation), geometryEpoch > 0, scopeEpoch > 0,
              content.utf8.count == 64, content.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              width > 0, height > 0, width <= 4096, height <= 4096,
              x >= 0, y >= 0, roiWidth > 0, roiHeight > 0, roiWidth <= 512, roiHeight <= 512,
              x <= width - roiWidth, y <= height - roiHeight, ["srgb", "bt709"].contains(transfer)
        else { throw RemoteError.invalidMessage }
    }
}
struct VideoRefinementImage {
    let identity: VideoRefinementIdentity
    let png: Data
}

/// Copies only the center ROI from the exact adapted encoder input, never an unrestricted screenshot.
/// One 1 MiB owned copy; PNG work is asynchronous with one in-flight job and no pending backlog.
final class VideoRefinementProducer {
    private let queue = DispatchQueue(label: "farside.video.refinement-png", qos: .utility)
    private let lock = NSLock()
    private var working = false
    private var stable: VideoRefinementIdentity?
    private var stableAt: Double = 0
    private var offered: VideoRefinementIdentity?
    private var offeredAt = -Double.infinity
    private var cached: VideoRefinementImage?
    private var generation = UUID()
    private var ended = false
    func reset(terminal: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); ended = ended || terminal
        stable = nil; stableAt = 0; offered = nil; offeredAt = -.infinity; cached = nil
        // An already-running bounded job owns its copy until completion. Keep `working` true
        // until it finishes so retirement cannot admit a second concurrent copy/job.
    }
    #if DEBUG
    var beforeEncodeForTesting: (() -> Void)?
    var cachedBytesForTesting: Int { lock.lock(); defer { lock.unlock() }; return cached?.png.count ?? 0 }
    func drainForTesting() { queue.sync {} }
    #endif
    func inspect(_ buffer: CVPixelBuffer, tag: VideoFrameTag, at now: Double,
                 emit: @escaping (VideoRefinementImage) -> Void) -> VideoRefinementIdentity? {
        lock.lock(); let ticket = generation, terminal = ended; lock.unlock()
        guard !terminal else { return nil }
        guard now.isFinite, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
              primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
              let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
              transfer == kCVImageBufferTransferFunction_sRGB as String || transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String
        else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let rw = min(512, width), rh = min(512, height), x = (width - rw) / 2, y = (height - rh) / 2
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer) >= width * 4 else { return nil }
        let rowStride = CVPixelBufferGetBytesPerRow(buffer)
        var hash = SHA256()
        for row in 0..<rh {
            let view = Data(bytesNoCopy: base.advanced(by: (y + row) * rowStride + x * 4), count: rw * 4, deallocator: .none)
            guard stride(from: 3, to: view.count, by: 4).allSatisfy({ view[$0] == 255 }) else { return nil }
            hash.update(data: view)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let identity = VideoRefinementIdentity(generation: tag.generation, geometryEpoch: tag.geometryEpoch,
            scopeEpoch: tag.scopeEpoch, content: digest, width: width, height: height, x: x, y: y,
            roiWidth: rw, roiHeight: rh, transfer: transfer == kCVImageBufferTransferFunction_sRGB as String ? "srgb" : "bt709")
        lock.lock()
        guard !ended, generation == ticket else { lock.unlock(); return nil }
        if stable != identity { stable = identity; stableAt = now; offered = nil; cached = nil }
        let cachedImage = !working && cached?.identity == identity && now - offeredAt >= 1.5 ? cached : nil
        if cachedImage != nil { offeredAt = now; working = true }
        let shouldEncode = !working && cachedImage == nil && offered != identity && now >= stableAt && now - stableAt >= 0.5
        if shouldEncode { working = true; offered = identity; offeredAt = now }
        lock.unlock()
        if let cachedImage {
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let current = !self.ended && self.generation == ticket && self.stable == cachedImage.identity; self.lock.unlock()
                if current { emit(cachedImage) }
                self.lock.lock(); self.working = false; self.lock.unlock()
            }
        }
        if shouldEncode {
            var bytes = Data(count: rw * rh * 4)
            bytes.withUnsafeMutableBytes { destination in
                for row in 0..<rh { memcpy(destination.baseAddress!.advanced(by: row * rw * 4), base.advanced(by: (y + row) * rowStride + x * 4), rw * 4) }
            }
            queue.async { [weak self] in
                guard let self else { return }
                defer { self.lock.lock(); self.working = false; self.lock.unlock() }
                #if DEBUG
                self.beforeEncodeForTesting?()
                #endif
                self.lock.lock(); let admitted = !self.ended && self.generation == ticket && self.stable == identity; self.lock.unlock()
                guard admitted else { return }
                guard let png = VideoRefinementPNG.encode(bytes, identity: identity) else { return }
                let image = VideoRefinementImage(identity: identity, png: png)
                self.lock.lock(); let current = !self.ended && self.generation == ticket && self.stable == identity; if current { self.cached = image }; self.lock.unlock()
                if current { emit(image) }
            }
        }
        return identity
    }
}

enum VideoRefinementPNG {
    private final class BoundedPNGOutput { var bytes = Data() }
    static let maximumBytes = 256 * 1024
    static func encode(_ bytes: Data, identity: VideoRefinementIdentity) -> Data? {
        guard (try? identity.validate()) != nil, bytes.count == identity.roiWidth * identity.roiHeight * 4,
              let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: identity.transfer == "srgb" ? CGColorSpace.sRGB : CGColorSpace.itur_709),
              let image = CGImage(width: identity.roiWidth, height: identity.roiHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: identity.roiWidth * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let result = BoundedPNGOutput()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
            guard let info else { return 0 }
            let result = Unmanaged<BoundedPNGOutput>.fromOpaque(info).takeUnretainedValue()
            guard count <= VideoRefinementPNG.maximumBytes - result.bytes.count else { return 0 }
            result.bytes.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(result).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard withExtendedLifetime(result, { CGImageDestinationFinalize(destination) }), !result.bytes.isEmpty else { return nil }
        return result.bytes
    }
    static func decode(_ image: VideoRefinementImage) -> CVPixelBuffer? {
        guard (try? image.identity.validate()) != nil, image.png.count > 0, image.png.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(image.png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) == "public.png" as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == image.identity.roiWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == image.identity.roiHeight,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.identity.roiWidth, image.identity.roiHeight, kCVPixelFormatType_32BGRA,
              [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &result) == kCVReturnSuccess,
              let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let space = CGColorSpace(name: image.identity.transfer == "srgb" ? CGColorSpace.sRGB : CGColorSpace.itur_709),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(result), width: image.identity.roiWidth, height: image.identity.roiHeight,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(result), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: image.identity.roiWidth, height: image.identity.roiHeight))
        guard let base = CVPixelBufferGetBaseAddress(result) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(result)
        var hash = SHA256()
        for row in 0..<image.identity.roiHeight { hash.update(data: Data(bytes: base.advanced(by: row * stride), count: image.identity.roiWidth * 4)) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == image.identity.content else { return nil }
        return result
    }
}
