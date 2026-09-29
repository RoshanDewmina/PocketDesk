import MetalKit
import UIKit

/// Counts decoded frames that reach a draw call and those replaced before one did.
/// Thread-safe: frames arrive on WebRTC's decode thread, draws run on the main thread.
final class PresentationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var newestArrival: TimeInterval = 0

    func frameArrived(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); pending += 1; newestArrival = time; lock.unlock()
    }

    /// A decoded frame arrived since the last draw.
    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending > 0
    }

    /// Returns the delay from the newest decoded frame to this draw and how many older
    /// decoded frames it replaced unseen, or nil when no new frame arrived since the last draw.
    func drew(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (latencyMs: Double, superseded: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard pending > 0 else { return nil }
        let result = (max(0, (time - newestArrival) * 1000), pending - 1)
        pending = 0
        return result
    }
}

/// The bench marker of a frame handed to a drawable's presented handler. The handler is added
/// before WebRTC draws, and the drawn frame is only known afterwards, so the marker is filled in
/// once the draw returns (long before the drawable reaches the display).
final class PresentedFrameMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BenchMarker?

    var marker: BenchMarker? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
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
    private weak var videoView: UIView?
    private var readsDrawnStamp = false
    var counters: StreamCounters?
    private var reportedRate = false
    private var chosenFramesPerSecond: Int?

    /// Stream statistics: the bench marker of the frame forwarded with this stamp.
    var markerForStamp: ((Int64) -> BenchMarker?)?
    /// Stream statistics fallback when the video view's drawn stamp cannot be read.
    var newestMarker: (() -> BenchMarker?)?
    /// MTKView creates its drawable lazily and WebRTC's renderer then presents that same one.
    var drawableProvider: (MTKView) -> (any MTLDrawable)? = { $0.currentDrawable }

    /// Returns nil when the view hierarchy is not the expected RTCMTLVideoView → MTKView shape.
    static func install(on videoView: UIView) -> VideoPresentationProbe? {
        guard let metalView = findMetalView(in: videoView),
              let renderer = metalView.delegate, renderer !== metalView else { return nil }
        let probe = VideoPresentationProbe()
        probe.renderer = renderer
        probe.metalView = metalView
        probe.videoView = videoView
        // A missing key would raise through KVC, so only read it when the view really has it.
        probe.readsDrawnStamp = videoView.responds(to: NSSelectorFromString(drawnStampKey))
        if StreamTuning.current.presentAtDisplayMaximum {
            metalView.preferredFramesPerSecond = preferredFramesPerSecond
            probe.chosenFramesPerSecond = preferredFramesPerSecond
            // Two drawables instead of three: one fewer frame waiting between draw and scan-out.
            (metalView.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        }
        metalView.delegate = probe
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
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        let presentation = observePresentation(in: view)
        renderer?.draw(in: view)
        if let presentation { presentation.marker = drawnMarker() }
        // WebRTC's Metal renderer sets 30 fps on the view when it starts on the first frame.
        if let chosen = chosenFramesPerSecond, view.preferredFramesPerSecond != chosen {
            view.preferredFramesPerSecond = chosen
        }
        if !reportedRate, let screen = view.window?.windowScene?.screen {
            reportedRate = true
            counters?.setDisplayMaxFPS(min(screen.maximumFramesPerSecond, view.preferredFramesPerSecond))
        }
        guard let presented = tracker.drew() else { return }
        counters?.presented(latencyMs: presented.latencyMs)
        counters?.superseded(presented.superseded)
    }

    /// Only for a new decoded frame: fetching a drawable with nothing to draw would hold one of
    /// the two drawables and stall the next real frame.
    private func observePresentation(in view: MTKView) -> PresentedFrameMarker? {
        guard markerForStamp != nil, let counters, tracker.hasPending,
              let drawable = drawableProvider(view) else { return nil }
        let frame = PresentedFrameMarker()
        drawable.addPresentedHandler { presented in
            guard presented.presentedTime > 0 else { return }
            counters.presentedFrame(atMs: MachClock.milliseconds(fromMediaTime: presented.presentedTime),
                                    marker: frame.marker)
        }
        return frame
    }

    private func drawnMarker() -> BenchMarker? {
        guard readsDrawnStamp, let videoView,
              let stamp = (videoView.value(forKey: Self.drawnStampKey) as? NSNumber)?.int64Value else {
            return newestMarker?()
        }
        return markerForStamp?(stamp)
    }
}
