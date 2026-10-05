import AppKit
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CryptoKit
import OSLog

struct ScopedCaptureOwner {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        if current == 0 { current = 1 }
        return current
    }

    mutating func invalidate() {
        _ = begin()
    }

    func owns(_ token: UInt64) -> Bool {
        token == current
    }
}

struct CaptureStartPreflight {
    static func send(
        _ actions: [RemoteAction],
        whileCurrent isCurrent: () -> Bool,
        using sender: (RemoteAction) -> Bool
    ) -> Bool {
        guard isCurrent() else { return false }
        for action in actions {
            guard sender(action), isCurrent() else { return false }
        }
        return true
    }
}

struct CaptureHealthState {
    private(set) var lastStatusAt: TimeInterval?
    private(set) var statusIsHealthy = false
    private(set) var lastStatusWasIdle = false
    /// The captured display's window layout when the screen went still (`StillScreenWitness`).
    private(set) var stillLayout: Int?
    /// The drawn pointer inside the captured rect when the screen went still; nil when not drawn there.
    private(set) var stillPointer: CGPoint?
    private(set) var stillLayoutChanged = false

    mutating func observe(_ status: SCFrameStatus, at time: TimeInterval) {
        lastStatusAt = time
        statusIsHealthy = status == .complete || status == .idle
        lastStatusWasIdle = status == .idle
        if status != .idle { stillLayout = nil; stillPointer = nil }
        stillLayoutChanged = false
    }

    /// Read on the 0.4 s health tick, never on the frame path: once while idle status still arrives
    /// (the baseline), then on every silent tick until it differs; nil (no window list) is a change.
    /// So at most 2.5 window lists a second, and none between frames of moving content.
    func wantsStillLayout(at time: TimeInterval, streamCapturing: Bool?, stillWitnessEnabled: Bool = false) -> Bool {
        guard streamCapturing == true || (streamCapturing == nil && stillWitnessEnabled),
              lastStatusWasIdle, !stillLayoutChanged else { return false }
        return stillLayout == nil || isSilent(at: time)
    }

    /// A pointer move counts only beyond 1 point, at least a whole pixel the stream must redraw, so a
    /// sub-pixel drift never fails a live stream closed.
    mutating func witnessStillLayout(_ layout: Int?, pointer: CGPoint? = nil) {
        guard lastStatusWasIdle, !stillLayoutChanged else { return }
        guard let layout else { stillLayoutChanged = true; return }
        guard let stillLayout else { stillLayout = layout; stillPointer = pointer; return }
        let pointerMoved: Bool
        switch (stillPointer, pointer) {
        case (nil, nil): pointerMoved = false
        case let (old?, new?): pointerMoved = hypot(new.x - old.x, new.y - old.y) > 1
        default: pointerMoved = true
        }
        stillLayoutChanged = layout != stillLayout || pointerMoved
    }

    mutating func witnessContentChanged() { stillLayoutChanged = true }

    /// Fresh complete/idle status, or a still screen: ScreenCaptureKit stops sending idle status
    /// about 9 s after the picture last changed (PocketDeskStreamStats, 1 Oct 2026: captureIdleFPS
    /// ~36 then 0 in every still run), so after an idle status the source counts as alive while
    /// `streamCapturing` (macOS 27's `SCStream.isCapturing`, nil before it) holds and the display's
    /// window layout is unchanged: a window that opened, closed or moved without a frame is a stalled
    /// stream. Any other status, or a stream that says it stopped, fails closed as before.
    func isHealthy(at time: TimeInterval, staleAfter: TimeInterval = 0.8, streamCapturing: Bool? = nil,
                   stillWitnessAt: TimeInterval? = nil, stillWitnessEnabled: Bool = true) -> Bool {
        guard statusIsHealthy, let lastStatusAt, time >= lastStatusAt else { return false }
        if time - lastStatusAt <= staleAfter { return true }
        guard lastStatusWasIdle, !stillLayoutChanged else { return false }
        if streamCapturing == true { return true }
        guard streamCapturing == nil, stillWitnessEnabled, let stillWitnessAt,
              time >= stillWitnessAt else { return false }
        return time - stillWitnessAt <= CaptureStillWitness.leaseSeconds
    }

    func isSilent(at time: TimeInterval, staleAfter: TimeInterval = 0.8) -> Bool {
        lastStatusAt.map { time - $0 > staleAfter } ?? false
    }
}

/// Only one screenshot may be outstanding. A hung API call expires its lease but cannot queue
/// more work. Geometry/filter changes invalidate its token before any replacement can be shown.
struct CaptureStillWitness {
    static let disabledDefaultsKey = "farsideStillWitnessDisabled"
    // Source candidate only: enable explicitly for macOS 26 metadata/device acceptance.
    static let enabled = resolveEnabled()
    static func resolveEnabled(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.object(forKey: disabledDefaultsKey) as? Bool ?? true)
    }
    static let leaseSeconds: TimeInterval = 1.2
    static let interval: TimeInterval = 0.8
    private(set) var completedAt: TimeInterval?
    private(set) var pending: UInt64?
    private var generation: UInt64 = 0
    private var lastRequestedAt: TimeInterval?

    mutating func begin(at now: TimeInterval) -> UInt64? {
        guard pending == nil, lastRequestedAt.map({ now >= $0 && now - $0 >= Self.interval }) ?? true else { return nil }
        generation &+= 1
        pending = generation
        lastRequestedAt = now
        return generation
    }

    mutating func finish(_ token: UInt64, requestedAt: TimeInterval, at now: TimeInterval, succeeded: Bool) -> Bool {
        guard pending == token else { return false }
        pending = nil
        guard generation == token, succeeded, now >= requestedAt,
              now - requestedAt <= Self.leaseSeconds else { completedAt = nil; return false }
        // Callback processing time is not the capture time; latency must spend the lease.
        completedAt = requestedAt
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        completedAt = nil
        // Keep the pending slot until the old callback returns, even across reconfiguration.
    }
}

struct CaptureStillContentWitness {
    private var baseline: Data?
    private var awaitingIdle: (signature: Data, sourceTicks: UInt64)?
    mutating func observe(_ signature: Data?, sourceFresh: Bool, sourceTicks: UInt64 = 0) -> Bool {
        guard let signature else { return false }
        if sourceFresh, sourceTicks > 0 { awaitingIdle = (signature, sourceTicks) }
        return baseline == signature
    }

    /// The stream must confirm idle AFTER the screenshot completed. A timestamp merely still
    /// inside the freshness window cannot establish a baseline if the stream died before typing.
    mutating func confirmIdle(sourceTicks: UInt64) {
        guard let awaitingIdle, sourceTicks > 0, sourceTicks >= awaitingIdle.sourceTicks else { return }
        baseline = awaitingIdle.signature
        self.awaitingIdle = nil
    }

    /// Hash every visible byte (both NV12 planes or all BGRA channels), excluding stride padding.
    /// A sampled thumbnail can miss one typed character; unchanged layout alone misses it too.
    static func signature(_ buffer: CVPixelBuffer) -> Data? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var hash = SHA256()
        let planes = CVPixelBufferGetPlaneCount(buffer)
        for plane in 0..<max(1, planes) {
            let base = planes == 0 ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let height = planes == 0 ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, plane)
            let width = planes == 0 ? CVPixelBufferGetWidth(buffer) * 4 : CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            guard let base, width <= stride else { return nil }
            for row in 0..<height {
                hash.update(data: Data(bytesNoCopy: base.advanced(by: row * stride), count: width, deallocator: .none))
            }
        }
        return Data(hash.finalize())
    }
}

