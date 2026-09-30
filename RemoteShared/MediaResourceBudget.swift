import Foundation

/// Conservative bulk admission on the shared association. This does not promise SCTP priority:
/// real simultaneous media/control/file tests remain the final acceptance gate.
struct MediaCapacityObservation {
    var at: TimeInterval
    var route: String
    var capacityKbps: Double?
    var videoKbps: Double?
    var totalTransportKbps: Double? = nil
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
    private var replicatedGuests: (count: Int, at: TimeInterval, kbps: Double?) = (0, 0, 0)

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

    /// Active guest associations share this uplink. Unknown or stale replication pauses bulk files.
    func observeGuests(count: Int, kbps: Double?, at: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        let known = count == 0 || (count > 0 && count <= 2 && at.isFinite && kbps.map { $0.isFinite && $0 >= 0 } == true)
        let previouslyKnown = replicatedGuests.count == 0 || (replicatedGuests.count > 0 && replicatedGuests.count <= 2 &&
            replicatedGuests.at.isFinite && replicatedGuests.kbps.map { $0.isFinite && $0 >= 0 } == true)
        let loadIncreased = count > 0 && kbps.map { $0 > (replicatedGuests.kbps ?? 0) } == true
        if count != replicatedGuests.count || !known || !previouslyKnown || loadIncreased {
            tokens = 0; lastCredit = at
        }
        // A periodic refresh is not new congestion: preserve bounded credit for unchanged zero
        // guests and stable/decreasing known load, so a low-rate 16 KiB chunk can accumulate.
        replicatedGuests = (count, at, kbps)
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
              var observation,
              replicatedGuests.count == 0 || (replicatedGuests.count > 0 && replicatedGuests.count <= 2 &&
                replicatedGuests.at.isFinite && now >= replicatedGuests.at && now - replicatedGuests.at < 2 &&
                replicatedGuests.kbps.map { $0.isFinite && $0 >= 0 } == true)
        else {
            // Congestion/staleness never accumulates a burst that fires when input resumes.
            tokens = 0; lastCredit = now
            return false
        }
        if replicatedGuests.count > 0 {
            // A host guest lane never inherits the receive-only bulk fallback.
            guard observation.capacityKbps != nil, let total = observation.totalTransportKbps, total.isFinite, total >= 0, let kbps = replicatedGuests.kbps else { tokens = 0; lastCredit = now; return false }
            observation.videoKbps = total + kbps
        }
        guard let rate = BulkAdmissionPolicy.bytesPerSecond(observation, at: now, baselineRTT: baselineRTT) else {
            tokens = 0; lastCredit = now; return false
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
