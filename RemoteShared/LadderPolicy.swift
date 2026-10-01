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

    func fires(_ inputs: LadderInputs, at rung: LadderState) -> Bool {
        let fps = LadderPolicy.rungFPS(rung)
        let interval = LadderPolicy.frameIntervalMs(rung)
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
            let demand = LadderPolicy.demandFPS(inputs, at: rung)
            return demand >= 0.5 * fps && encoded < 0.8 * demand
        case .encodeLatency:
            return (inputs.encodeLatencyP90Ms ?? 0) > 2 * interval
        case .encodeBacklog:
            return (inputs.encodeInFlightMax ?? 0) >= 3
        case .encodeQueue:
            // Latency grows ~13 ms per frame in flight, so a sustained second frame is a queue forming,
            // but only while frames take longer than the rung's interval. At 30 fps a 17-19 ms 2560 px
            // encode overlaps the next frame now and then with no queue; on the M4 Air that failed every
            // climb to full size within 2 s and backed the ladder off to 60 s (20260930 stream stats).
            guard inputs.encodeInFlightMax == 2 else { return false }
            return inputs.encodeLatencyP90Ms.map { $0 > interval } ?? true
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
            // Network bunching alone supersedes frames too; it counts only with a second phone signal.
            guard let superseded = inputs.phoneSupersededPerSecond else { return false }
            let slowDecode = inputs.phoneDecodeMs.map { $0 > interval } ?? false
            let fewPresented = inputs.phonePresentedFPS.map { $0 < 0.8 * fps } ?? false
            return Double(superseded) > 0.25 * fps && (slowDecode || fewPresented)
        case .phoneDecode:
            return (inputs.phoneDecodeMs ?? 0) > interval
        }
    }

    static func firing(_ inputs: LadderInputs, at rung: LadderState) -> [LadderTrigger] {
        allCases.filter { $0.fires(inputs, at: rung) }
    }
}

/// The G12 ladder (StreamLadder.swift states the contract). Pure and deterministic: one call per
/// statistics sample with a monotonic time, no timers.
/// - Down one rung on the second sample in a row with a load trigger, on the first sample with three
///   frames in flight, or on the first thermal sample but at most one thermal step per 10 s.
/// - Up one rung after `climbWait` clean seconds since the last bad or neutral sample or move, and
///   30 s after a thermal move. A climb that steps down again within 10 s failed: the wait doubles
///   (10, 20, 40, 60 s); it returns to 10 s after 120 s on one rung or a down step with another reason.
/// - Low Power Mode caps the top at the first rung of 60 fps or less (reason `power`), in one move.
/// - A target change restarts at the top of the new ladder.
struct LadderPolicy: LadderEngine {
    static let downSamples = 2
    static let upAfter: TimeInterval = 10
    static let maxClimbWait: TimeInterval = 60
    static let failedClimbWindow: TimeInterval = 10
    static let stableReset: TimeInterval = 120
    static let thermalStepEvery: TimeInterval = 10
    static let thermalUpAfter: TimeInterval = 30
    static let seriousThermalLevel = 2
    static let lowPowerFPS = 60

