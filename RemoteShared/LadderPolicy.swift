import Foundation

/// The user-facing causes a ladder move or a busy state can carry (`LadderState.reason`, `BusyState.reason`).
/// `power` is the Mac's Low Power Mode, a cap rather than a load.
enum LadderReason: String, CaseIterable {
    case thermal, capture, encoding, network, phone, power, phonePower
}

/// One per-second signal that steps the ladder down, in priority order: when several fire in one
/// sample, the first one's reason is the move's reason. Frame-rate and interval thresholds are
/// relative to the rung the stream runs at now, not the session's target, so a stream already
/// stepped to 60 is judged against 16.7 ms and 60 fps.
enum LadderTrigger: CaseIterable {
    case hostThermal, phoneThermal, captureBehind, encodeShortfall, encodeLatency, encodeBacklog, encodeQueue,
         droppedBeforeEncode, cpuLimited, pacerDelay, lowEstimate, bandwidthLimited, phoneSuperseded, phoneDecode

    var reason: LadderReason {
        switch self {
        case .hostThermal: .thermal
        case .captureBehind: .capture
        case .encodeShortfall, .encodeLatency, .encodeBacklog, .encodeQueue, .droppedBeforeEncode, .cpuLimited:
            .encoding
        case .pacerDelay, .lowEstimate, .bandwidthLimited: .network
        // A hot phone is the phone's limit; "thermal" alone would read as the Mac's.
        case .phoneThermal, .phoneSuperseded, .phoneDecode: .phone
        }
    }

    /// Thermal triggers step on their first sample, at most once per `LadderPolicy.thermalStepEvery`;
    /// the rest need two bad samples in a row.
    var isThermal: Bool { self == .hostThermal || self == .phoneThermal }

    /// Three frames in VideoToolbox's queue already cost ~40 ms at 2560 px: step on the first sample.
    var isImmediate: Bool { self == .encodeBacklog }
    var isPhoneWindow: Bool { self == .phoneDecode || self == .phoneSuperseded }

    var isNetwork: Bool { reason == .network }

    /// `StreamTuning.ladderKeyNeutral`: the pacer wait and the estimate of a window with a key frame are
    /// that frame's cost (a 500 KB HEVC key drains for 200-300 ms at the screenshare pacing factor of 1.0),
    /// not the link's. A limited encoder still reports `bandwidth` through libwebrtc.
    var isKeyFrameCost: Bool { self == .pacerDelay || self == .lowEstimate }

    func fires(_ inputs: LadderInputs, at rung: LadderState, falseLoadRules: Bool = LadderFalseLoadSwitch.isOn,
               lanTrustRules: Bool = LadderLANTrustSwitch.isOn, encoderPipelining: Bool = false,
               keyNeutral: Bool = false) -> Bool {
        let fps = LadderPolicy.rungFPS(rung)
        let interval = LadderPolicy.frameIntervalMs(rung)
        let pipelined = encoderPipelining && inputs.encodeAtCapShare != nil && fps <= 60
        // The bandwidth estimate is not evidence on a proven LAN with a clean round trip and no loss:
        // it collapses to the sent rate of a still screen (1 Oct 2026, .4: 25,000 -> 3,720 -> 2,395 kbps
        // at rtt 6-8 ms, loss 0, sent 1 Mbps), and the next key frame's pacer wait then stepped the size.
        if lanTrustRules, isNetwork, inputs.lanTrusted { return false }
        if keyNeutral, isKeyFrameCost, LadderPolicy.hasUnsolicitedKeyFrame(inputs) { return false }
        switch self {
        case .hostThermal:
            return (LadderPolicy.thermalLevel(inputs.hostThermalState) ?? 0) >= LadderPolicy.seriousThermalLevel
        case .phoneThermal:
            return (LadderPolicy.thermalLevel(inputs.phoneThermalState) ?? 0) >= LadderPolicy.seriousThermalLevel
        case .captureBehind:
            // A still screen also delivers few frames, but on time; only late frames mean a busy Mac.
            guard let capture = inputs.captureFPS, let latency = inputs.captureLatencyP90Ms else { return false }
            return capture < 0.8 * fps && latency > interval
        case .encodeShortfall:
            guard let encoded = inputs.encodedFPS else { return false }
            let demand = LadderPolicy.demandFPS(inputs, at: rung, falseLoadRules: falseLoadRules)
            if pipelined {
                return demand >= 0.5 * fps && (inputs.encodeAtCapShare ?? 0) >= 0.9
                    && encoded + 1 < 0.95 * demand
            }
            return demand >= 0.5 * fps && encoded < 0.8 * demand
        case .encodeLatency:
            // Callback latency includes legitimate two-frame overlap and restart spikes.
            // In the bounded pipeline, saturation/delivery and persistent drops prove load.
            if pipelined { return false }
            return (inputs.encodeLatencyP90Ms ?? 0) > 2 * interval
        case .encodeBacklog:
            return (inputs.encodeInFlightMax ?? 0) >= 3
        case .encodeQueue:
            // Two frames can overlap normally. Sustained occupancy, not a window's maximum,
            // distinguishes a full pipeline from a queue; two bad windows still step down.
            if pipelined {
                return LadderTrigger.encodeShortfall.fires(inputs, at: rung, falseLoadRules: falseLoadRules,
                                                          encoderPipelining: true)
            }
            // Latency grows ~13 ms per frame in flight, so a sustained second frame is a queue forming,
            // but only while frames take longer than the rung's interval. At 30 fps a 17-19 ms 2560 px
            // encode overlaps the next frame now and then with no queue; on the M4 Air that failed every
            // climb to full size within 2 s and backed the ladder off to 60 s (20260930 stream stats).
            guard inputs.encodeInFlightMax == 2 else { return false }
            return inputs.encodeLatencyP90Ms.map { $0 > interval } ?? true
        case .droppedBeforeEncode:
            if pipelined {
                // .7 rows 10425-10426 lost ~5% without saturation. The drop count spans
                // the whole stats window; normalized rates keep a delayed window from
                // inflating its share. Real drops still count even at a fast p90.
                let demand = LadderPolicy.demandFPS(inputs, at: rung, falseLoadRules: falseLoadRules)
                guard demand >= 0.5 * fps, let encoded = inputs.encodedFPS, encoded >= 0 else { return false }
                return (inputs.droppedBeforeEncode ?? 0) > 0 && encoded < 0.9 * demand
            }
            // A frame that lands while the last one is still encoding is dropped (newest frame wins),
            // and the rate controller drops a few after a key frame. With the encoder well inside its
            // interval (1 Oct 2026: p90 12-18 ms at 30 fps) that is cadence jitter, not load: 17 % of
            // such samples dropped 2-5 frames, and two in a row stepped 1920 down to 1280.
            if falseLoadRules, let latency = inputs.encodeLatencyP90Ms, latency <= interval { return false }
            return Double(inputs.droppedBeforeEncode ?? 0) > 0.05 * fps
        case .cpuLimited:
            return inputs.qualityLimitation?.lowercased() == "cpu"
        case .pacerDelay:
            // A still screen sends a refresh frame or two, often one key frame after a resize; the
            // window's packet wait is that one frame's, not a queue. `isClean` holds the climb instead.
            guard !LadderPolicy.isStill(inputs) else { return false }
            return (inputs.pacerDelayMs ?? 0) > 50
        case .lowEstimate:
            guard let available = inputs.availableKbps, let target = inputs.targetKbps, target > 0 else { return false }
            return available < 0.6 * target
        case .bandwidthLimited:
            return inputs.qualityLimitation?.lowercased() == "bandwidth"
        case .phoneSuperseded:
            // Network bunching alone supersedes frames too; it counts only with a second phone signal.
            guard let superseded = inputs.phoneSupersededPerSecond, superseded >= 3,
                  let delivered = LadderPolicy.phoneMeasurableFPS(inputs, at: rung) else { return false }
            if falseLoadRules {
                // Every decoded frame is presented or superseded (VideoPresentationProbe), so over 25 %
                // superseded already means under 75 % presented: "few presented" is the same signal, and
                // bunched Wi-Fi arrivals alone fired it, busy at 1280 px on an iPhone 17 (1 Oct, .3).
                // The second signal is a decoder using over half the frame's budget.
                let pressedDecode = inputs.phoneDecodeMs.map { $0 > 0.5 * 1000 / delivered } ?? false
                return Double(superseded) > 0.25 * delivered && pressedDecode
            }
            let slowDecode = inputs.phoneDecodeMs.map { $0 > 1000 / delivered } ?? false
            let fewPresented = inputs.phonePresentedFPS.map { $0 < 0.8 * delivered } ?? false
            return Double(superseded) > 0.25 * delivered && (slowDecode || fewPresented)
        case .phoneDecode:
            guard let delivered = LadderPolicy.phoneMeasurableFPS(inputs, at: rung) else { return false }
            return (inputs.phoneDecodeMs ?? 0) > 1000 / delivered
        }
    }

