import AppKit

/// Streams authoritative pointer samples to a phone that advertised pointer telemetry and
/// decides when capture may omit the cursor. Capture shows the cursor unless the phone asked
/// for its own overlay, has received fresh samples, and capture confirmed the change.
@MainActor
final class HostPointerTelemetry {
    static let sampleInterval: TimeInterval = 1.0 / 60.0
    private static let idleShapeInterval: TimeInterval = 0.25
    private static let activeShapeInterval: TimeInterval = 0.05

    var send: ((RemoteAction) -> Bool)?
    var setCaptureShowsCursor: ((Bool) -> Void)?
    var captureShowsCursor: () -> Bool = { true }

    private var policy = HostPointerTelemetryPolicy()
    private let shapes = HostCursorShapeSampler()
    private var displayFrame: CGRect?
    private var epoch: UInt64 = 0
    private var timer: Timer?
    private var shape: PointerShape = .arrow
    private var shapeSampledAt: TimeInterval = -.infinity
    private var lastGlobal: CGPoint?
    private var lastMotionAt: TimeInterval = -.infinity
    private var wasHidden = false

    /// Begins a capture session; video keeps its cursor until the phone opts in again.
    func begin(displayFrame: CGRect, epoch: UInt64) {
        end()
        self.displayFrame = displayFrame
        self.epoch = epoch
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        // Common modes keep samples flowing while the menu bar menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
        displayFrame = nil
        policy.reset()
        shapes.reset()
        shape = .arrow
        shapeSampledAt = -.infinity
        lastGlobal = nil
        lastMotionAt = -.infinity
        wasHidden = false
        setCaptureShowsCursor?(true)
    }

    func phoneHeartbeat(_ sync: PointerSync?, epoch: UInt64, at now: TimeInterval) {
        guard displayFrame != nil, epoch == self.epoch else { return }
        policy.phoneHeartbeat(sync, at: now)
        reconcileCapture(at: now)
    }

    func moveProcessed(_ action: RemoteAction) {
        guard action.action == "move" || action.action == "moveTo", action.epoch == epoch else { return }
        policy.moveProcessed(ordinal: action.pointerSync?.move)
    }

    func moveInjected(globalPoint: CGPoint, at now: TimeInterval) {
        guard let displayFrame, let local = HostPointerTelemetryPolicy.displayPoint(globalPoint, in: displayFrame) else { return }
        policy.moveInjected(at: local, now: now)
    }

    /// Called when capture confirms a new cursor setting.
    func captureCursorChanged(showsCursor: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if showsCursor && wasHidden { policy.noteFallback(at: now) }
        wasHidden = !showsCursor
        sample(at: now, force: true)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        reconcileCapture(at: now)
        sample(at: now, force: false)
    }

    private func reconcileCapture(at now: TimeInterval) {
        guard displayFrame != nil else { return }
        setCaptureShowsCursor?(!policy.wantsCursorHidden(at: now))
    }

    private func sample(at now: TimeInterval, force: Bool) {
        guard let displayFrame, policy.streaming(at: now) else { return }
        let global = CGEvent(source: nil)?.location
        if global != lastGlobal {
            lastGlobal = global
            lastMotionAt = now
        }
        let shapeInterval = now - lastMotionAt < 1 ? Self.activeShapeInterval : Self.idleShapeInterval
        if force || now - shapeSampledAt >= shapeInterval || now < shapeSampledAt {
            shape = shapes.currentShape(at: global, now: now)
            shapeSampledAt = now
        }
        let local = global.flatMap { HostPointerTelemetryPolicy.displayPoint($0, in: displayFrame) }
        guard let sync = policy.sample(observed: local, shape: shape,
                                       videoCursor: captureShowsCursor(), at: now) else { return }
        _ = send?(RemoteAction(action: "pointer", epoch: epoch, pointerSync: sync))
    }
}
