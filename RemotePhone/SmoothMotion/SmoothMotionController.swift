import CoreVideo
import Foundation
import MetalKit
import QuartzCore
import WebRTC

/// D40 Smooth motion: shows 120 Hz motion from the Mac's 60 fps stream by presenting a
/// VideoToolbox midpoint N−½ one display tick before each source frame N.
///
/// Latency: N is held until its midpoint has been made and shown, so while engaged each source
/// frame reaches the view one display tick plus processing later than pass-through (measured as
/// "added latency"). Auto keeps this off while typing and tapping.
///
/// Pointer: the pointer overlay is drawn by the phone at 120 Hz from its own state and is never
/// interpolated or delayed. The picture and the pointer share one viewport placement, so pans and
/// zooms move them together; only the Mac content under the pointer is up to one extra frame
/// older while engaged. Delaying the pointer to match would put that frame on every pointer
/// movement, including precise targeting, which is the thing Farside most needs to feel direct.
///
/// Fallback: anything unexpected (no processor, a rejected size or format, an error, a pair still
/// in flight when the next frame lands, serious thermal state, a display under 120 Hz) shows the
/// frame directly, exactly as with the feature off.
final class SmoothMotionController: @unchecked Sendable {
    typealias Output = (frame: RTCVideoFrame, marker: BenchMarker?)

    struct Environment {
        var makeEngine: () -> FrameInterpolationEngine?
        var supported: Bool
        var limits: InterpolationLimits
        var upscaleLimits: InterpolationLimits?
        var now: () -> TimeInterval
        var thermal: () -> ProcessInfo.ThermalState
        var queue: DispatchQueue
        var fitOversize = SmoothMotionFitOversizeSwitch.isOn
        var midpointDeadline = SmoothMotionMidpointDeadlineSwitch.isOn
        var colorTags = InterpolationColorTagsSwitch.isOn
        var lowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        var lowPowerBypass = InterpolationLPMBypassSwitch.isOn

        static var live: Environment {
            Environment(makeEngine: InterpolationAvailability.makeEngine,
                        supported: InterpolationAvailability.isSupported,
                        limits: InterpolationAvailability.limits,
                        upscaleLimits: InterpolationAvailability.upscaleLimits,
                        now: CACurrentMediaTime,
                        thermal: { ProcessInfo.processInfo.thermalState },
                        queue: DispatchQueue(label: "Farside.smooth-motion", qos: .userInteractive))
        }
    }

    /// Busy frames within `behindWindow` that put interpolation into a cooldown.
    static let behindLimit = 6
    static let behindWindow: TimeInterval = 1
    static let cooldown: TimeInterval = 3
    static let errorLimit = 3
    static let logEvery: TimeInterval = 10

    /// The controller on screen, for input hints and the settings readout. Main thread.
    private(set) static weak var active: SmoothMotionController?

    private final class Sink: @unchecked Sendable {
        var deliver: ((Output) -> Void)?
    }

    let diagnostics = SmoothMotionDiagnostics()
    let interpolator: FrameInterpolator
    private let environment: Environment
    private let preparer = SmoothMotionInputPreparer()
    private let sink = Sink()
    private let presenter: SmoothMotionPresenter<Output>
    private let lock = NSLock()
    private var policy: SmoothMotionPolicy
    private var upscale = false
    private var sampler = FrameChangeSampler()
    private var sequence: Int64 = 0
    private var lastArrival: TimeInterval?
    private var sourceInterval: TimeInterval = 1.0 / 60
    private var displayCapable: Bool?
    private var displayCadence = SmoothMotionDisplayCadence()
    private var busyTimes: [TimeInterval] = []
    private var cooldownUntil = -TimeInterval.infinity
    private var consecutiveErrors = 0
    private var failed = false
    private var wasEngaged = false
    private var reportedBlock: String?
    private var referenceHeld = false
    private var lastGeometry: FrameGeometry?
    private var lastDropped = 0
    private var lastLog = -TimeInterval.infinity
    private var loggedAvailability = false

    init(mode: SmoothMotionMode = .stored(), environment: Environment = .live) {
        self.environment = environment
        policy = SmoothMotionPolicy(mode: mode)
        interpolator = FrameInterpolator(queue: environment.queue, colorTags: environment.colorTags,
                                         makeEngine: environment.makeEngine)
        presenter = SmoothMotionPresenter<Output>(deliver: { [sink] in sink.deliver?($0) })
        diagnostics.reset(mode: mode)
    }

    /// Hands a frame to the video view. Set once, before any frame arrives.
    var deliver: ((Output) -> Void)? {
        get { sink.deliver }
        set { sink.deliver = newValue }
    }

    // MARK: Main thread

    func activate() { Self.active = self }