/// An independent check on a silent stream. A reconfiguration does not make ScreenCaptureKit speak
/// again, and a screenshot differs from a stream frame of the same screen in ~460k of 4.2M luma
/// samples (1 Oct 2026 probe), too close to a typed character to compare. What the stream would show
/// moving is cheap and exact: other apps' on-screen windows over the captured rect, in order (only
/// `owner`'s for an app capture; only the size of `window` for a window capture), plus the pointer
/// (`CaptureHealthState.witnessStillLayout`). 0.04 ms of CPU a call with 3 windows, 0.65 ms with 145 (1 Oct 2026).
enum StillScreenWitness {
    static func layout(over captured: CGRect, owner: pid_t? = nil, window: CGWindowID? = nil,
                       excludingProcess pid: pid_t) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        var hasher = Hasher()
        for info in windows {
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            let number = info[kCGWindowNumber as String] as? Int
            guard ownerPID != pid, owner == nil || ownerPID == owner,
                  window == nil || number == window.map(Int.init),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  window != nil || rect.intersects(captured) else { continue }
            hasher.combine(number)
            hasher.combine(info[kCGWindowLayer as String] as? Int)
            if window == nil { hasher.combine(rect.origin.x); hasher.combine(rect.origin.y) }
            hasher.combine(rect.width); hasher.combine(rect.height)
        }
        return hasher.finalize()
    }
}

/// The idle refresh: while the source is healthy and nothing new was sent, the last frame goes out
/// again, so a still screen keeps arriving at about 1.25 fps (one 0.4 s health tick in two), well
/// inside the phone's 2 s freshness limit and enough traffic that the bandwidth estimate holds.
enum CaptureIdleRefresh {
    static let interval: TimeInterval = 0.45

    static func isDue(healthy: Bool, hasFrame: Bool, now: TimeInterval, lastSentAt: TimeInterval, lowData: Bool = false) -> Bool {
        // Keep the essential picture lease alive (phone freshness is two seconds), without 0.45s bursts.
        healthy && hasFrame && now - lastSentAt >= (lowData ? 1 : interval)
    }
}

/// Capture pixels are independent of the logical points used for remote input.
struct CapturePixelDimensions: Equatable {
    let width: Int
    let height: Int

    /// `maximumDimension` replaces the mode's cap (the client-pixel cap); `fps` sets the level fit.
    static func fitted(contentSize: CGSize, pointPixelScale: Double, quality: StreamQuality,
                       fps: Int = CaptureRatePolicy.standardFPS, maximumDimension: Int? = nil) -> CapturePixelDimensions? {
        let sourceWidth = Double(contentSize.width) * pointPixelScale
        let sourceHeight = Double(contentSize.height) * pointPixelScale
        guard pointPixelScale.isFinite, pointPixelScale > 0,
              sourceWidth.isFinite, sourceHeight.isFinite,
              sourceWidth >= 2, sourceHeight >= 2, fps > 0 else { return nil }

        let maximum = Double(maximumDimension ?? quality.maximumDimension(at: fps))
        let scale = min(1, maximum / max(sourceWidth, sourceHeight))
        var width = Int((sourceWidth * scale).rounded(.down)) & ~1
        var height = Int((sourceHeight * scale).rounded(.down)) & ~1
        while width >= 2, height >= 2, !H264LevelPolicy.fits(width: width, height: height, fps: fps) {
            width -= 2
            height = Int((Double(width) * sourceHeight / sourceWidth).rounded(.down)) & ~1
        }
        guard width >= 2, height >= 2 else { return nil }
        return CapturePixelDimensions(width: width, height: height)
    }
}

/// ScreenCaptureKit output and configuration completion can reach the capture queue in
/// either order. Decide whether the cached frame belongs to the newly applied output.
enum CaptureFrameCachePolicy {
    static func shouldDiscard(cachedDimensions: CapturePixelDimensions?, frameArrivedDuringUpdate: Bool,
                              cachedDisplayTime: UInt64, updateRequestedAt: UInt64,
                              previous: CaptureRegion, next: CaptureRegion) -> Bool {
        guard ViewportCapturePolicy.needsReconfiguration(from: previous, to: next) else { return false }
        let previousOutput = CapturePixelDimensions(width: previous.outputWidth, height: previous.outputHeight)
        let nextOutput = CapturePixelDimensions(width: next.outputWidth, height: next.outputHeight)
        // Dimensions identify new output only for a size change over the same source.
        // Arrival alone cannot reject a delayed old callback in an A→B→A cycle.
        // Both timestamps use ScreenCaptureKit's existing mach absolute time domain.
        guard previous.isWholeDisplay == next.isWholeDisplay, previous.rect == next.rect,
              previousOutput != nextOutput, frameArrivedDuringUpdate, cachedDimensions == nextOutput,
              cachedDisplayTime > 0, updateRequestedAt > 0, cachedDisplayTime >= updateRequestedAt
        else { return true }
        return false
    }
}

/// The refresh rate of the display being captured, from CoreGraphics' current mode or the
/// matching NSScreen; nil when neither reports one (some virtual and adaptive displays say 0).
enum DisplayRefresh {
    static func rateHz(for displayID: CGDirectDisplayID) -> Double? {
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 { return mode.refreshRate }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        if let fps = screen?.maximumFramesPerSecond, fps > 0 { return Double(fps) }
        return nil
    }
}

private enum CaptureSizingError: Error { case invalidSource }

/// The stream reported started, or had been running, but macOS says it is not capturing.
struct CaptureNotCapturingError: Error, Equatable {}

/// Why ScreenCaptureKit stopped or refused a capture, as far as Farside acts on it.
enum CaptureStopReason: Equatable {
    /// macOS stopped the stream, the person declined it, or it is not capturing: someone at the Mac
    /// has to approve screen recording before Farside can share again.
    case needsApproval
    case failed

    static func classify(_ error: Error) -> Self {
        if error is CaptureNotCapturingError { return .needsApproval }
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return .failed }
        switch error.code {
        case SCStreamError.Code.userDeclined.rawValue, SCStreamError.Code.systemStoppedStream.rawValue:
            return .needsApproval
        default:
            return .failed
        }
    }

    /// macOS 27 says whether screen recording is supported and allowed here; earlier systems cannot.
    static var systemAllowsCapture: Bool {
        if #available(macOS 27, *) { return SCContentSharingPicker.shared.isAvailable }
        return true
    }
}

/// The active session may already be nil while its OS producer is still stopping. Keep that
/// cleanup obligation across every stop/start, including a newer start superseding a waiting one.
@MainActor
final class CaptureRetirementBarrier {
    private var pending: CaptureStartupTicket?

    func retire(_ ticket: CaptureStartupTicket) {
        guard !ticket.retirementConfirmed else { return }
        // The producer reservation admits only one unretired ticket. A late caller must never
        // overwrite a newer ticket's cleanup obligation if it retires an older session again.
        if pending == nil || pending === ticket || pending?.retirementConfirmed == true {
            pending = ticket
        }
        ticket.requestStop() // Synchronous picture/audio fence; confirmation remains asynchronous.
    }

    func waitForRetirement(timeout: TimeInterval = 3, whileCurrent: () -> Bool) async throws {
        try Task.checkCancellation()
        guard whileCurrent() else { throw CancellationError() }
        guard let ticket = pending else { return }
        let retired = await ticket.waitForRetirement(timeout: timeout)
        try Task.checkCancellation()
        guard whileCurrent() else { throw CancellationError() }
        guard retired else { throw CaptureStartupTicket.Failure.cleanupPending }
        if pending === ticket { pending = nil }
    }
}

@MainActor
final class RemoteCapture {
    var onFailure: ((Error) -> Void)?
    var onHealth: ((Bool) -> Void)?
    var onQuality: ((StreamQuality) -> Void)?
    /// Reports changes to `cursorInVideo`.
    var onCursorVisibility: ((Bool) -> Void)?
    private(set) var appliedQuality: StreamQuality?
    private(set) var appliedShowsCursor = true
    /// True only while every upcoming frame includes the cursor: false as soon as hiding is
    /// requested, true again only once showing is applied. A client drawing its own pointer
    /// therefore sees a brief duplicate at a transition, never a missing pointer.
    var cursorInVideo: Bool { appliedShowsCursor && requestedShowsCursor }

