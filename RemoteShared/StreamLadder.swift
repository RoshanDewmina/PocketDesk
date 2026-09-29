import Foundation

/// One rung of the quality ladder (G12, Docs/perf/PLAN-120FPS-AND-LOAD.md §4): the frame rate the
/// Mac captures and sends at, and the fraction of the viewport-matched (or capped) picture size.
/// Rung 0 is the best the session can do; higher rungs cost less. The Mac reports the active rung
/// on `capture` status so the phone and the logs can show it.
struct LadderState: Codable, Equatable {
    var rung: Int
    var fps: Int
    var sizeFraction: Double
    /// Why the ladder moved here: "encode", "capture", "bandwidth", "phone", "thermal", or nil at rung 0.
    var reason: String?

    static let sizeFractions: [Double] = [1.0, 0.75, 0.5]

    /// The rungs for a session whose top rate is `targetFPS`. A frame-rate step needs no key
    /// frame, a size step does, so the order alternates: keep the rate as long as a smaller picture
    /// can carry it, then halve the rate. Policies may pick any rung; the order is the default path.
    static func rungs(targetFPS: Int) -> [LadderState] {
        var rungs: [LadderState] = []
        var rates = [60, 30]
        if targetFPS > 60 { rates.insert(targetFPS, at: 0) }
        for (index, fps) in rates.enumerated() {
            let fractions = index == 0 ? [1.0, 0.75] : index == rates.count - 1 ? [0.75, 0.5] : [1.0, 0.75, 0.5]
            for fraction in fractions {
                rungs.append(LadderState(rung: rungs.count, fps: fps, sizeFraction: fraction, reason: nil))
            }
        }
        return rungs
    }

    func validate() throws {
        guard (0...16).contains(rung), (1...240).contains(fps), sizeFraction.isFinite,
              sizeFraction > 0, sizeFraction <= 1, (reason?.utf8.count ?? 0) <= 24 else { throw RemoteError.invalidMessage }
    }
}

/// What the ladder policy reads once per statistics second. Everything comes from
/// `StreamStatsReport` (host) and the phone's report forwarded on its heartbeat; nil means unknown.
struct LadderInputs: Equatable {
    var targetFPS: Int
    var captureFPS: Double?
    var encodedFPS: Double?
    var encodeLatencyP90Ms: Double?
    var encodeInFlightMax: Int?
    var droppedBeforeEncode: Int?
    var pacerDelayMs: Double?
    var targetKbps: Double?
    var availableKbps: Double?
    var qualityLimitation: String?
    var hostThermalState: String?
    var phoneSupersededPerSecond: Int?
    var phoneDecodeMs: Double?
    var phonePresentedFPS: Double?
    var phoneThermalState: String?

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