    static func firing(_ inputs: LadderInputs, at rung: LadderState,
                       falseLoadRules: Bool = LadderFalseLoadSwitch.isOn,
                       lanTrustRules: Bool = LadderLANTrustSwitch.isOn, encoderPipelining: Bool = false,
                       keyNeutral: Bool = false) -> [LadderTrigger] {
        allCases.filter { $0.fires(inputs, at: rung, falseLoadRules: falseLoadRules, lanTrustRules: lanTrustRules,
                                 encoderPipelining: encoderPipelining, keyNeutral: keyNeutral) }
    }
}

/// A link whose capacity is known to exceed the stream: a proven local link (host candidates on both
/// ends, authorised) with remote loss under `lossLimitPercent` (libwebrtc's own no-change band) and a
/// round trip under `roundTripLimitMs`. Home Wi-Fi shows 50-150 ms spikes with no loss while the
/// phone's radio sleeps on a still screen (1 Oct 2026: 85 of 469 rows over 60 ms, 22 over 100, loss
/// in 23); real congestion holds the round trip up and loses packets, which ends the trust within a sample.
enum LANTrustPolicy {
    static let roundTripLimitMs = 100.0
    static let lossLimitPercent = 2.0

    static func trusted(provenLocalLink: Bool, lossPercent: Double?, rttMs: Double?) -> Bool {
        guard provenLocalLink, let rttMs, rttMs.isFinite, rttMs <= roundTripLimitMs else { return false }
        return (lossPercent ?? 0) < lossLimitPercent
    }

}

/// `LANTrustPolicy` with memory. Trust is withdrawn by a pacer wait over `inflationLimitMs` in
/// `strikeSamples` samples in a row (the link is not draining the floor rate), by a round trip over the
/// limit in `strikeSamples` samples in a row, or by loss at once; it returns only after
/// `recoverySamples` samples in a row that are trusted and not inflated. So a LAN slower than the floor
/// cannot oscillate between floor on and floor off: the floor stays off and the old rules judge the
/// link. The media layer runs one per peer and publishes the verdict on the host report.
struct LANTrustTracker: Equatable {
    static let inflationLimitMs = 250.0
    static let strikeSamples = 2
    static let recoverySamples = 5

    private var pacerStrikes = 0
    private var roundTripStrikes = 0
    private var clean = 0
    private(set) var withdrawn = false
    private(set) var trusted = false

