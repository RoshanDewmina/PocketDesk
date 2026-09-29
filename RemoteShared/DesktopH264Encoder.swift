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

    private(set) var targetKbps = 0.0
    private(set) var baselineKbps = 0.0
    private var eligibleSince: TimeInterval?
    private var lastRestartAt: TimeInterval?
    private(set) var restarts = 0

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

/// libwebrtc's VideoToolbox H.264 encoder plus `EncoderRestartPolicy`. Packetization, rate control,
/// bitstream format and key-frame handling stay the stock implementation; a restart is the same
/// release/start sequence libwebrtc itself uses when the resolution changes.
final class DesktopH264Encoder: NSObject, RTCVideoEncoder {
    /// Benchmark-only trace of rate updates, restarts and key frames; nil in the apps.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    private let inner: RTCVideoEncoderH264
    private let lock = NSLock()
    private var policy = EncoderRestartPolicy()
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
        let wrapped: RTCVideoEncoderCallback = { image, info in
            if let trace = Self.trace, image.frameType == .videoFrameKey {
                trace("encoded key \(image.buffer.count)B")
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
        policy = EncoderRestartPolicy()
        policy.sessionStarted(kbps: Double(settings.startBitrate), at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        return inner.startEncode(with: settings, numberOfCores: numberOfCores)
    }

    func release() -> Int {
        lock.lock(); settings = nil; lock.unlock()
        return inner.release()
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        lock.lock()
        let restart = settings != nil && policy.shouldRestart(at: ProcessInfo.processInfo.systemUptime)
        let target = UInt32(policy.targetKbps)
        let settings = settings, cores = cores, framerate = framerate, callback = callback
        lock.unlock()
        if restart, let settings {
            settings.startBitrate = target
            _ = inner.release()
            if inner.startEncode(with: settings, numberOfCores: cores) == 0 {
                inner.setCallback(callback)
                _ = inner.setBitrate(target, framerate: framerate)
                Self.trace?("restarted session at \(target)kbps")
            }
        }
        return inner.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        lock.lock()
        policy.updateTarget(kbps: Double(bitrateKbit))
        if framerate > 0 { self.framerate = framerate }
        lock.unlock()
        Self.trace?("setBitrate \(bitrateKbit)kbps \(framerate)fps")
        return inner.setBitrate(bitrateKbit, framerate: framerate)
    }

    func implementationName() -> String { inner.implementationName() }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { inner.scalingSettings() }
    var resolutionAlignment: Int { inner.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { inner.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { inner.supportsNativeHandle }
}
