import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox
import WebRTC

/// A decoded WebRTC frame as smooth motion reads it: zero-copy for the hardware decoder's
/// `RTCCVPixelBuffer`, or the planar I420 of a software decode, which is converted to NV12 on
/// the interpolator's queue only when a pair is actually processed.
struct SmoothMotionSource {
    enum Pixels {
        case pixelBuffer(CVPixelBuffer)
        case i420(RTCI420BufferProtocol)
    }

    let pixels: Pixels
    /// Picture area inside the buffer in its own pixels (WebRTC's crop), top-left origin.
    let crop: CGRect
    /// The buffer size the interpolator would see before any fitting.
    let geometry: FrameGeometry
    let rotation: RTCVideoRotation

    static let convertedFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    init?(_ frame: RTCVideoFrame) {
        rotation = frame.rotation
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let pixelBuffer = buffer.pixelBuffer
            pixels = .pixelBuffer(pixelBuffer)
            geometry = FrameGeometry(pixelBuffer)
            crop = CGRect(x: Int(buffer.cropX), y: Int(buffer.cropY), width: Int(buffer.cropWidth), height: Int(buffer.cropHeight))
        } else if let planar = frame.buffer as? RTCI420BufferProtocol {
            pixels = .i420(planar)
            geometry = FrameGeometry(width: Int(planar.width), height: Int(planar.height), pixelFormat: Self.convertedFormat)
            crop = CGRect(x: 0, y: 0, width: Int(planar.width), height: Int(planar.height))
        } else {
            return nil
        }
        guard geometry.width > 0, geometry.height > 0 else { return nil }
    }

    /// The luma plane for the motion sampler, read in place.
    func withLuma<T>(_ body: (UnsafePointer<UInt8>, Int, Int, Int) -> T?) -> T? {
        switch pixels {
        case .pixelBuffer(let buffer):
            guard DecodedLuma.formats.contains(CVPixelBufferGetPixelFormatType(buffer)),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            return body(base.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetWidthOfPlane(buffer, 0),
                        CVPixelBufferGetHeightOfPlane(buffer, 0), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        case .i420(let planar):
            return body(planar.dataY, Int(planar.width), Int(planar.height), Int(planar.strideY))
        }
    }
}

/// What the interpolator is given for a source of one geometry: the input it runs at, whether
/// that is a fitted copy, and the spatial scale. Pure, so the choice is testable.
struct InterpolationPlan: Equatable {
    let setup: InterpolationSetup
    /// The input is a scaled copy of the decoded frame, so the source frame is shown from it too
    /// (alternating a sharp source with a softer midpoint would shimmer on text).
    let fitted: Bool

    /// `upscale` asks for the 2× A/B: the source is halved and the processor scales it back up
    /// in the same pass. Nil when nothing usable fits.
    static func make(for source: FrameGeometry, limits: InterpolationLimits,
                     upscaleLimits: InterpolationLimits?, upscale: Bool, fitOversize: Bool) -> InterpolationPlan? {
        if upscale, let upscaleLimits {
            let half = (width: max(2, (source.width / 2) & ~1), height: max(2, (source.height / 2) & ~1))
            let size = upscaleLimits.fits(width: half.width, height: half.height)
                ? half : upscaleLimits.fitted(width: half.width, height: half.height)
            return InterpolationPlan(setup: InterpolationSetup(
                input: FrameGeometry(width: size.width, height: size.height, pixelFormat: source.pixelFormat), scale: 2),
                fitted: true)
        }
        if limits.fits(width: source.width, height: source.height) {
            return InterpolationPlan(setup: InterpolationSetup(input: source), fitted: false)
        }
        guard fitOversize else { return nil }
        let size = limits.fitted(width: source.width, height: source.height)
        return InterpolationPlan(setup: InterpolationSetup(
            input: FrameGeometry(width: size.width, height: size.height, pixelFormat: source.pixelFormat)), fitted: true)
    }
}

/// Makes the interpolator's input on its queue: I420 to NV12, and scaling to a fitted size with
/// a VTPixelTransferSession. Buffers come from pools rebuilt on any geometry change, so a pool
/// never hands out a buffer of the previous size. Queue-confined.
final class SmoothMotionInputPreparer {
    private var transfer: VTPixelTransferSession?
    private var pools: [FrameGeometry: CVPixelBufferPool] = [:]

    func input(for source: SmoothMotionSource, setup: InterpolationSetup) -> CVPixelBuffer? {
        let target = setup.input
        switch source.pixels {
        case .pixelBuffer(let buffer):
            if target.matches(buffer) { return buffer }
            return scaled(buffer, to: target)
        case .i420(let planar):
            let full = FrameGeometry(width: Int(planar.width), height: Int(planar.height), pixelFormat: target.pixelFormat)
            guard let converted = convert(planar, to: full) else { return nil }
            return full == target ? converted : scaled(converted, to: target)
        }
    }

    func reset() {
        pools.removeAll()
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
    }

    private func buffer(_ geometry: FrameGeometry) -> CVPixelBuffer? {
        if pools.count > 3 { pools.removeAll() }
        let pool = pools[geometry] ?? {
            var made: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: geometry.width,
                kCVPixelBufferHeightKey as String: geometry.height,
                kCVPixelBufferPixelFormatTypeKey as String: geometry.pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                    attributes as CFDictionary, &made)
            return made
        }()
        guard let pool else { return nil }
        pools[geometry] = pool
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
              let result = created, geometry.matches(result) else { return nil }
        return result
    }

    private func scaled(_ source: CVPixelBuffer, to target: FrameGeometry) -> CVPixelBuffer? {
        if transfer == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
                  let session else { return nil }
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            transfer = session
        }
        guard let transfer, let destination = buffer(target),
              VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else { return nil }
        return destination
    }

    private func convert(_ planar: RTCI420BufferProtocol, to geometry: FrameGeometry) -> CVPixelBuffer? {
        guard let destination = buffer(geometry),
              CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(destination, 0)?.assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(destination, 1)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let width = Int(planar.width), height = Int(planar.height)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        for row in 0..<height {
            (luma + row * lumaStride).update(from: planar.dataY + row * Int(planar.strideY), count: width)
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        let chromaWidth = Int(planar.chromaWidth), chromaHeight = Int(planar.chromaHeight)
        for row in 0..<chromaHeight {
            let u = planar.dataU + row * Int(planar.strideU)
            let v = planar.dataV + row * Int(planar.strideV)
            let line = chroma + row * chromaStride
            for column in 0..<chromaWidth {
                line[column * 2] = u[column]
                line[column * 2 + 1] = v[column]
            }
        }
        return destination
    }
}