    /// `roundTripFresh` is false when `rttMs` is the previous sample's reading repeated (RTCP reports
    /// arrive about once a second, not always every sample): it then neither adds nor clears a strike.
    @discardableResult
    mutating func observe(provenLocalLink: Bool, lossPercent: Double?, rttMs: Double?, roundTripFresh: Bool = true,
                          pacerDelayMs: Double?) -> Bool {
        let base = LANTrustPolicy.trusted(provenLocalLink: provenLocalLink, lossPercent: lossPercent, rttMs: rttMs)
        let inflated = (pacerDelayMs ?? 0) > Self.inflationLimitMs
        let longRoundTrip = provenLocalLink && (rttMs.map { !$0.isFinite || $0 > LANTrustPolicy.roundTripLimitMs } ?? false)
        let lossy = provenLocalLink && (lossPercent ?? 0) >= LANTrustPolicy.lossLimitPercent
        pacerStrikes = inflated ? pacerStrikes + 1 : 0
        if roundTripFresh { roundTripStrikes = longRoundTrip ? roundTripStrikes + 1 : 0 }
        if pacerStrikes >= Self.strikeSamples || roundTripStrikes >= Self.strikeSamples || lossy {
            withdrawn = true
            clean = 0
        } else if withdrawn {
            clean = base && !inflated ? clean + 1 : 0
            if clean >= Self.recoverySamples { withdrawn = false }
        }
        trusted = base && !withdrawn
        return trusted
    }
}

/// The G12 ladder (StreamLadder.swift states the contract). Pure and deterministic: one call per
/// statistics sample with a monotonic time, no timers.
/// - Down one rung on the second sample in a row with a load trigger, on the first sample with three
///   frames in flight, or on the first thermal sample but at most one thermal step per 10 s.
/// - A still screen (`isStill`) and a window that sent under half the rung's frames are not load:
///   the pacer wait of one key frame and the phone counters of a 1 fps refresh step nothing.
/// - An encoder session's first `warmupSeconds` (session start, every size move, every rate
///   restart) are neutral like a still screen: its key frame, the capture spin-up and the ramping
///   estimate are the session's cost, not load. Only thermal and a three-frame backlog step, and the
///   climb waits. A warm-up sample neither counts nor clears load, so load on both sides of a
///   restart still steps; one that lasts past `maxWarmupSeconds` (restarts in a loop) counts again.
/// - Up one rung after `climbWait` clean seconds since the last bad or neutral sample or move, and
///   30 s after a thermal move. Pipelined same-size 30→60 recovery trials use delivery and two-frame
///   delay headroom; other climbs require p90 to fit one frame interval. A climb that steps down again within 10 s, or within its first 10
///   samples of a moving picture (a climb made on a still screen), failed: the wait doubles
///   (10, 20, 40, 60 s); it returns to 10 s after 120 s on one rung or a down step with another reason.
/// - Low Power Mode caps the top at the first rung of 60 fps or less (reason `power`), in one move.
/// - A target change restarts at the top of the new ladder.
/// - On a trusted LAN (`LANTrustPolicy`) the network triggers are not evidence: the estimate collapses
///   on a still screen while the link itself is fine.
/// - Key-neutral (`StreamTuning.ladderKeyNeutral`, off by default): a window with a key frame the phone
///   did not ask for (no PLI) is not pacer-wait or low-estimate evidence and does not hold the climb for
///   its pacer wait, and a sample whose only firing triggers are those two resets the climb clock only
///   when the next sample fires too (two in a row already step down). A window with a requested key is
///   judged as before: on a lossy link the phone asks every 500 ms, and that congestion is real. Off,
///   every firing sample resets the clock, so a key frame every 10 s can pin a 10 s climb.
struct LadderPolicy: LadderEngine {
    static let downSamples = 2
    static let upAfter: TimeInterval = 10
    static let maxClimbWait: TimeInterval = 60
    static let failedClimbWindow: TimeInterval = 10
    static let failedClimbSamples = 10
    static let stableReset: TimeInterval = 120
    static let thermalStepEvery: TimeInterval = 10
    static let thermalUpAfter: TimeInterval = 30
    static let seriousThermalLevel = 2
    static let lowPowerFPS = 60
    static let warmupSeconds: TimeInterval = 3
    static let maxWarmupSeconds: TimeInterval = 6

    private(set) var state: LadderState
    private(set) var targetFPS: Int
    let rungs: [LadderState]
    let lowPowerRung: Int
    private(set) var climbWait = LadderPolicy.upAfter
    private var loadSamples = 0
    private var loadSamplesIncludePhone = false
    private var phonePressurePending = false
    private var hadPhoneWindow = false
    private var calmSince: TimeInterval?
    private var lastMoveAt: TimeInterval?
    private var lastClimbAt: TimeInterval?
    /// Samples since the last climb in which the picture moved (`!isStill`).
    private var movingSinceClimb = 0
    private var thermalMoveAt: TimeInterval?
    private var backoffReason: LadderReason?
    private var warmingSince: TimeInterval?
    private var firedLastSample = false
    /// `LadderFalseLoadSwitch` (read once per process; tests turn it off per policy).
    var falseLoadRules = LadderFalseLoadSwitch.isOn
    /// `LadderLANTrustSwitch`, likewise.
    var lanTrustRules = LadderLANTrustSwitch.isOn
    var encoderPipelining = StreamTuning.current.encoderPipelining
    /// `StreamTuning.ladderKeyNeutral`, likewise.
    var keyNeutralRules = StreamTuning.current.ladderKeyNeutral

    init(targetFPS: Int) {
        self.targetFPS = targetFPS
        rungs = Self.ladder(targetFPS: targetFPS)
        lowPowerRung = rungs.firstIndex { $0.fps <= Self.lowPowerFPS } ?? 0
        state = rungs[0]
    }