    /// Windows the running stream excludes (the privacy curtain) were dropped because capture
    /// stopped or restarted; whoever owns them must not rely on the old exclusion.
    var onExclusionLost: (() -> Void)?
    private(set) var excludedWindowIDs: Set<CGWindowID> = []

    /// G4: what the stream covers, once at every start (the whole display) and whenever
    /// ScreenCaptureKit has applied a different region; echoed to the phone on `capture` status.
    var onGuestFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onGuestSourceFence: (() -> Void)?
    var onGuestSourceChanged: (() -> Void)?
    var onCaptureRegion: ((CaptureRegion) -> Void)?
    private(set) var appliedCaptureRegion: CaptureRegion?

    /// Stream pixels per displayed phone pixel for the applied region and the latest viewport, to 3 places.
    var deliveredSharpness: Double? {
        guard let region = appliedCaptureRegion, let geometry = session?.geometry,
              let value = ViewportCapturePolicy.deliveredSharpness(region: region, viewport: requestedViewport,
                                                                   display: geometry) else { return nil }
        return (value * 1000).rounded() / 1000
    }

    private var ownership = ScopedCaptureOwner()
    private var session: RemoteCaptureSession?
    private let retirement = CaptureRetirementBarrier()
    private weak var streamPeer: PeerMedia?
    private var requestedQuality: StreamQuality = .balanced
    private var requestedShowsCursor = true
    /// The client's longest screen edge in pixels, capping the capture (reduction only).
    private var requestedClientLongEdge: Int?
    private var appliedClientLongEdge: Int?
    private var requestedViewport: ViewportRegion?
    /// The display the requested viewport's points refer to.
    private var viewportDisplayID: CGDirectDisplayID?
    private var requestedLadder: LadderState?
    private var captureStarted = false
    private var qualityUpdateTask: Task<Void, Never>?
    private var scopeMonitor: Task<Void, Never>?
    private var exclusionGeneration: UInt64 = 0
    private var exclusionTask: Task<Bool, Never>?

    /// Fence PCM synchronously, then serialize audio with picture configuration updates.
    /// Listening never restarts the picture or retires its geometry/input epoch.
    func setSystemAudioEnabled(_ enabled: Bool) {
        streamPeer?.setSystemAudioEnabled(enabled)
        session?.requestSystemAudio(enabled)
    }

    func setQuality(_ quality: StreamQuality) {
        guard quality != requestedQuality else { return }
        requestedQuality = quality
        scheduleQualityUpdate()
    }

    /// The client's screen in pixels (heartbeats); the capture never exceeds its longest edge.
    func setClientPixels(_ pixels: PixelSize?) {
        let edge = pixels?.longEdge
        guard edge != requestedClientLongEdge else { return }
        requestedClientLongEdge = edge
        scheduleQualityUpdate()
    }

    /// G4: the desktop region the phone shows (heartbeats). The crop is resolved and applied on the
    /// capture queue; nil returns to the whole display.
    func setViewport(_ viewport: ViewportRegion?) {
        guard viewport != requestedViewport else { return }
        requestedViewport = viewport
        guard captureStarted, let session else { return }
        session.requestViewport(viewport)
    }

    /// G12: the ladder's rung is applied at the capture (frame interval and output size), so the
    /// encoder never sees frames it would have to drop; nil is rung 0. Cleared by `stop()`.
    func setLadder(_ state: LadderState?) {
        guard state != requestedLadder else { return }
        requestedLadder = state
        guard captureStarted, let session else { return }
        session.requestLadder(state)
    }

    /// Only a client drawing its own pointer may hide it. Every capture starts with it shown.
    func setShowsCursor(_ shows: Bool) {
        guard shows != requestedShowsCursor else { return }
        let before = cursorInVideo
        requestedShowsCursor = shows
        notifyCursor(changedFrom: before)
        scheduleQualityUpdate()
    }

