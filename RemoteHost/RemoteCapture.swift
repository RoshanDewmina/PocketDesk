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

    static func fitted(contentSize: CGSize, pointPixelScale: Double,
                       quality: StreamQuality) -> CapturePixelDimensions? {
        let sourceWidth = Double(contentSize.width) * pointPixelScale
        let sourceHeight = Double(contentSize.height) * pointPixelScale
        guard pointPixelScale.isFinite, pointPixelScale > 0,
              sourceWidth.isFinite, sourceHeight.isFinite,
              sourceWidth >= 2, sourceHeight >= 2 else { return nil }

        let maximum = Double(quality.maximumDimension)
        let scale = min(1, maximum / max(sourceWidth, sourceHeight))
        var width = Int((sourceWidth * scale).rounded(.down)) & ~1
        var height = Int((sourceHeight * scale).rounded(.down)) & ~1
        while width >= 2, height >= 2, !H264LevelPolicy.fitsAt60FPS(width: width, height: height) {
            width -= 2
            height = Int((Double(width) * sourceHeight / sourceWidth).rounded(.down)) & ~1
        }
        guard width >= 2, height >= 2 else { return nil }
        return CapturePixelDimensions(width: width, height: height)
    }
}

private enum CaptureSizingError: Error { case invalidSource }

@MainActor
final class RemoteCapture {
    var onFailure: (() -> Void)?
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

    private var ownership = ScopedCaptureOwner()
    private var session: RemoteCaptureSession?
    private weak var streamPeer: PeerMedia?
    private var requestedQuality: StreamQuality = .balanced
    private var requestedShowsCursor = true
    private var captureStarted = false
    private var qualityUpdateTask: Task<Void, Never>?

    func setQuality(_ quality: StreamQuality) {
        guard quality != requestedQuality else { return }
        requestedQuality = quality
        scheduleQualityUpdate()
    }

    /// Only a client drawing its own pointer may hide it. Every capture starts with it shown.
    func setShowsCursor(_ shows: Bool) {
        guard shows != requestedShowsCursor else { return }
        let before = cursorInVideo
        requestedShowsCursor = shows
        notifyCursor(changedFrom: before)
        scheduleQualityUpdate()
    }

