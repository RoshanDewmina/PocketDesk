import AVKit
import WebRTC

/// Root must supply current authorization and release ALL control before background live viewing.
/// A legitimate PiP playback session is acquired only by explicit Start. No fake audio or network grant.
final class LivePiPController: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let mediaSession: PhoneMediaSession
    private var mediaOwner: UUID?
    private let supported: () -> Bool
    private let possible: (AVPictureInPictureController) -> Bool
    private let startPlatform: (AVPictureInPictureController) -> Void
    @MainActor
    init(mediaSession: PhoneMediaSession = .shared,
         supported: @escaping () -> Bool = { AVPictureInPictureController.isPictureInPictureSupported() },
         possible: @escaping (AVPictureInPictureController) -> Bool = { $0.isPictureInPicturePossible },
         startPlatform: @escaping (AVPictureInPictureController) -> Void = { $0.startPictureInPicture() }) {
        self.mediaSession = mediaSession; self.supported = supported; self.possible = possible
        self.startPlatform = startPlatform; super.init()
    }

    private(set) var policy = LivePiPPolicy()
    private(set) var controller: AVPictureInPictureController?
    private(set) var sink: LivePiPSampleBufferSink?
    private var fence: VideoPresentationFence?
    private var source: LivePiPSource?
    private var expiryTimer: Timer?
    private let sourceLock = NSLock()
    private var sourceSink: LivePiPSampleBufferSink?
    private func synchronizeSource() {
        sourceLock.lock()
        sourceSink = policy.state == .ready || policy.state == .starting || policy.state == .active ? sink : nil
        sink?.setEnabled(sourceSink != nil)
        sourceLock.unlock()
    }
    var didChangeState: ((LivePiPPolicy.State) -> Void)?
    var restoreForeground: ((@escaping (Bool) -> Void) -> Void)?
    var renderSizeChanged: ((CMVideoDimensions) -> Void)?

    /// Main-thread only; cannot retarget a live PiP window across host/grant/session/content epochs.
    func updateAdmission(_ next: VideoPresentationAdmission?) {
        precondition(Thread.isMainThread)
        if let old = policy.admission, let next, (old.identity != next.identity || old.lifetime !== next.lifetime) {
            stop() // End the old view before authorizing a new inline preroll; never auto-start it.
        }
        if policy.update(next, at: ProcessInfo.processInfo.systemUptime) { stop(); return }
        guard let next, policy.admission != nil else { stop(); return }
        if let fence { guard fence.renew(next) else { stop(); return } }
        else {
            let fence = VideoPresentationFence(next); self.fence = fence
            let sink = LivePiPSampleBufferSink(admission: next, fence: fence); self.sink = sink
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: sink.layer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self; controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            self.controller = controller
        }
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.001, next.validUntil - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in self?.stop() }
        expiryTimer = timer; RunLoop.main.add(timer, forMode: .common)
        controller?.invalidatePlaybackState()
        synchronizeSource(); didChangeState?(policy.state)
    }
    var displayLayer: AVSampleBufferDisplayLayer? { sink?.layer }
    /// Prefer this independent registration for live background PiP. Do not ALSO feed Surface.onSourceFrame.
    func attachSourceTrack(_ track: RTCVideoTrack) {
        precondition(Thread.isMainThread)
        guard let admission = policy.admission, admission.permits(at: ProcessInfo.processInfo.systemUptime), let fence else { return }
        if let source {
            if source.track !== track { stop() } // Root must provide a new immutable track identity first.
            return
        }
        source = LivePiPSource(track: track, admission: admission, fence: fence) { [weak self] in self?.offer($0) }
    }
    /// Deliberate foreground button action only. The attached inline display layer must be visible.
    @discardableResult
    func startFromUserAction(foreground: Bool) -> Bool {
        precondition(Thread.isMainThread)
        guard foreground, policy.state == .ready, mediaOwner == nil,
              let admission = policy.admission,
              admission.permits(at: ProcessInfo.processInfo.systemUptime),
              let controller, let fence else { return false }
        let isSupported = supported()
        guard isSupported, startContextMatches(controller, admission: admission, fence: fence, state: .ready) else { return false }
        let owner = UUID()
        let acquired = MainActor.assumeIsolated {
            mediaSession.acquire(owner, kind: .pictureInPicture, onRetired: { [weak self] in
                guard let self, self.mediaOwner == owner else { return }
                self.mediaOwner = nil
                self.stop()
            })
        }
        guard acquired else { return false }
        // Platform configuration may synchronously retire or replace this controller.
        guard mediaOwner == nil, startContextMatches(controller, admission: admission, fence: fence, state: .ready) else {
            releaseMediaOwner(owner); return false
        }
        mediaOwner = owner
        let isPossible = possible(controller)
        guard isPossible, mediaOwner == owner,
              startContextMatches(controller, admission: admission, fence: fence, state: .ready),
              MainActor.assumeIsolated({ mediaSession.contains(owner) }),
              policy.userStart(foreground: foreground, supported: isSupported, possible: isPossible,
                               at: ProcessInfo.processInfo.systemUptime) else {
            releaseMediaOwner(owner); return false
        }
        // Check after every external callback. Do not hold a presentation lock across the
        // OS call: its synchronous delegate may stop/detach the native source reentrantly.
        let admitted = fence.withAdmission(admission.identity, at: ProcessInfo.processInfo.systemUptime) {
            mediaOwner == owner && startContextMatches(controller, admission: admission, fence: fence, state: .starting)
                && MainActor.assumeIsolated({ mediaSession.contains(owner) })
        } == true
        guard admitted else {
            releaseMediaOwner(owner)
            if self.controller === controller { stop() }
            return false
        }
        startPlatform(controller); synchronizeSource(); didChangeState?(policy.state); return true
    }
    private func startContextMatches(_ controller: AVPictureInPictureController, admission: VideoPresentationAdmission,
                                     fence: VideoPresentationFence, state: LivePiPPolicy.State) -> Bool {
        self.controller === controller && self.fence === fence && policy.state == state &&
        policy.admission?.identity == admission.identity && policy.admission?.lifetime === admission.lifetime &&
        admission.permits(at: ProcessInfo.processInfo.systemUptime) &&
        policy.admission?.permits(at: ProcessInfo.processInfo.systemUptime) == true
    }
    func offer(_ source: VideoFrameEnvelope) {
        sourceLock.lock(); let current = sourceSink; sourceLock.unlock()
        current?.offer(source) // Sink enforces exact identity and monotonic admission under its fence.
    }
    private func releaseMediaOwner() {
        guard let owner = mediaOwner else { return }
        releaseMediaOwner(owner)
    }
    private func releaseMediaOwner(_ owner: UUID) {
        if mediaOwner == owner { mediaOwner = nil }
        MainActor.assumeIsolated { mediaSession.release(owner) }
    }
    func stop() {
        precondition(Thread.isMainThread)
        fence?.invalidate() // BEFORE sample flush, OS stop, or any application callback
        source?.detach(); source = nil
        policy.stop(); expiryTimer?.invalidate(); expiryTimer = nil
        sink?.invalidate(); sink = nil; fence = nil
        let old = controller; controller = nil
        old?.stopPictureInPicture(); old?.delegate = nil
        releaseMediaOwner()
        policy.didStop(); synchronizeSource(); didChangeState?(policy.state)
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { controller.stopPictureInPicture(); return }
        guard policy.didStart(at: ProcessInfo.processInfo.systemUptime) else { stop(); return }
        synchronizeSource(); didChangeState?(policy.state)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { if self.controller === controller { stop() } }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { if self.controller === controller { stop() } }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard self.controller === controller else { completionHandler(false); return }
        if let restoreForeground { restoreForeground(completionHandler) } else { completionHandler(false) }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard self.controller === controller else { return }
        policy.setPlaying(playing, at: ProcessInfo.processInfo.systemUptime)
        if policy.state == .stopping { stop() } else { controller.invalidatePlaybackState(); synchronizeSource(); didChangeState?(policy.state) }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        guard self.controller === controller, policy.admission?.permits(at: ProcessInfo.processInfo.systemUptime) == true else { return .invalid }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { self.controller !== controller || policy.state != .active }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        if self.controller === controller { renderSizeChanged?(newRenderSize) }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    deinit {
        expiryTimer?.invalidate(); fence?.invalidate(); source?.detach(); sink?.invalidate()
        if let owner = mediaOwner { let session = mediaSession; Task { @MainActor in session.release(owner) } }
    }
}
