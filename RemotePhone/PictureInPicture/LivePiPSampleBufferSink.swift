import AVFoundation
import CoreImage
import ImageIO
import UIKit
import os

/// One conversion plus one newest pending source. Pool threshold bounds retained output buffers to three.
final class LivePiPSampleBufferSink: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let fence: VideoPresentationFence
    private let identity: VideoPresentationIdentity
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Farside.pip.samples", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// iOS refuses a background app's GPU work (Metal "notPermitted"), so a GPU CIContext render in background
    /// PiP silently leaves the output unchanged and the window freezes (1 Oct 15:3x). Render on the CPU there.
    private lazy var softwareContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private var background = false
    private var observers: [NSObjectProtocol] = []
    /// Decoded 4:2:0 or BGRA frames with no crop or rotation go to the layer as they are: no per-frame conversion
    /// (CPU in the background cost a core and made PiP jittery, device 1 Oct 18:1x). Kill switch, no UI:
    /// `farsidePiPConvertFrames` YES restores the Core Image conversion for every frame.
    static let convertFramesKey = "farsidePiPConvertFrames"
    private let directFrames = !UserDefaults.standard.bool(forKey: LivePiPSampleBufferSink.convertFramesKey)
    private static let log = Logger(subsystem: "com.roshan.PocketDesk", category: "pip")
    private var cadence = (since: 0.0, last: 0.0, frames: 0, maxGap: 0.0, direct: 0)
    private(set) var directCount = 0
    var rendersInSoftware: Bool { lock.lock(); defer { lock.unlock() }; return background }
    func setBackground(_ value: Bool) { lock.lock(); background = value; lock.unlock() }
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
    private let center: NotificationCenter
    init(admission: VideoPresentationAdmission, fence: VideoPresentationFence, center: NotificationCenter = .default) {
        self.center = center
        identity = admission.identity; self.fence = fence
        layer.videoGravity = .resizeAspect
        if Thread.isMainThread { background = MainActor.assumeIsolated { UIApplication.shared.applicationState == .background } }
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.setBackground(true) },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in self?.setBackground(false) }
        ]
    }
    deinit { observers.forEach(center.removeObserver) }
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
        queue.async { [weak self] in
            self?.pool = nil; self?.poolSize = .zero; self?.context.clearCaches(); self?.softwareContext.clearCaches()
        }
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
                noteCadence()
            }
        }
    }
    /// Lock held. One line every 5 s while frames flow: enqueue rate, worst gap and path, for device reports.
    private func noteCadence() {
        let now = ProcessInfo.processInfo.systemUptime
        if cadence.frames == 0 { cadence.since = now } else { cadence.maxGap = max(cadence.maxGap, now - cadence.last) }
        cadence.last = now; cadence.frames += 1
        guard now - cadence.since >= 5 else { return }
        let fps = Double(cadence.frames - 1) / (now - cadence.since)
        Self.log.info("pip enqueue fps=\(fps, format: .fixed(precision: 1), privacy: .public) maxGapMs=\(Int(self.cadence.maxGap * 1000), privacy: .public) direct=\(self.cadence.direct, privacy: .public)/\(self.cadence.frames, privacy: .public) background=\(self.background, privacy: .public)")
        cadence = (0, 0, 0, 0, 0)
    }

    static func displaysDirectly(_ pixels: VideoFrameEnvelope.Pixels, rotation: Int) -> Bool {
        let buffer = pixels.buffer
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return rotation == 0 && CVPixelBufferGetIOSurface(buffer) != nil
            && [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_32BGRA].contains(format)
            && pixels.crop == CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    private func makeSample(_ frame: VideoFrameEnvelope) -> CMSampleBuffer? {
        guard let pixels = frame.pixels, let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        if directFrames, Self.displaysDirectly(pixels, rotation: Int(frame.frame.rotation.rawValue)),
           let sample = sampleBuffer(for: pixels.buffer) {
            lock.lock(); cadence.direct += 1; directCount += 1; lock.unlock()
            return sample
        }
        let h = CGFloat(CVPixelBufferGetHeight(pixels.buffer))
        let crop = CGRect(x: pixels.crop.minX, y: h - pixels.crop.maxY, width: pixels.crop.width, height: pixels.crop.height)
        let inputSpace = CGColorSpace(name: pixels.transfer == .srgb ? CGColorSpace.sRGB : CGColorSpace.itur_709)!
        var image = CIImage(cvPixelBuffer: pixels.buffer, options: [.colorSpace: inputSpace]).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let orientation: CGImagePropertyOrientation
        switch frame.frame.rotation.rawValue { case 90: orientation = .right; case 180: orientation = .down; case 270: orientation = .left; default: orientation = .up }
        image = image.oriented(orientation)
        lock.lock(); let software = background; lock.unlock()
        // The CPU path costs per pixel; the PiP window is small, so cap its output lower.
        let scale = min(1, (software ? 1280 : 2048) / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGSize(width: max(1, Int(image.extent.width)), height: max(1, Int(image.extent.height)))
        if poolSize != size {
            // The Mac's ladder resizes the stream within one identity (1 Oct: 1920x1232 <-> 2560x1656 during a PiP
            // session). Returning nil here froze the PiP for good. Replace the pool; buffers the layer holds stay valid.
            pool = nil; poolSize = .zero
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
        (software ? softwareContext : context).render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return sampleBuffer(for: output)
    }

    private func sampleBuffer(for output: CVPixelBuffer) -> CMSampleBuffer? {
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
