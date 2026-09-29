import Foundation
import WebRTC

/// Decides when to restart the VideoToolbox session so its rate control matches the current target.
///
/// libwebrtc starts every stream at 300 kb/s, and its H.264 wrapper pairs each target with a tight
/// `DataRateLimits` (1.5x per second). Measured on this Mac (VideoToolboxProbeTests): after a
/// 300 kb/s start, raising the target to 18 Mb/s left a rendered code page at 21.6 dB after 1 s and
/// 23.7 dB after 3 s, while a session created at 18 Mb/s codes it at 32.5 dB immediately. Static
/// screen content is then coded as skipped blocks, so the starved first picture persists for minutes.
/// Forcing a key frame inside the old session did not help (it overran the rate window and QP stayed
/// at 51). Restarting the session at the new rate does: its first frame is a key frame coded with a
/// fresh rate-control state.
///
/// Restart when the target has stayed at or above `riseFactor` x the lowest target seen since the
/// session started, and at least `minimumKbps`, for `settleTime` (below 5 Mb/s the restart's key
/// frame, ~200-400 KB of text, would sit in the pacer for most of a second; waiting lets the estimate
/// finish ramping so the new session starts at the settled rate). Repeats are spaced by
/// `repeatInterval` so an oscillating estimate cannot turn into a stream of key-frame bursts.
struct EncoderRestartPolicy {
    var riseFactor = 2.0
    var minimumKbps = 5_000.0
    var settleTime: TimeInterval = 0.75
    var repeatInterval: TimeInterval = 15
    /// G9: when set, the restart's key frame must fit in this much link time at the target rate,
    /// judged by the last key frame's size (or `defaultKeyFrameBytes` before one was seen).
    var keyFrameBudgetMs: Double?
    var lastKeyFrameBytes: Int?
    static let defaultKeyFrameBytes = 200_000

    private(set) var targetKbps = 0.0
    private(set) var baselineKbps = 0.0
    private var eligibleSince: TimeInterval?
    private var lastRestartAt: TimeInterval?
    private(set) var restarts = 0

    /// Link time the next restart's key frame would take at the current target, in ms.
    var keyFrameLinkTimeMs: Double? {
        guard targetKbps > 0 else { return nil }
        return Double(lastKeyFrameBytes ?? Self.defaultKeyFrameBytes) * 8 / targetKbps
    }

    mutating func sessionStarted(kbps: Double, at time: TimeInterval) {
        targetKbps = max(0, kbps)
        baselineKbps = targetKbps
        eligibleSince = nil
    }

    mutating func updateTarget(kbps: Double) {
        targetKbps = max(0, kbps)
        baselineKbps = min(baselineKbps, targetKbps)
    }

    /// True when the session should be recreated before encoding the next frame.
    mutating func shouldRestart(at time: TimeInterval) -> Bool {
        guard targetKbps >= minimumKbps, targetKbps >= baselineKbps * riseFactor else {
            eligibleSince = nil
            return false
        }
        if let keyFrameBudgetMs, let linkTime = keyFrameLinkTimeMs, linkTime > keyFrameBudgetMs {
            eligibleSince = nil
            return false
        }
        let since = eligibleSince ?? time
        eligibleSince = since
        guard time - since >= settleTime,
              lastRestartAt.map({ time - $0 >= repeatInterval }) != false else { return false }
        lastRestartAt = time
        restarts += 1
        sessionStarted(kbps: targetKbps, at: time)
        return true
    }
}

/// Per-frame bookkeeping for the encoder trace: when each frame went into VideoToolbox and how many
/// were already inside. Frames are matched back by their capture time (ms); a frame VideoToolbox
/// drops never calls back and is forgotten after `staleAfterMs`.
struct EncoderLatencyTrace {
    struct Sample: Equatable {
        var latencyMs: Double
        /// Frames inside the encoder when this one was submitted, this one included.
        var inFlight: Int
    }

    var staleAfterMs = 1_000.0
    private var pending: [(key: Int64, atMs: Double, inFlight: Int)] = []

    var inFlight: Int { pending.count }

    mutating func submitted(key: Int64, atMs: Double) {
        prune(now: atMs)
        pending.append((key: key, atMs: atMs, inFlight: pending.count + 1))
    }

    /// The matching submission, or the oldest one when the key is unknown.
    mutating func completed(key: Int64, atMs: Double) -> Sample? {
        prune(now: atMs)
        guard !pending.isEmpty else { return nil }
        let index = pending.firstIndex { $0.key == key } ?? 0
        let entry = pending.remove(at: index)
        return Sample(latencyMs: max(0, atMs - entry.atMs), inFlight: entry.inFlight)
    }