    /// `LadderState.rungs(targetFPS:)`, except that no rung runs faster than the target: a 30 fps
    /// override becomes a size-only ladder instead of starting at 60.
    static func ladder(targetFPS: Int) -> [LadderState] {
        let top = min(max(targetFPS, 1), 240)
        var ladder: [LadderState] = []
        for rung in LadderState.rungs(targetFPS: top) {
            let fps = min(rung.fps, top)
            if let last = ladder.last, last.fps == fps, last.sizeFraction == rung.sizeFraction { continue }
            ladder.append(LadderState(rung: ladder.count, fps: fps, sizeFraction: rung.sizeFraction, reason: nil))
        }
        return ladder
    }

    mutating func evaluate(_ inputs: LadderInputs, at time: TimeInterval) -> LadderState? {
        let previous = state
        if inputs.targetFPS != targetFPS {
            let rules = (falseLoadRules, lanTrustRules, encoderPipelining, keyNeutralRules)
            self = LadderPolicy(targetFPS: inputs.targetFPS)
            (falseLoadRules, lanTrustRules, encoderPipelining, keyNeutralRules) = rules
            calmSince = time
        }
        step(inputs, at: time)
        return state == previous ? nil : state
    }

    /// Retire only phone-dependent evidence when the inbox observed a gap between host ticks.
    /// Keep independent host overload and the phone sequence/replay ledger owned by the caller.
    mutating func retirePhoneEvidence(at time: TimeInterval) {
        if loadSamplesIncludePhone { loadSamples = 0; loadSamplesIncludePhone = false }
        phonePressurePending = false
        if hadPhoneWindow { calmSince = time; hadPhoneWindow = false }
    }

    private mutating func step(_ inputs: LadderInputs, at time: TimeInterval) {
        if let lastMoveAt, time - lastMoveAt >= Self.stableReset { climbWait = Self.upAfter }
        let lowPower = inputs.hostLowPowerMode == true || inputs.phoneLowPowerMode == true
        let powerReason: LadderReason = inputs.hostLowPowerMode == true ? .power : .phonePower
        if lowPower && state.rung < lowPowerRung {
            move(to: lowPowerRung, reason: powerReason.rawValue, at: time)
            return
        }
        if lastClimbAt != nil, !Self.isStill(inputs) { movingSinceClimb += 1 }
        let warming = warmingUp(inputs, at: time)
        let raw = LadderTrigger.firing(inputs, at: state, falseLoadRules: falseLoadRules, lanTrustRules: lanTrustRules,
                                      encoderPipelining: encoderPipelining, keyNeutral: keyNeutralRules)
        let firing = raw.filter { !warming || $0.isThermal || $0.isImmediate }
        let thermal = firing.first { $0.isThermal }
        let phoneLoad = firing.first { $0.isPhoneWindow }
        let load = firing.first { !$0.isThermal && (!$0.isPhoneWindow || inputs.phoneSampleState == .fresh) }
        // A warm-up sample with load neither counts nor clears: load on both sides of a restart still
        // steps, so restarts every few seconds cannot hide a real overload.
        switch inputs.phoneSampleState {
        case .fresh:
            hadPhoneWindow = true
            if !warming {
                phonePressurePending = phoneLoad != nil
            }
        case .held:
            break // Neither another bad observation nor evidence of recovery.
        case .unknown:
            retirePhoneEvidence(at: time)
        }
        if let load {
            loadSamples += 1
            loadSamplesIncludePhone = loadSamplesIncludePhone || load.isPhoneWindow
        } else if !(inputs.phoneSampleState == .held && phonePressurePending),
                  !warming || !raw.contains(where: { !$0.isThermal }) {
            loadSamples = 0
            loadSamplesIncludePhone = false
        }
        let atFloor = state.rung >= rungs.count - 1
        if let thermal, !atFloor, thermalMoveAt.map({ time - $0 >= Self.thermalStepEvery }) ?? true {
            thermalMoveAt = time
            stepDown(because: thermal.reason, at: time)
            return
        }
        if let load, !atFloor, loadSamples >= Self.downSamples || firing.contains(where: \.isImmediate) {
            stepDown(because: load.reason, at: time)
            return
        }
        // The old one-frame gate prevented 2560 px streams with 17-19 ms p90 from trying 60.
        // Preserve it outside the owned encoder's bounded pipeline and same-size rate recovery.
        let pipelined = encoderPipelining && inputs.encodeAtCapShare != nil && state.fps <= 60
        // A thinned 30 fps source cannot demonstrate 60 fps. Trial the same-size 60 rung after
        // sustained delivery with 10% delay headroom; at 60 the measured delivery rate decides.
        // Size and higher-rate climbs retain their conservative single-frame gate.
        let rateTrial = pipelined && state.rung > 0 && state.fps == 30 && rungs[state.rung - 1].fps == 60
            && state.sizeFraction == rungs[state.rung - 1].sizeFraction
        let fitsAbove = rateTrial
            ? inputs.encodeLatencyP90Ms.map {
                let nextInterval = Self.frameIntervalMs(rungs[state.rung - 1])
                let moving = Self.demandFPS(inputs, at: state, falseLoadRules: falseLoadRules) >= 0.9 * Self.rungFPS(state)
                return $0.isFinite && $0 < (moving ? 1.8 : 1) * nextInterval
            } ?? false
            : !falseLoadRules || state.rung == 0
            || inputs.encodeLatencyP90Ms.map { $0 < Self.frameIntervalMs(rungs[state.rung - 1]) } ?? true
        let clean = Self.isClean(inputs, at: state, falseLoadRules: falseLoadRules, encoderPipelining: pipelined,
                                 keyNeutral: keyNeutralRules)
        let firedBefore = firedLastSample
        firedLastSample = !firing.isEmpty
        guard firing.isEmpty, !phonePressurePending, !warming, fitsAbove, clean else {
            // Key-neutral: a lone network sample keeps the clock; the second in a row resets it (or steps).
            let loneFiring = keyNeutralRules && !firing.isEmpty && !firedBefore && firing.allSatisfy(\.isKeyFrameCost)
                && !phonePressurePending && !warming && fitsAbove && clean
            if !loneFiring { calmSince = time }
            return
        }
        let top = lowPower ? lowPowerRung : 0
        guard state.rung > top, let calmSince, time - calmSince >= climbWait else { return }
        if let thermalMoveAt, time - thermalMoveAt < Self.thermalUpAfter { return }
        let next = state.rung - 1
        move(to: next, reason: lowPower && next == lowPowerRung ? powerReason.rawValue : state.reason, at: time)
        lastClimbAt = time
        movingSinceClimb = 0
    }

