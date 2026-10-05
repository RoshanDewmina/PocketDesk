import Foundation

/// Sample on the host's 0.4-second tick, independently of video statistics (which stop while paused).
/// Transitions affect video only; the caller retires capture production on pause and starts a fresh
/// capture generation on resume, preserving the authenticated session and control authority.
struct CriticalThermalPausePolicy {
    enum Transition: Equatable { case pause, resume }
    static let disabledDefaultsKey = "farsideCriticalThermalPauseDisabled"
    static let processStartEnabled = resolveEnabled()
    static let recoveryDuration: TimeInterval = 10
    let enabled: Bool
    private(set) var isPaused = false
    private var coolSince: TimeInterval?
    private var lastSampleTime: TimeInterval?

    init(enabled: Bool = processStartEnabled) {
        self.enabled = enabled
    }

    static func resolveEnabled(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledDefaultsKey)
    }

    mutating func evaluate(thermalState: ProcessInfo.ThermalState, at time: TimeInterval) -> Transition? {
        guard enabled else { return nil }
        if !time.isFinite || lastSampleTime.map({ time < $0 }) == true { coolSince = nil }
        lastSampleTime = time.isFinite ? time : nil
        if thermalState == .critical {
            coolSince = nil
            guard !isPaused else { return nil }
            isPaused = true
            return .pause
        }
        guard isPaused else { return nil }
        guard thermalState == .nominal || thermalState == .fair, time.isFinite else {
            coolSince = nil
            return nil
        }
        guard let coolSince else {
            self.coolSince = time
            return nil
        }
        guard time - coolSince >= Self.recoveryDuration else { return nil }
        isPaused = false
        self.coolSince = nil
        return .resume
    }
}

/// Availability teardown completions belong to their loss generation. A recovery or another
/// loss invalidates older completions, so they cannot suspend a newly recovered sharing attempt.
struct AvailabilityTeardownGeneration {
    static let disabledDefaultsKey = "farsideAvailabilityGenerationDisabled"
    static let processStartEnabled = resolveEnabled()
    let enabled: Bool
    private var generation: UInt64 = 0

    init(enabled: Bool = processStartEnabled) {
        self.enabled = enabled
    }

    static func resolveEnabled(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledDefaultsKey)
    }

    mutating func beginTeardown() -> UInt64 {
        if enabled { generation &+= 1 }
        return generation
    }

    mutating func recover() {
        if enabled { generation &+= 1 }
    }

    func owns(_ token: UInt64) -> Bool {
        !enabled || token == generation
    }
}

/// One statistics second on the Mac, reduced to what the ladder and the busy state read (G12).
/// `longEdge` is the long edge in pixels of the rung-0 picture (the capture size before the ladder's
/// `sizeFraction`); nil keeps the last one. Old phones leave `phoneLoad` nil.
struct HostLoadSample: Equatable {
    var targetFPS: Int
    var longEdge: Int?
    var captureFPS: Double?
    var captureLatencyP90Ms: Double?
    var encodedFPS: Double?
    var encodeLatencyP90Ms: Double?
    var encodeInFlightMax: Int?
    var droppedBeforeEncode: Int?
    var pacerDelayMs: Double?
    var targetKbps: Double?
    var availableKbps: Double?
    var qualityLimitation: String?
    var hostThermalState: String?
    var lowPowerMode: Bool?
    var phoneLoad: PhoneLoadFeedback? = nil
    var sentKbps: Double? = nil
    var senderQueueMs: Double? = nil
    var networkQueueMs: Double? = nil
    var routeDetail: String? = nil
    var provenLocalLink = false
    var sentFPS: Double? = nil
    var encoderSessionAgeS: Double? = nil
    var sourceFPS: Double? = nil
    var lanTrusted = false
    var encodeAtCapShare: Double? = nil
}

extension HostLoadSample {
    /// From the host's own per-second report. Thermal state and Low Power Mode are not in the
    /// report yet, so the caller reads them (`HostLoadMonitor.thermalName`).
    init(report: StreamStatsReport, targetFPS: Int, longEdge: Int?, hostThermalState: String?, lowPowerMode: Bool?) {
        self.init(targetFPS: targetFPS, longEdge: longEdge, captureFPS: report.captureFPS,
                  captureLatencyP90Ms: report.captureLatencyP90Ms, encodedFPS: report.encodedFPS,
                  encodeLatencyP90Ms: report.encodeLatencyP90Ms, encodeInFlightMax: report.encodeInFlightMax,
                  droppedBeforeEncode: report.droppedBeforeEncode, pacerDelayMs: report.pacerDelayMs,
                  targetKbps: report.targetKbps, availableKbps: report.availableOutgoingKbps,
                  qualityLimitation: report.qualityLimitation, hostThermalState: hostThermalState,
                  lowPowerMode: lowPowerMode, sentKbps: report.sentKbps, senderQueueMs: report.senderQueueMs,
                  networkQueueMs: report.networkQueueMs, routeDetail: report.routeDetail, sentFPS: report.sentFPS,
                  encoderSessionAgeS: report.encoderSessionAgeS, sourceFPS: report.sourceFPS,
                  lanTrusted: report.lanTrusted ?? false)
        encodeAtCapShare = report.encodeAtCapShare
    }
}

