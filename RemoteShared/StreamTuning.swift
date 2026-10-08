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
    /// (Chrome Remote Desktop keeps one pending). Nil lets frames queue on the old path.
    /// Tuned default 2 in the .7 pipeline test; the NO kill switch restores 1 and old diagnostics.
    var encoderMaxInFlight: Int?
    /// .7 test default: bounded two-frame owned VT pipeline and throughput-based 60 fps recovery.
    var encoderPipelining = true
    /// Cap the capture long edge to the client's advertised screen pixels (reduction only).
    var capToClientPixels = true
    /// Displayed-pixels cap: limit the whole-display output to the pixels the Mac picture occupies on the
    /// phone (`DisplayedPixelsPolicy`). Needs a whole-display session whose phone reports its viewport (not
    /// view-only); with viewport capture off the viewport only sizes the whole display. Window-scoped capture
    /// keeps the mode/client cap. On by default in `tuned` (7 Oct 2026 A/B); `PocketDeskDisplayedPixelsCap NO` turns it off.
    var displayedPixelsCap = false
    /// Headroom multiplier on the displayed-pixels cap (0.5…1.5).
    var displayedPixelsScale = 1.0
    /// Resolution-floor test: the capture long edge (any scope), under the mode cap only; wins over the
    /// client and displayed-pixels caps and ignores the 640 client floor. Unset by default.
    var outputLongEdgeOverride: Int?
    /// G4: crop the capture to the phone's reported viewport (`SessionFeature.viewportCapture`). Off in `tuned`
    /// since 8 Oct 2026; `PocketDeskViewportCapture YES` turns the crop back on.
    var viewportCapture = true
    /// Fill view (7 Oct 2026): a crop's output is its phone-native size × this (0.5…1.0). Below 1 the
    /// visible rect is upscaled a little on the phone in exchange for a cheaper encode; the crop-gain
    /// gate is still judged at phone-native size, so the knob never flips a crop back to the whole display.
    var cropPixelScale = 1.0
    /// A crop rect change at the same viewport zoom (a pan, the phone's pan widening, the return to rest)
    /// keeps the held output size while it fits the budget, so only the ScreenCaptureKit source rect
    /// moves and the encoder never restarts for a pan (ViewportCapturePolicy).
    var cropHoldsOutput = false
    /// A frame of the same pixel size shown after a region switch was requested and before it completed
    /// cannot be tagged with its region (CaptureFrameRegionPolicy); drop it rather than let the phone
    /// place it by the status echo, which is still the old rect.
    var cropDropsAmbiguousFrames = false
    /// Holding the output makes every pan re-crop a same-size switch, so the hold always drops those frames too.
    var dropsAmbiguousFrames: Bool { cropDropsAmbiguousFrames || cropHoldsOutput }
    /// The host asks for and applies the phone's viewport: to crop, or only to size the whole display for
    /// the displayed-pixels cap while cropping stays off (it never crops without `viewportCapture`).
    var acceptsViewport: Bool { viewportCapture || displayedPixelsCap }
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
    /// HEVC is offered whenever both ends' hardware probes pass. Off (internal A/B or kill switch only)
    /// makes this side offer H.264 alone, so the session negotiates H.264 with the owned encoder.
    var hevc = true
    /// Host: on a proven one-hop local link (`LANCodecPolicy`), offer H.264 alone instead of HEVC. 7 Oct 2026
    /// device A/B (M4 Air, iPhone 17): H.264 felt less jittery, with VT p90 ≈19 ms against 24–27 ms at 2560 and a
    /// ≈0.1 ms submit against ≈9 ms; HEVC's ~30 % bandwidth saving matters mainly off the LAN. An explicit
    /// `PocketDeskHEVC` wins (this stays off). Off until decided: every session keeps today's codec choice.
    var h264OnLAN = false
    /// Owned encoder: ask VideoToolbox to favour encode speed over quality (an optional hint; a rejecting
    /// encoder keeps its default). Not offered by the low-latency rate controller.
    var encoderPrioritizeSpeed = false
    /// Owned encoder: `kVTCompressionPropertyKey_RealTime`. 7 Oct 2026 HEVC bench (M4 Air, paced cadence): off
    /// halved the still-frame VT p90 (2560 at 60 fps: 21 → 10 ms, gate drops 90 → 2). On until a device A/B.
    var encoderRealTime = true
    /// Owned encoder: ExpectedFrameRate never below this (30, 60 or 120; 0 is the session rate). Same bench: 60
    /// while frames arrived at 30 halved the still-frame VT p90. 0 until a device A/B.
    var encoderMinExpectedFPS = 0
    /// Owned HEVC encoder: request VideoToolbox's low-latency rate control; creation falls back to the
    /// standard hardware session if it is refused.
    var hevcLowLatency = false
    /// Owned encoder: off (default) sets the maximum key frame interval and duration so VideoToolbox emits
    /// only requested key frames (start, PLI/FIR, restart); its own 150-500 KB key frames every few seconds
    /// on a still screen collapsed the bandwidth estimate. On restores VideoToolbox's own placement.
    var encoderPeriodicKeyFrames = false
    /// Keys on demand (ENCODER-OPTIMIZATIONS row 1): with a phone that asked for
    /// `SessionFeature.keysOnDemand`, the owned HEVC encoder sets no key frame duration limit, so the only
    /// key frames are the requested ones (start, PLI/FIR, restart, size step). Each 10 s safety key costs
    /// the receiver a 216–309 ms gap behind the screenshare pacer. Off until a device A/B; a phone that
    /// does not ask, and any H.264 session keeps the 10 s key whatever this says (`keysOnDemandH264`).
    var keysOnDemand = false
    /// Latency item 7: keys on demand for owned H.264 sessions too, under the same phone capability. Recovery
    /// relies on libwebrtc M153's stock path: `RTCVideoDecoderH264` returns an error on the decode after a
    /// failed one and `VideoReceiveStream2` then requests a key (evidence in the latency impl notes). Off
    /// until a device A/B.
    var keysOnDemandH264 = false
    /// Latency item 14: `MaxFrameDelayCount` on owned encoder sessions (1…8). VideoToolbox must emit frame
    /// N-M before encoding frame N returns, so 1 makes each submission wait for the previous frame. Nil
    /// leaves VideoToolbox's unlimited default.
    var encoderMaxFrameDelay: Int?
    /// Latency item 15: ScreenCaptureKit's queue depth at 60 fps and below (3…8); nil keeps 5.
    var captureQueueDepth: Int?
    /// Latency item 16: `SCStreamConfiguration.captureResolution`. `.nominal` reads one pixel per point, so
    /// the host's sizes and crops use a scale of 1 instead of the display's backing scale.
    var captureResolution: CaptureResolutionChoice = .automatic
    /// Latency item 5: on a trusted LAN only, the video encoding's minimum bitrate (kbps, at most half the
    /// encoder ceiling), which also floors the estimate. libwebrtc's congestion-window pushback drops frames only while its target is above
    /// the encoder minimum. Nil leaves the minimum unset.
    var encodingMinBitrateLANKbps: Int?
    /// Key-neutral ladder (row 2): a statistics window with a key frame is not pacer-wait or low-estimate
    /// evidence and does not reset the climb clock, and one firing sample resets the clock only when the
    /// next sample fires too. Off until a device A/B.
    var ladderKeyNeutral = false
    /// Row 3: libwebrtc's own degradation at 60 fps and below. Off hands the rate to the app's ladder
    /// alone (`maintainFramerateAndResolution`, as `highRefreshNoAdaptation` does above 60), so the
    /// overuse detector cannot cut the frame rate behind the ladder's back. On is today's behaviour.
    var webRTCAdaptationAt60 = true
    /// Idea 2 (LATENCY-PLAN §2.2): for a phone that asked (`SessionFeature.backdrop`), a second 640 px,
    /// 4 fps whole-display capture sent as snapshots on the `backdrop.1` channel. Off: no second capture
    /// and no channel.
    var backdropTrack = false
    /// Host: on a remote (Anywhere) route, run the one-hop local link proof alongside the stream with a
    /// phone that offers it (`RemoteRouteLANProofRequest`). A pass grants no authority and changes no
    /// route; it only lets `LANTrustTracker` judge a selected pair that is exactly the proven one.
    /// Off until a device A/B: every remote-route session stays unproven, as today.
    var remoteRouteLANProof = false
    /// Host: on a likely-LAN pair (`LikelyLANPair`) with a LAN round trip, seed the estimate at the first
    /// statistics sample, before the encoder exists, and hold it at the seed for a few guarded samples
    /// (`FastStartLANPolicy`). Off until a device A/B: the seed waits for the second sample, as today.
    var fastStartLAN = false
    /// Host: a scroll burst that reaches the Mac at once after a network stall is posted at no more than twice the
    /// phone's 120 Hz cadence (`ScrollPacer`) instead of in one instant. Off: every scroll message posts on arrival.
    var scrollSmoothing = false
    /// Host: before a scroll gesture begins, a Mac cursor that sits outside the streamed display is moved onto it,
    /// so macOS (which delivers scroll events under the real cursor) scrolls the window the phone shows.
    var scrollTargetsStream = false
    /// Host (research3 P4-B): a paired phone's next whole-display or window capture on the same display starts in
    /// the picture mode, client edge and displayed edge it last applied (`StreamShapeMemory`) instead of Balanced
    /// with no client edge, which cost two reconfigures and an encoder size swap per connect. Off: nothing is
    /// remembered or applied.
    var rememberStreamShape = false

    func maximumBitrateBps(for quality: StreamQuality) -> Int {
        encoderCeilingKbps.map { $0 * 1000 } ?? quality.maximumBitrateBps
    }

    static let tuned: StreamTuning = {
        var tuning = StreamTuning(playoutDelayMinMs: 0, playoutDelayMaxMs: 0, videoPacing: nil,
                                  qualityBitrates: true, bandwidthHeadroom: 1, degradationPreference: .maintainResolution,
                                  encoderRestart: true, presentAtDisplayMaximum: true)
        tuning.encoderMaxInFlight = 2
        // 7 Oct 2026 device A/B (iPhone 17, M4 Air, H.264): ≥50 fps 95–97 % of moving seconds at 1520
        // against 43–60 % uncapped; 1520 matched full-size sharpness where 1216 softened small text.
        tuning.displayedPixelsCap = true
        tuning.displayedPixelsScale = 1.25
        // 8 Oct 2026 device A/B: HEVC with RealTime off encoded in 7 ms p90 against 15-16 ms, at 99 % of
        // moving seconds at 50+ fps and 35 % less bitrate than H.264, thermal state nominal throughout.
        tuning.encoderRealTime = false
        // Same session: the portrait Fill crop with output hold and ambiguous-frame drop kept 60 fps with fewer
        // key frames; the remote-route LAN proof trusted the link; scroll smoothing halved the largest jump.
        tuning.cropHoldsOutput = true
        tuning.cropDropsAmbiguousFrames = true
        tuning.remoteRouteLANProof = true
        tuning.scrollSmoothing = true
        // 8 Oct 2026 on device: the Fill crop's pan edges showed black strips (the backdrop did not hide them);
        // the whole display in Fill was "perfect", text about as sharp. The phone still asks for the crop.
        tuning.viewportCapture = false
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
        tuning.encoderPrioritizeSpeed = false
        tuning.hevcLowLatency = false
        tuning.encoderPeriodicKeyFrames = true
        tuning.encoderPipelining = false
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
    static let displayedPixelsCapKey = "PocketDeskDisplayedPixelsCap"
    static let displayedPixelsScaleKey = "PocketDeskDisplayedPixelsScale"
    static let displayedPixelsScaleRange = 0.5...1.5
    static let outputLongEdgeKey = "PocketDeskOutputLongEdge"
    static let outputLongEdgeRange = 256...4096
    static let viewportCaptureKey = "PocketDeskViewportCapture"
    static let cropPixelScaleKey = "PocketDeskCropPixelScale"
    static let cropPixelScaleRange = 0.5...1.0
    static let cropHoldsOutputKey = "PocketDeskCropHoldsOutput"
    static let cropDropsAmbiguousFramesKey = "PocketDeskCropDropsAmbiguousFrames"
    static let ladderKey = "PocketDeskLadder"
    static let senderQueueGovernorKey = "PocketDeskSenderQueueGovernor"
    static let senderQueueGovernorApplyKey = "PocketDeskSenderQueueGovernorApply"
    static let encoderMaxInFlightKey = "PocketDeskEncoderMaxInFlight"
    static let encoderPipeliningKey = "FarsideEncoderPipelining"
    static let lanHeadroomKey = "PocketDeskLANHeadroom"
    static let mergePointerMovesKey = "PocketDeskMergePointerMoves"
    static let idleVideoRefreshKey = "PocketDeskIdleVideoRefresh"
    static let frameTimingKey = "PocketDeskFrameTiming"
    static let encoderMaximumQPKey = "PocketDeskEncoderMaxQP"
    static let hevcKey = "PocketDeskHEVC"
    static let h264OnLANKey = "PocketDeskH264OnLAN"
    static let encoderPrioritizeSpeedKey = "PocketDeskEncoderPrioritizeSpeed"
    static let encoderRealTimeKey = "PocketDeskEncoderRealTime"
    static let encoderMinExpectedFPSKey = "PocketDeskEncoderMinExpectedFPS"
    static let encoderMinExpectedFPSValues: Set<Int> = [0, 30, 60, 120]
    static let hevcLowLatencyKey = "PocketDeskHEVCLowLatency"
    static let encoderPeriodicKeyFramesKey = "PocketDeskEncoderPeriodicKeyFrames"
    static let keysOnDemandKey = "PocketDeskKeysOnDemand"
    static let ladderKeyNeutralKey = "PocketDeskLadderKeyNeutral"
    static let webRTCAdaptationAt60Key = "PocketDeskWebRTCAdaptationAt60"
    static let keysOnDemandH264Key = "PocketDeskKeysOnDemandH264"
    static let encoderMaxFrameDelayKey = "PocketDeskEncoderMaxFrameDelay"
    static let captureQueueDepthKey = "PocketDeskCaptureQueueDepth"
    static let captureResolutionKey = "PocketDeskCaptureResolution"
    static let encodingMinBitrateLANKey = "PocketDeskEncodingMinBitrateLAN"
    static let encoderMaxFrameDelayRange = 1...8
    static let captureQueueDepthRange = 3...8
    static let encodingMinBitrateLANRange = 300...100_000
    static let backdropTrackKey = "PocketDeskBackdropTrack"
    /// Host readiness, not streaming: read by `HostDisplayRecovery`; listed here for the cleanup step only.
    static let unlockDisplayRefreshKey = "PocketDeskUnlockDisplayRefresh"
    static let remoteRouteLANProofKey = "PocketDeskRemoteRouteLANProof"
    static let fastStartLANKey = "PocketDeskFastStartLAN"
    static let scrollSmoothingKey = "PocketDeskScrollSmoothing"
    static let scrollTargetsStreamKey = "PocketDeskScrollTargetsStream"
    static let rememberStreamShapeKey = "PocketDeskRememberStreamShape"
    /// Every experiment key, for the session protocol's cleanup step.
    static let experimentKeys = [legacyDefaultsKey, captureNativeRateKey, routeAwareSeedKey, restartFloorKey,
                                 restartKeyFrameBudgetKey, encoderCeilingKey, level52ProbeCacheKey,
                                 highRefreshCaptureKey, targetFPSKey, highRefreshNoAdaptationKey, capToClientPixelsKey,
                                 viewportCaptureKey, ladderKey, encoderMaxInFlightKey, idleVideoRefreshKey, lanHeadroomKey,
                                 mergePointerMovesKey, frameTimingKey, senderQueueGovernorKey, senderQueueGovernorApplyKey, encoderMaximumQPKey, hevcKey,
                                 encoderPrioritizeSpeedKey, hevcLowLatencyKey, encoderPeriodicKeyFramesKey, encoderPipeliningKey,
                                 keysOnDemandKey, ladderKeyNeutralKey, webRTCAdaptationAt60Key,
                                 keysOnDemandH264Key, encoderMaxFrameDelayKey, captureQueueDepthKey, captureResolutionKey,
                                 encodingMinBitrateLANKey,
                                 backdropTrackKey, unlockDisplayRefreshKey, remoteRouteLANProofKey,
                                 displayedPixelsCapKey, displayedPixelsScaleKey, outputLongEdgeKey, fastStartLANKey,
                                 scrollSmoothingKey, scrollTargetsStreamKey, h264OnLANKey,
                                 cropPixelScaleKey, cropHoldsOutputKey, cropDropsAmbiguousFramesKey,
                                 encoderRealTimeKey, encoderMinExpectedFPSKey, rememberStreamShapeKey]

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
        if defaults.object(forKey: encoderPipeliningKey) != nil {
            tuning.encoderPipelining = defaults.bool(forKey: encoderPipeliningKey)
        }
        if !tuning.encoderPipelining { tuning.encoderMaxInFlight = 1 }
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
        if defaults.object(forKey: displayedPixelsCapKey) != nil {
            tuning.displayedPixelsCap = defaults.bool(forKey: displayedPixelsCapKey)
        }
        if defaults.object(forKey: displayedPixelsScaleKey) != nil {
            let scale = defaults.double(forKey: displayedPixelsScaleKey)
            if displayedPixelsScaleRange.contains(scale) { tuning.displayedPixelsScale = scale }
        }
        if defaults.object(forKey: outputLongEdgeKey) != nil {
            let edge = defaults.integer(forKey: outputLongEdgeKey)
            if outputLongEdgeRange.contains(edge) { tuning.outputLongEdgeOverride = edge }
        }
        if defaults.object(forKey: viewportCaptureKey) != nil {
            tuning.viewportCapture = defaults.bool(forKey: viewportCaptureKey)
        }
        if defaults.object(forKey: cropPixelScaleKey) != nil {
            let scale = defaults.double(forKey: cropPixelScaleKey)
            if cropPixelScaleRange.contains(scale) { tuning.cropPixelScale = scale }
        }
        if defaults.object(forKey: cropHoldsOutputKey) != nil {
            tuning.cropHoldsOutput = defaults.bool(forKey: cropHoldsOutputKey)
        }
        if defaults.object(forKey: cropDropsAmbiguousFramesKey) != nil {
            tuning.cropDropsAmbiguousFrames = defaults.bool(forKey: cropDropsAmbiguousFramesKey)
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
        // The new path remains bounded even when older diagnostics request an unbounded queue.
        if tuning.encoderPipelining { tuning.encoderMaxInFlight = min(2, max(1, tuning.encoderMaxInFlight ?? 2)) }
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
        if defaults.object(forKey: hevcKey) != nil {
            tuning.hevc = defaults.bool(forKey: hevcKey)
        } else {
            tuning.h264OnLAN = defaults.bool(forKey: h264OnLANKey)
        }
        if defaults.object(forKey: encoderPrioritizeSpeedKey) != nil {
            tuning.encoderPrioritizeSpeed = defaults.bool(forKey: encoderPrioritizeSpeedKey)
        }
        if defaults.object(forKey: encoderRealTimeKey) != nil {
            tuning.encoderRealTime = defaults.bool(forKey: encoderRealTimeKey)
        }
        if defaults.object(forKey: encoderMinExpectedFPSKey) != nil {
            let fps = defaults.integer(forKey: encoderMinExpectedFPSKey)
            tuning.encoderMinExpectedFPS = encoderMinExpectedFPSValues.contains(fps) ? fps : 0
        }
        if defaults.object(forKey: hevcLowLatencyKey) != nil {
            tuning.hevcLowLatency = defaults.bool(forKey: hevcLowLatencyKey)
        }
        if defaults.object(forKey: encoderPeriodicKeyFramesKey) != nil {
            tuning.encoderPeriodicKeyFrames = defaults.bool(forKey: encoderPeriodicKeyFramesKey)
        }
        if defaults.object(forKey: keysOnDemandKey) != nil {
            tuning.keysOnDemand = defaults.bool(forKey: keysOnDemandKey)
        }
        if defaults.object(forKey: ladderKeyNeutralKey) != nil {
            tuning.ladderKeyNeutral = defaults.bool(forKey: ladderKeyNeutralKey)
        }
        if defaults.object(forKey: webRTCAdaptationAt60Key) != nil {
            tuning.webRTCAdaptationAt60 = defaults.bool(forKey: webRTCAdaptationAt60Key)
        }
        if defaults.object(forKey: keysOnDemandH264Key) != nil {
            tuning.keysOnDemandH264 = defaults.bool(forKey: keysOnDemandH264Key)
        }
        if defaults.object(forKey: encoderMaxFrameDelayKey) != nil {
            let count = defaults.integer(forKey: encoderMaxFrameDelayKey)
            tuning.encoderMaxFrameDelay = encoderMaxFrameDelayRange.contains(count) ? count : nil
        }
        if defaults.object(forKey: captureQueueDepthKey) != nil {
            let depth = defaults.integer(forKey: captureQueueDepthKey)
            tuning.captureQueueDepth = captureQueueDepthRange.contains(depth) ? depth : nil
        }
        if let value = defaults.string(forKey: captureResolutionKey) {
            tuning.captureResolution = CaptureResolutionChoice(rawValue: value.lowercased()) ?? .automatic
        }
        if defaults.object(forKey: encodingMinBitrateLANKey) != nil {
            let kbps = defaults.integer(forKey: encodingMinBitrateLANKey)
            tuning.encodingMinBitrateLANKbps = encodingMinBitrateLANRange.contains(kbps) ? kbps : nil
        }
        if defaults.object(forKey: backdropTrackKey) != nil {
            tuning.backdropTrack = defaults.bool(forKey: backdropTrackKey)
        }
        if defaults.object(forKey: remoteRouteLANProofKey) != nil { tuning.remoteRouteLANProof = defaults.bool(forKey: remoteRouteLANProofKey) }
        tuning.fastStartLAN = defaults.bool(forKey: fastStartLANKey)
        if defaults.object(forKey: scrollSmoothingKey) != nil { tuning.scrollSmoothing = defaults.bool(forKey: scrollSmoothingKey) }
        tuning.scrollTargetsStream = defaults.bool(forKey: scrollTargetsStreamKey)
        tuning.rememberStreamShape = defaults.bool(forKey: rememberStreamShapeKey)
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
        if displayedPixelsCap { parts.append("displayed cap") }
        if displayedPixelsScale != 1 { parts.append("displayed ×\(String(format: "%g", displayedPixelsScale))") }
        if let outputLongEdgeOverride { parts.append("output edge \(outputLongEdgeOverride)") }
        if !viewportCapture { parts.append("whole-display capture") }
        if cropPixelScale != 1 { parts.append("crop ×\(String(format: "%g", cropPixelScale))") }
        if cropHoldsOutput { parts.append("crop holds output") }
        if cropDropsAmbiguousFrames { parts.append("crop drops ambiguous") }
        if !ladder { parts.append("no ladder") }
        if let encoderMaxInFlight { parts.append("max in-flight \(encoderMaxInFlight)") }
        if lanBandwidthHeadroom > 1 { parts.append("LAN ceiling ×\(String(format: "%g", lanBandwidthHeadroom))") }
        if !mergePointerMoves { parts.append("no move merge") }
        if presentAtDisplayMaximum && !idleVideoRefresh { parts.append("no idle refresh") }
        if !frameTiming { parts.append("no frame timing") }
        if encoderMaximumQP != Self.tuned.encoderMaximumQP { parts.append("max QP \(encoderMaximumQP)") }
        if !hevc { parts.append("no HEVC") }
        if h264OnLAN { parts.append("H.264 on LAN") }
        if encoderPrioritizeSpeed { parts.append("encode speed priority") }
        if !encoderRealTime { parts.append("encoder real time off") }
        if encoderMinExpectedFPS > 0 { parts.append("expected fps ≥\(encoderMinExpectedFPS)") }
        if hevcLowLatency { parts.append("HEVC low-latency") }
        if encoderPeriodicKeyFrames { parts.append("periodic keys") }
        if keysOnDemand { parts.append("keys on demand") }
        if ladderKeyNeutral { parts.append("key-neutral ladder") }
        if !webRTCAdaptationAt60 { parts.append("no webrtc adaptation at 60") }
        if keysOnDemandH264 { parts.append("H.264 keys on demand") }
        if let encoderMaxFrameDelay { parts.append("max frame delay \(encoderMaxFrameDelay)") }
        if let captureQueueDepth { parts.append("capture queue \(captureQueueDepth)") }
        if captureResolution != .automatic { parts.append("capture resolution \(captureResolution.rawValue)") }
        if let encodingMinBitrateLANKbps { parts.append("LAN encoding floor \(encodingMinBitrateLANKbps)") }
        if backdropTrack { parts.append("backdrop track") }
        if remoteRouteLANProof { parts.append("remote-route LAN proof") }
        if fastStartLAN { parts.append("fast start LAN") }
        if scrollSmoothing { parts.append("scroll smoothing") }
        if scrollTargetsStream { parts.append("scroll on stream") }
        if rememberStreamShape { parts.append("remembered shape") }
        if ladder { parts.append("governor " + (!senderQueueGovernor ? "off" : senderQueueGovernorApply ? "apply" : "shadow")) }
        return parts.isEmpty ? "legacy" : parts.joined(separator: " · ")
    }

    /// `summary` plus the runtime switches, as recorded in statistics samples and diagnostics.
    var liveSummary: String {
        liveSummary(defaults: .standard)
    }
    func liveSummary(defaults: UserDefaults) -> String {
        var parts = [summary]
        if encoderMaxInFlight != nil, !NewestFrameWinsSwitch.isOn { parts.append("newest-frame-wins off") }
        if MetalDisplayLinkSwitch.isOn(defaults) { parts.append("metal display link") }
        if MailboxWakeOnReleaseSwitch.isOn(defaults) { parts.append("mailbox wake on release") }
        return parts.joined(separator: " · ")
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

/// Phone, research run 3 P1-B (`defaults write com.roshan.PocketDesk.Remote PocketDeskMetalDisplayLink -bool YES`
/// or the launch argument `-PocketDeskMetalDisplayLink YES`, then relaunch): the owned video view draws on a
/// `CAMetalDisplayLink` with one frame of latency instead of MTKView's display link. Off keeps today's path.
enum MetalDisplayLinkSwitch {
    static let defaultsKey = "PocketDeskMetalDisplayLink"
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

/// Phone, research run 3 P1-C (`PocketDeskMailboxWakeOnRelease`): a frame waiting behind two unfinished draws
/// is drawn as soon as a slot frees, and `preferredFramesPerSecond` is rewritten only when it changes.
enum MailboxWakeOnReleaseSwitch {
    static let defaultsKey = "PocketDeskMailboxWakeOnRelease"
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

/// `SCCaptureResolutionType` without ScreenCaptureKit, so the shared tuning compiles on the phone.
enum CaptureResolutionChoice: String, Equatable {
    case automatic, nominal, best
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

    /// `FastStartLANPolicy` seeded at the first sample. Its hold replaces the re-check: the minimum keeps
    /// the estimate at the seed, so a probe result can no longer replace it.
    mutating func markSeeded() {
        attempts = Self.maximumAttempts
    }

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

/// Kill switch for seeding again on every resume after a phone background pause
/// (`defaults write <bundle id> PocketDeskSeedRearmOnResume -bool NO`, then relaunch the host).
enum BandwidthSeedRearmSwitch {
    static let defaultsKey = "PocketDeskSeedRearmOnResume"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
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