    func deactivate() {
        if Self.active === self { Self.active = nil }
        interpolator.stop()
        presenter.flush(at: environment.now())
    }

    var mode: SmoothMotionMode {
        lock.lock(); defer { lock.unlock() }
        return policy.mode
    }

    func setMode(_ mode: SmoothMotionMode) {
        lock.lock()
        let changed = policy.mode != mode
        policy.mode = mode
        lock.unlock()
        guard changed else { return }
        if mode == .off { interpolator.stop() }
        presenter.flush(at: environment.now())
    }

    /// Hidden Diagnostics A/B: interpolate at half size with the processor's 2× upscale (iOS 27).
    func setUpscale(_ enabled: Bool) {
        lock.lock(); upscale = enabled; lock.unlock()
    }

    /// A new stream (track): per-session diagnostics start again.
    func resetSession() {
        interpolator.stop()
        presenter.flush(at: environment.now())
        lock.lock()
        let mode = policy.mode
        policy = SmoothMotionPolicy(mode: mode)
        sampler.reset()
        lastArrival = nil
        if environment.lowPowerBypass {
            displayCapable = nil
            displayCadence = SmoothMotionDisplayCadence()
        }
        busyTimes.removeAll()
        cooldownUntil = -.infinity
        consecutiveErrors = 0
        failed = false
        wasEngaged = false
        reportedBlock = nil
        referenceHeld = false
        lastGeometry = nil
        loggedAvailability = false
        lock.unlock()
        diagnostics.reset(mode: mode)
        environment.queue.async { [preparer] in preparer.reset() }
    }

    static func note(_ hint: SmoothMotionHint) {
        active?.note(hint, at: CACurrentMediaTime())
    }

    /// Every outgoing control action passes here (see `PhoneRemoteModel.transmit`).
    static func noteOutgoing(action: String, dragging: Bool) {
        guard let hint = SmoothMotionHint.classify(action: action, dragging: dragging) else { return }
        note(hint)
    }

    func note(_ hint: SmoothMotionHint, at now: TimeInterval) {
        lock.lock(); policy.note(hint, at: now); lock.unlock()
    }

    /// Start of each video view draw, before WebRTC's renderer draws: hands over the paced
    /// midpoint or held source frame that is due, so it is drawn in this same display tick.
    func displayTick(_ view: MTKView) {
        if let owned = view.superview as? OwnedMetalVideoView { owned.renderDiagnostics = diagnostics }
        let screenMaximum = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        displayTick(at: environment.now(), framesPerSecond: view.preferredFramesPerSecond,
                    capable: StreamTuning.current.presentAtDisplayMaximum && screenMaximum >= 100)
    }

    func displayTick(at now: TimeInterval, framesPerSecond: Int, capable: Bool) {
        lock.lock()
        displayCapable = capable
        if environment.lowPowerBypass { displayCadence.observe(at: now) }
        let bypass = environment.lowPowerBypass &&
            (environment.lowPower() || !capable || !displayCadence.permitsInterpolation)
        let stop = bypass && wasEngaged
        if stop { wasEngaged = false }
        let tick = environment.lowPowerBypass
            ? min(1.0 / 30, max(1.0 / 120, displayCadence.interval ?? 1.0 / 60))
            : 1.0 / Double(min(120, max(30, framesPerSecond)))
        lock.unlock()
        if stop { interpolator.stop() }
        let delivery = bypass ? presenter.flush(at: now) : presenter.pump(at: now, tick: tick)
        if let delay = delivery?.addedDelay {
            diagnostics.addedLatency(delay)
        }
        let dropped = presenter.dropped
        lock.lock()
        let newDrops = dropped - lastDropped
        lastDropped = dropped
        lock.unlock()
        diagnostics.dropped(newDrops)
    }

    // MARK: Decode thread

