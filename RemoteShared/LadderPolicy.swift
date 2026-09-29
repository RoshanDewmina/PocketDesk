import Foundation

/// The user-facing causes a ladder move or a busy state can carry (`LadderState.reason`, `BusyState.reason`).
enum LadderReason: String, CaseIterable {
    case thermal, capture, encoding, network, phone
}

/// One per-second signal that steps the ladder down, in priority order: when several fire in one
/// sample, the first one's reason is the move's reason. Frame-rate and interval thresholds are
/// relative to the rung the stream runs at now, not the session's target, so a stream already
/// stepped to 60 is judged against 16.7 ms and 60 fps.
enum LadderTrigger: CaseIterable {
    case hostThermal, phoneThermal, captureBehind, encodeShortfall, encodeLatency, encodeBacklog,
         droppedBeforeEncode, cpuLimited, pacerDelay, lowEstimate, bandwidthLimited, phoneSuperseded, phoneDecode

    var reason: LadderReason {
        switch self {
        case .hostThermal: .thermal
        case .captureBehind: .capture
        case .encodeShortfall, .encodeLatency, .encodeBacklog, .droppedBeforeEncode, .cpuLimited: .encoding
        case .pacerDelay, .lowEstimate, .bandwidthLimited: .network
        // A hot phone is the phone's limit; "thermal" alone would read as the Mac's.
        case .phoneThermal, .phoneSuperseded, .phoneDecode: .phone
        }
    }

    /// Thermal triggers step on their first sample; the rest need two in a row.
    var isThermal: Bool { self == .hostThermal || self == .phoneThermal }

    func fires(_ inputs: LadderInputs, at rung: LadderState, captureLatencyP90Ms: Double? = nil) -> Bool {
        let fps = LadderPolicy.rungFPS(rung)
        let interval = LadderPolicy.frameIntervalMs(rung)
        switch self {
        case .hostThermal:
            return (LadderPolicy.thermalLevel(inputs.hostThermalState) ?? 0) >= LadderPolicy.seriousThermalLevel
        case .phoneThermal:
            return (LadderPolicy.thermalLevel(inputs.phoneThermalState) ?? 0) >= LadderPolicy.seriousThermalLevel
        case .captureBehind:
            // A still screen also delivers few frames, but on time; only late frames mean a busy Mac.
            guard let capture = inputs.captureFPS, let latency = captureLatencyP90Ms else { return false }
            return capture < 0.8 * fps && latency > interval
        case .encodeShortfall:
            guard let encoded = inputs.encodedFPS else { return false }
            let demand = LadderPolicy.demandFPS(inputs, at: rung)
            return demand >= 0.5 * fps && encoded < 0.8 * demand
        case .encodeLatency:
            return (inputs.encodeLatencyP90Ms ?? 0) > 2 * interval
        case .encodeBacklog:
            return (inputs.encodeInFlightMax ?? 0) >= 3
        case .droppedBeforeEncode:
            return Double(inputs.droppedBeforeEncode ?? 0) > 0.05 * fps
        case .cpuLimited:
            return inputs.qualityLimitation?.lowercased() == "cpu"
        case .pacerDelay:
            return (inputs.pacerDelayMs ?? 0) > 50
        case .lowEstimate:
            guard let available = inputs.availableKbps, let target = inputs.targetKbps, target > 0 else { return false }
            return available < 0.6 * target
        case .bandwidthLimited:
            return inputs.qualityLimitation?.lowercased() == "bandwidth"
        case .phoneSuperseded:
            return Double(inputs.phoneSupersededPerSecond ?? 0) > 0.1 * fps
        case .phoneDecode:
            return (inputs.phoneDecodeMs ?? 0) > interval
        }
    }

    static func firing(_ inputs: LadderInputs, at rung: LadderState,
                       captureLatencyP90Ms: Double? = nil) -> [LadderTrigger] {
        allCases.filter { $0.fires(inputs, at: rung, captureLatencyP90Ms: captureLatencyP90Ms) }
    }
}

/// The G12 ladder (StreamLadder.swift states the contract). Pure and deterministic: one call per
/// statistics sample with a monotonic time, no timers. Down: one rung on the second bad sample in a
/// row (the first for thermal). Up: one rung once the stream has been clean for 10 s since the last
/// bad or neutral sample or move, and 30 s after a thermal move. A target change restarts at the top.
struct LadderPolicy: LadderEngine {
    static let downSamples = 2
    static let upAfter: TimeInterval = 10
    static let thermalUpAfter: TimeInterval = 30
    static let seriousThermalLevel = 2

    private(set) var state: LadderState
    private(set) var targetFPS: Int
    let rungs: [LadderState]
    private var badSamples = 0
    private var calmSince: TimeInterval?
    private var thermalMoveAt: TimeInterval?

    init(targetFPS: Int) {
        self.targetFPS = targetFPS
        rungs = Self.ladder(targetFPS: targetFPS)
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
        evaluate(inputs, captureLatencyP90Ms: nil, at: time)
    }

