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
    /// Current selected candidate-pair classification, never a configured route or authorization.
    var routeDetail: String? = nil
    /// Bulk bytes this budget itself admitted over the last window. Subtracted from `videoKbps`
    /// only when that figure is the whole transport rate, so a transfer never throttles itself.
    var bulkKbps: Double? = nil
    /// Adaptive allowance learned from this budget's own achieved rate, used only without a
    /// capacity estimate. It is never a capacity estimate and never admits guest replication.
    var probeKbps: Double? = nil
}

/// Off-LAN allowance for a sender with no outbound-video GCC estimate (the receive-only phone).
/// Starts at a conservative floor, ramps while the allowance is actually used and RTT is calm,
/// halves on moderate RTT inflation or a standing file queue.
struct BulkRateProbe: Equatable {
    static let rampFactor = 1.5
    static let rampUtilization = 0.7
    static let jitterFloorMs: Double = 10
    let floorKbps: Double
    let ceilingKbps: Double
    private(set) var kbps: Double

    init(route: String) {
        floorKbps = route == "Relay" ? 384 : 512
        ceilingKbps = route == "Relay" ? 1_500 : 8_000
        kbps = floorKbps
    }

    static func inflated(rttMs: Double?, baselineRTTMs: Double?) -> Bool {
        guard let rttMs, let baselineRTTMs, rttMs.isFinite, baselineRTTMs.isFinite else { return false }
        return rttMs - baselineRTTMs > max(jitterFloorMs, min(50, baselineRTTMs * 0.5))
    }

    mutating func update(achievedKbps: Double?, rttMs: Double?, baselineRTTMs: Double?, standingQueue: Bool) {
        if standingQueue || Self.inflated(rttMs: rttMs, baselineRTTMs: baselineRTTMs) {
            kbps = max(floorKbps, kbps / 2)
        } else if let achievedKbps, achievedKbps.isFinite, achievedKbps >= kbps * Self.rampUtilization,
                  let rttMs, rttMs.isFinite, rttMs >= 0 {
            kbps = min(ceilingKbps, kbps * Self.rampFactor)
        }
    }
}

enum BulkAdmissionPolicy {
    static let maximumMessageBytes = 16 * 1024
    static let maximumBufferedBytes: UInt64 = 32 * 1024
    static let freshness: TimeInterval = 3
    // Includes room for output audio and control even before audio counters are available.
    static let reservedKbps: Double = 128
    static let capacityShare = 0.3
    static let spareShare = 0.5
    static let directCeilingKbps: Double = 16_000
    static let relayCeilingKbps: Double = 1_500
    /// A fresh selected LAN pair with measured low RTT may use a bounded policy allowance on either
    /// side. This is NOT a measured capacity or a throughput guarantee.
    static let lanBytesPerSecond: Double = 1_000_000
    static let creditWindow: TimeInterval = 0.03

    static func bucketBytes(rate: Double) -> Double { max(Double(maximumMessageBytes), rate * creditWindow) }

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
        let relay = observation.route == "Relay"
        let lan = observation.route == "Direct" && observation.routeDetail == "lan"
            && observation.rttMs.map { $0 <= 20 } == true
        guard let capacity = observation.capacityKbps else {
            if lan { return lanBytesPerSecond }
            let probe = BulkRateProbe(route: observation.route)
            let kbps = observation.probeKbps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? probe.floorKbps
            return min(max(kbps, probe.floorKbps), probe.ceilingKbps) * 1_000 / 8
        }
        guard capacity.isFinite, capacity > 0 else { return nil }
        let measured = observation.videoKbps ?? 0
        let bulk = observation.bulkKbps ?? 0
        guard measured.isFinite, measured >= 0, bulk.isFinite, bulk >= 0 else { return nil }
        let spareKbps = capacity - max(0, measured - bulk) - reservedKbps
        // The host's GCC estimate is allocation-limited on a LAN; the pacer and RTT gates above
        // still pause files when video backs up.
        guard spareKbps > 0 else { return lan ? lanBytesPerSecond : nil }
        let kbps = min(capacity * capacityShare, spareKbps * spareShare,
                       relay ? relayCeilingKbps : directCeilingKbps)
        return max(kbps * 1_000 / 8, lan ? lanBytesPerSecond : 0)
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
    private var probe: BulkRateProbe?
    private var windowAdmittedBytes = 0
    private var windowMinimumBuffered: UInt64?