    private mutating func warmingUp(_ inputs: LadderInputs, at time: TimeInterval) -> Bool {
        // No session age and nothing encoded yet: capture is spinning up before the first encoder. That
        // is warm-up too, but it does not use up the cap the encoder's own first seconds need.
        if falseLoadRules, inputs.encoderSessionAgeS == nil, inputs.encodedFPS == 0 { return true }
        guard falseLoadRules, let age = inputs.encoderSessionAgeS, age < Self.warmupSeconds else {
            warmingSince = nil
            return false
        }
        let since = warmingSince ?? time
        warmingSince = since
        return time - since < Self.maxWarmupSeconds
    }

    private mutating func stepDown(because reason: LadderReason, at time: TimeInterval) {
        if reason != backoffReason {
            climbWait = Self.upAfter
            backoffReason = reason
        }
        // A climb made on a still screen is tested only once the picture moves: it failed if the step
        // comes within 10 s of it or within its first 10 moving samples, inside the 120 s reset.
        if let lastClimbAt, time - lastClimbAt < Self.failedClimbWindow
            || (movingSinceClimb < Self.failedClimbSamples && time - lastClimbAt < Self.stableReset) {
            climbWait = min(climbWait * 2, Self.maxClimbWait)
        }
        lastClimbAt = nil
        move(to: state.rung + 1, reason: reason.rawValue, at: time)
    }

    private mutating func move(to index: Int, reason: String?, at time: TimeInterval) {
        var next = rungs[index]
        next.reason = index == 0 ? nil : reason
        state = next
        loadSamples = 0
        loadSamplesIncludePhone = false
        calmSince = time
        lastMoveAt = time
    }

    /// Headroom: no trigger (checked by the caller), the encoder keeps up with what capture
    /// delivered, and its latency fits one frame interval. The one-frame allowance keeps ordinary
    /// one-second bucket jitter (28/29 frames at a 30 fps rung) from restarting recovery forever.
    /// An encoder without a latency trace (nil) does not block the climb.
    static func isClean(_ inputs: LadderInputs, at rung: LadderState,
                        falseLoadRules: Bool = LadderFalseLoadSwitch.isOn, encoderPipelining: Bool = false,
                        keyNeutral: Bool = false) -> Bool {
        guard keepsUp(inputs, at: rung, falseLoadRules: falseLoadRules) else { return false }
        let budget = frameIntervalMs(rung) * (encoderPipelining ? 2 : 1)
        if let latency = inputs.encodeLatencyP90Ms, latency >= budget { return false }
        if isStill(inputs), (inputs.pacerDelayMs ?? 0) > 50, !(keyNeutral && hasUnsolicitedKeyFrame(inputs)) { return false }
        return true
    }

    /// The window carried a key frame the phone did not ask for (session start, size move, restart, or
    /// the 10 s key): at least one key frame and a reported PLI count of zero.
    static func hasUnsolicitedKeyFrame(_ inputs: LadderInputs) -> Bool {
        (inputs.keyFrames ?? 0) >= 1 && inputs.pliReceived == 0
    }

    static func keepsUp(_ inputs: LadderInputs, at rung: LadderState, falseLoadRules: Bool) -> Bool {
        guard let encoded = inputs.encodedFPS, encoded >= 0,
              encoded + 1 >= 0.95 * demandFPS(inputs, at: rung, falseLoadRules: falseLoadRules) else { return false }
        return true
    }

    /// The frames there were to encode: the rung's rate, or fewer when the screen changed less
    /// (ScreenCaptureKit sends no complete frames for a still desktop, so a low encoded rate is not load).
    /// Judged by the frames offered to the encoder (`sourceFPS`): at a 30 fps rung the capture still runs
    /// at 60 and is thinned on the way in, so `captureFPS` overstates the demand by two (1 Oct 2026, .4:
    /// capture 36, source 19, encoded 18 read as a shortfall and stepped 2560 to 1920 px).
    static func demandFPS(_ inputs: LadderInputs, at rung: LadderState,
                          falseLoadRules: Bool = LadderFalseLoadSwitch.isOn) -> Double {
        let offered = falseLoadRules ? inputs.sourceFPS ?? inputs.captureFPS : inputs.captureFPS
        return max(0, min(rungFPS(rung), offered ?? rungFPS(rung)))
    }

    /// The source changed at most once in the window: what went out was the idle refresh, or the one
    /// new-size frame (a key frame) of a ladder move.
    static func isStill(_ inputs: LadderInputs) -> Bool {
        inputs.captureFPS.map { $0 <= 1 } ?? false
    }

    /// The frames the phone had to decode and show: the rung's rate, or fewer when the Mac sent fewer
    /// (24 fps video on a 60 rung leaves 41.7 ms a frame). nil under `phoneMinimumFPS`: a still
    /// screen's refresh is about 1 fps, so the phone's per-window counters are one or two frames,
    /// often a key frame at a new size, and a low presented rate is the Mac's choice. Such a window
    /// is neither phone load nor evidence against a climb.
    static func phoneMeasurableFPS(_ inputs: LadderInputs, at rung: LadderState) -> Double? {
        let delivered = max(0, min(rungFPS(rung), inputs.sentFPS ?? rungFPS(rung)))
        return delivered >= min(phoneMinimumFPS, 0.5 * rungFPS(rung)) ? delivered : nil
    }