    func start(display: SCDisplay, peer: PeerMedia) async throws -> UInt64 {
        let owner = ownership.begin()
        qualityUpdateTask?.cancel()
        qualityUpdateTask = nil
        captureStarted = false
        appliedQuality = nil
        resetCursor()
        streamPeer = nil
        let previous = session
        session = nil
        await previous?.stop()
        try Task.checkCancellation()
        guard ownership.owns(owner) else { throw CancellationError() }

        let initialQuality = requestedQuality
        let next = try RemoteCaptureSession(display: display, peer: peer, quality: initialQuality)
        next.onHealth = { [weak self, weak next] healthy in
            Task { @MainActor in
                guard let self, let next, self.ownership.owns(owner), self.session === next else { return }
                self.onHealth?(healthy)
            }
        }
        next.onFailure = { [weak self, weak next] in
            Task { @MainActor in
                guard let self, let next, self.ownership.owns(owner), self.session === next else { return }
                self.onFailure?()
            }
        }
        session = next

        do {
            try await next.start()
            try Task.checkCancellation()
            guard ownership.owns(owner), session === next else { throw CancellationError() }
            captureStarted = true
            appliedQuality = initialQuality
            streamPeer = peer
            peer.applyStreamQuality(initialQuality)
            onQuality?(initialQuality)
            scheduleQualityUpdate()
            return owner
        } catch {
            if ownership.owns(owner), session === next { session = nil }
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
        ownership.invalidate()
        qualityUpdateTask?.cancel()
        qualityUpdateTask = nil
        requestedQuality = .balanced
        appliedQuality = nil
        resetCursor()
        captureStarted = false
        streamPeer = nil
        let previous = session
        session = nil
        guard let previous else { return nil }
        return Task { await previous.stop() }
    }

    private func scheduleQualityUpdate() {
        guard qualityUpdateTask == nil, captureStarted, let session,
              requestedQuality != appliedQuality || requestedShowsCursor != appliedShowsCursor else { return }
        let owner = ownership.current
        qualityUpdateTask = Task { [weak self] in
            await self?.applyRequestedQuality(to: session, owner: owner)
        }
    }

    private func applyRequestedQuality(to target: RemoteCaptureSession, owner: UInt64) async {
        while !Task.isCancelled, ownership.owns(owner), session === target,
              let appliedQuality,
              requestedQuality != appliedQuality || requestedShowsCursor != appliedShowsCursor {
            let quality = requestedQuality
            let showsCursor = requestedShowsCursor
            let succeeded = await target.updateQuality(quality, showsCursor: showsCursor)
            guard !Task.isCancelled, ownership.owns(owner), session === target else { break }
            if succeeded {
                if quality != appliedQuality {
                    self.appliedQuality = quality
                    streamPeer?.applyStreamQuality(quality)
                    onQuality?(quality)
                }
                let before = cursorInVideo
                appliedShowsCursor = showsCursor
                notifyCursor(changedFrom: before)
            } else if requestedQuality == quality && requestedShowsCursor == showsCursor {
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
}

private final class RemoteCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "PocketDesk.capture", qos: .userInteractive)
    private var stream: SCStream!
    private var peer: PeerMedia?
    private var timer: DispatchSourceTimer?
    private var health = CaptureHealthState()
    private var lastBuffer: CVPixelBuffer?
    private var lastSentAt = 0.0
    private var stopping = false
    private let filter: SCContentFilter

    var onFailure: (() -> Void)?
    var onHealth: ((Bool) -> Void)?

    init(display: SCDisplay, peer: PeerMedia, quality: StreamQuality) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let configuration = Self.configuration(for: filter, quality: quality, showsCursor: true,
                                                     budget: peer.nativeCaptureBudget) else {
            throw CaptureSizingError.invalidSource
        }
        self.filter = filter
        self.peer = peer
        super.init()
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private static func configuration(for filter: SCContentFilter, quality: StreamQuality,
                                      showsCursor: Bool, budget: H264FrameBudget?) -> SCStreamConfiguration? {
        guard let dimensions = CapturePixelDimensions.fitted(
            contentSize: filter.contentRect.size,
            pointPixelScale: Double(filter.pointPixelScale), quality: quality
        ) else { return nil }
        let configuration = SCStreamConfiguration()
        let fitted = budget?.fitted(width: dimensions.width, height: dimensions.height)
        configuration.width = fitted?.width ?? dimensions.width
        configuration.height = fitted?.height ?? dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = RemoteCaptureConfiguration.queueDepth
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return configuration
    }

    func updateQuality(_ quality: StreamQuality, showsCursor: Bool) async -> Bool {
        let stopped = queue.sync { stopping }
        guard !stopped, let configuration = Self.configuration(for: filter, quality: quality, showsCursor: showsCursor,
                                                               budget: peer?.nativeCaptureBudget) else {
            return false
        }
        do {
            try await stream.updateConfiguration(configuration)
            return !queue.sync { stopping }
        } catch {
            return false
        }
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let stoppedDuringStart = queue.sync { stopping }
        if stoppedDuringStart {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        queue.sync {
            guard !stopping else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.4)
            timer.setEventHandler { [weak self] in self?.publishHealthAndIdleFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() async {
        queue.sync {
            if !stopping {
                stopping = true
                timer?.cancel()
                timer = nil
                lastBuffer = nil
                peer = nil
                onFailure = nil
                onHealth = nil
            }
        }
        try? await stream.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), !stopping else { return }

        let now = CACurrentMediaTime()
        health.observe(status, at: now)
        if status == .complete || status == .idle {
            let displayTime = (attachments.first?[.displayTime] as? NSNumber)?.uint64Value ?? 0
            peer?.counters.captured(idle: status == .idle,
                                    displayLatencyMs: CaptureTiming.displayLatencyMs(displayTime: displayTime))
        }
        guard status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              peer != nil else { return }
        lastBuffer = buffer
        deliver(buffer, at: now)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.health.observe(.stopped, at: CACurrentMediaTime())
            self.publishHealthAndIdleFrame()
            let callback = self.onFailure
            DispatchQueue.main.async { callback?() }
        }
    }

    private func publishHealthAndIdleFrame() {
        guard !stopping else { return }
        let now = CACurrentMediaTime()
        let healthy = health.isHealthy(at: now)
        let callback = onHealth
        DispatchQueue.main.async { callback?(healthy) }

        // Keep a static desktop visible, but only while fresh ScreenCaptureKit
        // complete/idle status independently proves the source is still alive.
        if healthy, now - lastSentAt >= 0.45, let lastBuffer {
            deliver(lastBuffer, at: now)
        }
    }

    private func deliver(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        lastSentAt = time
        peer?.pushFrame(buffer, timeStampNs: Int64(time * 1_000_000_000))
    }
}