    func observe(_ next: MediaCapacityObservation) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        var next = next
        if let previous = observation, previous.route == next.route, previous.routeDetail == next.routeDetail {
            let elapsed = next.at - previous.at
            let achieved = elapsed > 0 && elapsed <= BulkAdmissionPolicy.freshness
                ? Double(windowAdmittedBytes) * 8 / 1_000 / elapsed : nil
            let standingQueue = windowMinimumBuffered.map { $0 >= UInt64(BulkAdmissionPolicy.maximumMessageBytes) } ?? false
            probe?.update(achievedKbps: achieved, rttMs: next.rttMs, baselineRTTMs: baselineRTT, standingQueue: standingQueue)
            if next.totalTransportKbps != nil { next.bulkKbps = achieved }
        } else {
            baselineRTT = nil; tokens = 0; lastCredit = next.at
            probe = BulkRateProbe(route: next.route)
        }
        windowAdmittedBytes = 0; windowMinimumBuffered = nil
        if let rtt = next.rttMs, rtt.isFinite, rtt >= 0 {
            baselineRTT = min(baselineRTT ?? rtt, rtt)
        }
        next.probeKbps = probe?.kbps
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
        ended = true; observation = nil; tokens = 0; lastCredit = nil; probe = nil
    }

    func permits(bytes: Int, at now: TimeInterval, controlBuffered: UInt64?, fileBuffered: UInt64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        func refuse() -> Bool {
            // Congestion/staleness never accumulates a burst that fires when input resumes.
            tokens = 0; lastCredit = now
            return false
        }
        guard !ended, bytes > 0, bytes <= BulkAdmissionPolicy.maximumMessageBytes,
              let controlBuffered else { return refuse() }
        guard controlBuffered == 0 else {
            // Input always wins: no credit accrues while control is queued, but credit already
            // earned survives the pause instead of restarting the bulk ramp from empty.
            lastCredit = now
            return false
        }
        guard let fileBuffered, var observation,
              replicatedGuests.count == 0 || (replicatedGuests.count > 0 && replicatedGuests.count <= 2 &&
                replicatedGuests.at.isFinite && now >= replicatedGuests.at && now - replicatedGuests.at < 2 &&
                replicatedGuests.kbps.map { $0.isFinite && $0 >= 0 } == true)
        else { return refuse() }
        if replicatedGuests.count > 0 {
            // A host guest lane never inherits the receive-only bulk fallback or probe.
            guard observation.capacityKbps != nil, let total = observation.totalTransportKbps, total.isFinite, total >= 0,
                  let kbps = replicatedGuests.kbps else { return refuse() }
            observation.videoKbps = total + kbps
        }
        guard let rate = BulkAdmissionPolicy.bytesPerSecond(observation, at: now, baselineRTT: baselineRTT),
              let previous = lastCredit, now >= previous else { return refuse() }
        tokens = min(BulkAdmissionPolicy.bucketBytes(rate: rate), tokens + min(1, now - previous) * rate)
        lastCredit = now
        windowMinimumBuffered = min(windowMinimumBuffered ?? fileBuffered, fileBuffered)
        guard fileBuffered <= BulkAdmissionPolicy.maximumBufferedBytes,
              UInt64(bytes) <= BulkAdmissionPolicy.maximumBufferedBytes - fileBuffered,
              tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        windowAdmittedBytes += bytes
        return true
    }
}
