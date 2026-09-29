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

/// Raises the WebRTC Metal view's refresh to the display maximum (120 Hz on ProMotion with
/// `CADisableMinimumFrameDurationOnPhone`) and times decoded-frame → draw-call latency by
/// forwarding the MTKView delegate. RTCMTLVideoView still does all rendering; if its private
/// MTKView cannot be found, presentation is left exactly as WebRTC configured it.
final class VideoPresentationProbe: NSObject, MTKViewDelegate {
    static let preferredFramesPerSecond = 120

    let tracker = PresentationTracker()
    private weak var renderer: (any MTKViewDelegate)?
    private weak var metalView: MTKView?
    var counters: StreamCounters?
    private var reportedRate = false

    /// Returns nil when the view hierarchy is not the expected RTCMTLVideoView → MTKView shape.
    static func install(on videoView: UIView) -> VideoPresentationProbe? {
        guard let metalView = findMetalView(in: videoView),
              let renderer = metalView.delegate, renderer !== metalView else { return nil }
        let probe = VideoPresentationProbe()
        probe.renderer = renderer
        probe.metalView = metalView
        if StreamTuning.current.presentAtDisplayMaximum {
            metalView.preferredFramesPerSecond = preferredFramesPerSecond
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
        renderer?.draw(in: view)
        if !reportedRate, let screen = view.window?.windowScene?.screen {
            reportedRate = true
            counters?.setDisplayMaxFPS(min(screen.maximumFramesPerSecond, view.preferredFramesPerSecond))
        }
        guard let presented = tracker.drew() else { return }
        counters?.presented(latencyMs: presented.latencyMs)
        counters?.superseded(presented.superseded)
    }
}
