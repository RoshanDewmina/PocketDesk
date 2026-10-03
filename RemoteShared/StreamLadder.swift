import Foundation

/// One rung of the quality ladder (G12, Docs/perf/PLAN-120FPS-AND-LOAD.md §4): the frame rate the
/// Mac captures and sends at, and the fraction of the viewport-matched (or capped) picture size.
/// Rung 0 is the best the session can do; higher rungs cost less. The Mac reports the active rung
/// on `capture` status so the phone and the logs can show it.
struct LadderState: Codable, Equatable {
    var rung: Int
    var fps: Int
    var sizeFraction: Double
    /// Why the ladder moved here (`LadderReason`): "encoding", "capture", "network", "phone", "thermal",
    /// "power", "phonePower", or nil at rung 0.
    var reason: String?

    static let sizeFractions: [Double] = [1.0, 0.75, 0.5]

    /// Rate falls before size. Each step reduces one dimension without increasing the other, so
    /// stepping down under load cannot increase pixel throughput or enlarge an encoded frame.
    static func rungs(targetFPS: Int) -> [LadderState] {
        let top = min(max(targetFPS, 1), 240)
        let steps: [(Int, Double)] = top > 60
            ? [(top, 1), (60, 1), (60, 0.75), (30, 0.75), (30, 0.5)]
            : top > 30
                ? [(top, 1), (30, 1), (30, 0.75), (30, 0.5)]
                : [(top, 1), (top, 0.75), (top, 0.5)]
        return steps.enumerated().map { index, step in
            LadderState(rung: index, fps: step.0, sizeFraction: step.1, reason: nil)
        }
    }

    func validate() throws {
        guard (0...16).contains(rung), (1...240).contains(fps), sizeFraction.isFinite,
              sizeFraction > 0, sizeFraction <= 1, (reason?.utf8.count ?? 0) <= 24 else { throw RemoteError.invalidMessage }
    }
}

/// Optional phone-side load on a heartbeat. An older peer sends no field and leaves these inputs
/// unknown. Values are bounded before transmission and again at the host's protocol boundary.
struct PhoneLoadFeedback: Codable, Equatable {
    var supersededPerSecond: Int?
    var decodeMs: Double?
    var presentedFPS: Double?
    var thermalState: Int?
    var lowPowerMode: Bool?

    init(report: StreamStatsReport) {
        // The heartbeat carries whole frames/s. Never substitute the raw window count when
        // a report has no rate (including older saved reports); its duration is unknown.
        supersededPerSecond = report.supersededPerSecond.flatMap {
            $0.isFinite && (0...1_000).contains($0) ? Int($0) : nil
        }
        decodeMs = report.decodeMs.flatMap { $0.isFinite && (0...1_000).contains($0) ? $0 : nil }
        presentedFPS = report.presentedFPS.flatMap { $0.isFinite && (0...240).contains($0) ? $0 : nil }
        thermalState = report.thermalState.flatMap { (0...3).contains($0) ? $0 : nil }
        lowPowerMode = report.lowPowerMode
    }

    func validate() throws {
        guard supersededPerSecond.map({ (0...1_000).contains($0) }) ?? true,
              decodeMs.map({ $0.isFinite && (0...1_000).contains($0) }) ?? true,
              presentedFPS.map({ $0.isFinite && (0...240).contains($0) }) ?? true,
              thermalState.map({ (0...3).contains($0) }) ?? true else {
            throw RemoteError.invalidMessage
        }
    }
}

/// What the ladder policy reads once per statistics second. Everything comes from
/// `StreamStatsReport` (host) and the phone's report forwarded on its heartbeat; nil means unknown.
struct LadderInputs: Equatable {
    var targetFPS: Int
    var captureFPS: Double?
    /// Display to capture callback, p90: a still screen delivers few frames but on time.
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
    var hostLowPowerMode: Bool?
    var phoneSupersededPerSecond: Int?
    var phoneDecodeMs: Double?
    var phonePresentedFPS: Double?
    var phoneThermalState: String?
    var phoneLowPowerMode: Bool? = nil
    /// Frames the Mac sent in the window, which bounds what the phone could decode and show.
    var sentFPS: Double? = nil
    /// Seconds since the encoder session started: every session start, size move and rate restart
    /// begins a new one with a key frame. nil when the encoder reports none.
    var encoderSessionAgeS: Double? = nil
    /// Frames offered to the encoder in the window, after the rate thinning (a 30 fps rung on a 60 Hz
    /// capture offers half of `captureFPS`). nil on an older report.
    var sourceFPS: Double? = nil
    /// `LANTrustTracker`'s verdict on the link this second (`StreamStatsReport.lanTrusted`, the media layer).
    var lanTrusted = false
    /// Local owned-encoder time at its admission cap / statistics window. No wire field.
    var encodeAtCapShare: Double? = nil

    var frameIntervalMs: Double { 1000 / Double(max(1, targetFPS)) }
}

/// The ladder engine's contract (implemented in LadderPolicy.swift): evaluate the inputs once per
/// second and return the new rung when it changes. Rules the implementation must keep: step down
/// within 2 s of a sustained signal, step up only after 10 s of headroom, never oscillate between
/// two rungs faster than every 10 s, and report the reason of every move.
protocol LadderEngine {
    init(targetFPS: Int)
    var state: LadderState { get }
    mutating func evaluate(_ inputs: LadderInputs, at time: TimeInterval) -> LadderState?
}