    /// `keepingExclusions` starts the new stream already excluding the windows the previous one
    /// excluded, so the privacy curtain never appears in it; if any of them can no longer be found,
    /// the exclusion is dropped as usual.
    func start(display: SCDisplay, peer: PeerMedia, keepingExclusions: Bool = false,
               target: HostCaptureTarget? = nil,
               beforeStart: ((DisplayGeometry) -> Bool)? = nil) async throws -> UInt64 {
        let owner = ownership.begin()
        if viewportDisplayID != display.displayID { requestedViewport = nil }
        viewportDisplayID = display.displayID
        appliedCaptureRegion = nil
        if keepingExclusions { cancelPendingExclusions() } else { dropExclusions() }
        qualityUpdateTask?.cancel()
        qualityUpdateTask = nil
        captureStarted = false
        appliedQuality = nil
        resetCursor()
        streamPeer = nil
        scopeMonitor?.cancel(); scopeMonitor = nil
        let previous = session
        previous?.fenceCapture()
        session = nil
        if let previous { retirement.retire(previous.retirementTicket) }
        try await retirement.waitForRetirement(whileCurrent: { self.ownership.owns(owner) })
        var excluding: [SCWindow] = []
        if keepingExclusions {
            excluding = await keptExclusionWindows()
            try Task.checkCancellation()
            guard ownership.owns(owner) else { throw CancellationError() }
            if excluding.isEmpty { dropExclusions() }
        }

        let resolved: HostResolvedCaptureScope
        if let target {
            peer.setSystemAudioEnabled(false)
            requestedViewport = nil
            resolved = try await HostCaptureScope.resolve(target)
            try Task.checkCancellation()
            guard ownership.owns(owner) else { throw CancellationError() }
        } else {
            resolved = HostResolvedCaptureScope(display: display,
                filter: SCContentFilter(display: display, excludingWindows: excluding), target: nil)
        }
        let lease = CaptureScopeLease(validUntil: target == nil ? .infinity : CACurrentMediaTime() + 1, clock: { CACurrentMediaTime() })
        let initialQuality = requestedQuality
        let initialClientLongEdge = requestedClientLongEdge
        let guestFence = onGuestSourceFence
        let scopedGuestFence: () -> Void = { [weak self] in
            // An old session cannot retire a replacement session's guests. Source lease → guest lease.
            lease.performIfValid {
                guestFence?()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.ownership.owns(owner) else { return }
                        self.onGuestSourceChanged?()
                    }
                }
            }
        }
        let reservation = CaptureProducerReservation.shared
        let producerToken = try reservation.reserve()
        let next: RemoteCaptureSession
        do {
            next = try RemoteCaptureSession(resolved: resolved, lease: lease, peer: peer, quality: initialQuality,
                clientLongEdge: initialClientLongEdge, guestFrame: onGuestFrame,
                guestSourceFence: scopedGuestFence, producerToken: producerToken)
        } catch { reservation.release(producerToken); throw error }
        reservation.retain(next, token: producerToken)
        next.onHealth = { [weak self, weak next] healthy in
            Task { @MainActor in
                guard let self, let next, self.ownership.owns(owner), self.session === next else { return }
                self.onHealth?(healthy && next.admitsPicture)
            }
        }
        next.onFailure = { [weak self, weak next] error in
            Task { @MainActor in
                guard let self, let next, self.ownership.owns(owner), self.session === next else { return }
                self.onFailure?(error)
            }
        }
        // Delivered on the main queue in the order applied; a Task hop could reorder two regions.
        next.onCaptureRegion = { [weak self, weak next] region in
            MainActor.assumeIsolated {
                guard let self, let next, self.ownership.owns(owner), self.session === next, next.admitsPicture else { return }
                self.publishCaptureRegion(region)
            }
        }
        guard beforeStart?(next.geometry) != false else {
            retirement.retire(next.retirementTicket)
            throw CancellationError()
        }
        session = next
        if let target {
            scopeMonitor = Task { [weak self, weak next] in
                while !Task.isCancelled {
                    do {
                        _ = try await HostCaptureScope.resolve(target)
                        guard let self, let next, self.ownership.owns(owner), self.session === next,
                              !Task.isCancelled else { return }
                        lease.renew(until: CACurrentMediaTime() + 1)
                        try await Task.sleep(for: .milliseconds(300))
                    } catch {
                        guard !Task.isCancelled, let self, let next,
                              self.ownership.owns(owner), self.session === next else { return }
                        next.fenceCapture()
                        self.onFailure?(HostCaptureScopeError.targetUnavailable)
                        return
                    }
                }
            }
        }

        do {
            try await next.start()
            try Task.checkCancellation()
            guard ownership.owns(owner), session === next, next.admitsPicture else { throw CancellationError() }
            captureStarted = true
            appliedQuality = initialQuality
            appliedClientLongEdge = initialClientLongEdge
            streamPeer = peer
            peer.applyStreamQuality(initialQuality)
            peer.applyCaptureRate(targetFPS: next.targetFPS, displayRefreshHz: next.displayRefreshHz,
                                  display: next.displayDescription)
            onQuality?(initialQuality)
            publishCaptureRegion(next.initialRegion)
            if let viewport = requestedViewport {
                if ViewportCapturePolicy.isValid(viewport, for: next.geometry) {
                    next.requestViewport(viewport)
                } else {
                    requestedViewport = nil
                }
            }
            scheduleQualityUpdate()
            return owner
        } catch {
            if ownership.owns(owner), session === next { scopeMonitor?.cancel(); scopeMonitor = nil; session = nil }
            retirement.retire(next.retirementTicket)
            throw error
        }
    }

    @discardableResult
    func stop(ifOwnedBy owner: UInt64) -> Task<Void, Never>? {
        guard ownership.owns(owner) else { return nil }
        return stop()
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        stop(keepingExclusions: false)
    }

    @discardableResult
    func stop(keepingExclusions: Bool) -> Task<Void, Never>? {
        ownership.invalidate()
        if keepingExclusions { cancelPendingExclusions() } else { dropExclusions() }
        qualityUpdateTask?.cancel()
        qualityUpdateTask = nil
        requestedQuality = .balanced
        appliedQuality = nil
        requestedClientLongEdge = nil
        appliedClientLongEdge = nil
        requestedViewport = nil
        viewportDisplayID = nil
        requestedLadder = nil
        appliedCaptureRegion = nil
        resetCursor()
        captureStarted = false
        streamPeer = nil
        scopeMonitor?.cancel(); scopeMonitor = nil
        let previous = session
        if let previous { retirement.retire(previous.retirementTicket) }
        session = nil
        guard let previous else { return nil }
        return Task { _ = await previous.stop() }
    }

    /// Hides the given windows (the privacy curtain) from the running stream. True only once the live
    /// content filter excludes every one of them. Requests are applied in order, so an older request
    /// finishing late can never replace a newer filter.
    func excludeWindows(_ ids: Set<CGWindowID>) async -> Bool {
        exclusionGeneration &+= 1
        let generation = exclusionGeneration
        let previous = exclusionTask
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self, generation == self.exclusionGeneration else { return false }
            return await self.applyExclusion(ids)
        }
        exclusionTask = task
        return await task.value
    }

    /// A coarse luma grid of the most recent captured frame, used to verify the curtain stays out
    /// of the stream.
    func lumaSignature() async -> CaptureLumaSignature? {
        guard captureStarted, let session else { return nil }
        return await session.lumaSignature()
    }

    private func applyExclusion(_ ids: Set<CGWindowID>) async -> Bool {
        guard !ids.isEmpty, captureStarted, let target = session else { return false }
        let owner = ownership.current
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              ownership.owns(owner), session === target,
              let windows = CaptureWindowExclusion.windows(for: ids, in: content.windows, id: { $0.windowID })
        else { return false }
        guard await target.updateExcludedWindows(windows), ownership.owns(owner), session === target else {
            return false
        }
        excludedWindowIDs = ids
        return true
    }

    private func keptExclusionWindows() async -> [SCWindow] {
        let ids = excludedWindowIDs
        guard !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              ids == excludedWindowIDs
        else { return [] }
        return CaptureWindowExclusion.windows(for: ids, in: content.windows, id: { $0.windowID }) ?? []
    }

    private func cancelPendingExclusions() {
        exclusionGeneration &+= 1
        exclusionTask = nil
    }

    private func dropExclusions() {
        cancelPendingExclusions()
        guard !excludedWindowIDs.isEmpty else { return }
        excludedWindowIDs = []
        onExclusionLost?()
    }

    private var qualityUpdatePending: Bool {
        requestedQuality != appliedQuality || requestedShowsCursor != appliedShowsCursor
            || requestedClientLongEdge != appliedClientLongEdge
    }

    private func scheduleQualityUpdate() {
        guard qualityUpdateTask == nil, captureStarted, let session, qualityUpdatePending else { return }
        let owner = ownership.current
        qualityUpdateTask = Task { [weak self] in
            await self?.applyRequestedQuality(to: session, owner: owner)
        }
    }

    private func applyRequestedQuality(to target: RemoteCaptureSession, owner: UInt64) async {
        while !Task.isCancelled, ownership.owns(owner), session === target,
              let appliedQuality, qualityUpdatePending {
            let quality = requestedQuality
            let showsCursor = requestedShowsCursor
            let clientLongEdge = requestedClientLongEdge
            let succeeded = await target.updateQuality(quality, showsCursor: showsCursor, clientLongEdge: clientLongEdge)
            guard !Task.isCancelled, ownership.owns(owner), session === target else { break }
            if succeeded {
                if quality != appliedQuality {
                    self.appliedQuality = quality
                    streamPeer?.applyStreamQuality(quality)
                    onQuality?(quality)
                }
                appliedClientLongEdge = clientLongEdge
                let before = cursorInVideo
                appliedShowsCursor = showsCursor
                notifyCursor(changedFrom: before)
            } else if requestedQuality == quality && requestedShowsCursor == showsCursor && requestedClientLongEdge == clientLongEdge {
                // A rejected client cap must not retry forever; keep the applied one.
                requestedClientLongEdge = appliedClientLongEdge
                if requestedShowsCursor != appliedShowsCursor {
                    // Keep reporting what frames really contain; the caller may retry later.
                    let before = cursorInVideo
                    requestedShowsCursor = appliedShowsCursor
                    notifyCursor(changedFrom: before)
                }
                break
            }
        }
        guard ownership.owns(owner), session === target else { return }
        qualityUpdateTask = nil
    }

    private func publishCaptureRegion(_ region: CaptureRegion) {
        guard region != appliedCaptureRegion else { return }
        appliedCaptureRegion = region
        onCaptureRegion?(region)
    }

    private func resetCursor() {
        let before = cursorInVideo
        requestedShowsCursor = true
        appliedShowsCursor = true
        notifyCursor(changedFrom: before)
    }

    private func notifyCursor(changedFrom before: Bool) {
        if cursorInVideo != before { onCursorVisibility?(cursorInVideo) }
    }
}

/// Converts ScreenCaptureKit's `displayTime` (mach absolute time) into display→callback delay.
enum CaptureTiming {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func milliseconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    static func displayLatencyMs(displayTime: UInt64, now: UInt64 = mach_absolute_time()) -> Double? {
        guard displayTime > 0, now >= displayTime else { return nil }
        let latency = milliseconds(fromMachTicks: now - displayTime)
        return latency < 1_000 ? latency : nil
    }
}

enum RemoteCaptureConfiguration {
    /// Deeper than ScreenCaptureKit's minimum of three: the idle-refresh copy and the encoder each
    /// hold a surface, and Apple's capture sample uses five to keep a high frame rate without stalls.
    static let queueDepth = 5

    /// A 1/60 floor by default; `.zero` asks ScreenCaptureKit for the display's own cadence (G1).
    static func minimumFrameInterval(for tuning: StreamTuning) -> CMTime {
        minimumFrameInterval(for: tuning, targetFPS: CaptureRatePolicy.standardFPS, displayRefreshHz: nil)
    }