    static let phoneMinimumFPS = 10.0

    static func rungFPS(_ rung: LadderState) -> Double { Double(max(1, rung.fps)) }

    static func frameIntervalMs(_ rung: LadderState) -> Double { 1000 / rungFPS(rung) }

    /// `ProcessInfo.ThermalState` as a name ("nominal", "fair", "serious", "critical") or its raw value.
    static func thermalLevel(_ state: String?) -> Int? {
        switch state?.lowercased() ?? "" {
        case "nominal", "0": 0
        case "fair", "1": 1
        case "serious", "2": 2
        case "critical", "3": 3
        default: nil
        }
    }
}

/// Kill switch for the false-load rules (`defaults write <bundle id> PocketDeskLadderFalseLoad -bool NO`,
/// then relaunch the host). Off restores, in the ladder and the busy pill alike: an encoder's first
/// seconds and pre-encode drops inside the frame interval count as load, superseded phone frames
/// count with few presented, a climb no longer needs to fit the faster rung's interval, and the
/// encoder's demand is judged by the capture rate again instead of the frames offered to it.
enum LadderFalseLoadSwitch {
    static let defaultsKey = "PocketDeskLadderFalseLoad"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
}

/// Kill switch for the LAN trust rule (`defaults write <bundle id> PocketDeskLadderLANTrust -bool NO`,
/// then relaunch the host): off, the pacer wait, a low estimate and a bandwidth-limited encoder step
/// the ladder on a proven local link as anywhere else.
enum LadderLANTrustSwitch {
    static let defaultsKey = "PocketDeskLadderLANTrust"
    static let isOn = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
}

/// The floor under the host's bandwidth estimate while the link is trusted (`LANTrustPolicy`): the
/// picture mode's LAN start rate, so a collapsed estimate cannot starve the encoder or queue a key
/// frame for a second. `defaults write <bundle id> PocketDeskLANBitrateFloorKbps -int 0` turns it off,
/// another value replaces the start rate; relaunch the host.
enum LANBitrateFloor {
    static let defaultsKey = "PocketDeskLANBitrateFloorKbps"
    static let override: Int? = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) != nil else { return nil }
        return max(0, min(100_000, defaults.integer(forKey: defaultsKey)))
    }()

    /// nil when switched off.
    static func bps(startBitrateBps: Int) -> Int? {
        let kbps = override ?? startBitrateBps / 1000
        return kbps > 0 ? kbps * 1000 : nil
    }
}

/// Latency item 5 (`StreamTuning.encodingMinBitrateLANKbps`): the video encoding's minimum bitrate while
/// the link is trusted, at most half the picture mode's encoder ceiling (at the ceiling the estimate could
/// never move and congestion control would be off). libwebrtc's congestion-window
/// pushback drops frames before the encoder only while its target is above the encoder minimum, and
/// GoogCC already floors the estimate at the allocated minimum; the explicit estimate floor is raised to
/// it too so the two never disagree.
enum EncodingMinBitrateFloor {
    /// nil while untrusted or with the flag unset.
    static func bps(kbps: Int?, trusted: Bool, ceilingBps: Int) -> Int? {
        guard trusted, let kbps, kbps > 0, ceilingBps > 0 else { return nil }
        return min(kbps * 1000, ceilingBps / 2)
    }

    /// What the sender's encoding carries: nothing in low-data mode, never above the applied ceiling.
    static func senderMinimumBps(floorBps: Int?, ceilingBps: Int, lowData: Bool) -> Int? {
        guard !lowData, let floorBps else { return nil }
        return min(floorBps, ceilingBps / 2)
    }

    /// The estimate floor while trusted: the higher of the `LANBitrateFloor` and the encoding floor.
    static func estimateFloorBps(lanFloorBps: Int?, encodingFloorBps: Int?) -> Int? {
        guard let encodingFloorBps else { return lanFloorBps }
        return max(lanFloorBps ?? 0, encodingFloorBps)
    }
}

/// X17: a send-path cap layered over the G12 ladder. Once per statistics window it reads the pacer
/// delay, the network queue estimate (`SenderQueueEstimate`) and the available outgoing rate, and caps
/// the stream rate first, then size: 30 fps, 15 fps, then 15 fps at 0.75 and 0.5 of the picture. The
/// host runs it in shadow (reported, not applied) unless `StreamTuning.senderQueueGovernorApply`.
/// - A bad window is a saturated link under `capacityKbps` (sending at ≥ 80 % of an estimate below 5 Mb/s
///   that has stopped rising, outside `idleGraceWindows` after an app-limited window) or a queue over
///   `queueLimitMs`. The queue is the pacer delay plus the network term, which is capped at
///   `networkCapMs` unless the pacer itself waits over `networkUncappedPacerMs`, so a stale RTT spike
///   alone never steps. The unsent-backlog estimate is never a trigger.
///   Low capacity alone stops at 15 fps full size, so text stays readable; only a queue that persists
///   at 15 fps costs resolution.
/// - Inactive on a proven local link: no level, reported as "LAN, inactive".
/// - Down one level after `downWindows` bad windows in a row; up one level after `climbWindows` clean
///   windows (estimate ≥ `clearCapacityKbps` or app-limited, and queue under `clearQueueMs`). A climb
///   that is undone within `failedClimbWindows` doubles the wait, up to `maxClimbWindows`.
/// - A size level costs one key frame (the encoder restarts at the new size); size levels are at least
///   `sizeStepSpacing` windows apart, so a move is never a key-frame storm. The governor never asks
///   for a key frame itself.
/// - A route change resets it, and nothing moves in the first `warmupWindows` of a route (the estimate
///   is still ramping). A window with the route still pending keeps the last one.
struct SenderQueueGovernor: Equatable {
    struct Window: Equatable {
        var route: String?
        var availableKbps: Double?
        var sentKbps: Double?
        var senderQueueMs: Double?
        var networkQueueMs: Double?
        var provenLocalLink = false
    }
    struct Level: Equatable {
        var fps: Int?
        var sizeFraction: Double
    }

