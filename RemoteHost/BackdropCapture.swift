import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import VideoToolbox

/// Idea 2's Mac half: a second ScreenCaptureKit stream of the picture's own display and content filter
/// (so it shows exactly what the whole-display picture would, curtain exclusions included) at a 640 px
/// long edge and 4 fps, without the cursor, encoded to `BackdropSnapshot`s for `PeerMedia.sendBackdrop`.
/// Only complete (changed) frames are kept; the newest waits for the byte budget and an open channel,
/// and is encoded only then.
final class BackdropCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Link {
        var readiness: () -> BackdropLink.Readiness
        var nextSequence: () -> UInt32
        /// Must not block.
        var send: (Data) -> Bool
    }

    private let queue = DispatchQueue(label: "PocketDesk.backdrop", qos: .utility)
    private let display: SCDisplay
    private let displaySize: CGSize
    private var stream: SCStream!
    private let link: Link
    private let admits: () -> Bool
    private let lock = NSLock()
    // Guarded by `lock`.
    private var fenced = false
    private var started = false
    private var stopped = false
    private var stopFinished = false
    private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var excludedWindows: [SCWindow]?
    private var filterGeneration: UInt64 = 0
    private var appliedFilterGeneration: UInt64 = 0
    private var filterTask: Task<Void, Never>?

    // Confined to `queue`.
    private var latest: CVPixelBuffer?
    private var encoded: Data?
    private var budget = BackdropByteBudget()
    private var timer: DispatchSourceTimer?

    static func configuration(contentSize: CGSize) -> SCStreamConfiguration? {
        guard let size = BackdropCapturePolicy.outputSize(contentSize: contentSize) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: BackdropCapturePolicy.framesPerSecond)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = StreamColor.captureColorSpaceName
        return configuration
    }

    /// `admits` is the picture session's own admission.
    init?(display: SCDisplay, filter: SCContentFilter, link: Link, admits: @escaping () -> Bool) {
        let size = filter.contentRect.size
        guard let configuration = Self.configuration(contentSize: size) else { return nil }
        self.display = display
        displaySize = size
        self.link = link
        self.admits = admits
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private var isFenced: Bool { lock.withLock { fenced } }
    /// No snapshot leaves while a curtain exclusion is still being applied to this stream.
    private var filterCurrent: Bool { lock.withLock { appliedFilterGeneration == filterGeneration } }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let windows: [SCWindow]? = lock.withLock { started = true; return fenced ? nil : excludedWindows }
        guard !isFenced else { await stop(); return }
        if let windows { excludeWindows(windows) }
        queue.async { [self] in
            guard !isFenced, timer == nil else { return }
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
            tick.setEventHandler { [weak self] in self?.flush() }
            timer = tick
            tick.resume()
        }
    }

    /// Follows the picture's privacy-curtain exclusions: the newest list wins, applied in order, and
    /// re-applied once a stream that was still starting has started.
    func excludeWindows(_ windows: [SCWindow]) {
        let (generation, previous, running): (UInt64, Task<Void, Never>?, Bool) = lock.withLock {
            excludedWindows = windows
            filterGeneration &+= 1
            return (filterGeneration, filterTask, started && !fenced)
        }
        guard running else { return }
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, !self.isFenced else { return }
            let filter = SCContentFilter(display: self.display, excludingWindows: windows)
            do { try await self.stream.updateContentFilter(filter) } catch {
                SessionLog.log.info("backdrop exclusion failed: \(error.localizedDescription, privacy: .public)")
                self.fence(); await self.stop(); return
            }
            self.lock.withLock { self.appliedFilterGeneration = max(self.appliedFilterGeneration, generation) }
        }
        lock.withLock { filterTask = task }
    }

    /// Synchronous: no snapshot is sent once this returns.
    func fence() {
        lock.withLock { fenced = true }
        queue.async { [self] in timer?.cancel(); timer = nil; latest = nil; encoded = nil }
    }

    /// Fences, then stops the stream; returns once stopped or after `timeout`.
    func stop(timeout: TimeInterval = 1) async {
        fence()
        let first = lock.withLock { () -> Bool in defer { stopped = true }; return !stopped }
        if first {
            Task { [self] in
                try? await stream.stopCapture()
                let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    stopFinished = true
                    defer { stopWaiters = [:] }
                    return Array(stopWaiters.values)
                }
                waiters.forEach { $0.resume() }
            }
        }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = lock.withLock { () -> Bool in
                if stopFinished { return true }
                stopWaiters[id] = continuation
                return false
            }
            if finished { continuation.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.withLock { stopWaiters.removeValue(forKey: id) }?.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), !isFenced else { return }
        latest = buffer
        encoded = nil
        flush()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        SessionLog.log.info("backdrop capture stopped: \(error.localizedDescription, privacy: .public)")
        fence()
    }

    private func flush() {
        guard latest != nil || encoded != nil, !isFenced else { return }
        switch link.readiness() {
        case .closed:
            // The phone refused the channel or the session ended: stop spending the Mac on it.
            fence(); Task { await stop() }; return
        case .waiting: return
        case .ready: break
        }
        let now = CACurrentMediaTime()
        guard admits(), filterCurrent, budget.permits(at: now) else { return }
        if encoded == nil, let buffer = latest {
            latest = nil
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image,
                  let data = BackdropSnapshot.encodeImage(image) else { return }
            encoded = BackdropSnapshot(sequence: link.nextSequence(), displaySize: displaySize, image: data).encoded()
        }
        guard let message = encoded else { return }
        let sent = lock.withLock { !fenced && link.send(message) }
        guard sent else { return }
        budget.spend(message.count, at: now)
        encoded = nil
        if let sequence = BackdropSnapshot.decode(message)?.sequence, sequence <= 3 || sequence % 100 == 0 {
            SessionLog.log.info("backdrop snapshot #\(sequence, privacy: .public) \(message.count, privacy: .public) bytes")
        }
    }
}
