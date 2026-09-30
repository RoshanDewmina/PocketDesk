import MetalKit
import UIKit

/// Counts decoded frames that reach a draw call and those replaced before one did.
/// Thread-safe: frames arrive on WebRTC's decode thread, draws run on the main thread.
final class PresentationTracker: @unchecked Sendable {
    private struct PendingFrame {
        let stampNs: Int64
        let arrivalMs: Double
    }

    private static let pendingLimit = 256
    private let lock = NSLock()
    private var pending: [PendingFrame] = []
    private var discardedBeforePending = 0

    /// Registers the restamped identity before RTCMTLVideoView receives the frame.
    func frameWillForward(stampNs: Int64, atMs: Double = MachClock.nowMs()) {
        lock.lock()
        if pending.count == Self.pendingLimit {
            pending.removeFirst()
            discardedBeforePending += 1
        }
        pending.append(PendingFrame(stampNs: stampNs, arrivalMs: atMs))
        lock.unlock()
    }

    /// A decoded frame arrived since the last draw.
    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Returns a sample only when RTCMTLVideoView confirms the exact stamp it completed.
    /// Frames registered after that stamp remain pending for a later draw.
    func drew(stampNs: Int64, atMs: Double = MachClock.nowMs()) -> (latencyMs: Double, superseded: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let index = pending.firstIndex(where: { $0.stampNs == stampNs }) else { return nil }
        let frame = pending[index]
        let result = (max(0, atMs - frame.arrivalMs), discardedBeforePending + index)
        pending.removeFirst(index + 1)
        discardedBeforePending = 0
        return result
    }
}

/// Rendezvous between a drawable's presented handler and the exact completed WebRTC stamp.
/// An unrecognized or unavailable stamp never resolves, so it cannot become a presentation sample.
final class PresentedFrameMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var stored: BenchMarker?
    private var waiting: ((BenchMarker?) -> Void)?

    func resolve(marker: BenchMarker?) {
        lock.lock()
        resolved = true
        stored = marker
        let callback = waiting
        waiting = nil
        lock.unlock()
        callback?(marker)
    }

    /// Runs only after the draw has been matched to an exact registered stamp. The drawable may
    /// present before or after that match, so the two events rendezvous here without guessing.
    func whenResolved(_ callback: @escaping (BenchMarker?) -> Void) {
        lock.lock()
        if resolved {
            let marker = stored
            lock.unlock()
            callback(marker)
        } else {
            waiting = callback
            lock.unlock()
        }
    }
}

/// Efficiency audit P2: the video view's refresh while the Mac picture is static. The view drops
/// to `idleFramesPerSecond` once `idleAfter` passes without a new frame or a touch, and returns to
/// its full rate on the next one; a frame that ends idle is drawn at once (`raiseAndDraw`), so
/// going idle never delays the first changed frame. Not thread-safe; the probe locks around it.
struct VideoRefreshPolicy: Equatable {
    static let idleFramesPerSecond = 30
    static let idleAfter: TimeInterval = 0.25

    enum Wake: Equatable { case none, raise, raiseAndDraw }

    let activeFramesPerSecond: Int
    private(set) var idle = false
    private var lastSignal: TimeInterval

    init(activeFramesPerSecond: Int, now: TimeInterval) {
        self.activeFramesPerSecond = activeFramesPerSecond
        lastSignal = now
    }

    var framesPerSecond: Int { idle ? min(Self.idleFramesPerSecond, activeFramesPerSecond) : activeFramesPerSecond }

    /// A decoded frame (`newFrame`) or a touch, pan, zoom or pointer motion.
    mutating func signal(at now: TimeInterval, newFrame: Bool) -> Wake {
        lastSignal = max(lastSignal, now)
        guard idle else { return .none }
        idle = false
        return newFrame ? .raiseAndDraw : .raise
    }

    /// After each draw: a frame still waiting counts as activity; otherwise go idle once quiet.
    mutating func drew(at now: TimeInterval, framePending: Bool) {
        if framePending {
            lastSignal = max(lastSignal, now)
        } else if !idle, now - lastSignal >= Self.idleAfter {
            idle = true
        }
    }
}