/// Auxiliary heartbeats carry independent probes, not a statement that phone load is absent.
/// The host owner still checks connected picture authority before offering a message here.
struct HostPhoneLoadInbox {
    private var feedback: PhoneLoadFeedback?
    private var receivedAt: TimeInterval?

    mutating func receive(_ action: RemoteAction, epoch: UInt64, at now: TimeInterval) {
        guard action.isRegularPhoneHeartbeat, action.epoch == epoch else { return }
        feedback = action.phoneLoad
        receivedAt = feedback == nil ? nil : now
    }

    mutating func reset() { feedback = nil; receivedAt = nil }

    func current(at now: TimeInterval) -> PhoneLoadFeedback? {
        HostLoadMonitor.currentPhoneLoad(feedback, receivedAt: receivedAt, now: now)
    }
}

/// Runs the ladder and the busy policy on each host statistics sample. Create one per capture
/// session; a change of `targetFPS` inside a session restarts both at the top. The X17 governor, when
/// computed, runs in shadow (reported only) unless `applyGovernor`; then the rung applied is the
/// ladder's rung under its send-path cap.
struct HostLoadMonitor {
    static let phoneFeedbackMaxAge: TimeInterval = 2.5
    private(set) var ladder: LadderPolicy
    private(set) var busy = BusyPolicy()
    private(set) var longEdge = 0
    private(set) var governor: SenderQueueGovernor?
    let applyGovernor: Bool
    private(set) var applied: LadderState

    init(targetFPS: Int, senderQueueGovernor: Bool = false, applyGovernor: Bool = false) {
        ladder = LadderPolicy(targetFPS: targetFPS)
        governor = senderQueueGovernor ? SenderQueueGovernor() : nil
        self.applyGovernor = senderQueueGovernor && applyGovernor
        applied = ladder.state
    }

    var governorStatus: String { governor?.status(applied: applyGovernor) ?? "off" }
    /// Bulk transfers pause only while an applied governor is actually shedding for a building queue;
    /// shadow mode and a small-link cap never stop files.
    var governorShedding: Bool { applyGovernor && (governor?.level ?? 0) > 0 && governor?.queueShedding == true }

    static func currentPhoneLoad(_ feedback: PhoneLoadFeedback?, receivedAt: TimeInterval?,
                                 now: TimeInterval) -> PhoneLoadFeedback? {
        guard let feedback, let receivedAt, now >= receivedAt,
              now - receivedAt <= phoneFeedbackMaxAge else { return nil }
        return feedback
    }

    static func inputs(from sample: HostLoadSample) -> LadderInputs {
        LadderInputs(targetFPS: sample.targetFPS, captureFPS: sample.captureFPS,
                     captureLatencyP90Ms: sample.captureLatencyP90Ms, encodedFPS: sample.encodedFPS,
                     encodeLatencyP90Ms: sample.encodeLatencyP90Ms, encodeInFlightMax: sample.encodeInFlightMax,
                     droppedBeforeEncode: sample.droppedBeforeEncode, pacerDelayMs: sample.pacerDelayMs,
                     targetKbps: sample.targetKbps, availableKbps: sample.availableKbps,
                     qualityLimitation: sample.qualityLimitation, hostThermalState: sample.hostThermalState,
                     hostLowPowerMode: sample.lowPowerMode,
                     phoneSupersededPerSecond: sample.phoneLoad?.supersededPerSecond,
                     phoneDecodeMs: sample.phoneLoad?.decodeMs,
                     phonePresentedFPS: sample.phoneLoad?.presentedFPS,
                     phoneThermalState: sample.phoneLoad?.thermalState.map(String.init),
                     phoneLowPowerMode: sample.phoneLoad?.lowPowerMode, sentFPS: sample.sentFPS,
                     encoderSessionAgeS: sample.encoderSessionAgeS, sourceFPS: sample.sourceFPS,
                     lanTrusted: sample.lanTrusted, encodeAtCapShare: sample.encodeAtCapShare)
    }

    /// The new rung to apply and the new busy state to send, each nil when unchanged.
    mutating func tick(sample: HostLoadSample, at time: TimeInterval) -> (ladder: LadderState?, busy: BusyState?) {
        if let edge = sample.longEdge, edge > 0 { longEdge = edge }
        let inputs = Self.inputs(from: sample)
        _ = ladder.evaluate(inputs, at: time)
        _ = governor?.observe(SenderQueueGovernor.Window(route: sample.routeDetail, availableKbps: sample.availableKbps,
            sentKbps: sample.sentKbps, senderQueueMs: sample.senderQueueMs, networkQueueMs: sample.networkQueueMs,
            provenLocalLink: sample.provenLocalLink))
        let next = applyGovernor ? governor?.apply(to: ladder.state) ?? ladder.state : ladder.state
        let ladderChange = next == applied ? nil : next
        applied = next
        let busyChange = busy.evaluate(ladder: next, inputs: inputs, longEdge: longEdge, at: time)
        return (ladderChange, busyChange)
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: String(state.rawValue)
        }
    }
}