    /// `captureLatencyP90Ms` (display to capture callback) is not in `LadderInputs`; without it the
    /// capture trigger stays off.
    mutating func evaluate(_ inputs: LadderInputs, captureLatencyP90Ms: Double?,
                           at time: TimeInterval) -> LadderState? {
        if inputs.targetFPS != targetFPS {
            let previous = state
            self = LadderPolicy(targetFPS: inputs.targetFPS)
            calmSince = time
            return state == previous ? nil : state
        }
        if let trigger = LadderTrigger.firing(inputs, at: state, captureLatencyP90Ms: captureLatencyP90Ms).first {
            badSamples += 1
            calmSince = time
            guard trigger.isThermal || badSamples >= Self.downSamples, state.rung < rungs.count - 1 else { return nil }
            if trigger.isThermal { thermalMoveAt = time }
            return move(to: state.rung + 1, reason: trigger.reason.rawValue, at: time)
        }
        badSamples = 0
        guard Self.isClean(inputs, at: state) else {
            calmSince = time
            return nil
        }
        guard state.rung > 0, let calmSince, time - calmSince >= Self.upAfter else { return nil }
        if let thermalMoveAt, time - thermalMoveAt < Self.thermalUpAfter { return nil }
        return move(to: state.rung - 1, reason: state.reason, at: time)
    }

    private mutating func move(to index: Int, reason: String?, at time: TimeInterval) -> LadderState {
        var next = rungs[index]
        next.reason = index == 0 ? nil : reason
        state = next
        badSamples = 0
        calmSince = time
        return next
    }

    /// Headroom: no trigger (checked by the caller), the encoder keeps up with what capture
    /// delivered, and its latency fits one frame interval. An encoder without a latency trace
    /// (nil) does not block the climb.
    static func isClean(_ inputs: LadderInputs, at rung: LadderState) -> Bool {
        guard let encoded = inputs.encodedFPS, encoded >= 0.95 * demandFPS(inputs, at: rung) else { return false }
        if let latency = inputs.encodeLatencyP90Ms, latency >= frameIntervalMs(rung) { return false }
        return true
    }

    /// The frames there were to encode: the rung's rate, or fewer when the screen changed less
    /// (ScreenCaptureKit sends no complete frames for a still desktop, so a low encoded rate is not load).
    static func demandFPS(_ inputs: LadderInputs, at rung: LadderState) -> Double {
        max(0, min(rungFPS(rung), inputs.captureFPS ?? rungFPS(rung)))
    }

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

/// The honest load pill (BusyState.swift states the contract). `busy`: the ladder at its floor, or
/// capture behind or encoder latency over two frame intervals for 5 s; `strained`: the ladder below
/// its top for 5 s; each level clears only after 10 s without its condition. The size shown is
/// `longEdge × sizeFraction`, where `longEdge` is the long edge of the rung-0 picture.
struct BusyPolicy {
    static let holdSeconds: TimeInterval = 5
    static let clearSeconds: TimeInterval = 10

    private(set) var state = BusyState.ok
    private var targetFPS: Int?
    private var belowTopSince: TimeInterval?
    private var captureBehindSince: TimeInterval?
    private var encodeSlowSince: TimeInterval?
    private var busyAt: TimeInterval?
    private var strainedAt: TimeInterval?

    mutating func evaluate(ladder: LadderState, inputs: LadderInputs, at time: TimeInterval) -> BusyState? {
        evaluate(ladder: ladder, inputs: inputs, longEdge: 0, captureLatencyP90Ms: nil, at: time)
    }

    mutating func evaluate(ladder: LadderState, inputs: LadderInputs, longEdge: Int, captureLatencyP90Ms: Double?,
                           at time: TimeInterval) -> BusyState? {
        if targetFPS != inputs.targetFPS {
            let shown = state
            self = BusyPolicy()
            state = shown
            targetFPS = inputs.targetFPS
        }
        let floor = LadderPolicy.ladder(targetFPS: inputs.targetFPS).count - 1
        let captureLate = LadderTrigger.captureBehind.fires(inputs, at: ladder,
                                                            captureLatencyP90Ms: captureLatencyP90Ms)
        let encodeSlow = LadderTrigger.encodeLatency.fires(inputs, at: ladder)
        belowTopSince = ladder.rung > 0 ? belowTopSince ?? time : nil
        captureBehindSince = captureLate ? captureBehindSince ?? time : nil
        encodeSlowSince = encodeSlow ? encodeSlowSince ?? time : nil

        let captureHeld = Self.held(captureBehindSince, at: time)
        let encodeHeld = Self.held(encodeSlowSince, at: time)
        let rawBusy = ladder.rung >= floor || captureHeld || encodeHeld
        let rawStrained = rawBusy || Self.held(belowTopSince, at: time)
        if rawBusy { busyAt = time }
        if rawStrained { strainedAt = time }

        let level: BusyState.Level
        if rawBusy || (state.level == .busy && Self.recent(busyAt, at: time)) {
            level = .busy
        } else if rawStrained || (state.level != .ok && Self.recent(strainedAt, at: time)) {
            level = .strained
        } else {
            level = .ok
        }

        let next: BusyState
        if level == .ok {
            next = .ok
        } else {
            let trigger: LadderReason? = captureHeld ? .capture : encodeHeld ? .encoding : nil
            let reason = (ladder.rung > 0 ? ladder.reason : nil) ?? trigger?.rawValue ?? state.reason
            let edge = Int((Double(max(0, longEdge)) * ladder.sizeFraction).rounded())
            next = BusyState(level: level, fps: min(240, max(0, ladder.fps)), longEdge: min(16_384, edge),
                             reason: reason)
        }
        guard next != state else { return nil }
        state = next
        return next
    }

    private static func held(_ since: TimeInterval?, at time: TimeInterval) -> Bool {
        since.map { time - $0 >= holdSeconds } ?? false
    }

    private static func recent(_ last: TimeInterval?, at time: TimeInterval) -> Bool {
        last.map { time - $0 < clearSeconds } ?? false
    }
}