    static let capacityKbps = 5_000.0
    static let clearCapacityKbps = 6_000.0
    static let saturation = 0.8
    static let queueLimitMs = 100.0
    static let clearQueueMs = 50.0
    static let downWindows = 2
    static let climbWindows = 10
    static let maxClimbWindows = 60
    static let failedClimbWindows = 10
    static let warmupWindows = 3
    static let sizeStepSpacing = 4
    static let levels = [Level(fps: nil, sizeFraction: 1), Level(fps: 30, sizeFraction: 1), Level(fps: 15, sizeFraction: 1),
                         Level(fps: 15, sizeFraction: 0.75), Level(fps: 15, sizeFraction: 0.5)]
    static let capacityFloor = 2
    static let networkCapMs = 50.0
    static let networkUncappedPacerMs = 30.0
    static let plateauRise = 1.05
    static let idleShare = 0.5
    static let idleGraceWindows = 3

    private(set) var level = 0
    /// Level moves that changed the picture size, each one encoder restart and so one key frame.
    private(set) var keyFrameSteps = 0
    private(set) var climbWait = SenderQueueGovernor.climbWindows
    private var route: String?
    private var windows = 0
    private var badWindows = 0
    private var cleanWindows = 0
    private var windowsSinceSizeStep = SenderQueueGovernor.sizeStepSpacing
    private var windowsSinceClimb: Int?
    private var lastAvailableKbps: Double?
    private var windowsSinceIdle: Int?
    private(set) var inactiveOnLocalLink = false
    /// True while the current level was reached because the send queue was building, not because the
    /// link is merely small; only this kind of shedding should pause bulk transfers.
    private(set) var queueShedding = false

    var cap: Level { Self.levels[level] }

    func status(applied: Bool) -> String {
        if inactiveOnLocalLink { return "LAN, inactive" }
        let mode = applied ? "applied" : "shadow, would cap"
        guard level > 0 else { return applied ? "applied, no cap" : "shadow, no cap" }
        let fps = cap.fps.map { "\($0) fps" } ?? "full rate"
        return "\(mode): \(fps)" + (cap.sizeFraction < 1 ? " ×\(String(format: "%g", cap.sizeFraction))" : "")
    }

    /// True when `level` changed.
    mutating func observe(_ window: Window) -> Bool {
        let before = level
        if window.provenLocalLink {
            self = SenderQueueGovernor()
            inactiveOnLocalLink = true
            return level != before
        }
        if inactiveOnLocalLink { self = SenderQueueGovernor() }
        if let next = window.route, next != route {
            if route != nil { self = SenderQueueGovernor() }
            route = next
        }
        windows += 1
        windowsSinceSizeStep += 1
        windowsSinceClimb = windowsSinceClimb.map { $0 + 1 }
        let previousAvailable = lastAvailableKbps
        lastAvailableKbps = window.availableKbps
        let appLimited = window.availableKbps.flatMap { available in
            window.sentKbps.map { available > 0 && $0 < Self.idleShare * available }
        } ?? false
        windowsSinceIdle = appLimited ? 0 : windowsSinceIdle.map { $0 + 1 }
        guard windows > Self.warmupWindows else { return level != before }
        let pacer = max(0, window.senderQueueMs ?? 0)
        let network = min(max(0, window.networkQueueMs ?? 0), pacer > Self.networkUncappedPacerMs ? .infinity : Self.networkCapMs)
        let queue = pacer + network
        let saturated = window.availableKbps.flatMap { available in
            window.sentKbps.map { available > 0 && $0 >= Self.saturation * available }
        } ?? false
        let plateau = window.availableKbps.flatMap { available in
            previousAvailable.map { available <= $0 * Self.plateauRise }
        } ?? false
        let idleGrace = windowsSinceIdle.map { $0 < Self.idleGraceWindows } ?? false
        let lowCapacity = saturated && plateau && !idleGrace && (window.availableKbps ?? .infinity) < Self.capacityKbps
        let queueHigh = queue > Self.queueLimitMs
        if lowCapacity || queueHigh {
            cleanWindows = 0
            badWindows += 1
            let floor = queueHigh ? Self.levels.count - 1 : Self.capacityFloor
            if badWindows >= Self.downWindows, level < floor, move(to: level + 1) {
                queueShedding = queueHigh
                if windowsSinceClimb.map({ $0 <= Self.failedClimbWindows }) ?? false {
                    climbWait = min(climbWait * 2, Self.maxClimbWindows)
                }
                windowsSinceClimb = nil
                badWindows = 0
            }
            return level != before
        }
        badWindows = 0
        let roomy = window.availableKbps.map { available in
            available >= Self.clearCapacityKbps || !saturated
        } ?? true
        guard roomy, queue < Self.clearQueueMs else { cleanWindows = 0; return level != before }
        cleanWindows += 1
        if level > 0, cleanWindows >= climbWait, move(to: level - 1) {
            cleanWindows = 0
            windowsSinceClimb = 0
            if level == 0 { queueShedding = false }
        }
        if let windowsSinceClimb, windowsSinceClimb > Self.failedClimbWindows, level == 0 { climbWait = Self.climbWindows }
        return level != before
    }

