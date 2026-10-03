import MetalKit
import WebRTC
import os

/// Public drawable ownership. The fallback is public WebRTC rendering with timing unavailable.
final class OwnedMetalVideoView: UIView, MTKViewDelegate {
    let metal: MTKView
    let fence: VideoPresentationFence
    let identity: VideoPresentationIdentity
    let mailbox = NewestFrameMailbox<VideoFrameEnvelope>()
    var counters: StreamCounters?
    var beforeDraw: ((MTKView) -> Void)?
    /// Main thread, after each fenced draw that acquired a drawable: the envelope just encoded for
    /// presentation (b7-scroll). The model places the picture by this frame's own capture region.
    var onFrameDrawn: ((VideoFrameEnvelope) -> Void)?
    private var drawnEnvelope: VideoFrameEnvelope?
    var fillsFrame = false
    var videoFeedback: VideoFeedbackContext?
    /// Only an actual original source drawable presentation may report this receipt.
    /// Consumers enqueue owner-validated work; they must not synchronously hop to main.
    private var originalSourcePresented: ((VideoPresentationIdentity, UUID) -> Void)?
    var onOriginalSourcePresented: ((VideoPresentationIdentity, UUID) -> Void)? {
        get { fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) { originalSourcePresented } ?? nil }
        set { _ = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) { originalSourcePresented = newValue } }
    }
    private let commandQueue: MTLCommandQueue?
    private var cache: CVMetalTextureCache?
    private var pipelines: [Bool: MTLRenderPipelineState] = [:]
    private let precompiledShaders: Bool
    private var backingPolicy: OwnedVideoBackingPolicy
    weak var renderDiagnostics: SmoothMotionDiagnostics? {
        didSet {
            guard let renderDiagnostics, renderDiagnostics !== oldValue else { return }
            // First direct-source prompt draws precede the scheduled motion tick that attaches
            // diagnostics. Preserve their waits/fallbacks rather than hiding first-picture work.
            renderDiagnostics.adoptDrawableWaits(drawableWaits, fallbackCreations: fallbackCreationCount)
        }
    }
    private var drawableWaits = SampleRing(capacity: 1024)
    private var lastDrawableLog: TimeInterval = 0
    private(set) var fallbackCreationCount = 0
    private static let renderLogger = Logger(subsystem: "com.roshan.PocketDesk", category: "phone-render")
    private var fallback: RTCMTLVideoView?
    private let wakeLock = NSLock()
    private var wakeScheduled = false
    // Internal A/B controls, read once for this immutable renderer registration.
    private let unfencedPreparation: Bool
    private let immediateSourceDraw: Bool
    /// Test seam uses the same acquisition boundary as Metal's blocking lazy drawable access.
    var drawableAcquirer: (MTKView) -> (MTLRenderPassDescriptor, CAMetalDrawable)? = { view in
        guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return nil }
        return (descriptor, drawable)
    }
    var drawRequester: (MTKView) -> Void = { $0.draw() }
    private var closed = false
    private var refresh: VideoRefreshPolicy
    private var redraw = false
    private var drawingPromptSource = false // Main-thread coalesced wake only.
    private var stamp: Int64 = 0
    private(set) var timingAvailable = false
    var renderOptimizations: (unfencedDrawable: Bool, promptSourceDraw: Bool, singleResample: Bool, precompiledShaders: Bool) {
        (unfencedPreparation, immediateSourceDraw, backingPolicy.enabled, precompiledShaders)
    }
    func observesPresentation(isNew: Bool) -> Bool {
        isNew || unfencedPreparation || backingPolicy.enabled
    }

    init(admission: VideoPresentationAdmission, fence: VideoPresentationFence, defaults: UserDefaults = .standard) {
        self.fence = fence; identity = admission.identity
        unfencedPreparation = !defaults.bool(forKey: "phoneUnfencedDrawableDisabled")
        immediateSourceDraw = !defaults.bool(forKey: "phoneImmediateSourceDrawDisabled")
        // Picture/feel candidates remain opt-in until Roshan's exact-device A/B.
        backingPolicy = OwnedVideoBackingPolicy(enabled: defaults.bool(forKey: "PocketDeskSingleResample"))
        precompiledShaders = defaults.bool(forKey: "PocketDeskPrecompiledShaders")
        let device = MTLCreateSystemDefaultDevice()
        metal = MTKView(frame: .zero, device: device)
        commandQueue = device?.makeCommandQueue()
        let fps = StreamTuning.current.presentAtDisplayMaximum ? 120 : 60
        refresh = VideoRefreshPolicy(activeFramesPerSecond: fps, now: ProcessInfo.processInfo.systemUptime)
        super.init(frame: .zero)
        backgroundColor = .black; clipsToBounds = true
        metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metal.colorPixelFormat = .bgra8Unorm
        // Backing pixels are the decoded picture, whatever the zoom: pinch never reallocates them and
        // never draws the picture into a smaller drawable. Core Animation fills the picture placement.
        metal.autoResizeDrawable = false
        metal.drawableSize = CGSize(width: 1, height: 1)
        metal.layer.contentsGravity = .resize
        metal.framebufferOnly = true
        metal.preferredFramesPerSecond = fps
        (metal.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        (metal.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        // Taps, the pointer glyph and the mini map's markers all map over the full placement, so
        // the picture must fill it: a letterbox inset would move every one off its target pixel.
        metal.layer.contentsGravity = .resize
        addSubview(metal); metal.delegate = self
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            pipelines = Self.makePipelines(device: device, format: metal.colorPixelFormat, precompiled: precompiledShaders)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); metal.frame = bounds; fallback?.frame = bounds; redraw = true
    }
    /// Backing pixels ratchet: the drawable keeps its size while the picture aspect stays within 5 % of
    /// its own and it is at least as large as the picture, so a ladder step down, a crop wobble and a
    /// pinch never reallocate it (each reallocation showed a blank pass on 20260930.11). It grows only
    /// to a new largest picture, at the picture's exact aspect so the top rung draws 1:1, and a
    /// rotation or scope change reallocates once.
    static let backingCeiling: CGFloat = 4096
    static func backingSize(picture: CGSize, current: CGSize?) -> CGSize {
        guard picture.width > 0, picture.height > 0, picture.width.isFinite, picture.height.isFinite else { return current ?? picture }
        let aspect = picture.width / picture.height
        let pictureLong = max(picture.width, picture.height)
        var long = pictureLong
        if let current, current.width > 0, current.height > 0 {
            let currentLong = max(current.width, current.height)
            if abs(log((current.width / current.height) / aspect)) <= log(1.05) {
                if currentLong >= pictureLong { return current }
                long = max(pictureLong, currentLong)
            }
        }
        long = min(Self.backingCeiling, long)
        return aspect >= 1 ? CGSize(width: long, height: max(1, (long / aspect).rounded()))
                           : CGSize(width: max(1, (long * aspect).rounded()), height: long)
    }
    private var missingDrawableSince: TimeInterval?
    private(set) var drawsPresented = 0
    var pictureRect: CGRect {
        let drawable = metal.drawableSize, area = metal.bounds
        guard metal.layer.contentsGravity == .resizeAspect, drawable.width > 0, drawable.height > 0 else { return area }
        let scale = min(area.width / drawable.width, area.height / drawable.height)
        let size = CGSize(width: drawable.width * scale, height: drawable.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    func offer(_ envelope: VideoFrameEnvelope) {
        guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, {
            _ = mailbox.offer(envelope) { [weak self] replaced in
                if replaced.originalSource { self?.counters?.superseded(1) }
            }
        }) != nil else { return }
        wakeLock.lock()
        guard !wakeScheduled, !closed else { wakeLock.unlock(); return }
        wakeScheduled = true; wakeLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wakeLock.lock(); self.wakeScheduled = false; let closed = self.closed; self.wakeLock.unlock()
            guard !closed else { return }
            let wake = self.refresh.signal(at: ProcessInfo.processInfo.systemUptime, newFrame: true)
            self.metal.preferredFramesPerSecond = self.refresh.framesPerSecond
            // A tick may already have consumed the coalesced source. Do not redraw it twice.
            let prompt = self.immediateSourceDraw && self.mailbox.hasPending(where: { $0.promptDraw })
            if (wake == .raiseAndDraw || prompt), self.mailbox.hasPending {
                // This wake consumes only the pass-through mailbox; interpolation still pumps
                // on MTKView's ordinary ticks, with its existing deadlines and ordering.
                self.drawingPromptSource = prompt
                defer { self.drawingPromptSource = false }
                self.drawRequester(self.metal)
            }
        }
    }
    func noteActivity(at now: TimeInterval) {
        _ = refresh.signal(at: now, newFrame: false)
        metal.preferredFramesPerSecond = refresh.framesPerSecond
    }
    /// Main-thread root fence closure must precede ALL downstream renderer/interpolator flushing.
    func invalidate() {
        fence.invalidate(); mailbox.invalidate()
        wakeLock.lock(); closed = true; wakeLock.unlock()
        beforeDraw = nil; onFrameDrawn = nil; drawnEnvelope = nil; timingAvailable = false
        videoFeedback = nil
        originalSourcePresented = nil // The terminal fence already drained any earlier callback.
        metal.isPaused = true; metal.isHidden = true
        fallback?.isEnabled = false; fallback?.removeFromSuperview(); fallback = nil
        cache.map { CVMetalTextureCacheFlush($0, 0) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw = true }
    func draw(in view: MTKView) {
        guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { true }) == true else { invalidate(); return }
        // Presenter holds its own lock while delivering to the presentation fence. Do not
        // invert that order by pumping the presenter under this fence.
        if !drawingPromptSource { beforeDraw?(view) }
        if unfencedPreparation {
            drawAdmitted(in: view) // Preparation never holds the delivery/privacy fence.
        } else {
            guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { () -> Void in
                drawAdmitted(in: view)
            }) != nil else { invalidate(); return }
        }
        if let drawn = drawnEnvelope {
            drawnEnvelope = nil
            onFrameDrawn?(drawn) // Outside the fence: the model may update SwiftUI state.
        }
        if StreamTuning.current.idleVideoRefresh {
            refresh.drew(at: ProcessInfo.processInfo.systemUptime, framePending: mailbox.hasPending)
            view.preferredFramesPerSecond = refresh.framesPerSecond
        }
    }
    private func drawAdmitted(in view: MTKView) {
        guard let submission = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, {
            mailbox.take(redraw: redraw, holdUntilPresented: unfencedPreparation || backingPolicy.enabled)
        }) ?? nil else { return }
        let envelope = submission.frame
        guard let geometry = envelope.geometry else { mailbox.completed(submission.id); invalidate(); return }
        guard let backing = backingPolicy.target(picture: geometry.displaySize,
                current: view.drawableSize == CGSize(width: 1, height: 1) ? nil : view.drawableSize,
                at: ProcessInfo.processInfo.systemUptime, drained: mailbox.isOnlyFlight(submission.id)) else {
            mailbox.requeue(submission.id, frame: envelope, wasNew: submission.isNew)
            redraw = true
            return
        }
        if view.drawableSize != backing { view.drawableSize = backing }
        guard let pixels = envelope.pixels, let pipeline = pipelines[pixels.bgra], let cache,
              let command = commandQueue?.makeCommandBuffer() else {
            mailbox.completed(submission.id)
            showFallbackIfAdmitted(envelope)
            redraw = false
            return
        }
        let acquisitionStartMs = MachClock.nowMs()
        let acquired = drawableAcquirer(view)
        let acquireMs = MachClock.nowMs() - acquisitionStartMs
        counters?.phoneRenderTiming(.drawableAcquire, milliseconds: acquireMs)
        drawableWaits.record(acquireMs)
        renderDiagnostics?.drawableAcquisition(ms: acquireMs)
        let logAt = ProcessInfo.processInfo.systemUptime
        if logAt - lastDrawableLog >= 10 {
            lastDrawableLog = logAt
            let p50 = drawableWaits.percentile(0.5) ?? 0, p95 = drawableWaits.percentile(0.95) ?? 0
            let maximum = drawableWaits.percentile(1) ?? 0
            Self.renderLogger.notice("drawable wait p50 \(p50, privacy: .public) p95 \(p95, privacy: .public) max \(maximum, privacy: .public) ms n \(self.drawableWaits.count, privacy: .public) · fallback creations \(self.fallbackCreationCount, privacy: .public)")
        }
        guard let (descriptor, drawable) = acquired else {
            // Both drawables in flight, or a resize in progress: keep the last picture on screen and
            // retry the same frame next tick rather than covering it with the black fallback view.
            let now = ProcessInfo.processInfo.systemUptime
            if let since = missingDrawableSince, now - since > 1 {
                mailbox.completed(submission.id); showFallbackIfAdmitted(envelope); redraw = false; return
            }
            missingDrawableSince = missingDrawableSince ?? now
            mailbox.requeue(submission.id, frame: envelope, wasNew: submission.isNew)
            redraw = true
            return
        }
        missingDrawableSince = nil
        let buffer = pixels.buffer
        var wrappers: [CVMetalTexture] = []
        func texture(_ format: MTLPixelFormat, plane: Int, width: Int, height: Int) -> MTLTexture? {
            var wrapper: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                format, width, height, plane, &wrapper) == kCVReturnSuccess, let wrapper,
                let texture = CVMetalTextureGetTexture(wrapper) else { return nil }
            wrappers.append(wrapper); return texture
        }
        let first = texture(pixels.bgra ? .bgra8Unorm : .r8Unorm, plane: 0,
                            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let second = pixels.bgra ? nil : texture(.rg8Unorm, plane: 1,
                            width: CVPixelBufferGetWidthOfPlane(buffer, 1), height: CVPixelBufferGetHeightOfPlane(buffer, 1))
        guard let first, pixels.bgra || second != nil, let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            mailbox.completed(submission.id); showFallbackIfAdmitted(envelope); return
        }
        fallback?.removeFromSuperview(); fallback = nil; redraw = false
        drawnEnvelope = envelope // From here the frame is presented.
        #if targetEnvironment(simulator)
        timingAvailable = false // Simulator SDK does not expose actual presented handlers.
        #else
        timingAvailable = true
        #endif
        // The drawable is stretched edge to edge onto the placement (`.resize`), so the picture always
        // covers the whole drawable; a fitted extent here would letterbox into the drawable's aspect.
        let extent = SIMD2<Float>(1, 1)
        let crop = pixels.crop
        var uniforms = Uniforms(extent: extent, rotation: Int32(envelope.frame.rotation.rawValue / 90), bgra: pixels.bgra ? 1 : 0,
            crop: SIMD4(Float(crop.minX / CGFloat(CVPixelBufferGetWidth(buffer))), Float(crop.minY / CGFloat(CVPixelBufferGetHeight(buffer))),
                        Float(crop.width / CGFloat(CVPixelBufferGetWidth(buffer))), Float(crop.height / CGFloat(CVPixelBufferGetHeight(buffer)))),
            color: SIMD4(pixels.conversion?.kr ?? 0, pixels.conversion?.kb ?? 0, pixels.conversion?.yOffset ?? 0, pixels.conversion?.yScale ?? 1),
            range: SIMD4(pixels.conversion?.uvScale ?? 1, Float(0.5 / Double(pixels.bgra ? CVPixelBufferGetWidth(buffer) : CVPixelBufferGetWidthOfPlane(buffer, 1))), Float(0.5 / Double(pixels.bgra ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, 1))), pixels.transfer == .srgb ? 1 : 0))
        var refinement = RefinementUniform(rect: .zero, options: .zero)
        var refinementPixels: CVPixelBuffer?
        var refinementTexture: MTLTexture?
        if envelope.originalSource, let tag = envelope.videoTag, let roi = tag.refinement,
           roi.width == CVPixelBufferGetWidth(buffer), roi.height == CVPixelBufferGetHeight(buffer),
           let pixels = videoFeedback?.refinement(for: tag, at: ProcessInfo.processInfo.systemUptime) {
            var wrapper: CVMetalTexture?
            if CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, nil, .bgra8Unorm,
                roi.roiWidth, roi.roiHeight, 0, &wrapper) == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) {
                wrappers.append(wrapper); refinementPixels = pixels; refinementTexture = texture
                refinement = RefinementUniform(rect: SIMD4(Float(roi.x) / Float(roi.width), Float(roi.y) / Float(roi.height),
                    Float(roi.roiWidth) / Float(roi.width), Float(roi.roiHeight) / Float(roi.height)),
                    options: SIMD4(1, roi.transfer == "srgb" ? 1 : 0, 0.5 / Float(roi.roiWidth), 0.5 / Float(roi.roiHeight)))
            }
        }
        encoder.setFragmentBytes(&refinement, length: MemoryLayout<RefinementUniform>.stride, index: 1)
        encoder.setFragmentTexture(refinementTexture ?? first, index: 2)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(first, index: 0); encoder.setFragmentTexture(second, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
        // Capture this drawable's exact envelope, not whichever frame is newest at callback time.
        #if !targetEnvironment(simulator)
        if observesPresentation(isNew: submission.isNew) {
            let callback = onOriginalSourcePresented // Short admission snapshot, no layer access under it.
            let receipt = submission.isNew ? presentedReceipt(envelope, callback: callback) : nil
            let mailbox = mailbox, id = submission.id
            drawable.addPresentedHandler { shown in
                // Core Animation holds its private lock: enqueue before taking ANY local lock.
                Self.presentedReceiptQueue.async { mailbox.presented(id) }
                receipt?(shown.presentedTime)
            }
        }
        #endif
        let holdUntilPresented = unfencedPreparation || backingPolicy.enabled
        command.addCompletedHandler { [mailbox, wrappers, envelope, refinementPixels] completed in
            withExtendedLifetime((wrappers, envelope, refinementPixels)) {
                #if targetEnvironment(simulator)
                mailbox.completed(submission.id) // No presented handlers in simulator SDK.
                #else
                if holdUntilPresented && completed.status != .error { mailbox.gpuCompleted(submission.id) }
                else { mailbox.completed(submission.id) }
                #endif
            }
        }
        // Retirement can run while acquisition/preparation blocks. Only this final, short
        // effect is fenced; rejected preparation cannot publish or resurrect old pixels.
        let submitted = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) {
            command.present(drawable); command.commit(); drawsPresented += 1
            if submission.isNew && envelope.originalSource {
                counters?.presented(latencyMs: max(0, MachClock.nowMs() - envelope.arrivalMs))
            }
            return true
        }
        if submitted != true { mailbox.completed(submission.id); invalidate() }
    }
    /// Core Animation runs presented handlers while holding the layer's private lock, and this view
    /// calls `addPresentedHandler` on main while holding the fence. Waiting on the fence inside the
    /// handler inverts that order and deadlocks main (20260930.8 watchdog reports), so the handler
    /// only enqueues; admission is rechecked off Core Animation's thread.
    static let presentedReceiptQueue = DispatchQueue(label: "farside.owned-video.presented", qos: .userInteractive)
    func presentedReceipt(_ envelope: VideoFrameEnvelope,
                          callback: ((VideoPresentationIdentity, UUID) -> Void)?) -> (CFTimeInterval) -> Void {
        { [weak self] presentedTime in
            guard presentedTime.isFinite, presentedTime > 0 else { return }
            Self.presentedReceiptQueue.async {
                guard let self else { return }
                _ = self.fence.withAdmission(envelope.identity, at: ProcessInfo.processInfo.systemUptime) {
                    self.counters?.presentedFrame(atMs: presentedTime * 1000, marker: envelope.marker)
                    if envelope.originalSource, let trace = envelope.decodeTrace {
                        self.counters?.phoneRenderTiming(.decodedToPresented, milliseconds: presentedTime * 1000 - trace.callbackMs)
                        self.counters?.phoneRenderTiming(.deliveryToPresented, milliseconds: presentedTime * 1000 - trace.deliveryMs)
                    }
                    let clock = self.counters?.clockObservation
                    self.videoFeedback?.presentedTiming(envelope.videoTag, originalSource: envelope.originalSource,
                        newSubmission: true, presentedTime: presentedTime,
                        clock: clock?.estimate, observedAtMs: clock?.atMs)
                    if envelope.originalSource { callback?(envelope.identity, envelope.receiptID) }
                }
            }
        }
    }
    private func showFallbackIfAdmitted(_ envelope: VideoFrameEnvelope) {
        _ = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) { showFallback(envelope) }
    }
    private func showFallback(_ envelope: VideoFrameEnvelope) {
        timingAvailable = false
        drawnEnvelope = envelope // The compatibility view shows this frame; its region places it too.
        var buffer = envelope.frame.buffer
        if let cv = buffer as? RTCCVPixelBuffer, HEVC444PixelTransfer.isFullColor(cv.pixelBuffer) {
            // Pinned M153 stock/crop/toI420 paths do not support raw 444. Public declared-color
            // conversion is only a compatibility picture; it never creates a presented receipt.
            guard let converted = HEVC444PixelTransfer.compatibilityFrameBuffer(cv) else { invalidate(); return }
            buffer = converted
        }
        if fallback == nil {
            let view = RTCMTLVideoView(frame: bounds); addSubview(view); fallback = view
            fallbackCreationCount += 1
            renderDiagnostics?.rendererFallbackCreated()
        }
        fallback?.isHidden = false
        fallback?.videoContentMode = fillsFrame ? .scaleToFill : .scaleAspectFit
        stamp = max(stamp + 1, Int64(ProcessInfo.processInfo.systemUptime * 1e9))
        fallback?.renderFrame(RTCVideoFrame(buffer: buffer, rotation: envelope.frame.rotation, timeStampNs: stamp))
    }
    private struct RefinementUniform { var rect: SIMD4<Float>; var options: SIMD4<Float> }
    private struct Uniforms {
        var extent: SIMD2<Float>; var rotation: Int32; var bgra: Int32
        var crop: SIMD4<Float>; var color: SIMD4<Float>; var range: SIMD4<Float>
    }
    private struct PipelineKey: Hashable { let device: UInt64; let format: UInt }
    private static let pipelineLock = NSLock()
    private static var pipelineCache: [PipelineKey: [Bool: MTLRenderPipelineState]] = [:]
    private(set) static var precompiledPipelineBuilds = 0
    private static func makePipelines(device: MTLDevice, format: MTLPixelFormat, precompiled: Bool) -> [Bool: MTLRenderPipelineState] {
        let key = PipelineKey(device: device.registryID, format: format.rawValue)
        // Cache only the opt-in path; NO retains the original per-renderer runtime compilation.
        pipelineLock.lock(); defer { pipelineLock.unlock() }
        if precompiled, let cached = pipelineCache[key] { return cached }
        do {
            let library: MTLLibrary
            if precompiled {
                guard let compiled = device.makeDefaultLibrary() else { return [:] }
                library = compiled
            } else { library = try device.makeLibrary(source: shader, options: nil) }
            var made: [Bool: MTLRenderPipelineState] = [:]
            for bgra in [false, true] {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vertexPicture")
                descriptor.fragmentFunction = library.makeFunction(name: bgra ? "fragmentBGRA" : "fragmentNV12")
                descriptor.colorAttachments[0].pixelFormat = format
                made[bgra] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            if precompiled { pipelineCache[key] = made; precompiledPipelineBuilds += 1 }
            return made
        } catch { return [:] }
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 extent; int rotation; int bgra; float4 crop; float4 color; float4 range; };
    struct R { float4 rect; float4 options; };
    struct V { float4 position [[position]]; float2 uv; };
    float3 displayEncoded(float3 rgb, constant U &u) {
        if(u.range.w==0) return rgb;
        float3 v=max(rgb,float3(0));
        float3 linear=select(pow((v+0.055)/1.055,float3(2.4)),v/12.92,v<=0.04045);
        return select(1.099*pow(linear,float3(0.45))-0.099,4.5*linear,linear<0.018);
    }
    float3 refined(float3 base, float2 uv, constant R &r, texture2d<float> image) {
        if(r.options.x==0 || any(uv<r.rect.xy) || any(uv>=r.rect.xy+r.rect.zw)) return base;
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float3 rgb=image.sample(s,clamp((uv-r.rect.xy)/r.rect.zw,r.options.zw,1-r.options.zw)).rgb;
        if(r.options.y==0) return rgb;
        float3 v=max(rgb,float3(0));
        float3 linear=select(pow((v+0.055)/1.055,float3(2.4)),v/12.92,v<=0.04045);
        return select(1.099*pow(linear,float3(0.45))-0.099,4.5*linear,linear<0.018);
    }
    vertex V vertexPicture(uint i [[vertex_id]], constant U &u [[buffer(0)]]) {
        float2 p[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        float2 t[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        float2 uv = t[i];
        if(u.rotation==1) uv=float2(uv.y,1-uv.x);
        if(u.rotation==2) uv=1-uv;
        if(u.rotation==3) uv=float2(1-uv.y,uv.x);
        V o; o.position=float4(p[i]*u.extent,0,1); o.uv=u.crop.xy+uv*u.crop.zw; return o;
    }
    fragment float4 fragmentNV12(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]], constant R &r [[buffer(1)]], texture2d<float> refinement [[texture(2)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 t=clamp(v.uv,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
        float l=(y.sample(s,t).r-u.color.z)*u.color.w;
        float2 c=(uv.sample(s,t).rg-float2(128.0/255.0))*u.range.x;
        float kr=u.color.x,kb=u.color.y,kg=1-kr-kb;
        return float4(refined(displayEncoded(float3(l+2*(1-kr)*c.y,l-2*kb*(1-kb)/kg*c.x-2*kr*(1-kr)/kg*c.y,l+2*(1-kb)*c.x),u),v.uv,r,refinement),1);
    }
    fragment float4 fragmentBGRA(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]], constant R &r [[buffer(1)]], texture2d<float> refinement [[texture(2)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 t=clamp(v.uv,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
        return float4(refined(displayEncoded(image.sample(s,t).rgb,u),v.uv,r,refinement),1);
    }
    """
}

/// Preserve the legacy ratchet during transient rung/crop changes. An opt-in stable downshift
/// removes the intermediate upscale only after previous GPU AND presentation owners drain.
struct OwnedVideoBackingPolicy {
    let enabled: Bool
    private var candidate: CGSize?
    private var candidateSince: TimeInterval = 0
    static let settleSeconds: TimeInterval = 2

    init(enabled: Bool) { self.enabled = enabled }

    mutating func target(picture: CGSize, current: CGSize?, at now: TimeInterval, drained: Bool) -> CGSize? {
        let legacy = OwnedMetalVideoView.backingSize(picture: picture, current: current)
        guard enabled else { return legacy }
        guard now.isFinite, picture.width > 0, picture.height > 0,
              picture.width.isFinite, picture.height.isFinite else { return legacy }
        if picture != candidate { candidate = picture; candidateSince = now }
        var target = legacy
        let exact = OwnedMetalVideoView.backingSize(picture: picture, current: nil)
        if now - candidateSince >= Self.settleSeconds { target = exact }
        // Pinch/placement never enters this decision. A geometry swap waits instead of replacing
        // an occupied surface or drawing a new capture region into old geometry.
        if let current, target != current, !drained { return nil }
        return target
    }
}