    /// Every decoded frame. Returns at once: the frame is shown now, or held for a pair that is
    /// already on the interpolator's queue.
    func receive(_ frame: RTCVideoFrame, marker: BenchMarker?) {
        let now = environment.now()
        let source = SmoothMotionSource(frame)
        lock.lock()
        sequence += 1
        let order = sequence * 2
        if let lastArrival, now > lastArrival, now - lastArrival < 0.1 {
            sourceInterval = sourceInterval * 0.8 + (now - lastArrival) * 0.2
        }
        lastArrival = now
        let mode = policy.mode
        var change: Double?
        if mode == .auto, environment.supported, let source {
            if source.geometry != lastGeometry { sampler.reset() }
            change = source.withLuma { luma, width, height, stride in
                sampler.change(luma: luma, width: width, height: height, bytesPerRow: stride)
            }
        }
        lastGeometry = source?.geometry
        let plan = source.flatMap {
            InterpolationPlan.make(for: $0.geometry, limits: environment.limits, upscaleLimits: environment.upscaleLimits,
                                   upscale: upscale, fitOversize: environment.fitOversize)
        }
        let block = currentBlock(at: now, source: source, plan: plan)
        policy.block = block
        policy.frameArrived(change: change, at: now)
        let engaged = policy.evaluate(at: now)
        let state = policy.state.reason
        let disengaged = wasEngaged && !engaged
        wasEngaged = engaged
        var fallback: String?
        if let block, block != .display || displayCapable == false, reportedBlock != block.rawValue,
           mode != .off, source != nil {
            fallback = block.rawValue
        }
        reportedBlock = block?.rawValue
        let interval = sourceInterval
        let logNow = now - lastLog >= Self.logEvery && mode != .off
        if logNow { lastLog = now }
        let logAvailability = !loggedAvailability
        loggedAvailability = true
        lock.unlock()

        if logAvailability {
            InterpolationAvailability.logger.notice("smooth-motion \(InterpolationAvailability.summary, privacy: .public)")
        }
        if let fallback { diagnostics.fallback(fallback) }
        diagnostics.frameArrived(engaged: engaged, state: state, mode: mode, at: now)
        if logNow {
            let line = diagnostics.snapshot().overlayLine
            InterpolationAvailability.logger.notice("\(line, privacy: .public)")
        }
        if disengaged { presenter.flush(at: now) }

        guard engaged, let source, let plan else {
            presentDirect(frame, marker, order: order, at: now, arrival: nil)
            // Warm the session while streaming: loading its model can take longer than a frame,
            // and Auto should not spend the first frames of a scroll waiting for it.
            if mode != .off, block == nil, let plan {
                interpolator.prepare(for: plan.setup) { [weak self] in self?.sessionPrepared(plan.setup, $0) }
            }
            return
        }
        if interpolator.rejection(for: plan.setup) != nil {
            presentDirect(frame, marker, order: order, at: now, arrival: nil)
            return
        }
        if !interpolator.isReady(for: plan.setup) {
            interpolator.prepare(for: plan.setup) { [weak self] result in
                self?.sessionPrepared(plan.setup, result)
            }
            presentDirect(frame, marker, order: order, at: now, arrival: nil)
            return
        }
        if environment.midpointDeadline { presenter.dropMidpoints() }
        let submission = interpolator.submit(time: now, setup: plan.setup, prepare: { [preparer] in
            preparer.input(for: source, setup: plan.setup)
        }, completion: { [weak self] outcome in
            self?.finished(outcome, frame: frame, marker: marker, source: source, plan: plan,
                           order: order, arrival: now, interval: interval)
        })
        switch submission {
        case .accepted:
            lock.lock(); referenceHeld = true; lock.unlock()
        case .busy:
            diagnostics.busy()
            noteBusy(at: now)
            presentDirect(frame, marker, order: order, at: now, arrival: now)
        case .notReady:
            presentDirect(frame, marker, order: order, at: now, arrival: nil)
        }
    }

    // MARK: Interpolator queue

    private func finished(_ outcome: FrameInterpolator.Outcome, frame: RTCVideoFrame, marker: BenchMarker?,
                          source: SmoothMotionSource, plan: InterpolationPlan, order: Int64,
                          arrival: TimeInterval, interval: TimeInterval) {
        let now = environment.now()
        switch outcome {
        case .interpolated(let frames, let input, let ms):
            lock.lock()
            consecutiveErrors = 0
            let bypass = environment.lowPowerBypass &&
                (environment.lowPower() || displayCapable != true || !displayCadence.permitsInterpolation)
            lock.unlock()
            if bypass {
                // Power/cadence may change while VT owns the pair. Never enqueue its midpoint
                // after a bypass flushed the presenter; show the decoded source directly.
                diagnostics.processed(ms: ms, interpolated: false)
                presentDirect(frame, marker, order: order, at: now, arrival: arrival)
                return
            }
            diagnostics.processed(ms: ms, interpolated: true)
            if ms > interval * 900 { noteBusy(at: now) }
            let shown = frames.upscaledSource ?? (plan.fitted ? input : nil)
            let sourceOutput: Output = (shown.map { Self.frame($0, like: source) } ?? frame, marker)
            let spacing = min(max(interval / 2, 1.0 / 120), 1.0 / 40)
            presenter.enqueue([
                .init(payload: (Self.frame(frames.middle, like: source), nil), order: order - 1, spacing: 0, arrival: nil,
                      deadline: environment.midpointDeadline ? arrival + interval : nil),
                .init(payload: sourceOutput, order: order, spacing: spacing, arrival: arrival),
            ])
        case .primed(let input):
            let shown = plan.fitted ? Self.frame(input, like: source) : frame
            if presenter.presentNow((shown, marker), order: order, at: now) { diagnostics.addedLatency(now - arrival) }
        case .failed(let error, _, let ms):
            diagnostics.processed(ms: ms, interpolated: false)
            diagnostics.fallback(error.description)
            lock.lock()
            consecutiveErrors += 1
            let stop = consecutiveErrors >= Self.errorLimit
            if stop { failed = true }
            lock.unlock()
            if stop { interpolator.stop() }
            if presenter.presentNow((frame, marker), order: order, at: now) { diagnostics.addedLatency(now - arrival) }
        }
    }

