import WebRTC

/// A renderer registration is immutable for one track/authorization epoch. Never reuse it for another track.
final class VideoPresentationSession: NSObject, RTCVideoRenderer {
    let track: RTCVideoTrack
    let admissionIdentity: VideoPresentationIdentity
    let fence: VideoPresentationFence
    let view: OwnedMetalVideoView
    let smoothMotion = SmoothMotionController()
    private let motionGate = VideoMotionGate()
    let legibility = LegibilityProbe()
    private var readsMarkers = false
    private var lastNotification: TimeInterval = 0
    private final class SourceReceipt {
        weak var frame: RTCVideoFrame?
        let id = UUID()
        let arrivalMs: Double
        init(_ frame: RTCVideoFrame, at now: Double) { self.frame = frame; arrivalMs = now }
    }
    private var sources: [SourceReceipt] = []
    private let onFrame: () -> Void
    private var onSourceFrame: ((VideoFrameEnvelope) -> Void)?
    private var stopped = false
    private var expiryTimer: Timer?
    private final class Registration { weak var value: VideoPresentationSession?; init(_ value: VideoPresentationSession) { self.value = value } }
    private static var registrations: [Registration] = []
    static weak var active: VideoPresentationSession?

    init(track: RTCVideoTrack, admission: VideoPresentationAdmission, onFrame: @escaping () -> Void, primary: Bool = true) {
        self.track = track; admissionIdentity = admission.identity
        fence = VideoPresentationFence(admission)
        view = OwnedMetalVideoView(admission: admission, fence: fence)
        self.onFrame = onFrame
        super.init()
        smoothMotion.deliver = { [weak self] output in self?.deliver(output.frame, marker: output.marker) }
        view.beforeDraw = { [weak self] view in
            guard let self else { return }
            self.motionGate.perform { self.smoothMotion.displayTick(view) }
        }
        smoothMotion.activate(); if primary { Self.active = self }
        Self.registrations.removeAll { $0.value == nil }; Self.registrations.append(Registration(self))
        track.add(self)
    }
    func configure(admission: VideoPresentationAdmission, counters: StreamCounters?, statistics: Bool,
                   sourceSize: CGSize, displayedPixelWidth: CGFloat, fillsFrame: Bool,
                   mode: SmoothMotionMode, upscale: Bool, onSourceFrame: ((VideoFrameEnvelope) -> Void)?) {
        _ = fence.renew(admission)
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.001, admission.validUntil - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in self?.invalidate() }
        expiryTimer = timer; RunLoop.main.add(timer, forMode: .common)
        let configured = fence.withAdmission(admissionIdentity, at: ProcessInfo.processInfo.systemUptime) {
            view.counters = counters; view.fillsFrame = fillsFrame; readsMarkers = statistics
            self.onSourceFrame = onSourceFrame
            legibility.configure(enabled: statistics, counters: counters, sourceSize: sourceSize, displayedPixelWidth: displayedPixelWidth)
            return true
        }
        if configured == true {
            motionGate.perform { smoothMotion.setMode(mode); smoothMotion.setUpscale(upscale) }
        }
    }
    func setSize(_ size: CGSize) {} // Actual public buffer dimensions/crop/rotation determine geometry.
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let receipt = fence.withAdmission(admissionIdentity, at: ProcessInfo.processInfo.systemUptime) {
            let now = MachClock.nowMs()
            sources.append(SourceReceipt(frame, at: now))
            if sources.count > 8 { sources.removeFirst(sources.count - 8) }
            let decoded = readsMarkers ? (frame.buffer as? RTCCVPixelBuffer).flatMap { DecodedLuma($0) } : nil
            let marker = decoded?.readMarker()
            let source = VideoFrameEnvelope(receiptID: sources.last!.id, identity: admissionIdentity, frame: frame,
                arrivalMs: now, marker: marker, originalSource: true)
            if let decoded { legibility.frameArrived(decoded.pixelBuffer, visible: decoded.visible, marker: marker) }
            let uptime = ProcessInfo.processInfo.systemUptime
            var notify = false
            if uptime - lastNotification > 0.25 {
                lastNotification = uptime
                notify = true
            }
            return (source, onSourceFrame, notify)
        }
        guard let (source, callback, notify) = receipt else { return }
        callback?(source) // The derivative sink independently rechecks its terminal admission.
        motionGate.perform { smoothMotion.receive(frame, marker: source.marker) }
        if notify {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fence.withAdmission(self.admissionIdentity, at: ProcessInfo.processInfo.systemUptime, { true }) == true else { return }
                self.onFrame() // Never call user/model hooks while holding the presentation fence.
            }
        }
    }
    private func deliver(_ frame: RTCVideoFrame, marker: BenchMarker?) {
        _ = fence.withAdmission(admissionIdentity, at: ProcessInfo.processInfo.systemUptime) {
            // Conversion/midpoint timestamps are not source identity. Unknown outputs get no decode→draw sample.
            let source = sources.last { $0.frame === frame }
            view.offer(VideoFrameEnvelope(receiptID: source?.id ?? UUID(), identity: admissionIdentity,
                frame: frame, arrivalMs: source?.arrivalMs ?? MachClock.nowMs(), marker: readsMarkers ? marker : nil,
                originalSource: source != nil))
        }
    }
    /// Main thread: immediately cover/clear; only then detach and drain the old motion pipeline.
    func invalidate() {
        precondition(Thread.isMainThread)
        fence.invalidate()
        guard !stopped else { return }; stopped = true
        expiryTimer?.invalidate(); expiryTimer = nil
        view.invalidate(); track.remove(self)
        motionGate.close { smoothMotion.deactivate() } // Late presenter flush callbacks see a closed fence.
        legibility.configure(enabled: false, counters: nil, sourceSize: .zero, displayedPixelWidth: 0)
        sources.removeAll(); onSourceFrame = nil
        if Self.active === self { Self.active = nil }
    }
    /// Root uses this synchronously for End/selection/lock/privacy/proof/content changes, before SwiftUI removal.
    static func invalidateActive() {
        precondition(Thread.isMainThread)
        let sessions = registrations.compactMap(\.value)
        registrations.removeAll()
        sessions.forEach { $0.invalidate() }
    }
    static func noteUserActivity(at now: TimeInterval) { active?.view.noteActivity(at: now) }
}