/// Raises the WebRTC Metal view's refresh to the display maximum (120 Hz on ProMotion with
/// `CADisableMinimumFrameDurationOnPhone`) and times decoded-frame → draw-call latency by
/// forwarding the MTKView delegate. RTCMTLVideoView still does all rendering; if its private
/// MTKView cannot be found, presentation is left exactly as WebRTC configured it.
///
/// While Stream statistics is on (`markerForStamp` is set), every draw of a new decoded frame
/// also registers a presented handler on the drawable WebRTC is about to present, so the phone
/// learns when that frame physically reached the display and which bench marker it carried.
final class VideoPresentationProbe: NSObject, MTKViewDelegate {
    static let preferredFramesPerSecond = 120
    static let drawnStampKey = "lastFrameTimeNs"

    let tracker = PresentationTracker()
    private weak var renderer: (any MTKViewDelegate)?
    private weak var metalView: MTKView?
    /// Compatibility-gated because WebRTC does not publish the completed stamp in its header.
    /// M153 updates `lastFrameTimeNs` only after the Metal renderer accepts the frame.
    var drawnStampReader: (() -> Int64?)?
    var counters: StreamCounters?
    private var reportedRate = false
    private var chosenFramesPerSecond: Int?
    /// P2, shared between the decode thread (frame arrivals) and the main thread (draws, touches).
    private let refreshLock = NSLock()
    private var refresh: VideoRefreshPolicy?
    private var wakeScheduled = false
    /// The probe on screen, for touches and input that should end idle refresh at once. Main thread.
    private(set) static weak var active: VideoPresentationProbe?

    /// Stream statistics: the bench marker of the frame forwarded with this stamp.
    var markerForStamp: ((Int64) -> BenchMarker?)?
    /// Smooth motion (D40) hands its paced frame over here so this same draw shows it.
    var beforeDraw: ((MTKView) -> Void)?
    /// MTKView creates its drawable lazily and WebRTC's renderer then presents that same one.
    var drawableProvider: (MTKView) -> (any MTLDrawable)? = { $0.currentDrawable }

    /// Returns nil when the view hierarchy is not the expected RTCMTLVideoView → MTKView shape.
    static func install(on videoView: UIView) -> VideoPresentationProbe? {
        guard let metalView = findMetalView(in: videoView),
              let renderer = metalView.delegate, renderer !== metalView else { return nil }
        let probe = VideoPresentationProbe()
        probe.renderer = renderer
        probe.metalView = metalView
        // A missing key would raise through KVC, so only install a reader when the shipped
        // RTCMTLVideoView exposes the M153 compatibility selector.
        if videoView.responds(to: NSSelectorFromString(drawnStampKey)) {
            probe.drawnStampReader = { [weak videoView] in
                (videoView?.value(forKey: Self.drawnStampKey) as? NSNumber)?.int64Value
            }
        }
        if StreamTuning.current.presentAtDisplayMaximum {
            metalView.preferredFramesPerSecond = preferredFramesPerSecond
            probe.chosenFramesPerSecond = preferredFramesPerSecond
            // Two drawables instead of three: one fewer frame waiting between draw and scan-out.
            (metalView.layer as? CAMetalLayer)?.maximumDrawableCount = 2
            if StreamTuning.current.idleVideoRefresh {
                probe.refresh = VideoRefreshPolicy(activeFramesPerSecond: preferredFramesPerSecond,
                                                   now: ProcessInfo.processInfo.systemUptime)
            }
        }
        metalView.delegate = probe
        active = probe
        return probe
    }

    static func findMetalView(in view: UIView) -> MTKView? {
        if let metal = view as? MTKView { return metal }
        for subview in view.subviews {
            if let found = findMetalView(in: subview) { return found }
        }
        return nil
    }

    func uninstall() {
        if let metalView, metalView.delegate === self { metalView.delegate = renderer }
        if Self.active === self { Self.active = nil }
        refreshLock.lock(); refresh = nil; refreshLock.unlock()
        if let metalView, let chosenFramesPerSecond { metalView.preferredFramesPerSecond = chosenFramesPerSecond }
    }