    private(set) var state: LadderState
    private(set) var targetFPS: Int
    let rungs: [LadderState]
    let lowPowerRung: Int
    private(set) var climbWait = LadderPolicy.upAfter
    private var loadSamples = 0
    private var calmSince: TimeInterval?
    private var lastMoveAt: TimeInterval?
    private var lastClimbAt: TimeInterval?
    private var thermalMoveAt: TimeInterval?
    private var backoffReason: LadderReason?

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
            self = LadderPolicy(targetFPS: inputs.targetFPS)
            calmSince = time
        }
        step(inputs, at: time)
        return state == previous ? nil : state
    }

    private mutating func step(_ inputs: LadderInputs, at time: TimeInterval) {
        if let lastMoveAt, time - lastMoveAt >= Self.stableReset { climbWait = Self.upAfter }
        let lowPower = inputs.hostLowPowerMode == true || inputs.phoneLowPowerMode == true
        let powerReason: LadderReason = inputs.hostLowPowerMode == true ? .power : .phonePower
        if lowPower && state.rung < lowPowerRung {
            move(to: lowPowerRung, reason: powerReason.rawValue, at: time)
            return
        }
        let firing = LadderTrigger.firing(inputs, at: state)
        let thermal = firing.first { $0.isThermal }
        let load = firing.first { !$0.isThermal }
        loadSamples = load == nil ? 0 : loadSamples + 1
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
        guard firing.isEmpty, Self.isClean(inputs, at: state) else {
            calmSince = time
            return
        }
        let top = lowPower ? lowPowerRung : 0
        guard state.rung > top, let calmSince, time - calmSince >= climbWait else { return }
        if let thermalMoveAt, time - thermalMoveAt < Self.thermalUpAfter { return }
        let next = state.rung - 1
        move(to: next, reason: lowPower && next == lowPowerRung ? powerReason.rawValue : state.reason, at: time)
        lastClimbAt = time
    }

    private mutating func stepDown(because reason: LadderReason, at time: TimeInterval) {
        if reason != backoffReason {
            climbWait = Self.upAfter
            backoffReason = reason
        }
        if let lastClimbAt, time - lastClimbAt < Self.failedClimbWindow {
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
        calmSince = time
        lastMoveAt = time
    }

    /// Headroom: no trigger (checked by the caller), the encoder keeps up with what capture
    /// delivered, and its latency fits one frame interval. The one-frame allowance keeps ordinary
    /// one-second bucket jitter (28/29 frames at a 30 fps rung) from restarting recovery forever.
    /// An encoder without a latency trace (nil) does not block the climb.
    static func isClean(_ inputs: LadderInputs, at rung: LadderState) -> Bool {
        guard let encoded = inputs.encodedFPS, encoded >= 0,
              encoded + 1 >= 0.95 * demandFPS(inputs, at: rung) else { return false }
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

/// The honest load pill (BusyState.swift states the contract). `busy` while current pressure keeps
/// firing at the floor, or capture is behind or encoder latency is over two frame intervals for
/// 5 s, and through 10 continuous seconds without a current trigger so intermittent samples do not
/// flicker the warning. `strained` is the bounded record of a recent downward step. The size shown
/// is `longEdge × sizeFraction`, `longEdge` being the rung-0 picture's.
struct BusyPolicy {
    static let holdSeconds: TimeInterval = 5
    static let clearSeconds: TimeInterval = 10
    static let strainedSeconds: TimeInterval = 8

    private(set) var state = BusyState.ok
    private var targetFPS: Int?
    private var lastRung = 0
    private var steppedDownAt: TimeInterval?
    private var captureBehindSince: TimeInterval?
    private var encodeSlowSince: TimeInterval?
    private var floorLoadSamples = 0
    private var busyAt: TimeInterval?
    private var busyReason: LadderReason?

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
        let firing = LadderTrigger.firing(inputs, at: ladder)
        let liveTrigger = firing.first
        let atFloor = ladder.rung >= floor
        floorLoadSamples = atFloor && liveTrigger != nil ? floorLoadSamples + 1 : 0
        let captureLate = LadderTrigger.captureBehind.fires(inputs, at: ladder)
        let encodeSlow = LadderTrigger.encodeLatency.fires(inputs, at: ladder)
        captureBehindSince = captureLate ? captureBehindSince ?? time : nil
        encodeSlowSince = encodeSlow ? encodeSlowSince ?? time : nil

        let captureHeld = Self.held(captureBehindSince, at: time)
        let encodeHeld = Self.held(encodeSlowSince, at: time)
        let floorBusy = atFloor && liveTrigger.map {
            $0.isImmediate || $0.isThermal || floorLoadSamples >= LadderPolicy.downSamples
        } == true
        let liveReason: LadderReason? = floorBusy ? liveTrigger?.reason
            : captureHeld ? .capture
            : encodeHeld ? .encoding
            : nil
        let rawBusy = floorBusy || captureHeld || encodeHeld
        if let currentReason = liveTrigger?.reason ?? liveReason {
            busyAt = time
            busyReason = currentReason
        }

        let level: BusyState.Level
        if rawBusy || (state.level == .busy && busyAt.map({ time - $0 < Self.clearSeconds }) ?? false) {
            level = .busy
        } else if ladder.rung > 0, let steppedDownAt, time - steppedDownAt < Self.strainedSeconds {
            level = .strained
        } else {
            level = .ok
        }

        let next: BusyState
        if level == .ok {
            next = .ok
        } else {
            let reason = (level == .busy ? (liveReason ?? busyReason)?.rawValue : nil)
                ?? (ladder.rung > 0 ? ladder.reason : nil)
                ?? state.reason
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
}