    mutating func reset() { pending.removeAll() }

    private mutating func prune(now: Double) {
        pending.removeAll { now - $0.atMs > staleAfterMs }
    }
}

/// libwebrtc's VideoToolbox H.264 encoder plus `EncoderRestartPolicy`. Packetization, rate control,
/// bitstream format and key-frame handling stay the stock implementation; a restart is the same
/// release/start sequence libwebrtc itself uses when the resolution changes.
///
/// It also feeds the encoder trace: submit → callback latency, frames in flight, bytes per frame,
/// key-frame size, rate updates and session age, reported through `sharedCounters`.
final class DesktopH264Encoder: NSObject, RTCVideoEncoder {
    /// Benchmark-only trace of rate updates, restarts and key frames; nil in the apps.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    /// The native host's stream counters; set by `PeerMedia` when it owns the desktop track.
    nonisolated(unsafe) static weak var sharedCounters: StreamCounters?
    private let inner: RTCVideoEncoderH264
    private let lock = NSLock()
    private var policy = EncoderRestartPolicy()
    private var latency = EncoderLatencyTrace()
    private var settings: RTCVideoEncoderSettings?
    private var cores: Int32 = 1
    private var framerate: UInt32 = 60
    private var callback: RTCVideoEncoderCallback?

    init(codecInfo: RTCVideoCodecInfo) {
        inner = RTCVideoEncoderH264(codecInfo: codecInfo)
        super.init()
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        guard let callback else {
            lock.lock(); self.callback = nil; lock.unlock()
            inner.setCallback(nil)
            return
        }
        let wrapped: RTCVideoEncoderCallback = { [weak self] image, info in
            let now = MachClock.nowMs()
            let isKey = image.frameType == .videoFrameKey
            if let trace = Self.trace, isKey {
                trace("encoded key \(image.buffer.count)B")
            }
            if let self {
                self.lock.lock()
                let sample = self.latency.completed(key: image.captureTimeMs, atMs: now)
                if isKey { self.policy.lastKeyFrameBytes = image.buffer.count }
                self.lock.unlock()
                if let sample {
                    Self.sharedCounters?.encoded(latencyMs: sample.latencyMs, bytes: image.buffer.count,
                                                 isKeyFrame: isKey, inFlight: sample.inFlight)
                }
            }
            return callback(image, info)
        }
        lock.lock(); self.callback = wrapped; lock.unlock()
        inner.setCallback(wrapped)
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.lock()
        self.settings = settings
        cores = numberOfCores
        if settings.maxFramerate > 0 { framerate = settings.maxFramerate }
        let tuning = StreamTuning.current
        policy = EncoderRestartPolicy()
        policy.minimumKbps = tuning.restartFloorKbps
        policy.keyFrameBudgetMs = tuning.restartKeyFrameBudgetMs
        policy.sessionStarted(kbps: Double(settings.startBitrate), at: ProcessInfo.processInfo.systemUptime)
        latency.reset()
        lock.unlock()
        Self.sharedCounters?.encoderSessionStarted()
        return inner.startEncode(with: settings, numberOfCores: numberOfCores)
    }

    func release() -> Int {
        lock.lock(); settings = nil; latency.reset(); lock.unlock()
        return inner.release()
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        lock.lock()
        let restart = settings != nil && policy.shouldRestart(at: ProcessInfo.processInfo.systemUptime)
        let target = UInt32(policy.targetKbps)
        let settings = settings, cores = cores, framerate = framerate, callback = callback
        if restart { latency.reset() }
        lock.unlock()
        if restart, let settings {
            settings.startBitrate = target
            _ = inner.release()
            if inner.startEncode(with: settings, numberOfCores: cores) == 0 {
                inner.setCallback(callback)
                _ = inner.setBitrate(target, framerate: framerate)
                Self.sharedCounters?.encoderSessionStarted()
                Self.trace?("restarted session at \(target)kbps")
            }
        }
        lock.lock()
        latency.submitted(key: frame.timeStampNs / 1_000_000, atMs: MachClock.nowMs())
        lock.unlock()
        return inner.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        lock.lock()
        policy.updateTarget(kbps: Double(bitrateKbit))
        if framerate > 0 { self.framerate = framerate }
        lock.unlock()
        Self.sharedCounters?.encoderRateUpdated()
        Self.trace?("setBitrate \(bitrateKbit)kbps \(framerate)fps")
        return inner.setBitrate(bitrateKbit, framerate: framerate)
    }

    func implementationName() -> String { inner.implementationName() }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { inner.scalingSettings() }
    var resolutionAlignment: Int { inner.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { inner.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { inner.supportsNativeHandle }
}
