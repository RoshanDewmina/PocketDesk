import Foundation

/// Conservative bulk admission on the shared association. This does not promise SCTP priority:
/// real simultaneous media/control/file tests remain the final acceptance gate.
struct MediaCapacityObservation {
    var at: TimeInterval
    var route: String
    var capacityKbps: Double?
    var videoKbps: Double?
    var rttMs: Double?
    var pacerDelayMs: Double?
}

enum BulkAdmissionPolicy {
    static let maximumMessageBytes = 16 * 1024
    static let maximumBufferedBytes: UInt64 = 32 * 1024
    static let freshness: TimeInterval = 3
    // Includes room for output audio and control even before audio counters are available.
    static let reservedKbps: Double = 128

    static func bytesPerSecond(_ observation: MediaCapacityObservation, at now: TimeInterval,
                               baselineRTT: Double?) -> Double? {
        guard now.isFinite, observation.at.isFinite, now >= observation.at,
              now - observation.at <= freshness,
              ["Direct", "Relay"].contains(observation.route) else { return nil }
        if let delay = observation.pacerDelayMs,
           !delay.isFinite || delay < 0 || delay >= 50 { return nil }
        if let rtt = observation.rttMs {
            guard rtt.isFinite, rtt >= 0 else { return nil }
            if let baselineRTT, rtt > baselineRTT + max(50, baselineRTT * 0.5) { return nil }
        }
        guard let capacity = observation.capacityKbps else {
            // A receive-only phone may have no GCC estimate. Keep a small bounded fallback;
            // it is not a measured capacity or a bandwidth/performance guarantee.
            return observation.route == "Relay" ? 16_000 : 32_000
        }
        guard capacity.isFinite, capacity > 0 else { return nil }
        let media = observation.videoKbps ?? 0
        guard media.isFinite, media >= 0 else { return nil }
        let spareKbps = capacity - media - reservedKbps
        guard spareKbps > 0 else { return nil }
        let kbps = min(capacity * 0.1, spareKbps * 0.25,
                       observation.route == "Relay" ? 500 : 2_000)
        return kbps * 1_000 / 8
    }
}

/// Thread-safe: stats update on the media thread; file pumping runs on an I/O queue.
final class MediaResourceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: MediaCapacityObservation?
    private var baselineRTT: Double?
    private var tokens: Double = 0
    private var lastCredit: TimeInterval?
    private var ended = false

    func observe(_ next: MediaCapacityObservation) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        if observation?.route != next.route {
            baselineRTT = nil; tokens = 0; lastCredit = next.at
        }
        if let rtt = next.rttMs, rtt.isFinite, rtt >= 0 {
            baselineRTT = min(baselineRTT ?? rtt, rtt)
        }
        observation = next
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        ended = true; observation = nil; tokens = 0; lastCredit = nil
    }

    func permits(bytes: Int, at now: TimeInterval, controlBuffered: UInt64?, fileBuffered: UInt64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, bytes > 0, bytes <= BulkAdmissionPolicy.maximumMessageBytes,
              controlBuffered == 0, let fileBuffered,
              fileBuffered <= BulkAdmissionPolicy.maximumBufferedBytes,
              UInt64(bytes) <= BulkAdmissionPolicy.maximumBufferedBytes - fileBuffered,
              let observation,
              let rate = BulkAdmissionPolicy.bytesPerSecond(observation, at: now, baselineRTT: baselineRTT)
        else {
            // Congestion/staleness never accumulates a burst that fires when input resumes.
            tokens = 0; lastCredit = now
            return false
        }
        guard let previous = lastCredit, now >= previous else {
            tokens = 0; lastCredit = now
            return false
        }
        tokens = min(Double(BulkAdmissionPolicy.maximumMessageBytes), tokens + min(1, now - previous) * rate)
        lastCredit = now
        guard tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        return true
    }
}
