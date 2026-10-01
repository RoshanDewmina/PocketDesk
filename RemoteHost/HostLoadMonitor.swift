import Foundation

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
                  networkQueueMs: report.networkQueueMs, routeDetail: report.routeDetail)
    }
}

/// Runs the ladder and the busy policy on each host statistics sample. Create one per capture
/// session; a change of `targetFPS` inside a session restarts both at the top. With the X17 governor
/// on, the rung applied is the ladder's rung under the governor's send-path cap.
struct HostLoadMonitor {
    static let phoneFeedbackMaxAge: TimeInterval = 2.5
    private(set) var ladder: LadderPolicy
    private(set) var busy = BusyPolicy()
    private(set) var longEdge = 0
    private(set) var governor: SenderQueueGovernor?
    private(set) var applied: LadderState

    init(targetFPS: Int, senderQueueGovernor: Bool = false) {
        ladder = LadderPolicy(targetFPS: targetFPS)
        governor = senderQueueGovernor ? SenderQueueGovernor() : nil
        applied = ladder.state
    }

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
                     phoneLowPowerMode: sample.phoneLoad?.lowPowerMode)
    }

    /// The new rung to apply and the new busy state to send, each nil when unchanged.
    mutating func tick(sample: HostLoadSample, at time: TimeInterval) -> (ladder: LadderState?, busy: BusyState?) {
        if let edge = sample.longEdge, edge > 0 { longEdge = edge }
        let inputs = Self.inputs(from: sample)
        _ = ladder.evaluate(inputs, at: time)
        _ = governor?.observe(SenderQueueGovernor.Window(route: sample.routeDetail, availableKbps: sample.availableKbps,
            sentKbps: sample.sentKbps, senderQueueMs: sample.senderQueueMs, networkQueueMs: sample.networkQueueMs))
        let next = governor?.apply(to: ladder.state) ?? ladder.state
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
