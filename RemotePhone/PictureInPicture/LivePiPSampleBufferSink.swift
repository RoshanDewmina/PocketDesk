import AVFoundation
import CoreImage
import ImageIO

/// One conversion plus one newest pending source. Pool threshold bounds retained output buffers to three.
final class LivePiPSampleBufferSink: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let fence: VideoPresentationFence
    private let identity: VideoPresentationIdentity
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Farside.pip.samples", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pending: VideoFrameEnvelope?
    private var working = false
    private var closed = false
    private var conversionEpoch = LivePiPConversionEpoch()
    func setEnabled(_ value: Bool) {
        lock.lock(); conversionEpoch.setEnabled(value); if !value { pending = nil }; lock.unlock()
    }
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var enqueueCount = 0
    var enqueued: Int { lock.lock(); defer { lock.unlock() }; return enqueueCount } // never presented FPS
    init(admission: VideoPresentationAdmission, fence: VideoPresentationFence) {
        identity = admission.identity; self.fence = fence
        layer.videoGravity = .resizeAspect
    }
    func offer(_ frame: VideoFrameEnvelope) {
        guard frame.originalSource, frame.identity == identity,
              fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, {}) != nil else { return }
        lock.lock()
        guard !closed, conversionEpoch.enabled else { lock.unlock(); return }
        pending = frame
        guard !working else { lock.unlock(); return }
        working = true; lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }
    func invalidate() {
        fence.invalidate()
        lock.lock(); closed = true; pending = nil; lock.unlock()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: {})
        queue.async { [weak self] in self?.pool = nil; self?.poolSize = .zero; self?.context.clearCaches() }
    }
    private func drain() {
        while true {
            lock.lock()
            guard !closed, let generation = conversionEpoch.ticket, let frame = pending else { working = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, {}) != nil,
                  layer.sampleBufferRenderer.isReadyForMoreMediaData,
                  let sample = makeSample(frame) else { continue }
            _ = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) {
                lock.lock(); defer { lock.unlock() }
                guard conversionEpoch.accepts(generation), !closed else { return }
                layer.sampleBufferRenderer.enqueue(sample)
                enqueueCount += 1
            }
        }
    }
    private func makeSample(_ frame: VideoFrameEnvelope) -> CMSampleBuffer? {
        guard let pixels = frame.pixels, let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        let h = CGFloat(CVPixelBufferGetHeight(pixels.buffer))
        let crop = CGRect(x: pixels.crop.minX, y: h - pixels.crop.maxY, width: pixels.crop.width, height: pixels.crop.height)
        let inputSpace = CGColorSpace(name: pixels.transfer == .srgb ? CGColorSpace.sRGB : CGColorSpace.itur_709)!
        var image = CIImage(cvPixelBuffer: pixels.buffer, options: [.colorSpace: inputSpace]).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let orientation: CGImagePropertyOrientation
        switch frame.frame.rotation.rawValue { case 90: orientation = .right; case 180: orientation = .down; case 270: orientation = .left; default: orientation = .up }
        image = image.oriented(orientation)
        let scale = min(1, 2048 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGSize(width: max(1, Int(image.extent.width)), height: max(1, Int(image.extent.height)))
        if poolSize != size {
            // A geometry change needs a new identity; never accumulate multiple output pools.
            guard pool == nil else { return nil }
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolSize = size
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &output) == kCVReturnSuccess,
              let output else { return nil }
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output,
              formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
