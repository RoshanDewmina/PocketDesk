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
    /// Sender-side `WebRTC-Video-Pacing` trial parameters (`factor:…,max_delay:…ms`). The desktop track
    /// is a screencast, so libwebrtc paces it with `WebRTC-ProbingScreenshareBwe` (factor 1.0, 2875 ms
    /// queue) and ignores this trial (PERF-PACK-2026-09-30 item 3); it only affects camera-type streams.
    var videoPacing: String?
    /// Seed the bandwidth estimate and cap the encoder per picture mode instead of starting at
    /// libwebrtc's 300 kbps and ramping for tens of seconds at maximum QP.
    var qualityBitrates: Bool
    /// Bandwidth-estimate ceiling as a multiple of the encoder ceiling. Above 1 lets the estimate, and
    /// with it the pacer (which sends at ~1.1x the estimate), exceed the encoder's average rate so a
    /// large key or full-screen frame drains faster. The estimate still only grows where the path allows.
    var bandwidthHeadroom: Int = 1
    /// X05: estimate-ceiling multiplier on a proven local link only (`BandwidthCeilingPolicy`), clamped to
    /// 1…2; probes are capped at 2x the encoder maximum, so more has no effect. It raises the ceiling the
    /// estimate may reach; WebRTC 153 has no per-sender pacer setting, so no pacer effect is claimed.
    /// Off (1) until a physical A/B.
    var lanBandwidthHeadroom: Double = 1
    /// Perf pack item 1a (phone): merge pointer moves while the control channel is backed up
    /// (`PointerMoveCoalescer`); a healthy channel is unchanged.
    var mergePointerMoves = true
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
    /// G5: stream a source of 100 Hz or more at 120 fps (capture at its native cadence, level fit
    /// and pixel budget at 120, sender at 120). Inert on a 60 Hz display.
    var highRefreshCapture = true
    /// G5 test override for the target rate (30…120), regardless of the display.
    var targetFPSOverride: Int?
    /// G5: in 120 mode, turn WebRTC's degradation off: its overuse detector trips at 200 % of the frame
    /// interval for a hardware encoder (16.7 ms at 120 fps, just above VideoToolbox's good 14.7 ms
    /// state), so it would cut the rate on every queueing spike; the app's own ladder decides instead.
    var highRefreshNoAdaptation = true
    /// Newest frame wins: drop a frame at submit while this many are already inside VideoToolbox
    /// (Chrome Remote Desktop keeps one pending). Nil lets frames queue. Tuned default 1 (efficiency
    /// audit P1); `NewestFrameWinsSwitch` turns it off at runtime from Settings → Diagnostics.
    var encoderMaxInFlight: Int?
    /// Cap the capture long edge to the client's advertised screen pixels (reduction only).
    var capToClientPixels = true
    /// G4: crop the capture to the phone's reported viewport (`SessionFeature.viewportCapture`).
    var viewportCapture = true
    /// G12: let the ladder step the rate and size down under load and report the busy state.
    var ladder = true
    /// X17: compute the send-path cap (`SenderQueueGovernor`) every window and report it; needs `ladder`.
    var senderQueueGovernor = true
    /// X17: apply that cap to the ladder. Off is shadow mode: the cap is only reported ("would cap").
    var senderQueueGovernorApply = false
    /// Phone (efficiency audit P2): with `presentAtDisplayMaximum`, the video view drops to 30 Hz while
    /// no frame or touch has arrived for a moment and returns to its maximum on the next one.
    var idleVideoRefresh = true
    /// Perf pack 4a: the host keeps per-frame display → encoded records and forwards the newest ones
    /// with its summary so the phone can time each frame to its decode. Off sends no records.
    var frameTiming = true
    /// Crisp still text: the owned VideoToolbox encoder's MaxAllowedFrameQP ceiling. 26 keeps text edges
    /// that 30 softened; VideoToolbox drops frames rather than exceed its rate limits, so motion pays in
    /// frame rate, not blur. The key is an A/B override only (1…51).
    var encoderMaximumQP = 26

    func maximumBitrateBps(for quality: StreamQuality) -> Int {
        encoderCeilingKbps.map { $0 * 1000 } ?? quality.maximumBitrateBps
    }

    static let tuned: StreamTuning = {
        var tuning = StreamTuning(playoutDelayMinMs: 0, playoutDelayMaxMs: 0, videoPacing: nil,
                                  qualityBitrates: true, bandwidthHeadroom: 1, degradationPreference: .maintainResolution,
                                  encoderRestart: true, presentAtDisplayMaximum: true)
        tuning.encoderMaxInFlight = 1
        return tuning
    }()
    static let legacy: StreamTuning = {
        var tuning = StreamTuning(playoutDelayMinMs: nil, playoutDelayMaxMs: nil, videoPacing: nil,
                                  qualityBitrates: false, bandwidthHeadroom: 1, degradationPreference: nil,
                                  encoderRestart: false, presentAtDisplayMaximum: false)
        // "Previous stream tuning" must also exclude features added after that baseline.
        tuning.cacheLevel52Probe = false
        tuning.highRefreshCapture = false
        tuning.highRefreshNoAdaptation = false
        tuning.capToClientPixels = false
        tuning.viewportCapture = false
        tuning.ladder = false
        tuning.senderQueueGovernor = false
        tuning.senderQueueGovernorApply = false
        tuning.idleVideoRefresh = false
        tuning.mergePointerMoves = false
        tuning.frameTiming = false
        tuning.encoderMaximumQP = 30
        return tuning
    }()

    static let legacyDefaultsKey = "PocketDeskLegacyStreamTuning"
    static let captureNativeRateKey = "PocketDeskCaptureNativeRate"
    static let routeAwareSeedKey = "PocketDeskRouteAwareSeed"
    static let restartFloorKey = "PocketDeskRestartFloorKbps"
    static let restartKeyFrameBudgetKey = "PocketDeskRestartKeyFrameBudgetMs"
    static let encoderCeilingKey = "PocketDeskEncoderCeilingKbps"
    static let level52ProbeCacheKey = "PocketDeskLevel52ProbeCache"
    static let highRefreshCaptureKey = "PocketDeskHighRefreshCapture"
    static let targetFPSKey = "PocketDeskTargetFPS"
    static let highRefreshNoAdaptationKey = "PocketDeskHighRefreshNoAdaptation"
    static let capToClientPixelsKey = "PocketDeskCapToClientPixels"
    static let viewportCaptureKey = "PocketDeskViewportCapture"
    static let ladderKey = "PocketDeskLadder"
    static let senderQueueGovernorKey = "PocketDeskSenderQueueGovernor"
    static let senderQueueGovernorApplyKey = "PocketDeskSenderQueueGovernorApply"
    static let encoderMaxInFlightKey = "PocketDeskEncoderMaxInFlight"
    static let lanHeadroomKey = "PocketDeskLANHeadroom"
    static let mergePointerMovesKey = "PocketDeskMergePointerMoves"
    static let idleVideoRefreshKey = "PocketDeskIdleVideoRefresh"
    static let frameTimingKey = "PocketDeskFrameTiming"
    static let encoderMaximumQPKey = "PocketDeskEncoderMaxQP"
    /// Every experiment key, for the session protocol's cleanup step.
    static let experimentKeys = [legacyDefaultsKey, captureNativeRateKey, routeAwareSeedKey, restartFloorKey,
                                 restartKeyFrameBudgetKey, encoderCeilingKey, level52ProbeCacheKey,
                                 highRefreshCaptureKey, targetFPSKey, highRefreshNoAdaptationKey, capToClientPixelsKey,
                                 viewportCaptureKey, ladderKey, encoderMaxInFlightKey, idleVideoRefreshKey, lanHeadroomKey,
                                 mergePointerMovesKey, frameTimingKey, senderQueueGovernorKey, senderQueueGovernorApplyKey, encoderMaximumQPKey]

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
        if defaults.object(forKey: highRefreshCaptureKey) != nil {
            tuning.highRefreshCapture = defaults.bool(forKey: highRefreshCaptureKey)
        }
        if defaults.object(forKey: targetFPSKey) != nil {
            let fps = defaults.integer(forKey: targetFPSKey)
            tuning.targetFPSOverride = CaptureRatePolicy.overrideRange.contains(fps) ? fps : nil
        }
        if defaults.object(forKey: highRefreshNoAdaptationKey) != nil {
            tuning.highRefreshNoAdaptation = defaults.bool(forKey: highRefreshNoAdaptationKey)
        }
        if defaults.object(forKey: capToClientPixelsKey) != nil {
            tuning.capToClientPixels = defaults.bool(forKey: capToClientPixelsKey)
        }
        if defaults.object(forKey: viewportCaptureKey) != nil {
            tuning.viewportCapture = defaults.bool(forKey: viewportCaptureKey)
        }
        if defaults.object(forKey: ladderKey) != nil {
            tuning.ladder = defaults.bool(forKey: ladderKey)
        }
        if defaults.object(forKey: senderQueueGovernorKey) != nil {
            tuning.senderQueueGovernor = defaults.bool(forKey: senderQueueGovernorKey)
        }
        if defaults.object(forKey: senderQueueGovernorApplyKey) != nil {
            tuning.senderQueueGovernorApply = defaults.bool(forKey: senderQueueGovernorApplyKey)
        }
        if defaults.object(forKey: mergePointerMovesKey) != nil {
            tuning.mergePointerMoves = defaults.bool(forKey: mergePointerMovesKey)
        }
        if defaults.object(forKey: lanHeadroomKey) != nil {
            tuning.lanBandwidthHeadroom = BandwidthCeilingPolicy.clampedLANHeadroom(defaults.double(forKey: lanHeadroomKey))
        }
        if defaults.object(forKey: encoderMaxInFlightKey) != nil {
            // 0 (or anything outside 1…8) lets frames queue, as before the default changed.
            let limit = defaults.integer(forKey: encoderMaxInFlightKey)
            tuning.encoderMaxInFlight = (1...8).contains(limit) ? limit : nil
        }
        if defaults.object(forKey: idleVideoRefreshKey) != nil {
            tuning.idleVideoRefresh = defaults.bool(forKey: idleVideoRefreshKey)
        }
        if defaults.object(forKey: frameTimingKey) != nil {
            tuning.frameTiming = defaults.bool(forKey: frameTimingKey)
        }
        if defaults.object(forKey: encoderMaximumQPKey) != nil {
            let qp = defaults.integer(forKey: encoderMaximumQPKey)
            if (1...51).contains(qp) { tuning.encoderMaximumQP = qp }
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
        if self == Self.legacy { return "legacy" }
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
        if !highRefreshCapture { parts.append("60 fps only") }
        if let targetFPSOverride { parts.append("target \(targetFPSOverride) fps") }
        if !highRefreshNoAdaptation { parts.append("webrtc adaptation at 120") }
        if !capToClientPixels { parts.append("no client cap") }
        if !viewportCapture { parts.append("whole-display capture") }
        if !ladder { parts.append("no ladder") }
        if let encoderMaxInFlight { parts.append("max in-flight \(encoderMaxInFlight)") }
        if lanBandwidthHeadroom > 1 { parts.append("LAN ceiling ×\(String(format: "%g", lanBandwidthHeadroom))") }
        if !mergePointerMoves { parts.append("no move merge") }
        if presentAtDisplayMaximum && !idleVideoRefresh { parts.append("no idle refresh") }
        if !frameTiming { parts.append("no frame timing") }
        if encoderMaximumQP != Self.tuned.encoderMaximumQP { parts.append("max QP \(encoderMaximumQP)") }
        if ladder { parts.append("governor " + (!senderQueueGovernor ? "off" : senderQueueGovernorApply ? "apply" : "shadow")) }
        return parts.isEmpty ? "legacy" : parts.joined(separator: " · ")
    }

    /// `summary` plus the runtime switches, as recorded in statistics samples and diagnostics.
    var liveSummary: String {
        guard encoderMaxInFlight != nil, !NewestFrameWinsSwitch.isOn else { return summary }
        return summary + " · newest-frame-wins off"
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
        var trials = tuning.fieldTrials
        #if DEBUG
        if PacketRepairPreferences.activeThisLaunch {
            trials[kRTCFieldTrialFlexFec03AdvertisedKey] = "Enabled"
            trials[kRTCFieldTrialFlexFec03Key] = "Enabled"
        }
        #endif
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

/// The estimate ceiling for the route in use: the encoder ceiling times `bandwidthHeadroom`, and on a LAN
/// host pair that is also the proven local link, times `lanBandwidthHeadroom`, so the estimate may climb
/// past the encoder's average where the link has room. Internet P2P, relay, an unproven host pair and
/// unknown routes never see the LAN multiplier.
enum BandwidthCeilingPolicy {
    static let lanHeadroomRange = 1.0...2.0

    static func clampedLANHeadroom(_ value: Double) -> Double {
        value.isFinite ? min(lanHeadroomRange.upperBound, max(lanHeadroomRange.lowerBound, value)) : 1
    }

    /// The LAN multiplier in force: 1 unless the route is LAN on a proven local link.
    static func lanMultiplier(route: SeedRoute?, provenLocal: Bool, tuning: StreamTuning) -> Double {
        guard route == .lan, provenLocal else { return 1 }
        return clampedLANHeadroom(tuning.lanBandwidthHeadroom)
    }

    static func maxBitrateBps(ceiling: Int, route: SeedRoute?, provenLocal: Bool, tuning: StreamTuning) -> Int {
        let multiplier = max(Double(max(1, tuning.bandwidthHeadroom)),
                             lanMultiplier(route: route, provenLocal: provenLocal, tuning: tuning))
        return Int((Double(ceiling) * multiplier).rounded())
    }
}

/// The route class the estimate ceiling follows, with hysteresis so a busy LAN whose round trip
/// wanders around `SeedRoute.lanRoundTripLimitMs` does not flip the ceiling every second.
/// `provenLocal` is whether the selected pair is still the proven local link; losing it collapses the
/// LAN multiplier even while the pair still looks like a LAN host pair.
struct CeilingRouteTracker: Equatable {
    static let lanExitRoundTripMs = 25.0
    private(set) var route: SeedRoute?
    private(set) var provenLocal = false

    /// True when the class or the proof changed and the ceiling must be re-applied.
    mutating func observe(detail: String?, rttMs: Double?, provenLocal: Bool = false) -> Bool {
        var next = SeedRoute.classify(detail: detail, rttMs: rttMs)
        if route == .lan, detail == "lan", let rttMs, rttMs < Self.lanExitRoundTripMs { next = .lan }
        guard next != route || provenLocal != self.provenLocal else { return false }
        route = next
        self.provenLocal = provenLocal
        return true
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
