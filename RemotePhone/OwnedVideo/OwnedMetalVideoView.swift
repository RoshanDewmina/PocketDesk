import MetalKit
import WebRTC

/// Public drawable ownership. The fallback is public WebRTC rendering with timing unavailable.
final class OwnedMetalVideoView: UIView, MTKViewDelegate {
    let metal: MTKView
    let fence: VideoPresentationFence
    let identity: VideoPresentationIdentity
    let mailbox = NewestFrameMailbox<VideoFrameEnvelope>()
    var counters: StreamCounters?
    var beforeDraw: ((MTKView) -> Void)?
    var fillsFrame = false
    private let commandQueue: MTLCommandQueue?
    private var cache: CVMetalTextureCache?
    private var pipelines: [Bool: MTLRenderPipelineState] = [:]
    private var fallback: RTCMTLVideoView?
    private let wakeLock = NSLock()
    private var wakeScheduled = false
    private var closed = false
    private var refresh: VideoRefreshPolicy
    private var redraw = false
    private var stamp: Int64 = 0
    private(set) var timingAvailable = false

    init(admission: VideoPresentationAdmission, fence: VideoPresentationFence) {
        self.fence = fence; identity = admission.identity
        let device = MTLCreateSystemDefaultDevice()
        metal = MTKView(frame: .zero, device: device)
        commandQueue = device?.makeCommandQueue()
        let fps = StreamTuning.current.presentAtDisplayMaximum ? 120 : 60
        refresh = VideoRefreshPolicy(activeFramesPerSecond: fps, now: ProcessInfo.processInfo.systemUptime)
        super.init(frame: .zero)
        backgroundColor = .black; clipsToBounds = true
        metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metal.colorPixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.preferredFramesPerSecond = fps
        (metal.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        (metal.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        addSubview(metal); metal.delegate = self
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            do {
                let library = try device.makeLibrary(source: Self.shader, options: nil)
                for bgra in [false, true] {
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "vertexPicture")
                    descriptor.fragmentFunction = library.makeFunction(name: bgra ? "fragmentBGRA" : "fragmentNV12")
                    descriptor.colorAttachments[0].pixelFormat = metal.colorPixelFormat
                    pipelines[bgra] = try device.makeRenderPipelineState(descriptor: descriptor)
                }
            } catch { pipelines.removeAll() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); metal.frame = bounds; fallback?.frame = bounds; redraw = true
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
            if wake == .raiseAndDraw { self.metal.draw() }
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
        beforeDraw = nil; timingAvailable = false
        metal.isPaused = true; metal.isHidden = true
        fallback?.isEnabled = false; fallback?.removeFromSuperview(); fallback = nil
        cache.map { CVMetalTextureCacheFlush($0, 0) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw = true }
    func draw(in view: MTKView) {
        guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { true }) == true else { invalidate(); return }
        // Presenter holds its own lock while delivering to the presentation fence. Do not
        // invert that order by pumping the presenter under this fence.
        beforeDraw?(view)
        guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { () -> Void in
            drawAdmitted(in: view)
        }) != nil else { invalidate(); return }
        if StreamTuning.current.idleVideoRefresh {
            refresh.drew(at: ProcessInfo.processInfo.systemUptime, framePending: mailbox.hasPending)
            view.preferredFramesPerSecond = refresh.framesPerSecond
        }
    }
    private func drawAdmitted(in view: MTKView) {
        guard let submission = mailbox.take(redraw: redraw) else { return }
        let envelope = submission.frame
        guard envelope.geometry != nil else { mailbox.completed(submission.id); invalidate(); return }
        guard let pixels = envelope.pixels, let pipeline = pipelines[pixels.bgra], let cache,
              let command = commandQueue?.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            mailbox.completed(submission.id)
            showFallback(envelope)
            redraw = false
            return
        }
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
            mailbox.completed(submission.id); showFallback(envelope); return
        }
        fallback?.removeFromSuperview(); fallback = nil; redraw = false
        #if targetEnvironment(simulator)
        timingAvailable = false // Simulator SDK does not expose actual presented handlers.
        #else
        timingAvailable = true
        #endif
        let size = CGSize(width: Int(envelope.frame.width), height: Int(envelope.frame.height))
        let rotated = envelope.frame.rotation.rawValue % 180 != 0
        let picture = rotated ? CGSize(width: size.height, height: size.width) : size
        let scale = min(view.drawableSize.width / max(1, picture.width), view.drawableSize.height / max(1, picture.height))
        let extent = fillsFrame ? SIMD2<Float>(1, 1) : SIMD2<Float>(Float(picture.width * scale / max(1, view.drawableSize.width)), Float(picture.height * scale / max(1, view.drawableSize.height)))
        let crop = pixels.crop
        var uniforms = Uniforms(extent: extent, rotation: Int32(envelope.frame.rotation.rawValue / 90), bgra: pixels.bgra ? 1 : 0,
            crop: SIMD4(Float(crop.minX / CGFloat(CVPixelBufferGetWidth(buffer))), Float(crop.minY / CGFloat(CVPixelBufferGetHeight(buffer))),
                        Float(crop.width / CGFloat(CVPixelBufferGetWidth(buffer))), Float(crop.height / CGFloat(CVPixelBufferGetHeight(buffer)))),
            color: SIMD4(pixels.conversion?.kr ?? 0, pixels.conversion?.kb ?? 0, pixels.conversion?.yOffset ?? 0, pixels.conversion?.yScale ?? 1),
            range: SIMD4(pixels.conversion?.uvScale ?? 1, Float((pixels.bgra ? 0.5 : 1) / Double(CVPixelBufferGetWidth(buffer))), Float((pixels.bgra ? 0.5 : 1) / Double(CVPixelBufferGetHeight(buffer))), pixels.transfer == .srgb ? 1 : 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(first, index: 0); encoder.setFragmentTexture(second, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
        if submission.isNew && envelope.originalSource { counters?.presented(latencyMs: max(0, MachClock.nowMs() - envelope.arrivalMs)) }
        // Capture this drawable's exact envelope, not whichever frame is newest at callback time.
        #if !targetEnvironment(simulator)
        if submission.isNew {
            drawable.addPresentedHandler { [weak self, envelope] shown in
                guard shown.presentedTime > 0, let self else { return }
                _ = self.fence.withAdmission(envelope.identity, at: ProcessInfo.processInfo.systemUptime) {
                    self.counters?.presentedFrame(atMs: shown.presentedTime * 1000, marker: envelope.marker)
                }
            }
        }
        #endif
        command.addCompletedHandler { [mailbox, wrappers, envelope] _ in
            withExtendedLifetime((wrappers, envelope)) { mailbox.completed(submission.id) }
        }
        command.present(drawable); command.commit()
    }
    private func showFallback(_ envelope: VideoFrameEnvelope) {
        timingAvailable = false
        if fallback == nil {
            let view = RTCMTLVideoView(frame: bounds); addSubview(view); fallback = view
        }
        fallback?.isHidden = false
        fallback?.videoContentMode = fillsFrame ? .scaleToFill : .scaleAspectFit
        stamp = max(stamp + 1, Int64(ProcessInfo.processInfo.systemUptime * 1e9))
        fallback?.renderFrame(RTCVideoFrame(buffer: envelope.frame.buffer, rotation: envelope.frame.rotation, timeStampNs: stamp))
    }
    private struct Uniforms {
        var extent: SIMD2<Float>; var rotation: Int32; var bgra: Int32
        var crop: SIMD4<Float>; var color: SIMD4<Float>; var range: SIMD4<Float>
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 extent; int rotation; int bgra; float4 crop; float4 color; float4 range; };
    struct V { float4 position [[position]]; float2 uv; };
    float3 displayEncoded(float3 rgb, constant U &u) {
        if(u.range.w==0) return rgb;
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
    fragment float4 fragmentNV12(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 t=clamp(v.uv,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
        float l=(y.sample(s,t).r-u.color.z)*u.color.w;
        float2 c=(uv.sample(s,t).rg-float2(128.0/255.0))*u.range.x;
        float kr=u.color.x,kb=u.color.y,kg=1-kr-kb;
        return float4(displayEncoded(float3(l+2*(1-kr)*c.y,l-2*kb*(1-kb)/kg*c.x-2*kr*(1-kr)/kg*c.y,l+2*(1-kb)*c.x),u),1);
    }
    fragment float4 fragmentBGRA(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 t=clamp(v.uv,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
        return float4(displayEncoded(image.sample(s,t).rgb,u),1);
    }
    """
}
