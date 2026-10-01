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
            // Latency grows ~13 ms per frame in flight, so a sustained second frame is a queue forming.
            return inputs.encodeInFlightMax == 2
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

/// X17: a send-path cap layered over the G12 ladder. Once per statistics window it reads the estimate
/// (`SenderQueueEstimate`) and the available outgoing rate, and caps the stream rate first, then size:
/// 30 fps, 15 fps, then 15 fps at 0.75 and 0.5 of the picture.
/// - A bad window is a saturated link under `capacityKbps` (sending at ≥ 80 % of an estimate below 5 Mb/s;
///   an app-limited still screen is not a bottleneck) or a send + network queue over `queueLimitMs`.
///   Low capacity alone stops at 15 fps full size, so text stays readable; only a queue that persists
///   at 15 fps costs resolution.
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

    var cap: Level { Self.levels[level] }

    /// True when `level` changed.
    mutating func observe(_ window: Window) -> Bool {
        let before = level
        if let next = window.route, next != route {
            if route != nil { self = SenderQueueGovernor() }
            route = next
        }
        windows += 1
        windowsSinceSizeStep += 1
        windowsSinceClimb = windowsSinceClimb.map { $0 + 1 }
        guard windows > Self.warmupWindows else { return level != before }
        let queue = (window.senderQueueMs ?? 0) + (window.networkQueueMs ?? 0)
        let saturated = window.availableKbps.flatMap { available in
            window.sentKbps.map { available > 0 && $0 >= Self.saturation * available }
        } ?? false
        let lowCapacity = saturated && (window.availableKbps ?? .infinity) < Self.capacityKbps
        let queueHigh = queue > Self.queueLimitMs
        if lowCapacity || queueHigh {
            cleanWindows = 0
            badWindows += 1
            let floor = queueHigh ? Self.levels.count - 1 : Self.capacityFloor
            if badWindows >= Self.downWindows, level < floor, move(to: level + 1) {
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
