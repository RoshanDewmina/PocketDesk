import Foundation

/// Exact capture identity and host stages carried inside that compressed access unit.
/// This is software timing; it never measures panel scanout, network handoff or photon latency.
struct ExactVideoTiming: Codable, Equatable {
    let sourceID: String
    let displayMs: Double
    let capturedMs: Double
    let pushedMs: Double
    var submittedMs: Double
    var encodedMs: Double
    let resend: Bool

    func validate() throws {
        let times = [displayMs, capturedMs, pushedMs, submittedMs, encodedMs]
        guard InputCausalEnvelope.validID(sourceID), times.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1e13 }),
              displayMs <= capturedMs, capturedMs <= pushedMs, pushedMs <= submittedMs, submittedMs <= encodedMs,
              encodedMs - displayMs <= 10_000 else { throw RemoteError.invalidMessage }
    }
}

/// No pixels retained. Only successful exact decoder output and original public drawable presentation
/// contribute; redraw/interpolation, idle resend and missing/stale clock mapping cannot pass cadence.
final class ExactVideoTimingReceiver: @unchecked Sendable {
    struct Drain: Equatable {
        var decoded = 0
        var presented = 0
        var uniqueSources = 0
        var resends = 0
        var timed = 0
        var missingClock = 0
        var captureToDecodeP50Ms: Double?
        var captureToDecodeP95Ms: Double?
        var captureToPresentP50Ms: Double?
        var captureToPresentP95Ms: Double?
        var maximumClockUncertaintyMs: Double?
    }
    private struct Pending {
        let timing: ExactVideoTiming
        let decodedMs: Double
    }
    static let maximumPending = 128
    static let maximumSeen = 512
    static let maximumClockAgeMs = 30_000.0
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var seen: [String] = []
    private var sources: [String] = []
    private var result = Drain()
    private var decode = LatencyWindow()
    private var present = LatencyWindow()

    private func key(_ generation: String, _ nonce: String) -> String? {
        guard InputCausalEnvelope.validID(generation), InputCausalEnvelope.validID(nonce) else { return nil }
        return generation + nonce
    }
    func decoded(_ timing: ExactVideoTiming, generation: String, nonce: String, atMs: Double) {
        guard (try? timing.validate()) != nil, let key = key(generation, nonce), atMs.isFinite, atMs > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !seen.contains(key), pending[key] == nil else { return }
        if pending.count >= Self.maximumPending, let oldest = pending.min(by: { $0.value.decodedMs < $1.value.decodedMs })?.key { pending.removeValue(forKey: oldest) }
        pending[key] = Pending(timing: timing, decodedMs: atMs)
        result.decoded += 1
    }
    func presented(_ timing: ExactVideoTiming, generation: String, nonce: String, atMs: Double,
                   clock: ClockSyncEstimate?, clockRecordedAtMs: Double?, nowMs: Double) {
        guard let key = key(generation, nonce), atMs.isFinite, atMs > 0, nowMs.isFinite, nowMs >= atMs else { return }
        lock.lock(); defer { lock.unlock() }
        guard let output = pending.removeValue(forKey: key), output.timing == timing,
              atMs >= output.decodedMs, atMs - output.decodedMs <= 5_000, !seen.contains(key) else { return }
        seen.append(key); if seen.count > Self.maximumSeen { seen.removeFirst() }
        result.presented += 1
        if timing.resend { result.resends += 1; return }
        if !sources.contains(timing.sourceID) {
            sources.append(timing.sourceID); if sources.count > Self.maximumSeen { sources.removeFirst() }
            result.uniqueSources += 1
        }
        guard let clock, let recorded = clockRecordedAtMs, recorded.isFinite, recorded > 0,
              nowMs >= recorded, nowMs - recorded <= Self.maximumClockAgeMs,
              clock.samples > 0, clock.offsetMs.isFinite, clock.uncertaintyMs.isFinite, clock.uncertaintyMs >= 0 else {
            result.missingClock += 1; return
        }
        let decodedMs = output.decodedMs + clock.offsetMs - timing.displayMs
        let presentedMs = atMs + clock.offsetMs - timing.displayMs
        // Keep uncertainty visible; a point estimate below zero is not a plausible measured latency.
        guard decodedMs.isFinite, presentedMs.isFinite, decodedMs >= 0, presentedMs >= decodedMs,
              presentedMs <= 10_000 else { result.missingClock += 1; return }
        decode.record(decodedMs); present.record(presentedMs); result.timed += 1
        result.maximumClockUncertaintyMs = max(result.maximumClockUncertaintyMs ?? 0, clock.uncertaintyMs)
    }
    func drain() -> Drain {
        lock.lock(); defer { lock.unlock() }
        let d = decode.drainPercentiles(), p = present.drainPercentiles()
        result.captureToDecodeP50Ms = d.p50; result.captureToDecodeP95Ms = d.p95
        result.captureToPresentP50Ms = p.p50; result.captureToPresentP95Ms = p.p95
        defer { result = Drain() }
        return result
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(); seen.removeAll(); sources.removeAll(); result = Drain()
        _ = decode.drainPercentiles(); _ = present.drainPercentiles()
    }
}
