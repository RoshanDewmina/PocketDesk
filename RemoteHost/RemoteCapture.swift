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

@MainActor
final class RemoteCapture {
    var onFailure: (() -> Void)?
    var onHealth: ((Bool) -> Void)?

    private var ownership = ScopedCaptureOwner()
    private var session: RemoteCaptureSession?

    func start(display: SCDisplay, peer: PeerMedia) async throws -> UInt64 {
        let owner = ownership.begin()
        let previous = session
        session = nil
        await previous?.stop()
        try Task.checkCancellation()
        guard ownership.owns(owner) else { throw CancellationError() }

        let next = RemoteCaptureSession(display: display, peer: peer)
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
        let previous = session
        session = nil
        guard let previous else { return nil }
        return Task { await previous.stop() }
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

    var onFailure: (() -> Void)?
    var onHealth: ((Bool) -> Void)?

    init(display: SCDisplay, peer: PeerMedia) {
        let configuration = SCStreamConfiguration()
        let ratio = min(1.0, 1920.0 / Double(display.width))
        configuration.width = max(2, Int(Double(display.width) * ratio) / 2 * 2)
        configuration.height = max(2, Int(Double(display.height) * ratio) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        self.peer = peer
        super.init()
        self.stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
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