    /// The frame refresh the view should run at now: the chosen rate, or the idle rate (P2).
    var targetFramesPerSecond: Int? {
        refreshLock.lock(); defer { refreshLock.unlock() }
        return refresh?.framesPerSecond ?? chosenFramesPerSecond
    }

    /// Decode thread, after the frame reached RTCMTLVideoView: ends idle refresh and draws it now.
    func frameForwarded(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        signal(at: now, newFrame: true)
    }

    /// Touch, pan, zoom or pointer motion on the session (main thread).
    static func noteUserActivity(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        VideoPresentationSession.noteUserActivity(at: now)
        active?.signal(at: now, newFrame: false)
    }

    private func signal(at now: TimeInterval, newFrame: Bool) {
        refreshLock.lock()
        guard var policy = refresh else { refreshLock.unlock(); return }
        let wake = policy.signal(at: now, newFrame: newFrame)
        refresh = policy
        let schedule = wake != .none && !wakeScheduled
        if schedule { wakeScheduled = true }
        refreshLock.unlock()
        guard schedule else { return }
        let draw = wake == .raiseAndDraw
        if Thread.isMainThread && !draw {
            applyWake(draw: false)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyWake(draw: draw) }
        }
    }

    private func applyWake(draw: Bool) {
        refreshLock.lock()
        wakeScheduled = false
        let target = refresh?.framesPerSecond
        refreshLock.unlock()
        guard let metalView, let target else { return }
        if metalView.preferredFramesPerSecond != target { metalView.preferredFramesPerSecond = target }
        // The display link may be up to one idle interval away; draw the new frame now.
        if draw, metalView.delegate === self, metalView.window != nil { metalView.draw() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        beforeDraw?(view)
        let presentation = observePresentation(in: view)
        renderer?.draw(in: view)
        let drawnStamp = drawnStampReader?()
        refreshLock.lock()
        refresh?.drew(at: ProcessInfo.processInfo.systemUptime, framePending: tracker.hasPending)
        let target = refresh?.framesPerSecond ?? chosenFramesPerSecond
        refreshLock.unlock()
        // WebRTC's Metal renderer sets 30 fps on the view when it starts on the first frame.
        if let target, view.preferredFramesPerSecond != target {
            view.preferredFramesPerSecond = target
        }
        if !reportedRate, let screen = view.window?.windowScene?.screen {
            reportedRate = true
            counters?.setDisplayMaxFPS(min(screen.maximumFramesPerSecond, chosenFramesPerSecond ?? view.preferredFramesPerSecond))
        }
        guard let drawnStamp, let presented = tracker.drew(stampNs: drawnStamp) else { return }
        if let presentation {
            presentation.resolve(marker: markerForStamp?(drawnStamp))
            #if targetEnvironment(simulator)
            presentation.whenResolved { [weak counters] marker in
                counters?.presentedFrame(atMs: MachClock.nowMs(), marker: marker)
            }
            #endif
        }
        counters?.presented(latencyMs: presented.latencyMs)
        counters?.superseded(presented.superseded)
    }

    /// Only for a new decoded frame: fetching a drawable with nothing to draw would hold one of
    /// the two drawables and stall the next real frame.
    private func observePresentation(in view: MTKView) -> PresentedFrameMarker? {
        guard drawnStampReader != nil, markerForStamp != nil, let counters, tracker.hasPending,
              let drawable = drawableProvider(view) else { return nil }
        let frame = PresentedFrameMarker()
        #if targetEnvironment(simulator)
        // The simulator's Metal has no presented handler; the draw call stands in for the display time.
        _ = drawable
        #else
        drawable.addPresentedHandler { presented in
            guard presented.presentedTime > 0 else { return }
            let presentedAtMs = MachClock.milliseconds(fromMediaTime: presented.presentedTime)
            frame.whenResolved { marker in
                counters.presentedFrame(atMs: presentedAtMs, marker: marker)
            }
        }
        #endif
        return frame
    }

}
