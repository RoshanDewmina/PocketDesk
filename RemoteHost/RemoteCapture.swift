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
        let width = Int((sourceWidth * scale).rounded(.down)) & ~1
        let height = Int((sourceHeight * scale).rounded(.down)) & ~1
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
    private(set) var appliedQuality: StreamQuality?

    private var ownership = ScopedCaptureOwner()
    private var session: RemoteCaptureSession?
    private var requestedQuality: StreamQuality = .balanced
    private var captureStarted = false
    private var qualityUpdateTask: Task<Void, Never>?

    func setQuality(_ quality: StreamQuality) {
        guard quality != requestedQuality else { return }
        requestedQuality = quality
        scheduleQualityUpdate()
    }

    func start(display: SCDisplay, peer: PeerMedia) async throws -> UInt64 {
        let owner = ownership.begin()
        qualityUpdateTask?.cancel()
        qualityUpdateTask = nil
        captureStarted = false
        appliedQuality = nil
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
        captureStarted = false
        let previous = session
        session = nil
        guard let previous else { return nil }
        return Task { await previous.stop() }
    }

    private func scheduleQualityUpdate() {
        guard qualityUpdateTask == nil, captureStarted, let session,
              requestedQuality != appliedQuality else { return }
        let owner = ownership.current
        qualityUpdateTask = Task { [weak self] in
            await self?.applyRequestedQuality(to: session, owner: owner)
        }
    }

    private func applyRequestedQuality(to target: RemoteCaptureSession, owner: UInt64) async {
        while !Task.isCancelled, ownership.owns(owner), session === target,
              let appliedQuality, requestedQuality != appliedQuality {
            let quality = requestedQuality
            let succeeded = await target.updateQuality(quality)
            guard !Task.isCancelled, ownership.owns(owner), session === target else { break }
            if succeeded {
                self.appliedQuality = quality
                onQuality?(quality)
            } else if requestedQuality == quality {
                break
            }
        }
        guard ownership.owns(owner), session === target else { return }
        qualityUpdateTask = nil
    }
}

private final class RemoteCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "PocketDesk.capture")
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
        guard let configuration = Self.configuration(for: filter, quality: quality) else {
            throw CaptureSizingError.invalidSource
        }
        self.filter = filter
        self.peer = peer
        super.init()
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private static func configuration(for filter: SCContentFilter,
                                      quality: StreamQuality) -> SCStreamConfiguration? {
        guard let dimensions = CapturePixelDimensions.fitted(
            contentSize: filter.contentRect.size,
            pointPixelScale: Double(filter.pointPixelScale), quality: quality
        ) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return configuration
    }

    func updateQuality(_ quality: StreamQuality) async -> Bool {
        let stopped = queue.sync { stopping }
        guard !stopped, let configuration = Self.configuration(for: filter, quality: quality) else {
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
        if status == .complete || status == .idle { peer?.counters.captured(idle: status == .idle) }
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
