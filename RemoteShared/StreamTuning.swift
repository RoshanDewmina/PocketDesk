import Foundation
import WebRTC

/// Latency and sharpness policy for the native desktop stream. The loopback evidence for each
/// value is in Docs/research/2026-09-28-round2/STREAM-FIX-REPORT.md. Browser peers keep WebRTC defaults.
struct StreamTuning: Equatable {
    /// libwebrtc's receiver-side `WebRTC-ForcePlayoutDelay` trial. A zero minimum selects its
    /// low-latency rendering path: frames go to the decoder as soon as they are complete instead of
    /// waiting for the jitter-buffer target; a zero maximum also skips its 8 ms inter-decode pacing so
    /// frames queued behind a stall are fast-forwarded. Process-wide: set before any factory exists.
    var playoutDelayMinMs: Int?
    var playoutDelayMaxMs: Int?
    /// Sender-side `WebRTC-Video-Pacing` trial parameters (`factor:…,max_delay:…ms`), bounding how long
    /// a large key frame can sit in the pacer queue. Nil keeps libwebrtc's 1.1x factor and 2 s queue.
    var videoPacing: String?
    /// Seed the bandwidth estimate and cap the encoder per picture mode instead of starting at
    /// libwebrtc's 300 kbps and ramping for tens of seconds at maximum QP.
    var qualityBitrates: Bool
    /// Bandwidth-estimate ceiling as a multiple of the encoder ceiling. Above 1 lets the estimate, and
    /// with it the pacer (which sends at ~1.1x the estimate), exceed the encoder's average rate so a
    /// large key or full-screen frame drains faster. The estimate still only grows where the path allows.
    var bandwidthHeadroom: Int = 1
    var degradationPreference: RTCDegradationPreference?
    /// Restart the VideoToolbox session when the target rate has doubled, so text is not left at the
    /// quality of a 300 kb/s start (see `EncoderRestartPolicy`).
    var encoderRestart: Bool
    /// Phone: let the Metal video view redraw at the display maximum (120 Hz on ProMotion) instead of 60.
    var presentAtDisplayMaximum: Bool

    static let tuned = StreamTuning(playoutDelayMinMs: 0, playoutDelayMaxMs: 0, videoPacing: nil,
                                    qualityBitrates: true, bandwidthHeadroom: 1, degradationPreference: .maintainResolution,
                                    encoderRestart: true, presentAtDisplayMaximum: true)
    static let legacy = StreamTuning(playoutDelayMinMs: nil, playoutDelayMaxMs: nil, videoPacing: nil,
                                     qualityBitrates: false, bandwidthHeadroom: 1, degradationPreference: nil,
                                     encoderRestart: false, presentAtDisplayMaximum: false)

    static let legacyDefaultsKey = "PocketDeskLegacyStreamTuning"

    private static let lock = NSLock()
    private static var resolved: StreamTuning?

    /// Fixed for the life of the process on first use; field trials cannot change afterwards.
    static var current: StreamTuning {
        lock.lock(); defer { lock.unlock() }
        if let resolved { return resolved }
        let value = UserDefaults.standard.bool(forKey: legacyDefaultsKey) ? legacy : tuned
        resolved = value
        return value
    }

    /// Test/benchmark hook. Returns false once a factory has already consumed the policy.
    @discardableResult
    static func override(_ tuning: StreamTuning) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !runtimePrepared else { return resolved == tuning }
        resolved = tuning
        return true
    }

    var fieldTrials: [String: String] {
        var trials: [String: String] = [:]
        if let playoutDelayMinMs, let playoutDelayMaxMs {
            trials["WebRTC-ForcePlayoutDelay"] = "min_ms:\(playoutDelayMinMs),max_ms:\(playoutDelayMaxMs)"
        }
        if let videoPacing { trials["WebRTC-Video-Pacing"] = videoPacing }
        return trials
    }

    var summary: String {
        var parts: [String] = []
        if let playoutDelayMinMs, let playoutDelayMaxMs { parts.append("playout \(playoutDelayMinMs)-\(playoutDelayMaxMs)ms") }
        if let videoPacing { parts.append("pacing \(videoPacing)") }
        if qualityBitrates { parts.append("mode bitrates") }
        if let degradationPreference { parts.append(Self.name(degradationPreference)) }
        if encoderRestart { parts.append("encoder restart") }
        if presentAtDisplayMaximum { parts.append("max refresh") }
        return parts.isEmpty ? "legacy" : parts.joined(separator: " · ")
    }

    private static func name(_ preference: RTCDegradationPreference) -> String {
        switch preference {
        case .maintainFramerate: return "keep fps"
        case .maintainResolution: return "keep resolution"
        case .balanced: return "balanced"
        default: return "no adaptation"
        }
    }

    private static var runtimePrepared = false

    /// Installs field trials once, before the first RTCPeerConnectionFactory is created.
    static func prepareRuntime() {
        let tuning = current
        lock.lock(); defer { lock.unlock() }
        guard !runtimePrepared else { return }
        runtimePrepared = true
        let trials = tuning.fieldTrials
        if !trials.isEmpty { RTCInitFieldTrialDictionary(trials) }
    }
}

/// When to force the bandwidth estimate up to the picture mode's start rate on a direct route.
/// libwebrtc's initial probe results can land after an early seed and replace it with their much
/// smaller measurement (seen in the loopback: estimate stuck near 2 Mb/s, 0.4-1 s pacer queue), so the
/// seed waits for the second statistics sample and is re-applied once if the estimate is still below
/// half of it without reported loss.
struct BandwidthSeedPolicy {
    static let maximumAttempts = 2
    private(set) var attempts = 0
    private var directSamples = 0

    mutating func observe(route: String, estimateKbps: Double?, lossPercent: Double?, seedKbps: Double) -> Bool {
        guard route == "Direct" else { return false }
        directSamples += 1
        guard directSamples >= 2, attempts < Self.maximumAttempts else { return false }
        if attempts == 0 {
            attempts = 1
            return true
        }
        guard let estimateKbps, estimateKbps < seedKbps / 2, (lossPercent ?? 0) < 1 else {
            attempts = Self.maximumAttempts
            return false
        }
        attempts += 1
        return true
    }
}

extension StreamQuality {
    /// Initial bandwidth estimate for a direct route. libwebrtc still backs off on delay or loss.
    var startBitrateBps: Int { self == .sharp ? 10_000_000 : 6_000_000 }
    /// Encoder ceiling. Sharper carries ~1.8x the pixels of Responsive, so it needs a higher cap,
    /// not just more pixels, to avoid spending the same bits on a larger picture.
    var maximumBitrateBps: Int { self == .sharp ? 25_000_000 : 12_000_000 }
}
