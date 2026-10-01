import AppKit
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

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

    mutating func observe(_ status: SCFrameStatus, at time: TimeInterval) {
        lastStatusAt = time
        statusIsHealthy = status == .complete || status == .idle
    }

    func isHealthy(at time: TimeInterval, staleAfter: TimeInterval = 0.8) -> Bool {
        guard statusIsHealthy, let lastStatusAt else { return false }
        return time >= lastStatusAt && time - lastStatusAt <= staleAfter
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

    private var ownership = ScopedCaptureOwner()
    private var session: RemoteCaptureSession?
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

    /// System output is a separate, explicit host consent. All apps on the Mac may be audible.
    /// The host restarts capture after this immediate fence so the SCK configuration matches consent.
    func setSystemAudioEnabled(_ enabled: Bool) {
        streamPeer?.setSystemAudioEnabled(enabled)
        session?.fenceAudio()
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
        await previous?.stop()
        try Task.checkCancellation()
        guard ownership.owns(owner) else { throw CancellationError() }
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
        let next = try RemoteCaptureSession(resolved: resolved, lease: lease, peer: peer, quality: initialQuality,
            clientLongEdge: initialClientLongEdge, guestFrame: onGuestFrame, guestSourceFence: scopedGuestFence)
        next.onHealth = { [weak self, weak next] healthy in
            Task { @MainActor in
                guard let self, let next, self.ownership.owns(owner), self.session === next else { return }
                self.onHealth?(healthy)
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
                guard let self, let next, self.ownership.owns(owner), self.session === next else { return }
                self.publishCaptureRegion(region)
            }
        }
        guard beforeStart?(next.geometry) != false else { next.fenceCapture(); throw CancellationError() }
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
            guard ownership.owns(owner), session === next else { throw CancellationError() }
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
            await next.stop()
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
        previous?.fenceCapture()
        session = nil
        guard let previous else { return nil }
        return Task { await previous.stop() }
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
        if targetFPS > CaptureRatePolicy.standardFPS {
            if let displayRefreshHz, displayRefreshHz > Double(targetFPS) + 1 {
                return CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            }
            return .zero
        }
        return tuning.captureAtNativeRate ? .zero : CMTime(value: 1, timescale: 60)
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
    /// G12: a rung below the session rate, and a picture fraction below 1; nil at rung 0.
    var ladderFPS: Int? = nil
    var sizeFraction: Double? = nil
}

private final class RemoteCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "PocketDesk.capture", qos: .userInteractive)
    private var stream: SCStream!
    private let audioConverter = SystemAudioPCMConverter()
    private let audioEpoch: UInt64
    private let capturesAudio: Bool
    private let audioPeer: PeerMedia
    private let scopeLease: CaptureScopeLease
    private let scopeTarget: HostCaptureTarget?
    private let captureQueueKey = DispatchSpecificKey<Bool>()

    func fenceCapture() {
        scopeLease.invalidate()
        fenceAudio()
        let clear = { [self] in lastBuffer = nil; sourceTiming.reset(); audioConverter.reset() }
        if DispatchQueue.getSpecific(key: captureQueueKey) == true { clear() }
        else { queue.sync(execute: clear) }
    }

    func fenceAudio() { audioPeer.endSystemAudioCapture(audioEpoch) }
    private var peer: PeerMedia?
    private var timer: DispatchSourceTimer?
    private var health = CaptureHealthState()
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
         guestFrame: ((CVPixelBuffer, TimeInterval) -> Void)? = nil, guestSourceFence: (() -> Void)? = nil) throws {
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
        self.peer = peer
        audioPeer = peer
        capturesAudio = resolved.target == nil && peer.systemAudioEnabled
        audioEpoch = peer.beginSystemAudioCapture()
        self.tuning = tuning
        self.geometry = geometry
        let inputs = CaptureInputs(quality: quality, showsCursor: true, clientLongEdge: clientLongEdge)
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
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
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
                                                  previous: previous)
        let geometryChanges = ViewportCapturePolicy.needsReconfiguration(from: appliedRegion, to: region)
        guard inputs != applied || geometryChanges else {
            publish(region)
            completeConfigurationUpdate(succeeded: true)
            return
        }
        onGuestSourceFence?()
        let configuration = RemoteCaptureConfiguration.streamConfiguration(
            output: output, region: region, showsCursor: inputs.showsCursor,
            fps: min(targetFPS, inputs.ladderFPS ?? targetFPS),
            displayRefreshHz: displayRefreshHz, tuning: tuning, capturesAudio: capturesAudio, refinesText: peer?.refinementCaptureEnabled == true, fullColor444: peer?.fullColorCaptureEnabled == true
        )
        let previousRegion = appliedRegion
        let bufferVersionAtStart = bufferVersion
        let updateRequestedAt = mach_absolute_time()
        stream.updateConfiguration(configuration) { [self] error in
            queue.async { [self] in
                // stop() already answered the waiters.
                guard !stopping else { return }
                if error == nil {
                    applied = inputs
                    // The idle refresh must not resend a frame of the old region under the new one.
                    if CaptureFrameCachePolicy.shouldDiscard(
                        cachedDimensions: lastBuffer.map {
                            CapturePixelDimensions(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
                        }, frameArrivedDuringUpdate: bufferVersion != bufferVersionAtStart,
                        cachedDisplayTime: lastBufferDisplayTime, updateRequestedAt: updateRequestedAt,
                        previous: previousRegion, next: region
                    ) { lastBuffer = nil }
                    publish(region)
                } else if requested == inputs {
                    requested = applied
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
            try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: windows))
            return !queue.sync { stopping }
        } catch {
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
        if capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        let stoppedDuringStart = queue.sync { stopping }
        if stoppedDuringStart {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        if #available(macOS 27, *), !stream.isCapturing {
            try? await stream.stopCapture()
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

    func stop() async {
        fenceCapture()
        queue.sync {
            audioConverter.reset()
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
        try? await stream.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let capturedMs = MachClock.nowMs() // Public SCK callback entry, before admission/metadata work.
        guard scopeTarget?.processIsAlive != false,
              scopeLease.performIfValid({}) else {
            reportStopped(HostCaptureScopeError.targetUnavailable)
            return
        }
        if type == .audio {
            guard !stopping, capturesAudio, let peer else { return }
            for packet in audioConverter.packets(from: sampleBuffer) { peer.submitSystemAudio(packet.pcm, epoch: audioEpoch, hostTime: packet.hostTime) }
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
        health.observe(status, at: now)
        let displayTime = (attachments.first?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        if status == .complete || status == .idle {
            peer?.counters.captured(idle: status == .idle,
                                    displayLatencyMs: CaptureTiming.displayLatencyMs(displayTime: displayTime),
                                    displayTimeMs: displayTime > 0 ? CaptureTiming.milliseconds(fromMachTicks: displayTime) : nil)
        }
        guard status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              peer != nil else { return }
        peer?.captureContentChanged()
        lastBuffer = buffer
        bufferVersion &+= 1
        lastBufferDisplayTime = displayTime
        let timing = sourceTiming.captured(displayTicks: displayTime, atMs: capturedMs)
        deliver(buffer, at: now, displayMs: displayTime > 0 ? CaptureTiming.milliseconds(fromMachTicks: displayTime) : 0, timing: timing)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.reportStopped(error) }
    }

    private func reportStopped(_ error: Error) {
        guard !stopping, !failureReported else { return }
        failureReported = true
        fenceCapture()
        lastBuffer = nil
        audioConverter.reset()
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
        if #available(macOS 27, *), !failureReported {
            notCapturingTicks = stream.isCapturing ? 0 : notCapturingTicks + 1
            // Two ticks apart, so a stream still settling is never mistaken for one macOS stopped.
            if notCapturingTicks >= 2 { reportStopped(CaptureNotCapturingError()); return }
        }
        let now = CACurrentMediaTime()
        let healthy = health.isHealthy(at: now)
        let callback = onHealth
        DispatchQueue.main.async { callback?(healthy) }

        // Keep a static desktop visible, but only while fresh ScreenCaptureKit
        // complete/idle status independently proves the source is still alive.
        if healthy, now - lastSentAt >= 0.45, let lastBuffer {
            deliver(lastBuffer, at: now, timing: sourceTiming.resent())
        }
    }

    private func deliver(_ buffer: CVPixelBuffer, at time: TimeInterval, displayMs: Double = 0, timing: ExactVideoTiming? = nil) {
        lastSentAt = time
        guard scopeTarget?.processIsAlive != false else { return }
        scopeLease.performIfValid {
            peer?.pushFrame(buffer, timeStampNs: Int64(time * 1_000_000_000), displayMs: displayMs, exactTiming: timing)
            onGuestFrame?(buffer, time)
        }
    }
}