    /// The ladder rung with this cap applied: never a higher rate or a larger picture than the ladder's.
    func apply(to state: LadderState) -> LadderState {
        guard level > 0 else { return state }
        var result = state
        result.fps = min(state.fps, cap.fps ?? state.fps)
        result.sizeFraction = min(state.sizeFraction, cap.sizeFraction)
        guard result.fps < state.fps || result.sizeFraction < state.sizeFraction else { return state }
        result.rung = min(16, state.rung + level)
        result.reason = LadderReason.network.rawValue
        return result
    }

    private mutating func move(to next: Int) -> Bool {
        let resizes = Self.levels[next].sizeFraction != Self.levels[level].sizeFraction
        if resizes {
            guard windowsSinceSizeStep >= Self.sizeStepSpacing else { return false }
            windowsSinceSizeStep = 0
            keyFrameSteps += 1
        }
        level = next
        return true
    }
}

/// The honest load pill (BusyState.swift states the contract). `busy` only for persistent trouble:
/// one cause firing at the floor for 5 s (a thermal one at once), or capture behind or encoder
/// latency over two frame intervals for 5 s outside the measured bounded pipeline. It holds
/// through 10 continuous seconds without its
/// cause so intermittent samples do not flicker the warning. A step for load (encoding, capture,
/// network, phone) shows nothing: the ladder heals it within seconds. `strained` is the bounded
/// record of a step for a condition that does not heal by itself, a hot Mac or Low Power Mode.
/// The reason is the cause that persisted, never a different trigger that fired once since. The
/// size shown is `longEdge × sizeFraction`, `longEdge` being the rung-0 picture's.
struct BusyPolicy {
    static let holdSeconds: TimeInterval = 5
    static let clearSeconds: TimeInterval = 10
    static let strainedSeconds: TimeInterval = 8
    static let conditionReasons: Set<String> = [LadderReason.thermal.rawValue, LadderReason.power.rawValue,
                                                LadderReason.phonePower.rawValue]

    private(set) var state = BusyState.ok
    private var targetFPS: Int?
    private var lastRung = 0
    private var steppedDownAt: TimeInterval?
    private var captureBehindSince: TimeInterval?
    private var encodeSlowSince: TimeInterval?
    private var floorSince: [LadderReason: TimeInterval] = [:]
    private var busyAt: TimeInterval?
    private var busyReason: LadderReason?

    mutating func retirePhoneEvidence() {
        floorSince.removeValue(forKey: .phone)
    }

    mutating func evaluate(ladder: LadderState, inputs: LadderInputs, at time: TimeInterval) -> BusyState? {
        evaluate(ladder: ladder, inputs: inputs, longEdge: 0, at: time)
    }

    mutating func evaluate(ladder: LadderState, inputs: LadderInputs, longEdge: Int,
                           at time: TimeInterval) -> BusyState? {
        if targetFPS != inputs.targetFPS {
            let shown = state
            self = BusyPolicy()
            state = shown
            targetFPS = inputs.targetFPS
        }
        if ladder.rung > lastRung { steppedDownAt = time }
        lastRung = ladder.rung
        let floor = LadderPolicy.ladder(targetFPS: inputs.targetFPS).count - 1
        let firing = LadderTrigger.firing(inputs, at: ladder, encoderPipelining: StreamTuning.current.encoderPipelining)
        let atFloor = ladder.rung >= floor
        let floorReasons = atFloor ? Set(firing.map(\.reason)) : []
        floorSince = floorSince.filter { floorReasons.contains($0.key) }
        for reason in floorReasons where floorSince[reason] == nil { floorSince[reason] = time }
        let captureLate = LadderTrigger.captureBehind.fires(inputs, at: ladder)
        let encodeSlow = LadderTrigger.encodeLatency.fires(inputs, at: ladder,
                                                          encoderPipelining: StreamTuning.current.encoderPipelining)
        captureBehindSince = captureLate ? captureBehindSince ?? time : nil
        encodeSlowSince = encodeSlow ? encodeSlowSince ?? time : nil

        let floorHeld = firing.first { trigger in
            atFloor && (!trigger.isPhoneWindow || inputs.phoneSampleState == .fresh)
                && (trigger.isThermal || Self.held(floorSince[trigger.reason], at: time))
        }
        let liveReason: LadderReason? = floorHeld?.reason
            ?? (Self.held(captureBehindSince, at: time) ? .capture : nil)
            ?? (Self.held(encodeSlowSince, at: time) ? .encoding : nil)
        if let liveReason {
            busyAt = time
            busyReason = liveReason
        } else if state.level == .busy, let busyReason, firing.contains(where: {
            $0.reason == busyReason && (!$0.isPhoneWindow || inputs.phoneSampleState == .fresh)
        }) {
            busyAt = time
        }

        let holding = state.level == .busy && busyAt.map({ time - $0 < Self.clearSeconds }) ?? false
        let edge = min(16_384, Int((Double(max(0, longEdge)) * ladder.sizeFraction).rounded()))
        let fps = min(240, max(0, ladder.fps))
        let next: BusyState
        if let reason = liveReason ?? (holding ? busyReason : nil) {
            next = BusyState(level: .busy, fps: fps, longEdge: edge, reason: reason.rawValue)
        } else if ladder.rung > 0, let reason = ladder.reason, Self.conditionReasons.contains(reason),
                  let steppedDownAt, time - steppedDownAt < Self.strainedSeconds {
            next = BusyState(level: .strained, fps: fps, longEdge: edge, reason: reason)
        } else {
            next = .ok
        }
        guard next != state else { return nil }
        state = next
        return next
    }

    private static func held(_ since: TimeInterval?, at time: TimeInterval) -> Bool {
        since.map { time - $0 >= holdSeconds } ?? false
    }
}