    /// Above 60: the display's own cadence, unless the display runs faster than the target (a
    /// 144 Hz panel streamed at 120), in which case ScreenCaptureKit thins to the target itself.
    static func minimumFrameInterval(for tuning: StreamTuning, targetFPS: Int, displayRefreshHz: Double?) -> CMTime {
        CaptureRatePolicy.minimumFrameInterval(for: tuning, targetFPS: targetFPS, displayRefreshHz: displayRefreshHz)
    }

    /// The whole-display output: the mode's (or the client's) long-edge cap at this rate, then the
    /// receiver's H.264 level.
    static func outputSize(contentSize: CGSize, pointPixelScale: Double, quality: StreamQuality,
                           budget: H264FrameBudget?, fps: Int, clientLongEdge: Int?,
                           tuning: StreamTuning) -> CapturePixelDimensions? {
        let maximum = CaptureRatePolicy.maximumDimension(quality: quality, fps: fps, clientLongEdge: clientLongEdge,
                                                         tuning: tuning)
        guard let dimensions = CapturePixelDimensions.fitted(
            contentSize: contentSize, pointPixelScale: pointPixelScale, quality: quality, fps: fps,
            maximumDimension: maximum
        ) else { return nil }
        guard let fitted = budget?.fitted(width: dimensions.width, height: dimensions.height, fps: fps) else {
            return dimensions
        }
        return CapturePixelDimensions(width: fitted.width, height: fitted.height)
    }

    /// G12: a size rung shrinks the whole-display output linearly, to whole macroblocks.
    static func scaled(_ size: CapturePixelDimensions, by fraction: Double?) -> CapturePixelDimensions {
        guard let fraction, fraction.isFinite, fraction > 0, fraction < 1 else { return size }
        let block = ViewportCapturePolicy.macroblock
        func shrink(_ value: Int) -> Int { max(block, Int(Double(value) * fraction) / block * block) }
        return CapturePixelDimensions(width: shrink(size.width), height: shrink(size.height))
    }

    /// A crop (G4) sets `sourceRect` and its own output size, and fills the output exactly: its
    /// macroblock alignment leaves its aspect up to a few percent off the output's, and the default
    /// aspect-preserving fit would letterbox the picture and shift it against the rect the phone maps
    /// it to. Without a crop the configuration is the whole-display one, unchanged.
    static func streamConfiguration(output: CapturePixelDimensions, region: CaptureRegion?, showsCursor: Bool,
                                    fps: Int, displayRefreshHz: Double?,
                                    tuning: StreamTuning, capturesAudio: Bool = false, refinesText: Bool = false, fullColor444: Bool = false) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = output.width
        configuration.height = output.height
        if let region, !region.isWholeDisplay {
            configuration.sourceRect = region.rect
            configuration.width = region.outputWidth
            configuration.height = region.outputHeight
            configuration.preservesAspectRatio = false
        }
        configuration.minimumFrameInterval = minimumFrameInterval(for: tuning, targetFPS: fps,
                                                                  displayRefreshHz: displayRefreshHz)
        configuration.queueDepth = CaptureRatePolicy.queueDepth(for: fps)
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = capturesAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = false
        configuration.pixelFormat = (refinesText || fullColor444) ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = StreamColor.captureColorSpaceName
        configuration.colorMatrix = StreamColor.captureYCbCrMatrix
        return configuration
    }
}

private struct CaptureInputs: Equatable {
    var quality: StreamQuality
    var showsCursor: Bool
    var clientLongEdge: Int?
    var capturesAudio: Bool = false
    /// G12: a rung below the session rate, and a picture fraction below 1; nil at rung 0.
    var ladderFPS: Int? = nil
    var sizeFraction: Double? = nil
}

/// One owner for the converter and PCM admission. Rollback keeps the original capture queue.
final class CaptureAudioQueue {
    static let splitEnabled = !UserDefaults.standard.bool(forKey: "farsideAudioQueueSplitDisabled")
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<Bool>()

    init(captureQueue: DispatchQueue, splitEnabled: Bool = CaptureAudioQueue.splitEnabled) {
        queue = splitEnabled ? DispatchQueue(label: "PocketDesk.capture.audio", qos: .userInteractive) : captureQueue
        queue.setSpecific(key: key, value: true)
    }

    func sync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: key) == true { body() }
        else { queue.sync(execute: body) }
    }
}

/// Confined to the selected audio queue; no capture-queue state is consulted by audio callbacks.
struct CaptureAudioAdmission {
    private var lease = HostAudioCaptureEpoch()
    private var capturesAudio = false
    private var terminal = false

    mutating func configure(capturesAudio: Bool, allowed: Bool, begin: () -> UInt64, end: (UInt64) -> Void) {
        guard !terminal else { return }
        self.capturesAudio = capturesAudio
        if capturesAudio && allowed { lease.arm(allowed: true, begin: begin) }
        else { retire(end: end) }
    }

    mutating func retire(terminal: Bool = false, end: (UInt64) -> Void) {
        self.terminal = self.terminal || terminal
        capturesAudio = false
        lease.retire(end: end)
    }

    func admittedEpoch(consent: Bool) -> UInt64? {
        capturesAudio && consent ? lease.epoch : nil
    }
}

#if DEBUG
private enum CaptureStartupPhysicalCheck {
    private static let lock = NSLock()
    private static var policy = CaptureStartupFaultPolicy()
    static func consume() -> Bool {
        lock.withLock {
            policy.consume(requested: ProcessInfo.processInfo.arguments.contains("--farside-capture-start-recovery-check"),
                           debugBuild: true)
        }
    }
}
#endif

