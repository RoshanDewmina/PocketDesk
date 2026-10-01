import AVKit
import WebRTC

/// Class identity is the platform operation identity; injected fixtures never manufacture AVKit objects.
protocol LivePiPPlatformController: AnyObject {
    var nativeController: AVPictureInPictureController? { get }
    var isPossible: Bool { get }
    func start()
    func stop()
    func invalidatePlaybackState()
    func detachDelegate()
    func setAutomaticStart(_ enabled: Bool)
}

extension LivePiPPlatformController {
    func setAutomaticStart(_ enabled: Bool) {}
}

private final class NativePiPPlatformController: LivePiPPlatformController {
    let nativeController: AVPictureInPictureController?
    init?(layer: AVSampleBufferDisplayLayer, owner: LivePiPController) {
        // ObjC documents nil on unsupported devices despite its nonnull imported initializer.
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: owner)
        let candidate: AVPictureInPictureController? = AVPictureInPictureController(contentSource: source)
        guard let candidate else { return nil }
        nativeController = candidate
        candidate.delegate = owner; candidate.requiresLinearPlayback = true
        candidate.canStartPictureInPictureAutomaticallyFromInline = false
    }
    var isPossible: Bool { nativeController?.isPictureInPicturePossible == true }
    func start() { nativeController?.startPictureInPicture() }
    func stop() { nativeController?.stopPictureInPicture() }
    func invalidatePlaybackState() { nativeController?.invalidatePlaybackState() }
    func detachDelegate() { nativeController?.delegate = nil }
    func setAutomaticStart(_ enabled: Bool) { nativeController?.canStartPictureInPictureAutomaticallyFromInline = enabled }
}

