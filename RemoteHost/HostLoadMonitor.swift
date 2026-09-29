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
                  lowPowerMode: lowPowerMode)
    }
}

/// Runs the ladder and the busy policy on each host statistics sample. Create one per capture
/// session; a change of `targetFPS` inside a session restarts both at the top.
struct HostLoadMonitor {
    static let phoneFeedbackMaxAge: TimeInterval = 2.5
    private(set) var ladder: LadderPolicy
    private(set) var busy = BusyPolicy()
    private(set) var longEdge = 0

    init(targetFPS: Int) {
        ladder = LadderPolicy(targetFPS: targetFPS)
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
        let ladderChange = ladder.evaluate(inputs, at: time)
        let busyChange = busy.evaluate(ladder: ladder.state, inputs: inputs, longEdge: longEdge, at: time)
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
