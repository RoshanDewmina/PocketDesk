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
    private var viewportCoverage: ViewportCoverageConstraint?
    /// Main picture only (`PocketDeskLocalScroll`): the finger-scroll slide applied to redraws of the shown frame.
    weak var localScroll: LocalScrollEchoController? {
        didSet { if localScroll !== oldValue { localScroll?.renderer = self } }
    }
    private var localScrollRedrawPending = false
    private var slideSubmissionID: UInt64?

    /// Main-thread presentation constraint. Decoding and the compressed reference chain are unchanged.
    func beginViewportCoverage(generation: UInt64, required: CGRect, scope: UInt64) -> Bool {
        guard required.width > 0, required.height > 0,
              [required.minX, required.minY, required.maxX, required.maxY].allSatisfy({ $0.isFinite }),
              fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { true }) == true else { return false }
        viewportCoverage = .init(generation: generation, required: required, scope: scope)
        return true
    }
    func viewportCoverageReady(generation: UInt64) -> Bool {
        fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) {
            viewportCoverage?.generation == generation && viewportCoverage?.presented == true
        } ?? false
    }
    func finishViewportCoverage(generation: UInt64, required: CGRect, retainEndpoint: Bool = false) {
        guard viewportCoverage?.generation == generation else { return }
        guard retainEndpoint else { viewportCoverage = nil; return }
        viewportCoverage?.required = required // Keep the current camera safe from delayed old crops.
    }
    func clearViewportCoverage() { viewportCoverage = nil }
    /// One rule for all subsequent camera edits, independent of their gesture or layout source.
    /// A deferred endpoint observation must not retire unchanged framing.
    func synchronizeViewportCoverage(visible: CGRect) {
        guard let coverage = viewportCoverage, coverage.required != visible else { return }
        viewportCoverage = nil
    }
    /// The first eligible submission must follow BOTH edges of all pre-install submissions.
    func viewportCoverageAllows(_ envelope: VideoFrameEnvelope, submissionID: UInt64) -> Bool {
        guard let coverage = viewportCoverage else { return true }
        return coverage.accepts(envelope, identity: identity) &&
            (coverage.presented || mailbox.isOnlyFlight(submissionID))
    }
    /// This exact closure is called from Core Animation. It captures generation before commit,
    /// then queues owner validation without waiting for main or any local lock.
    func viewportCoverageReceipt(_ envelope: VideoFrameEnvelope) -> ((TimeInterval) -> Void)? {
        guard let generation = viewportCoverage?.generation else { return nil }
        return { [weak self] time in
            Self.presentedReceiptQueue.async {
                DispatchQueue.main.async { [weak self] in
                    self?.viewportCoveragePresented(envelope, generation: generation, at: time)
                }
            }
        }
    }
    func viewportCoveragePresented(_ envelope: VideoFrameEnvelope, generation: UInt64, at time: TimeInterval) {
        guard time.isFinite, time > 0, time <= ProcessInfo.processInfo.systemUptime,
              fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { true }) == true,
              viewportCoverage?.generation == generation,
              viewportCoverage?.accepts(envelope, identity: identity) == true else { return }
        viewportCoverage?.presented = true
    }
    var fillsFrame = false
    /// Main-thread only. The reading magnifier opts in; ordinary video remains unmodified.
    var glassLensEnabled = false {
        didSet {
            assert(Thread.isMainThread)
            if glassLensEnabled != oldValue { redraw = true }
        }
    }
    var videoFeedback: VideoFeedbackContext?
    /// Only an actual original source drawable presentation may report this receipt.
    /// Consumers enqueue owner-validated work; they must not synchronously hop to main.
    var textSnapshotPresented: ((VideoFrameEnvelope) -> Void)?
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
    /// Research run 3. P1-C: a waiting frame is drawn as soon as a flight slot frees, and MTKView's rate is
    /// rewritten only when it changes. P1-B: a `CAMetalDisplayLink` on MTKView's layer is the only draw clock.
    private let mailboxWakeOnRelease: Bool
    private var displayLink: CAMetalDisplayLink?
    private var linkDrawable: CAMetalDrawable?
    private var linkRate = 0
    private var panelMaximumFramesPerSecond = 60
    private var powerStateObserver: NSObjectProtocol?
    var lowPowerMode: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var presentsThroughDisplayLink: Bool { displayLink != nil }
    var displayLinkPaused: Bool {
        get { displayLink?.isPaused ?? false }
        set { displayLink?.isPaused = newValue }
    }
    /// Explicit development experiment only; ordinary and distribution launches keep two drawables.
    let drawablePoolCount: Int
    private let pacingDiagnosticsEnabled: Bool
    private var pacingDiagnostics = OwnedVideoPacingWindow()
    private var pacingDrawOrigin = OwnedVideoPacingWindow.Origin.tick
    private var pacingWindowStartedAt: TimeInterval?
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
        true // Smart Zoom may begin after any submission, including a redraw.
    }

    init(admission: VideoPresentationAdmission, fence: VideoPresentationFence, defaults: UserDefaults = .standard) {
        self.fence = fence; identity = admission.identity
        unfencedPreparation = !defaults.bool(forKey: "phoneUnfencedDrawableDisabled")
        immediateSourceDraw = !defaults.bool(forKey: "phoneImmediateSourceDrawDisabled")
        mailboxWakeOnRelease = MailboxWakeOnReleaseSwitch.isOn(defaults)
        drawablePoolCount = OwnedVideoPacingExperiment.drawableCount(defaults: defaults)
        pacingDiagnosticsEnabled = OwnedVideoPacingExperiment.diagnosticsEnabled(defaults: defaults)
        // On in Roshan's combined .7 device test (3 Oct); NO turns each off. Release defaults follow that test.
        backingPolicy = OwnedVideoBackingPolicy(enabled: defaults.object(forKey: "PocketDeskSingleResample") == nil
            || defaults.bool(forKey: "PocketDeskSingleResample"))
        precompiledShaders = defaults.object(forKey: "PocketDeskPrecompiledShaders") == nil
            || defaults.bool(forKey: "PocketDeskPrecompiledShaders")
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
        (metal.layer as? CAMetalLayer)?.maximumDrawableCount = drawablePoolCount
        (metal.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        // Taps, the pointer glyph and the mini map's markers all map over the full placement, so
        // the picture must fill it: a letterbox inset would move every one off its target pixel.
        metal.layer.contentsGravity = .resize
        addSubview(metal); metal.delegate = self
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            pipelines = Self.makePipelines(device: device, format: metal.colorPixelFormat, precompiled: precompiledShaders)
        }
        if MetalDisplayLinkSwitch.isOn(defaults), let layer = metal.layer as? CAMetalLayer {
            // MTKView keeps the layer, its drawable pool and size; it no longer drives any draw.
            metal.isPaused = true; metal.enableSetNeedsDisplay = false
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameLatency = 1
            displayLink = link
            applyRefreshRate()
            link.add(to: .main, forMode: .common)
            powerStateObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                object: nil, queue: .main) { [weak self] _ in self?.applyRefreshRate() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        displayLink?.invalidate()
        if let powerStateObserver { NotificationCenter.default.removeObserver(powerStateObserver) }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); metal.frame = bounds; fallback?.frame = bounds; redraw = true
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard displayLink != nil, let screen = window?.windowScene?.screen else { return }
        panelMaximumFramesPerSecond = screen.maximumFramesPerSecond
        applyRefreshRate()
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
        scheduleWake()
    }
    /// Off Core Animation's thread, after a presented or GPU-completed edge (P1-C): a frame that waited for a
    /// slot is drawn now instead of at the next tick, where the next arrival might supersede it first.
    func flightReleased() {
        guard mailboxWakeOnRelease, mailbox.pendingAdmissible else { return }
        scheduleWake()
    }
    private func scheduleWake() {
        wakeLock.lock()
        guard !wakeScheduled, !closed else { wakeLock.unlock(); return }
        wakeScheduled = true; wakeLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wakeLock.lock(); self.wakeScheduled = false; let closed = self.closed; self.wakeLock.unlock()
            guard !closed else { return }
            let wake = self.refresh.signal(at: ProcessInfo.processInfo.systemUptime, newFrame: true)
            self.applyRefreshRate()
            guard self.displayLink == nil else { return } // The next link callback draws whatever is pending.
            // A tick may already have consumed the coalesced source. Do not redraw it twice.
            let prompt = self.immediateSourceDraw && self.mailbox.hasPending(where: { $0.promptDraw })
            if (wake == .raiseAndDraw || prompt), self.mailbox.hasPending {
                // This wake consumes only the pass-through mailbox; interpolation still pumps
                // on MTKView's ordinary ticks, with its existing deadlines and ordering.
                self.drawingPromptSource = prompt
                self.pacingDrawOrigin = .sourceWake
                defer { self.drawingPromptSource = false; self.pacingDrawOrigin = .tick }
                self.drawRequester(self.metal)
            }
        }
    }
    /// Off the link: MTKView's rate, rewritten on every call as before unless P1-C is on. On the link: the
    /// callback range, with MTKView's rate kept in step because Smooth Motion and the local scroll read
    /// the tick length from it.
    private func applyRefreshRate() {
        guard let displayLink else {
            if !mailboxWakeOnRelease || metal.preferredFramesPerSecond != refresh.framesPerSecond {
                metal.preferredFramesPerSecond = refresh.framesPerSecond
            }
            return
        }
        let rate = Self.linkRate(active: refresh.activeFramesPerSecond, panelMaximum: panelMaximumFramesPerSecond,
                                 lowPower: lowPowerMode(), idle: refresh.idle)
        guard rate != linkRate else { return }
        linkRate = rate
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        metal.preferredFramesPerSecond = rate
    }
    /// The link's fixed rate: the panel maximum (60 in Low Power Mode) while active; a 60 Hz floor while idle,
    /// so with no out-of-band draw the first frame after a still picture waits at most one 60 Hz tick.
    static func linkRate(active: Int, panelMaximum: Int, lowPower: Bool, idle: Bool) -> Int {
        let ceiling = max(1, min(active, panelMaximum, lowPower ? 60 : Int.max))
        return idle ? min(60, ceiling) : ceiling
    }
    /// Main thread: the local scroll slide moved. A display tick redraws the shown frame, only while no
    /// other draw is in flight and no real frame is due within the coming refresh (`LocalScrollEcho.redrawAllowed`).
    func localScrollChanged() {
        wakeLock.lock(); let closed = self.closed; wakeLock.unlock()
        guard !closed else { return }
        localScrollRedrawPending = true
        noteActivity(at: ProcessInfo.processInfo.systemUptime)
    }
    func noteActivity(at now: TimeInterval) {
        _ = refresh.signal(at: now, newFrame: false)
        applyRefreshRate()
    }
    /// Main-thread root fence closure must precede ALL downstream renderer/interpolator flushing.
    func invalidate() {
        fence.invalidate(); mailbox.invalidate()
        wakeLock.lock(); closed = true; wakeLock.unlock()
        beforeDraw = nil; onFrameDrawn = nil; drawnEnvelope = nil; viewportCoverage = nil; timingAvailable = false
        localScroll = nil; localScrollRedrawPending = false
        videoFeedback = nil
        originalSourcePresented = nil // The terminal fence already drained any earlier callback.
        displayLink?.invalidate(); displayLink = nil // A second invalidate() of a CAMetalDisplayLink crashes (null layer).
        if let powerStateObserver { NotificationCenter.default.removeObserver(powerStateObserver); self.powerStateObserver = nil }
        metal.isPaused = true; metal.isHidden = true
        fallback?.isEnabled = false; fallback?.removeFromSuperview(); fallback = nil
        cache.map { CVMetalTextureCacheFlush($0, 0) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw = true }
    func draw(in view: MTKView) {
        guard fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { true }) == true else { invalidate(); return }
        if pacingDiagnosticsEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            if pacingWindowStartedAt == nil { pacingWindowStartedAt = now }
            pacingDiagnostics.draw(pacingDrawOrigin)
        }
        if pacingDrawOrigin == .tick { counters?.displayTick() }
        defer { logPacingIfDue(view) }
        // Presenter holds its own lock while delivering to the presentation fence. Do not
        // invert that order by pumping the presenter under this fence.
        if !drawingPromptSource { beforeDraw?(view) }
        if localScrollRedrawPending, !drawingPromptSource {
            // A waiting frame replaces the slide anyway; otherwise redraw only into an idle pipeline.
            if mailbox.hasPending || localScroll == nil { localScrollRedrawPending = false }
            else if mailbox.isIdle, localScroll?.redrawAllowed(at: ProcessInfo.processInfo.systemUptime,
                        refresh: 1 / Double(max(1, view.preferredFramesPerSecond))) == true {
                localScrollRedrawPending = false; redraw = true
            }
        }
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
            applyRefreshRate()
        }
    }
    private func drawAdmitted(in view: MTKView) {
        guard let submission = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, {
            mailbox.take(redraw: redraw, holdUntilPresented: true)
        }) ?? nil else {
            if pacingDiagnosticsEnabled { pacingDiagnostics.noSubmission += 1 }
            if mailbox.hasPending { counters?.takeRefused() }
            return
        }
        let envelope = submission.frame
        guard viewportCoverageAllows(envelope, submissionID: submission.id) else {
            // No decoder drop: only this presentation is withheld, keeping the last safe picture.
            mailbox.requeue(submission.id, frame: envelope, wasNew: submission.isNew)
            return
        }
        guard let geometry = envelope.geometry else { mailbox.completed(submission.id); invalidate(); return }
        // Any newer picture replaces the local scroll slide outright, even if this draw must retry.
        if submission.isNew, let localScroll {
            localScroll.frameArrived(envelope.receiptID, original: envelope.originalSource, at: ProcessInfo.processInfo.systemUptime)
            if let slide = slideSubmissionID, mailbox.isInFlight(slide) { localScroll.framesBehindSlide += 1 }
            slideSubmissionID = nil
        }
        guard let backing = backingPolicy.target(picture: geometry.displaySize,
                current: view.drawableSize == CGSize(width: 1, height: 1) ? nil : view.drawableSize,
                at: ProcessInfo.processInfo.systemUptime, drained: mailbox.isOnlyFlight(submission.id)) else {
            if pacingDiagnosticsEnabled { pacingDiagnostics.geometryRetries += 1 }
            mailbox.requeue(submission.id, frame: envelope, wasNew: submission.isNew)
            redraw = true
            return
        }
        if view.drawableSize != backing {
            if pacingDiagnosticsEnabled { pacingDiagnostics.backingChanges += 1 }
            view.drawableSize = backing
        }
        if let linkDrawable, linkDrawable.texture.width != Int(backing.width) || linkDrawable.texture.height != Int(backing.height) {
            // The link handed this drawable out before the size change; the next callback's has the new size.
            mailbox.requeue(submission.id, frame: envelope, wasNew: submission.isNew)
            redraw = true
            return
        }
        guard let pixels = envelope.pixels, let pipeline = pipelines[pixels.bgra], let cache,
              let command = commandQueue?.makeCommandBuffer() else {
            mailbox.completed(submission.id)
            showFallbackIfAdmitted(envelope)
            redraw = false
            return
        }
        let acquisitionStartMs = MachClock.nowMs()
        // A layer driven by a CAMetalDisplayLink refuses `nextDrawable`; the link's own drawable is the only source.
        let acquired = linkDrawable.map { (Self.renderPass(into: $0, clearing: view.clearColor), $0) }
            ?? (displayLink == nil ? drawableAcquirer(view) : nil)
        let acquireMs = MachClock.nowMs() - acquisitionStartMs
        if pacingDiagnosticsEnabled { pacingDiagnostics.acquired(milliseconds: acquireMs, available: acquired != nil) }
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
        var lens = SIMD2<Float>(glassLensEnabled ? 1 : 0, Float(view.bounds.width / max(view.bounds.height, 1)))
        var scroll = LocalScrollUniform.off
        if !submission.isNew, !glassLensEnabled,
           let shift = localScroll?.uniform(picture: localScrollPicture(envelope), pixels: geometry.displaySize) {
            scroll = shift
        }
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
        encoder.setFragmentBytes(&lens, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.setFragmentBytes(&scroll, length: MemoryLayout<LocalScrollUniform>.stride, index: 3)
        encoder.setFragmentTexture(refinementTexture ?? first, index: 2)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(first, index: 0); encoder.setFragmentTexture(second, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
        // Capture this drawable's exact envelope, not whichever frame is newest at callback time.
        let released: (() -> Void)? = mailboxWakeOnRelease ? { [weak self] in self?.flightReleased() } : nil
        let commitStamp = PresentationStamp()
        #if !targetEnvironment(simulator)
        if observesPresentation(isNew: submission.isNew) {
            let callback = onOriginalSourcePresented // Short admission snapshot, no layer access under it.
            let receipt = submission.isNew ? presentedReceipt(envelope, commit: commitStamp, callback: callback) : nil
            let mailbox = mailbox, id = submission.id
            let coverageReceipt = viewportCoverageReceipt(envelope)
            drawable.addPresentedHandler { shown in
                // Core Animation holds its private lock: enqueue before taking ANY local lock.
                Self.presentedReceiptQueue.async { mailbox.presented(id); released?() }
                coverageReceipt?(shown.presentedTime)
                receipt?(shown.presentedTime)
            }
        }
        #endif
        let holdUntilPresented = true // All prior submissions retain both completion edges.
        command.addCompletedHandler { [mailbox, wrappers, envelope, refinementPixels] completed in
            withExtendedLifetime((wrappers, envelope, refinementPixels)) {
                #if targetEnvironment(simulator)
                mailbox.completed(submission.id) // No presented handlers in simulator SDK.
                #else
                if holdUntilPresented && completed.status != .error { mailbox.gpuCompleted(submission.id) }
                else { mailbox.completed(submission.id) }
                #endif
                released?()
            }
        }
        // Retirement can run while acquisition/preparation blocks. Only this final, short
        // effect is fenced; rejected preparation cannot publish or resurrect old pixels.
        let viaLink = linkDrawable != nil
        let submitted = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) {
            guard viewportCoverageAllows(envelope, submissionID: submission.id) else { return false }
            if viaLink { command.commit(); drawable.present() } else { command.present(drawable); command.commit() }
            commitStamp.commitMs = MachClock.nowMs()
            drawsPresented += 1
            drawnEnvelope = envelope // Only the accepted commit may update model placement.
            if scroll != .off { slideSubmissionID = submission.id; localScroll?.slideDraws += 1 }
            if pacingDiagnosticsEnabled {
                if submission.isNew && envelope.originalSource { pacingDiagnostics.originalSubmissions += 1 }
                else { pacingDiagnostics.otherSubmissions += 1 }
            }
            if submission.isNew && envelope.originalSource {
                counters?.presented(latencyMs: max(0, MachClock.nowMs() - envelope.arrivalMs))
            }
            counters?.drawCommitted(prompt: pacingDrawOrigin == .sourceWake)
            return true
        }
        if submitted != true {
            mailbox.completed(submission.id)
            if fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime, { true }) != true { invalidate() }
        } else if submission.isNew, envelope.originalSource, let localScroll, localScroll.wantsChangeCheck {
            localScroll.observe(pixels, geometry: geometry, picture: localScrollPicture(envelope)) // After commit: never delays it.
        }
    }
    /// The Mac-point rect the frame covers: its own tagged crop, else the model's last placement.
    private func localScrollPicture(_ envelope: VideoFrameEnvelope) -> CGRect {
        if let tag = envelope.videoTag, tag.geometryEpoch == identity.geometryEpoch, let region = tag.region,
           (try? region.validate()) != nil,
           region.outputWidth == Int(envelope.frame.width), region.outputHeight == Int(envelope.frame.height) {
            return region.rect
        }
        return localScroll?.picture ?? .zero
    }
    /// Main-thread counters only. This measures scheduling/submission, never actual presentation.
    /// No callback, fence, identity, pixel or original-frame ownership rule changes for this A/B.
    private func logPacingIfDue(_ view: MTKView) {
        guard pacingDiagnosticsEnabled, let start = pacingWindowStartedAt else { return }
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - start
        guard elapsed >= 10 else { return }
        let window = pacingDiagnostics
        Self.renderLogger.notice("pacing window seconds=\(elapsed, privacy: .public) drawables=\(self.drawablePoolCount, privacy: .public) requestedFPS=\(view.preferredFramesPerSecond, privacy: .public) immediate=\(self.immediateSourceDraw, privacy: .public) ticks=\(window.ticks, privacy: .public) sourceWakes=\(window.sourceWakes, privacy: .public) noSubmission=\(window.noSubmission, privacy: .public) originalSubmitted=\(window.originalSubmissions, privacy: .public) otherSubmitted=\(window.otherSubmissions, privacy: .public) geometryRetries=\(window.geometryRetries, privacy: .public) backingChanges=\(window.backingChanges, privacy: .public) acquisitions=\(window.acquisitions, privacy: .public) missing=\(window.missingDrawables, privacy: .public) waitMeanMs=\(window.meanAcquireMs, privacy: .public) waitMaxMs=\(window.maximumAcquireMs, privacy: .public) waitsOver16ms=\(window.waitsOverFrame, privacy: .public)")
        pacingDiagnostics = OwnedVideoPacingWindow()
        pacingWindowStartedAt = now
    }
    /// Core Animation runs presented handlers while holding the layer's private lock, and this view
    /// calls `addPresentedHandler` on main while holding the fence. Waiting on the fence inside the
    /// handler inverts that order and deadlocks main (20260930.8 watchdog reports), so the handler
    /// only enqueues; admission is rechecked off Core Animation's thread.
    static let presentedReceiptQueue = DispatchQueue(label: "farside.owned-video.presented", qos: .userInteractive)
    func presentedReceipt(_ envelope: VideoFrameEnvelope, commit: PresentationStamp? = nil,
                          callback: ((VideoPresentationIdentity, UUID) -> Void)?) -> (CFTimeInterval) -> Void {
        { [weak self] presentedTime in
            guard presentedTime.isFinite, presentedTime > 0 else {
                Self.presentedReceiptQueue.async {
                    guard let self, envelope.originalSource else { return }
                    _ = self.fence.withAdmission(envelope.identity, at: ProcessInfo.processInfo.systemUptime) { self.counters?.presentedDropped() }
                }
                return
            }
            Self.presentedReceiptQueue.async {
                guard let self else { return }
                _ = self.fence.withAdmission(envelope.identity, at: ProcessInfo.processInfo.systemUptime) {
                    self.counters?.presentedFrame(atMs: presentedTime * 1000, marker: envelope.marker)
                    if envelope.originalSource, let trace = envelope.decodeTrace {
                        if let callbackMs = trace.callbackMs {
                            self.counters?.phoneRenderTiming(.decodedToPresented, milliseconds: presentedTime * 1000 - callbackMs)
                        }
                        self.counters?.phoneRenderTiming(.deliveryToPresented, milliseconds: presentedTime * 1000 - trace.deliveryMs)
                    }
                    if envelope.originalSource, let commitMs = commit?.commitMs {
                        self.counters?.phoneRenderTiming(.commitToPresented, milliseconds: presentedTime * 1000 - commitMs)
                    }
                    let clock = self.counters?.clockObservation
                    self.videoFeedback?.presentedTiming(envelope.videoTag, originalSource: envelope.originalSource,
                        newSubmission: true, presentedTime: presentedTime,
                        clock: clock?.estimate, observedAtMs: clock?.atMs)
                    if envelope.originalSource { self.textSnapshotPresented?(envelope) }
                    if envelope.originalSource { callback?(envelope.identity, envelope.receiptID) }
                }
            }
        }
    }
    private func showFallbackIfAdmitted(_ envelope: VideoFrameEnvelope) {
        guard viewportCoverage == nil else { return } // Compatibility rendering has no positive presentation receipt.
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
    private static func renderPass(into drawable: CAMetalDrawable, clearing color: MTLClearColor) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = color
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
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
    struct S { float4 rect; float4 shift; };
    struct V { float4 position [[position]]; float2 uv; float2 displayUV; };
    // Bend only the outer 30% of the circular picture. Coordinates are measured in
    // the displayed view, so a rotated source bends at the visible rim as well.
    float2 glassDisplayUV(float2 displayUV, float aspect) {
        float safeAspect=max(aspect,0.0001);
        float2 circleScale=float2(max(safeAspect,1.0),max(1.0/safeAspect,1.0));
        float2 centered=displayUV-0.5;
        float radius=length(centered*circleScale)*2.0;
        float bend=0.10*smoothstep(0.70,1.0,radius);
        return 0.5+centered*(1.0-bend);
    }
    // Used by SwiftUI's offline preview; the live renderer applies the same map
    // before its source rotation and crop.
    [[stitchable]] float2 readingGlassLens(float2 position, float2 size) {
        float2 safeSize=max(size,float2(1.0));
        return glassDisplayUV(position/safeSize,safeSize.x/safeSize.y)*safeSize;
    }
    float2 glassSourceUV(float2 displayUV, constant U &u, float aspect) {
        float2 mapped=glassDisplayUV(displayUV,aspect);
        if(u.rotation==1) mapped=float2(mapped.y,1.0-mapped.x);
        if(u.rotation==2) mapped=1.0-mapped;
        if(u.rotation==3) mapped=float2(1.0-mapped.y,mapped.x);
        return u.crop.xy+mapped*u.crop.zw;
    }
    // Optimistic local scroll: inside the clip rect, show the picture moved by shift.xy; the strip it
    // vacates repeats the rect's own edge pixels (shift.zw is half a picture pixel).
    float2 scrolledSourceUV(float2 displayUV, constant U &u, constant S &s) {
        float2 d=displayUV;
        if(all(d>=s.rect.xy) && all(d<s.rect.xy+s.rect.zw)) d=clamp(d-s.shift.xy,s.rect.xy+s.shift.zw,s.rect.xy+s.rect.zw-s.shift.zw);
        if(u.rotation==1) d=float2(d.y,1.0-d.x);
        if(u.rotation==2) d=1.0-d;
        if(u.rotation==3) d=float2(1.0-d.y,d.x);
        return u.crop.xy+d*u.crop.zw;
    }
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
        V o; o.position=float4(p[i]*u.extent,0,1); o.uv=u.crop.xy+uv*u.crop.zw; o.displayUV=t[i]; return o;
    }
    fragment float4 fragmentNV12(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]], constant R &r [[buffer(1)]], texture2d<float> refinement [[texture(2)]], constant float2 &lens [[buffer(2)]], constant S &scroll [[buffer(3)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 sampleUV=lens.x!=0.0 ? glassSourceUV(v.displayUV,u,lens.y) : (scroll.shift.x==0.0 && scroll.shift.y==0.0 ? v.uv : scrolledSourceUV(v.displayUV,u,scroll));
        float2 t=clamp(sampleUV,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
        float l=(y.sample(s,t).r-u.color.z)*u.color.w;
        float2 c=(uv.sample(s,t).rg-float2(128.0/255.0))*u.range.x;
        float kr=u.color.x,kb=u.color.y,kg=1-kr-kb;
        return float4(refined(displayEncoded(float3(l+2*(1-kr)*c.y,l-2*kb*(1-kb)/kg*c.x-2*kr*(1-kr)/kg*c.y,l+2*(1-kb)*c.x),u),sampleUV,r,refinement),1);
    }
    fragment float4 fragmentBGRA(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]], constant R &r [[buffer(1)]], texture2d<float> refinement [[texture(2)]], constant float2 &lens [[buffer(2)]], constant S &scroll [[buffer(3)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 sampleUV=lens.x!=0.0 ? glassSourceUV(v.displayUV,u,lens.y) : (scroll.shift.x==0.0 && scroll.shift.y==0.0 ? v.uv : scrolledSourceUV(v.displayUV,u,scroll));
        float2 t=clamp(sampleUV,u.crop.xy+u.range.yz,u.crop.xy+u.crop.zw-u.range.yz);
        return float4(refined(displayEncoded(image.sample(s,t).rgb,u),sampleUV,r,refinement),1);
    }
    """
}

extension OwnedMetalVideoView: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        drawLinkFrame(into: update.drawable)
    }
    /// One link callback on the main run loop: the ordinary tick draw, taking this drawable instead of asking
    /// MTKView for one. With nothing to draw the drawable is left untouched and released with the update.
    func drawLinkFrame(into drawable: CAMetalDrawable) {
        linkDrawable = drawable
        defer { linkDrawable = nil }
        draw(in: metal)
    }
}

/// The commit time of one draw, written on main after `commit()` and read on the receipt queue once Core
/// Animation reports the drawable presented.
final class PresentationStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double?
    var commitMs: Double? {
        get { lock.lock(); defer { lock.unlock() }; return ms }
        set { lock.lock(); ms = newValue; lock.unlock() }
    }
}

/// Drawable pool size, frozen once per registered renderer. Three by default since the 7 Oct 2026
/// device A/B (drawable wait p99 14 → 0.1 ms, source-to-present p95 92 → 59 ms); 2 restores the old pool.
enum OwnedVideoPacingExperiment {
    static let drawableCountKey = "farsidePhoneRendererDrawableCount"
    static let diagnosticsKey = "farsidePhoneRendererPacingDiagnostics"
    static func drawableCount(defaults: UserDefaults) -> Int {
        defaults.integer(forKey: drawableCountKey) == 2 ? 2 : 3
    }
    static func diagnosticsEnabled(defaults: UserDefaults) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: diagnosticsKey)
        #else
        return false
        #endif
    }
}

/// One bounded main-thread telemetry window; no frames, identifiers or growing sample history.
struct OwnedVideoPacingWindow {
    enum Origin { case tick, sourceWake }
    private(set) var ticks = 0
    private(set) var sourceWakes = 0
    var noSubmission = 0
    var originalSubmissions = 0
    var otherSubmissions = 0
    var geometryRetries = 0
    var backingChanges = 0
    private(set) var acquisitions = 0
    private(set) var missingDrawables = 0
    private(set) var maximumAcquireMs = 0.0
    private(set) var waitsOverFrame = 0
    private var totalAcquireMs = 0.0
    var meanAcquireMs: Double { acquisitions > 0 ? totalAcquireMs / Double(acquisitions) : 0 }
    mutating func draw(_ origin: Origin) {
        switch origin { case .tick: ticks += 1; case .sourceWake: sourceWakes += 1 }
    }
    mutating func acquired(milliseconds: Double, available: Bool) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        acquisitions += 1
        if !available { missingDrawables += 1 }
        totalAcquireMs += milliseconds
        maximumAcquireMs = max(maximumAcquireMs, milliseconds)
        if milliseconds > 1000 / 60 { waitsOverFrame += 1 }
    }
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

/// Local camera motion accepts only a tagged original picture that covers its entire path.
/// Renderer lifetime/privacy authority remains independently fenced at every effect.
private struct ViewportCoverageConstraint {
    let generation: UInt64
    var required: CGRect
    let scope: UInt64
    var presented = false
    func accepts(_ envelope: VideoFrameEnvelope, identity: VideoPresentationIdentity) -> Bool {
        guard envelope.identity == identity, envelope.originalSource,
              let tag = envelope.videoTag, (try? tag.validate()) != nil,
              tag.geometryEpoch == identity.geometryEpoch, tag.scopeEpoch == scope,
              let region = tag.region, (try? region.validate()) != nil,
              region.outputWidth == Int(envelope.frame.width), region.outputHeight == Int(envelope.frame.height) else { return false }
        return region.rect.insetBy(dx: -0.01, dy: -0.01).contains(required)
    }
}