/// Root must supply current authorization and release ALL control before background live viewing.
/// A legitimate PiP playback session is acquired only by explicit Start. No fake audio or network grant.
final class LivePiPController: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let mediaSession: PhoneMediaSession
    private var mediaOwner: UUID?
    private var mediaInterrupted = false
    private let supported: () -> Bool
    typealias PlatformFactory = (AVSampleBufferDisplayLayer, LivePiPController) -> (any LivePiPPlatformController)?
    private let platformFactory: PlatformFactory
    private var preparationID = UUID()
    @MainActor
    init(mediaSession: PhoneMediaSession = .shared,
         supported: @escaping () -> Bool = { AVPictureInPictureController.isPictureInPictureSupported() },
         platformFactory: @escaping PlatformFactory = { NativePiPPlatformController(layer: $0, owner: $1) }) {
        self.mediaSession = mediaSession; self.supported = supported
        self.platformFactory = platformFactory; super.init()
    }

    private(set) var policy = LivePiPPolicy()
    private(set) var controller: (any LivePiPPlatformController)?
    private(set) var sink: LivePiPSampleBufferSink?
    private var fence: VideoPresentationFence?
    private var source: LivePiPSource?
    private var expiryTimer: Timer?
    private let sourceLock = NSLock()
    private var sourceSink: LivePiPSampleBufferSink?
    private func synchronizeSource() {
        sourceLock.lock()
        sourceSink = !mediaInterrupted && !automaticStartUnconfirmed
            && (policy.state == .ready || policy.state == .starting || policy.state == .active) ? sink : nil
        sink?.setEnabled(sourceSink != nil)
        sourceLock.unlock()
    }
    var didChangeState: ((LivePiPPolicy.State) -> Void)?
    /// Auto-start (leaving the app with a live session). The root sets this only while its session is live in
    /// picture mode; the OS then starts PiP from the inline layer, `mayStartAutomatically` must still agree, and
    /// `didStartAutomatically` then asks the Mac for live view only (which must confirm, as for a button start).
    var automaticStartAllowed = false { didSet { applyAutomaticStart() } }
    var mayStartAutomatically: (() -> Bool)?
    var didStartAutomatically: (() -> Void)?
    /// An OS start shows only the last inline frame until the Mac confirms live view only.
    private(set) var automaticStartUnconfirmed = false
    func automaticStartConfirmed() { automaticStartUnconfirmed = false; synchronizeSource() }
    /// Between AVKit's willStart and didStart of an OS start: its flag must stay set, and the start is bounded.
    private var automaticStartInFlight = false
    private static let automaticStartLimit: TimeInterval = 3
    private func applyAutomaticStart() {
        controller?.setAutomaticStart(automaticStartAllowed && (policy.state == .ready || automaticStartInFlight))
    }
    var restoreForeground: ((@escaping (Bool) -> Void) -> Void)?
    var renderSizeChanged: ((CMVideoDimensions) -> Void)?

    /// Main-thread only; cannot retarget a live PiP window across host/grant/session/content epochs.
    func updateAdmission(_ next: VideoPresentationAdmission?) {
        precondition(Thread.isMainThread)
        let preparation = UUID(); preparationID = preparation
        if let old = policy.admission, let next, (old.identity != next.identity || old.lifetime !== next.lifetime) {
            stopCurrent() // Retire old resources; a nested update must not be overwritten.
            guard preparationID == preparation else { return }
        }
        if policy.update(next, at: ProcessInfo.processInfo.systemUptime) { stop(); return }
        guard let next, policy.admission != nil else { stop(); return }
        let isSupported = supported()
        guard preparationMatches(preparation, admission: next) else {
            if preparationID == preparation { stop() }; return
        }
        guard isSupported else { stop(); return }
        if let fence { guard fence.renew(next) else { stop(); return } }
        else {
            let candidateFence = VideoPresentationFence(next)
            let candidateSink = LivePiPSampleBufferSink(admission: next, fence: candidateFence)
            let candidate = platformFactory(candidateSink.layer, self)
            guard preparationMatches(preparation, admission: next) else {
                candidateFence.invalidate(); candidateSink.invalidate()
                if let candidate, candidate !== controller { candidate.stop(); candidate.detachDelegate() }
                if preparationID == preparation { stop() }; return
            }
            guard let candidate else {
                candidateFence.invalidate(); candidateSink.invalidate(); stop(); return
            }
            fence = candidateFence; sink = candidateSink; controller = candidate
        }
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.001, next.validUntil - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in self?.stop() }
        expiryTimer = timer; RunLoop.main.add(timer, forMode: .common)
        controller?.invalidatePlaybackState()
        applyAutomaticStart()
        synchronizeSource(); didChangeState?(policy.state)
    }
    private func preparationMatches(_ preparation: UUID, admission: VideoPresentationAdmission) -> Bool {
        preparationID == preparation && policy.admission?.identity == admission.identity &&
            policy.admission?.lifetime === admission.lifetime && admission.permits(at: ProcessInfo.processInfo.systemUptime) &&
            policy.admission?.permits(at: ProcessInfo.processInfo.systemUptime) == true
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
    /// Deliberate foreground button action, or (`automatic`) the OS starting PiP as the user leaves the app.
    /// The attached inline display layer must be visible.
    @discardableResult
    func startFromUserAction(foreground: Bool, automatic: Bool = false) -> Bool {
        precondition(Thread.isMainThread)
        guard foreground || automatic && automaticStartAllowed, policy.state == .ready, mediaOwner == nil,
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
            }, onSuspended: { [weak self] in
                guard let self, self.mediaOwner == owner else { return }
                self.mediaInterrupted = true; self.synchronizeSource()
            }, onResumed: { [weak self, weak controller, weak fence] in
                guard let self, let controller, let fence, self.mediaOwner == owner,
                      self.controller === controller, self.fence === fence,
                      self.policy.admission?.identity == admission.identity,
                      self.policy.admission?.lifetime === admission.lifetime,
                      self.policy.admission?.permits(at: ProcessInfo.processInfo.systemUptime) == true,
                      [.starting, .active, .paused].contains(self.policy.state) else { return false }
                self.mediaInterrupted = false; self.synchronizeSource()
                return true // No new OS start: only the same admitted consumer becomes drawable again.
            })
        }
        guard acquired else { return false }
        // Platform configuration may synchronously retire or replace this controller.
        guard mediaOwner == nil, startContextMatches(controller, admission: admission, fence: fence, state: .ready) else {
            releaseMediaOwner(owner); return false
        }
        mediaOwner = owner
        let isPossible = controller.isPossible
        guard isPossible, mediaOwner == owner,
              startContextMatches(controller, admission: admission, fence: fence, state: .ready),
              MainActor.assumeIsolated({ mediaSession.contains(owner) }),
              policy.userStart(foreground: foreground || automatic, supported: isSupported, possible: isPossible,
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
        // An automatic start is already under way in the OS; leave its flag set until it finishes or stops.
        if automatic {
            automaticStartUnconfirmed = true; automaticStartInFlight = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.automaticStartLimit) { [weak self, weak controller] in
                guard let self, let controller, self.controller === controller, self.policy.state == .starting else { return }
                self.stop() // AVKit never reported the start finishing or failing.
            }
        } else { controller.start(); applyAutomaticStart() }
        synchronizeSource(); didChangeState?(policy.state); return true
    }
    private func startContextMatches(_ controller: any LivePiPPlatformController, admission: VideoPresentationAdmission,
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
        preparationID = UUID()
        stopCurrent()
    }
    private func stopCurrent() {
        fence?.invalidate() // BEFORE sample flush, OS stop, or any application callback.
        let oldSource = source, oldSink = sink, oldController = controller, oldOwner = mediaOwner
        source = nil; sink = nil; fence = nil; controller = nil; mediaOwner = nil
        mediaInterrupted = false; automaticStartUnconfirmed = false; automaticStartInFlight = false
        policy.stop(); expiryTimer?.invalidate(); expiryTimer = nil
        policy.didStop(); synchronizeSource()
        oldSource?.detach(); oldSink?.invalidate()
        oldController?.setAutomaticStart(false); oldController?.stop(); oldController?.detachDelegate()
        // AVKit keeps laying out the restore animation against this controller after our completion returns.
        if let oldController { Self.holdForAVKit([oldController, oldSink]) }
        // A synchronous OS stop callback may have installed a new run. Release only this capsule.
        if let oldOwner { MainActor.assumeIsolated { mediaSession.release(oldOwner) } }
        didChangeState?(policy.state)
    }
    private func matchesNative(_ controller: AVPictureInPictureController) -> Bool {
        self.controller?.nativeController === controller
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard matchesNative(controller), policy.state == .ready else { return } // A button start is already .starting.
        beginAutomaticStart(self.controller)
    }
    private func beginAutomaticStart(_ candidate: (any LivePiPPlatformController)?) {
        guard let candidate, candidate === controller, mayStartAutomatically?() == true,
              startFromUserAction(foreground: false, automatic: true) else { stop(); return }
        didStartAutomatically?()
    }
    #if DEBUG
    func automaticStartForTesting(_ candidate: any LivePiPPlatformController) { beginAutomaticStart(candidate) }
    #endif
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard matchesNative(controller) else { controller.stopPictureInPicture(); return }
        confirmPlatformStart(controller: self.controller)
    }
    private func confirmPlatformStart(controller candidate: (any LivePiPPlatformController)?) {
        guard let candidate, candidate === controller else { return }
        guard policy.didStart(at: ProcessInfo.processInfo.systemUptime) else { stop(); return }
        automaticStartInFlight = false
        applyAutomaticStart(); synchronizeSource(); didChangeState?(policy.state)
    }
    #if DEBUG
    /// Actual controller state boundary; injected fixtures do not manufacture or start native AVKit.
    func confirmPlatformStartForTesting(_ candidate: any LivePiPPlatformController) {
        confirmPlatformStart(controller: candidate)
    }
    #endif
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { if matchesNative(controller) { stop() } }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { if matchesNative(controller) { stop() } }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard matchesNative(controller) else { completionHandler(false); return }
        restoreUserInterface(platform: self.controller, native: controller, completionHandler)
    }
    /// The restore can finish after the root has already stopped this PiP (returning to the app retires it),
    /// and AVKit's completion block then reads the source layer's player controller. Keep the platform
    /// controller (and so the native controller), the sink and its layer alive until after the handler
    /// returns and one more main-queue turn, or AVKit touches a freed controller (crash 1 Oct 15:33).
    private func restoreUserInterface(platform: (any LivePiPPlatformController)?, native: AnyObject?,
                                      _ completionHandler: @escaping (Bool) -> Void) {
        let retained: [AnyObject?] = [platform, native, sink, sink?.layer]
        let complete: (Bool) -> Void = { restored in
            withExtendedLifetime(retained) { completionHandler(restored) }
            Self.holdForAVKit(retained)
        }
        if let restoreForeground { restoreForeground(complete) } else { complete(false) }
    }
    /// Long enough for AVKit's restore or stop animation to finish with the objects it still reads.
    static let avkitHold: TimeInterval = 3
    private static func holdForAVKit(_ objects: [AnyObject?]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + avkitHold) { withExtendedLifetime(objects) {} }
    }
    #if DEBUG
    func restoreUserInterfaceForTesting(on candidate: any LivePiPPlatformController, _ completionHandler: @escaping (Bool) -> Void) {
        guard candidate === controller else { completionHandler(false); return }
        restoreUserInterface(platform: candidate, native: nil, completionHandler)
    }
    #endif
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard matchesNative(controller) else { return }
        applyPlaying(playing)
    }
    private func applyPlaying(_ playing: Bool) {
        policy.setPlaying(playing, at: ProcessInfo.processInfo.systemUptime)
        if policy.state == .stopping { stop() } else { controller?.invalidatePlaybackState(); synchronizeSource(); didChangeState?(policy.state) }
    }
    #if DEBUG
    func setPlayingForTesting(_ playing: Bool, on candidate: any LivePiPPlatformController) {
        guard candidate === controller else { return }
        applyPlaying(playing)
    }
    #endif
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        guard matchesNative(controller), policy.admission?.permits(at: ProcessInfo.processInfo.systemUptime) == true else { return .invalid }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { !matchesNative(controller) || policy.state != .active }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        if matchesNative(controller) { renderSizeChanged?(newRenderSize) }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    deinit {
        expiryTimer?.invalidate(); fence?.invalidate(); source?.detach(); sink?.invalidate()
        if let owner = mediaOwner { let session = mediaSession; Task { @MainActor in session.release(owner) } }
    }
}