    private func sessionPrepared(_ setup: InterpolationSetup, _ result: Result<Double, InterpolationError>) {
        switch result {
        case .success(let ms): diagnostics.sessionStarted(setup: setup.description, ms: ms)
        case .failure(let error): diagnostics.fallback("\(setup): \(error)")
        }
    }

    // MARK: Helpers

    private func presentDirect(_ frame: RTCVideoFrame, _ marker: BenchMarker?, order: Int64,
                               at now: TimeInterval, arrival: TimeInterval?) {
        presenter.presentNow((frame, marker), order: order, at: now)
        if let arrival { diagnostics.addedLatency(now - arrival) }
        lock.lock()
        let drop = referenceHeld
        referenceHeld = false
        lock.unlock()
        if drop { interpolator.dropReference() }
    }

    /// Caller holds `lock`.
    private func currentBlock(at now: TimeInterval, source: SmoothMotionSource?, plan: InterpolationPlan?) -> SmoothMotionBlock? {
        if !environment.supported { return .unsupported }
        if case .unavailable = interpolator.currentPhase { return .unsupported }
        if environment.lowPowerBypass, environment.lowPower() { return .lowPower }
        if displayCapable != true { return .display }
        if environment.lowPowerBypass, !displayCadence.permitsInterpolation { return .display }
        if failed { return .failed }
        switch environment.thermal() {
        case .serious, .critical: return .thermal
        default: break
        }
        if now < cooldownUntil { return .behind }
        if source != nil, plan == nil { return .size }
        if let plan, let error = interpolator.rejection(for: plan.setup) {
            switch error {
            case .unsupportedFormat: return .format
            case .tooLarge, .configurationRejected: return .size
            default: return .failed
            }
        }
        return nil
    }

    private func noteBusy(at now: TimeInterval) {
        lock.lock()
        busyTimes.append(now)
        busyTimes.removeAll { now - $0 > Self.behindWindow }
        let behind = busyTimes.count >= Self.behindLimit
        if behind {
            cooldownUntil = now + Self.cooldown
            busyTimes.removeAll()
        }
        lock.unlock()
    }

    /// The same picture area as the source, in the output buffer's pixels.
    static func frame(_ buffer: CVPixelBuffer, like source: SmoothMotionSource) -> RTCVideoFrame {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sx = Double(width) / Double(source.geometry.width)
        let sy = Double(height) / Double(source.geometry.height)
        func even(_ value: Double) -> Int32 { Int32(Int(value.rounded()) & ~1) }
        let cropX = min(even(source.crop.minX * sx), Int32(width - 2))
        let cropY = min(even(source.crop.minY * sy), Int32(height - 2))
        let cropWidth = max(2, min(even(source.crop.width * sx), Int32(width) - cropX))
        let cropHeight = max(2, min(even(source.crop.height * sy), Int32(height) - cropY))
        let wrapped = RTCCVPixelBuffer(pixelBuffer: buffer, adaptedWidth: cropWidth, adaptedHeight: cropHeight,
                                       cropWidth: cropWidth, cropHeight: cropHeight, cropX: cropX, cropY: cropY)
        return RTCVideoFrame(buffer: wrapped, rotation: source.rotation, timeStampNs: 0)
    }
}

/// Kill switch for full-size pass-through (`defaults write com.roshan.PocketDesk.Remote
/// PocketDeskSmoothMotionFitOversize -bool YES`, then relaunch the phone app). YES restores
/// interpolating a source above the interpolator's limit from a fitted copy, which also shows the
/// source frames at that smaller size while engaged.
enum SmoothMotionFitOversizeSwitch {
    static let defaultsKey = "PocketDeskSmoothMotionFitOversize"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
}

/// Kill switch for the midpoint deadline (`defaults write com.roshan.PocketDesk.Remote
/// PocketDeskSmoothMotionMidpointDeadline -bool NO`, then relaunch the phone app). NO shows every
/// midpoint however late its pair finished, and the source frame waits behind it.
enum SmoothMotionMidpointDeadlineSwitch {
    static let defaultsKey = "PocketDeskSmoothMotionMidpointDeadline"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
}
