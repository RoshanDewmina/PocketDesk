import Foundation
import WebRTC

/// Latency and sharpness policy for the native desktop stream. The loopback evidence for each
/// value is in Docs/research/2026-09-28-round2/STREAM-FIX-REPORT.md. Browser peers keep WebRTC defaults.
///
/// Experiment switches (Docs/perf/LAB-NOTEBOOK.md) default to today's behaviour and are turned on
/// per session with host user defaults, so each A/B changes one variable and the active set is
/// recorded in every statistics sample through `summary`.
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
    /// G1: capture at the display's own cadence (`minimumFrameInterval = .zero`) instead of a 1/60 floor.
    var captureAtNativeRate = false
    /// G15/G16: seed the estimate by route class (LAN, internet P2P, relay) instead of on every "Direct"
    /// route, which today includes internet P2P, and never on relay.
    var routeAwareSeed = false
    /// G9: lowest target at which the encoder restart may fire.
    var restartFloorKbps = 5_000.0
    /// G9: when set, a restart also needs its key frame to fit in this much link time at the target rate.
    var restartKeyFrameBudgetMs: Double?
    /// Encoder A/B: replaces the picture mode's encoder ceiling (Sharper 25 Mb/s, Responsive 12 Mb/s).
    var encoderCeilingKbps: Int?
    /// G13: warm the level-5.2 decode probe up at launch and cache a positive result across launches.
    /// Off, the probe runs at the first factory as before and nothing is cached.
    var cacheLevel52Probe = true

    func maximumBitrateBps(for quality: StreamQuality) -> Int {
        encoderCeilingKbps.map { $0 * 1000 } ?? quality.maximumBitrateBps
    }

    static let tuned = StreamTuning(playoutDelayMinMs: 0, playoutDelayMaxMs: 0, videoPacing: nil,
                                    qualityBitrates: true, bandwidthHeadroom: 1, degradationPreference: .maintainResolution,
                                    encoderRestart: true, presentAtDisplayMaximum: true)
    static let legacy = StreamTuning(playoutDelayMinMs: nil, playoutDelayMaxMs: nil, videoPacing: nil,
                                     qualityBitrates: false, bandwidthHeadroom: 1, degradationPreference: nil,
                                     encoderRestart: false, presentAtDisplayMaximum: false)

    static let legacyDefaultsKey = "PocketDeskLegacyStreamTuning"
    static let captureNativeRateKey = "PocketDeskCaptureNativeRate"
    static let routeAwareSeedKey = "PocketDeskRouteAwareSeed"
    static let restartFloorKey = "PocketDeskRestartFloorKbps"
    static let restartKeyFrameBudgetKey = "PocketDeskRestartKeyFrameBudgetMs"
    static let encoderCeilingKey = "PocketDeskEncoderCeilingKbps"
    static let level52ProbeCacheKey = "PocketDeskLevel52ProbeCache"
    /// Every experiment key, for the session protocol's cleanup step.
    static let experimentKeys = [legacyDefaultsKey, captureNativeRateKey, routeAwareSeedKey, restartFloorKey,
                                 restartKeyFrameBudgetKey, encoderCeilingKey, level52ProbeCacheKey]

    private static let lock = NSLock()
    private static var resolved: StreamTuning?

    /// Fixed for the life of the process on first use; field trials cannot change afterwards.
    static var current: StreamTuning {
        lock.lock(); defer { lock.unlock() }
        if let resolved { return resolved }
        let value = resolve()
        resolved = value
        return value
    }

    /// The legacy switch wins; otherwise the tuned policy with any experiment switches set in defaults.
    static func resolve(defaults: UserDefaults = .standard) -> StreamTuning {
        guard !defaults.bool(forKey: legacyDefaultsKey) else { return legacy }
        var tuning = tuned
        if defaults.object(forKey: captureNativeRateKey) != nil {
            tuning.captureAtNativeRate = defaults.bool(forKey: captureNativeRateKey)
        }
        if defaults.object(forKey: routeAwareSeedKey) != nil {
            tuning.routeAwareSeed = defaults.bool(forKey: routeAwareSeedKey)
        }
        if defaults.object(forKey: restartFloorKey) != nil {
            let floor = defaults.double(forKey: restartFloorKey)
            if floor.isFinite, floor >= 300 { tuning.restartFloorKbps = floor }
        }
        if defaults.object(forKey: restartKeyFrameBudgetKey) != nil {
            let budget = defaults.double(forKey: restartKeyFrameBudgetKey)
            tuning.restartKeyFrameBudgetMs = budget.isFinite && budget > 0 ? budget : nil
        }
        if defaults.object(forKey: encoderCeilingKey) != nil {
            let ceiling = defaults.integer(forKey: encoderCeilingKey)
            tuning.encoderCeilingKbps = (1_000...60_000).contains(ceiling) ? ceiling : nil
        }
        if defaults.object(forKey: level52ProbeCacheKey) != nil {
            tuning.cacheLevel52Probe = defaults.bool(forKey: level52ProbeCacheKey)
        }
        return tuning
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
        if captureAtNativeRate { parts.append("native capture rate") }
        if routeAwareSeed { parts.append("route seed") }
        if restartFloorKbps != Self.tuned.restartFloorKbps { parts.append("restart floor \(Int(restartFloorKbps))") }
        if let restartKeyFrameBudgetMs { parts.append("IDR budget \(Int(restartKeyFrameBudgetMs))ms") }
        if let encoderCeilingKbps { parts.append("ceiling \(encoderCeilingKbps)") }
        if !cacheLevel52Probe { parts.append("no probe cache") }
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
/// seed waits for the second eligible statistics sample and is re-applied once if the estimate is still
/// below half of it without reported loss.
struct BandwidthSeedPolicy {
    static let maximumAttempts = 2
    private(set) var attempts = 0
    private var eligibleSamples = 0

    mutating func observe(route: String, estimateKbps: Double?, lossPercent: Double?, seedKbps: Double) -> Bool {
        observe(eligible: route == "Direct", estimateKbps: estimateKbps, lossPercent: lossPercent, seedKbps: seedKbps)
    }

    mutating func observe(eligible: Bool, estimateKbps: Double?, lossPercent: Double?, seedKbps: Double) -> Bool {
        guard eligible else { return false }
        eligibleSamples += 1
        guard eligibleSamples >= 2, attempts < Self.maximumAttempts else { return false }
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

/// Route classes the seed policy tells apart (G15/G16): the "Direct" label covers both a LAN pair
/// (host candidates on both ends) and internet P2P through STUN, whose uplink a 10 Mb/s seed can flood.
enum SeedRoute: String, Equatable {
    case lan, p2p, relay

    /// A host↔host pair with a LAN round trip is `lan`; the same pair over a VPN or tunnel counts as `p2p`.
    static let lanRoundTripLimitMs = 15.0

    /// A host pair without a round-trip figure yet is unknown, not LAN.
    static func classify(detail: String?, rttMs: Double?) -> SeedRoute? {
        switch detail {
        case "lan":
            guard let rttMs else { return nil }
            return rttMs < lanRoundTripLimitMs ? .lan : .p2p
        case "p2p": return .p2p
        case "relay": return .relay
        default: return nil
        }
    }
}

extension StreamQuality {
    /// Initial bandwidth estimate for a direct route. libwebrtc still backs off on delay or loss.
    var startBitrateBps: Int { self == .sharp ? 10_000_000 : 6_000_000 }
    /// Encoder ceiling. Sharper carries ~1.8x the pixels of Responsive, so it needs a higher cap,
    /// not just more pixels, to avoid spending the same bits on a larger picture.
    var maximumBitrateBps: Int { self == .sharp ? 25_000_000 : 12_000_000 }

    /// Route-aware start: the LAN keeps the mode's seed; internet P2P and relay start where a home
    /// uplink or a metered link can take it, well above libwebrtc's 300 kb/s but not at LAN rates.
    func startBitrateBps(for route: SeedRoute) -> Int {
        switch route {
        case .lan: return startBitrateBps
        case .p2p: return 3_000_000
        case .relay: return 2_500_000
        }
    }
}