private final class RemoteCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "PocketDesk.capture", qos: .userInteractive)
    private var stream: SCStream!
    #if DEBUG
    private let suppressFirstPictureForCheck: Bool
    #endif
    private let producerToken: UUID
    private var startup: CaptureStartupTicket!

    private func makeStartupTicket() -> CaptureStartupTicket {
        CaptureStartupTicket(
            start: { [weak self] completion in
                guard let self else { completion(CancellationError()); return }
                self.stream.startCapture(completionHandler: completion)
            }, stop: { [weak self] completion in
                guard let self else { completion(CancellationError()); return }
                self.stream.stopCapture(completionHandler: completion)
            }, fence: { [weak self] in self?.retireLocalSession() },
            retired: { [producerToken] in CaptureProducerReservation.shared.release(producerToken) },
            stoppedError: { error in
                let error = error as NSError
                return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.attemptToStopStreamState.rawValue
            }, event: { [producerToken] event in
                SessionLog.log.info("Capture startup producer=\(producerToken.uuidString, privacy: .public) event=\(event, privacy: .public)")
            })
    }
    private let audioConverter = SystemAudioPCMConverter()
    private let audioQueue: CaptureAudioQueue
    private var audioAdmission = CaptureAudioAdmission()
    private let audioPeer: PeerMedia
    private let scopeLease: CaptureScopeLease
    private let scopeTarget: HostCaptureTarget?
    private let captureQueueKey = DispatchSpecificKey<Bool>()

    func fenceCapture() {
        scopeLease.invalidate()
        fenceAudio(terminal: true)
        let clear = { [self] in lastBuffer = nil; sourceTiming.reset() }
        if DispatchQueue.getSpecific(key: captureQueueKey) == true { clear() }
        else { queue.sync(execute: clear) }
    }

    func fenceAudio(terminal: Bool = false) {
        audioQueue.sync { [self] in
            audioAdmission.retire(terminal: terminal, end: audioPeer.endSystemAudioCapture)
            audioConverter.reset()
        }
    }

    /// Capture queue calls synchronously after a completed configuration or a consent retry.
    private func synchronizeAudioAdmission(capturesAudio: Bool, allowed: Bool) {
        audioQueue.sync { [self] in
            let previous = audioAdmission.admittedEpoch(consent: true)
            audioAdmission.configure(capturesAudio: capturesAudio, allowed: allowed,
                                     begin: audioPeer.beginSystemAudioCapture, end: audioPeer.endSystemAudioCapture)
            if previous != audioAdmission.admittedEpoch(consent: true) { audioConverter.reset() }
        }
    }

    func requestSystemAudio(_ enabled: Bool) {
        if !enabled { fenceAudio() }
        queue.async { [self] in
            guard !stopping, scopeTarget == nil else { return }
            // A failed audio-off configuration can leave SCK on after PCM was retired.
            // A fresh Listen still needs a new epoch even if the configuration is already on.
            if enabled {
                synchronizeAudioAdmission(capturesAudio: applied.capturesAudio, allowed: audioPeer.systemAudioEnabled)
            }
            guard requested.capturesAudio != enabled else { return }
            requested.capturesAudio = enabled
            handle(gate.request(at: CACurrentMediaTime(), immediate: true))
        }
    }
    private var peer: PeerMedia?
    private var timer: DispatchSourceTimer?
    private var health = CaptureHealthState()
    private var stillWitness = CaptureStillWitness()
    private var stillContentWitness = CaptureStillContentWitness()
    private var witnessFilter: SCContentFilter
    private var witnessConfiguration: SCStreamConfiguration
    private var witnessConfigurationUpdating = false
    private var witnessFilterUpdating = false
    private var lastBuffer: CVPixelBuffer?
    private var bufferVersion: UInt64 = 0
    private var lastBufferDisplayTime: UInt64 = 0
    private var sourceTiming = CaptureSourceTiming()
    private var lastSentAt = 0.0
    private var stopping = false
    private let display: SCDisplay
    private let tuning: StreamTuning

    // Configuration state, confined to `queue`: every updateConfiguration is built from the latest
    // inputs and viewport, one at a time, so a crop can never undo a newer quality or cursor change.
    private var requested: CaptureInputs
    private var applied: CaptureInputs
    private var viewport: ViewportRegion?
    private var appliedRegion: CaptureRegion
    /// The whole-display output changed, so the next region must not keep a size held for the old one.
    private var heldOutputInvalid = false
    /// The region switch whose `updateConfiguration` has not completed, and the last completed one
    /// (CaptureFrameRegionPolicy). Confined to `queue`.
    private var regionSwitchInFlight: CaptureFrameRegionPolicy.Switch?
    private var lastRegionSwitch: CaptureFrameRegionPolicy.Switch?
    private var lastBufferRegion: CaptureRegion?
    private var gate = ConfigurationUpdateGate()
    private var trailingUpdate: DispatchSourceTimer?
    private var waiters: [(Bool) -> Void] = []
    private var inFlightWaiters: [(Bool) -> Void] = []

    var onFailure: ((Error) -> Void)?
    var onHealth: ((Bool) -> Void)?
    private let onGuestFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    private let onGuestSourceFence: (() -> Void)?
    var onCaptureRegion: ((CaptureRegion) -> Void)?
    /// Consecutive health ticks on which macOS 27 said the stream is not capturing; confined to `queue`.
    private var notCapturingTicks = 0
    private var failureReported = false

    /// The rate this session captures and the peer sends at, fixed for the session (G5).
    let targetFPS: Int
    let displayRefreshHz: Double?
    /// "2560x1440 @1x 144Hz": which display and scale a measurement came from.
    let displayDescription: String
    let geometry: DisplayGeometry
    let initialRegion: CaptureRegion

    init(resolved: HostResolvedCaptureScope, lease: CaptureScopeLease, peer: PeerMedia, quality: StreamQuality, clientLongEdge: Int?,
         guestFrame: ((CVPixelBuffer, TimeInterval) -> Void)? = nil, guestSourceFence: (() -> Void)? = nil, producerToken: UUID) throws {
        self.producerToken = producerToken
        #if DEBUG
        suppressFirstPictureForCheck = CaptureStartupPhysicalCheck.consume()
        if suppressFirstPictureForCheck {
            SessionLog.log.info("Capture startup check suppresses first producer complete-frame admission")
        }
        #endif
        onGuestFrame = guestFrame; onGuestSourceFence = guestSourceFence
        let display = resolved.display
        let filter = resolved.filter
        scopeLease = lease
        scopeTarget = resolved.target
        let tuning = StreamTuning.current
        let refresh = DisplayRefresh.rateHz(for: display.displayID)
        let fps = CaptureRatePolicy.targetFPS(displayRefreshHz: refresh, tuning: tuning)
        let geometry = DisplayGeometry(size: filter.contentRect.size, pointPixelScale: Double(filter.pointPixelScale))
        guard let output = RemoteCaptureConfiguration.outputSize(
            contentSize: geometry.size, pointPixelScale: geometry.pointPixelScale, quality: quality,
            budget: peer.nativeCaptureBudget, fps: fps, clientLongEdge: clientLongEdge, tuning: tuning
        ) else {
            throw CaptureSizingError.invalidSource
        }
        let configuration = RemoteCaptureConfiguration.streamConfiguration(
            output: output, region: nil, showsCursor: true, fps: fps, displayRefreshHz: refresh, tuning: tuning, capturesAudio: resolved.target == nil && peer.systemAudioEnabled, refinesText: peer.refinementCaptureEnabled, fullColor444: peer.fullColorCaptureEnabled
        )
        self.display = display
        witnessFilter = filter
        witnessConfiguration = configuration
        self.peer = peer
        audioPeer = peer
        audioQueue = CaptureAudioQueue(captureQueue: queue)
        self.tuning = tuning
        self.geometry = geometry
        let inputs = CaptureInputs(quality: quality, showsCursor: true, clientLongEdge: clientLongEdge,
                                   capturesAudio: resolved.target == nil && peer.systemAudioEnabled)
        requested = inputs
        applied = inputs
        initialRegion = ViewportCapturePolicy.wholeDisplay(geometry, output: output)
        appliedRegion = initialRegion
        targetFPS = fps
        displayRefreshHz = refresh
        let scale = Double(filter.pointPixelScale)
        let pixels = CGSize(width: Double(filter.contentRect.width) * scale, height: Double(filter.contentRect.height) * scale)
        displayDescription = String(format: "%.0fx%.0f @%.0fx %@", pixels.width, pixels.height, scale,
                                    refresh.map { String(format: "%.0fHz", $0) } ?? "?Hz")
        super.init()
        queue.setSpecific(key: captureQueueKey, value: true)
        synchronizeAudioAdmission(capturesAudio: inputs.capturesAudio, allowed: peer.systemAudioEnabled)
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        startup = makeStartupTicket() // One ticket exists before any queue or caller can observe the session.
    }

    /// A new quality or client cap resets the held output and re-derives the crop in the same update.
    func updateQuality(_ quality: StreamQuality, showsCursor: Bool, clientLongEdge: Int?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !stopping else {
                    continuation.resume(returning: false)
                    return
                }
                var inputs = requested
                inputs.quality = quality
                inputs.showsCursor = showsCursor
                inputs.clientLongEdge = clientLongEdge
                if inputs.quality != requested.quality || inputs.clientLongEdge != requested.clientLongEdge {
                    heldOutputInvalid = true
                }
                requested = inputs
                waiters.append { continuation.resume(returning: $0) }
                handle(gate.request(at: CACurrentMediaTime(), immediate: true))
            }
        }
    }

    /// A rung change goes out without the viewport wait; a size step resets the held crop output so
    /// the crop is re-derived for the new picture in the same update.
    func requestLadder(_ state: LadderState?) {
        queue.async { [self] in
            guard !stopping else { return }
            var inputs = requested
            inputs.ladderFPS = state.flatMap { $0.fps < targetFPS ? $0.fps : nil }
            inputs.sizeFraction = state.flatMap { $0.sizeFraction < 1 ? $0.sizeFraction : nil }
            guard inputs != requested else { return }
            if inputs.sizeFraction != requested.sizeFraction { heldOutputInvalid = true }
            requested = inputs
            handle(gate.request(at: CACurrentMediaTime(), immediate: true))
        }
    }

    /// One hop onto the capture queue; the crop is applied there on the leading edge when the gate is idle.
    func requestViewport(_ viewport: ViewportRegion?) {
        queue.async { [weak self] in
            guard let self, self.scopeTarget == nil, !self.stopping, self.viewport != viewport else { return }
            self.viewport = viewport
            self.handle(self.gate.request(at: CACurrentMediaTime(), immediate: !self.waiters.isEmpty))
        }
    }

    private func handle(_ action: ConfigurationUpdateGate.Action) {
        switch action {
        case .none: break
        case .start: performConfigurationUpdate()
        case .wait(let deadline): scheduleTrailingUpdate(at: deadline)
        }
    }

    private func scheduleTrailingUpdate(at deadline: TimeInterval) {
        guard trailingUpdate == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline - CACurrentMediaTime()))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            self.trailingUpdate?.cancel()
            self.trailingUpdate = nil
            self.handle(self.gate.deadlineReached(at: CACurrentMediaTime(), immediate: !self.waiters.isEmpty))
        }
        trailingUpdate = timer
        timer.resume()
    }

    private func performConfigurationUpdate() {
        trailingUpdate?.cancel()
        trailingUpdate = nil
        let inputs = requested
        inFlightWaiters = waiters
        waiters = []
        let previous = heldOutputInvalid ? nil : appliedRegion
        heldOutputInvalid = false
        // The pixel budget stays the session rate's: a slower rung must not grow the picture.
        guard let whole = RemoteCaptureConfiguration.outputSize(
            contentSize: geometry.size, pointPixelScale: geometry.pointPixelScale, quality: inputs.quality,
            budget: peer?.nativeCaptureBudget, fps: targetFPS, clientLongEdge: inputs.clientLongEdge, tuning: tuning
        ) else {
            requested = applied
            completeConfigurationUpdate(succeeded: false)
            return
        }
        let output = RemoteCaptureConfiguration.scaled(whole, by: inputs.sizeFraction)
        let region = ViewportCapturePolicy.region(for: viewport, display: geometry, output: output, tuning: tuning,
                                                  previous: previous, cropEngaged: !appliedRegion.isWholeDisplay)
        let geometryChanges = ViewportCapturePolicy.needsReconfiguration(from: appliedRegion, to: region)
        guard inputs != applied || geometryChanges else {
            publish(region)
            completeConfigurationUpdate(succeeded: true)
            return
        }
        onGuestSourceFence?()
        stillWitness.invalidate()
        stillContentWitness = CaptureStillContentWitness()
        witnessConfigurationUpdating = true
        let configuration = RemoteCaptureConfiguration.streamConfiguration(
            output: output, region: region, showsCursor: inputs.showsCursor,
            fps: min(targetFPS, inputs.ladderFPS ?? targetFPS),
            displayRefreshHz: displayRefreshHz, tuning: tuning, capturesAudio: inputs.capturesAudio, refinesText: peer?.refinementCaptureEnabled == true, fullColor444: peer?.fullColorCaptureEnabled == true
        )
        let previousRegion = appliedRegion
        let bufferVersionAtStart = bufferVersion
        let updateRequestedAt = mach_absolute_time()
        if geometryChanges {
            regionSwitchInFlight = CaptureFrameRegionPolicy.Switch(
                previous: previousRegion, next: region, requestedMs: CaptureTiming.milliseconds(fromMachTicks: updateRequestedAt))
        }
        stream.updateConfiguration(configuration) { [self] error in
            queue.async { [self] in
                // stop() already answered the waiters.
                guard !stopping else { return }
                witnessConfigurationUpdating = false
                if let inFlight = regionSwitchInFlight, inFlight.next == region {
                    lastRegionSwitch = error == nil ? inFlight : nil
                    regionSwitchInFlight = nil
                }
                if error == nil {
                    witnessConfiguration = configuration
                    applied = inputs
                    synchronizeAudioAdmission(capturesAudio: inputs.capturesAudio,
                                              allowed: requested.capturesAudio && audioPeer.systemAudioEnabled)
                    // The idle refresh must not resend a frame of the old region under the new one.
                    if CaptureFrameCachePolicy.shouldDiscard(
                        cachedDimensions: lastBuffer.map {
                            CapturePixelDimensions(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
                        }, frameArrivedDuringUpdate: bufferVersion != bufferVersionAtStart,
                        cachedDisplayTime: lastBufferDisplayTime, updateRequestedAt: updateRequestedAt,
                        previous: previousRegion, next: region
                    ) { lastBuffer = nil; lastBufferRegion = nil }
                    publish(region)
                } else if requested == inputs {
                    requested = applied
                    if inputs.capturesAudio {
                        audioPeer.setSystemAudioEnabled(false)
                        fenceAudio() // Next admitted heartbeat retries with a fresh epoch.
                    }
                }
                completeConfigurationUpdate(succeeded: error == nil)
            }
        }
    }

    private func completeConfigurationUpdate(succeeded: Bool) {
        let finished = inFlightWaiters
        inFlightWaiters = []
        finished.forEach { $0(succeeded) }
        handle(gate.finished(at: CACurrentMediaTime(), immediate: !waiters.isEmpty))
    }

    private func publish(_ region: CaptureRegion) {
        guard region != appliedRegion else { return }
        appliedRegion = region
        let callback = onCaptureRegion
        DispatchQueue.main.async { callback?(region) }
    }

    /// Same display, minus the given windows. Sizing is unchanged, so the configuration stays.
    func updateExcludedWindows(_ windows: [SCWindow]) async -> Bool {
        guard scopeTarget == nil, !queue.sync(execute: { stopping }) else { return false }
        onGuestSourceFence?()
        do {
            let filter = SCContentFilter(display: display, excludingWindows: windows)
            queue.sync { stillWitness.invalidate(); stillContentWitness = CaptureStillContentWitness(); witnessFilterUpdating = true }
            try await stream.updateContentFilter(filter)
            queue.sync { witnessFilter = filter; witnessFilterUpdating = false; stillWitness.invalidate() }
            return !queue.sync { stopping }
        } catch {
            queue.sync { witnessFilterUpdating = false }
            return false
        }
    }

    func lumaSignature() async -> CaptureLumaSignature? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.lastBuffer.flatMap(CaptureLumaSignature.init(pixelBuffer:)))
            }
        }
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if scopeTarget == nil { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue.queue) }
        do { try await startup.start() }
        catch CaptureStartupTicket.Failure.deadline { throw CaptureStartupTimeout(ticket: startup) }
        guard admitsPicture else { throw CancellationError() }
        if #available(macOS 27, *), !stream.isCapturing {
            requestStop()
            throw CaptureNotCapturingError()
        }
        queue.sync {
            guard !stopping else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.4, leeway: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.publishHealthAndIdleFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    var admitsPicture: Bool {
        let stopped = DispatchQueue.getSpecific(key: captureQueueKey) == true ? stopping : queue.sync { stopping }
        return CaptureStartupRecoveryPolicy.admitsCallback(ready: startup.isReady,
            scopeValid: scopeLease.performIfValid({}), stopping: stopped)
    }

    func requestStop() { startup.requestStop() }

    var retirementTicket: CaptureStartupTicket { startup }

    func stop() async -> Bool {
        requestStop()
        return await startup.waitForRetirement()
    }

    private func retireLocalSession() {
        fenceCapture()
        let retire = { [self] in
            if !stopping {
                stopping = true
                timer?.cancel()
                timer = nil
                trailingUpdate?.cancel()
                trailingUpdate = nil
                lastBuffer = nil
                peer = nil
                onFailure = nil
                onHealth = nil
                onCaptureRegion = nil
                let unanswered = inFlightWaiters + waiters
                inFlightWaiters = []
                waiters = []
                unanswered.forEach { $0(false) }
            }
        }
        if DispatchQueue.getSpecific(key: captureQueueKey) == true { retire() }
        else { queue.sync(execute: retire) }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .audio {
            guard startup.isReady, scopeTarget == nil, let audioEpoch = audioAdmission.admittedEpoch(consent: audioPeer.systemAudioEnabled) else { return }
            let staleBefore = audioConverter.staleDrops // converter and counter read only on the audio queue
            for packet in audioConverter.packets(from: sampleBuffer) {
                // Invalidation waits for actual submission, including a packet converted during a fence.
                scopeLease.performIfValid {
                    audioPeer.submitSystemAudio(packet.pcm, epoch: audioEpoch, hostTime: packet.hostTime)
                }
            }
            audioPeer.counters.audioSourceDropped(audioConverter.staleDrops - staleBefore)
            return
        }
        let capturedMs = MachClock.nowMs() // Public SCK callback entry, before admission/metadata work.
        guard scopeTarget?.processIsAlive != false,
              scopeLease.performIfValid({}) else {
            reportStopped(HostCaptureScopeError.targetUnavailable)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), !stopping else { return }

        let now = CACurrentMediaTime()
        let displayTime = (attachments.first?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        health.observe(status, at: now)
        if status != .idle { stillWitness.invalidate(); stillContentWitness = CaptureStillContentWitness() }
        else { stillContentWitness.confirmIdle(sourceTicks: displayTime) }
        if status == .complete || status == .idle {
            peer?.counters.captured(idle: status == .idle,
                                    displayLatencyMs: CaptureTiming.displayLatencyMs(displayTime: displayTime),
                                    displayTimeMs: displayTime > 0 ? CaptureTiming.milliseconds(fromMachTicks: displayTime) : nil)
        }
        guard status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              peer != nil else { return }
        #if DEBUG
        // Real SCK starts/stops; only this one process-opted-in producer loses frame admission.
        if suppressFirstPictureForCheck { return }
        #endif
        startup.completeFrame()
        peer?.captureContentChanged()
        lastBuffer = buffer
        bufferVersion &+= 1
        lastBufferDisplayTime = displayTime
        let timing = sourceTiming.captured(displayTicks: displayTime, atMs: capturedMs)
        let displayMs = displayTime > 0 ? CaptureTiming.milliseconds(fromMachTicks: displayTime) : 0
        let region = CaptureFrameRegionPolicy.region(
            displayMs: displayMs, bufferWidth: CVPixelBufferGetWidth(buffer), bufferHeight: CVPixelBufferGetHeight(buffer),
            applied: appliedRegion, inFlight: regionSwitchInFlight, lastSwitch: lastRegionSwitch)
        lastBufferRegion = region
        if startup.isReady { deliver(buffer, at: now, displayMs: displayMs, timing: timing, region: region) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.reportStopped(error) }
    }

    private func reportStopped(_ error: Error) {
        guard !stopping, !failureReported else { return }
        failureReported = true
        if !startup.isReady { startup.fail(error); return }
        fenceCapture()
        lastBuffer = nil
        health.observe(.stopped, at: CACurrentMediaTime())
        publishHealthAndIdleFrame()
        let callback = onFailure
        DispatchQueue.main.async { callback?(error) }
    }

    private func publishHealthAndIdleFrame() {
        guard !stopping else { return }
        if !failureReported && (scopeTarget?.processIsAlive == false || !scopeLease.performIfValid({})) {
            reportStopped(HostCaptureScopeError.targetUnavailable); return
        }
        var streamCapturing: Bool?
        if #available(macOS 27, *), !failureReported {
            let capturing = stream.isCapturing
            streamCapturing = capturing
            notCapturingTicks = capturing ? 0 : notCapturingTicks + 1
            // Two ticks apart, so a stream still settling is never mistaken for one macOS stopped.
            if notCapturingTicks >= 2 { reportStopped(CaptureNotCapturingError()); return }
        }
        let now = CACurrentMediaTime()
        if streamCapturing == nil, CaptureStillWitness.enabled, !failureReported, health.lastStatusWasIdle {
            requestStillWitness(at: now)
        }
        if health.wantsStillLayout(at: now, streamCapturing: streamCapturing, stillWitnessEnabled: CaptureStillWitness.enabled) {
            let (layout, pointer) = stillLayout()
            health.witnessStillLayout(layout, pointer: pointer)
        }
        let healthy = !failureReported && health.isHealthy(at: now, streamCapturing: streamCapturing,
            stillWitnessAt: stillWitness.completedAt, stillWitnessEnabled: CaptureStillWitness.enabled)
        let callback = onHealth
        DispatchQueue.main.async { callback?(healthy) }

        // Keep a static desktop visible, but only while ScreenCaptureKit status (or, once a still
        // screen silences it, the stream's own capturing state) proves the source is still alive.
        if CaptureIdleRefresh.isDue(healthy: healthy, hasFrame: lastBuffer != nil, now: now, lastSentAt: lastSentAt, lowData: peer?.lowDataPolicyActive == true),
           let lastBuffer {
            deliver(lastBuffer, at: now, timing: sourceTiming.resent(), idleResend: true, region: lastBufferRegion)
        }
    }

    /// On macOS 26 establish a screenshot baseline while SCK is fresh, then verify the still
    /// content against that same screenshot pipeline. No screenshot is injected into the picture.
    private func requestStillWitness(at now: TimeInterval) {
        guard !witnessConfigurationUpdating, !witnessFilterUpdating,
              regionSwitchInFlight == nil, let token = stillWitness.begin(at: now) else { return }
        let region = appliedRegion
        SCScreenshotManager.captureSampleBuffer(contentFilter: witnessFilter, configuration: witnessConfiguration) { [weak self] sample, error in
            guard let self else { return }
            self.queue.async { [self] in
                let completed = CACurrentMediaTime()
                let completedSourceTicks = mach_absolute_time()
                let buffer = sample.flatMap { $0.isValid ? CMSampleBufferGetImageBuffer($0) : nil }
                let accepted = self.stillWitness.finish(token, requestedAt: now, at: completed,
                    succeeded: error == nil && buffer != nil && !self.stopping && !self.failureReported && self.appliedRegion == region && self.health.lastStatusWasIdle)
                guard accepted, let buffer, self.scopeLease.performIfValid({}), self.scopeTarget?.processIsAlive != false else { return }
                let sourceFresh = !self.health.isSilent(at: completed)
                if !self.stillContentWitness.observe(CaptureStillContentWitness.signature(buffer), sourceFresh: sourceFresh, sourceTicks: completedSourceTicks) {
                    self.stillWitness.invalidate()
                    if !sourceFresh { self.health.witnessContentChanged() }
                    self.publishHealthAndIdleFrame()
                }
            }
        }
    }

    /// The captured rect in global points, read fresh so a display rearrangement is not a change.
    private func stillLayout() -> (layout: Int?, pointer: CGPoint?) {
        let bounds = CGDisplayBounds(display.displayID)
        let captured = appliedRegion.isWholeDisplay ? bounds : appliedRegion.rect.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let pointer = scopeTarget == nil && applied.showsCursor ? CGEvent(source: nil)?.location : nil
        let layout = StillScreenWitness.layout(over: captured, owner: scopeTarget?.application.processIdentifier,
                                               window: scopeTarget?.windowID, excludingProcess: getpid())
        return (layout, pointer.flatMap { captured.contains($0) ? $0 : nil })
    }

    private func deliver(_ buffer: CVPixelBuffer, at time: TimeInterval, displayMs: Double = 0, timing: ExactVideoTiming? = nil,
                         idleResend: Bool = false, region: CaptureRegion?) {
        lastSentAt = time
        guard scopeTarget?.processIsAlive != false else { return }
        scopeLease.performIfValid {
            if idleResend { peer?.counters.idleResent() }
            peer?.pushFrame(buffer, timeStampNs: Int64(time * 1_000_000_000), displayMs: displayMs, exactTiming: timing,
                            region: region)
            onGuestFrame?(buffer, time)
        }
    }
}
