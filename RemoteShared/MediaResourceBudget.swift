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
    /// Mean STUN round trip over the last stats window; `rttMs` is the pair's latest, refreshed only every few seconds.
    var rttSampleMs: Double? = nil
    /// Host: the encoder ceiling actually applied, to tell an allocation-limited estimate from a link limit.
    var senderMaxKbps: Double? = nil
    /// Sender-queue governor (X17). A degraded governor or a deep sender queue stops all bulk admission.
    var senderQueueMs: Double? = nil
    var governorDegraded = false
}

/// Off-LAN allowance for a sender with no outbound-video GCC estimate (the receive-only phone).
/// Ramps while the allowance is used and the per-window RTT is calm; backs off to the achieved
/// rate when the file queue refuses most sends, halves on RTT inflation, decays while idle.
struct BulkRateProbe: Equatable {
    static let rampFactor = 1.5
    static let rampUtilization = 0.7
    static let idleUtilization = 0.1
    static let queueRefusalShare = 0.5
    static let queueBackoff = 0.85
    static let jitterFloorMs: Double = 10
    let startKbps: Double
    let floorKbps: Double
    let ceilingKbps: Double
    private(set) var kbps: Double

    init(route: String) {
        let relay = route == "Relay"
        startKbps = relay ? 384 : 512
        floorKbps = relay ? 128 : 256
        ceilingKbps = relay ? 1_500 : 8_000
        kbps = startKbps
    }

    static func inflated(rttMs: Double?, baselineRTTMs: Double?) -> Bool {
        guard let rttMs, let baselineRTTMs, rttMs.isFinite, baselineRTTMs.isFinite else { return false }
        return rttMs - baselineRTTMs > max(jitterFloorMs, min(50, baselineRTTMs * 0.5))
    }

    /// `standingQueue`: the file queue never drained below half its bound during the window.
    mutating func update(achievedKbps: Double?, rttSampleMs: Double?, baselineRTTMs: Double?,
                         queueRefusedShare: Double, standingQueue: Bool = false) {
        guard let achievedKbps, achievedKbps.isFinite, achievedKbps >= 0 else { return }
        if queueRefusedShare > Self.queueRefusalShare || standingQueue {
            // One halving at most: a window that straddled a transfer's start or end under-reports achieved.
            kbps = min(kbps, max(floorKbps, kbps / 2, achievedKbps * Self.queueBackoff))
            return
        }
        if achievedKbps < kbps * Self.idleUtilization {
            kbps = max(min(startKbps, kbps), kbps / 2)
            return
        }
        guard let rttSampleMs, rttSampleMs.isFinite, rttSampleMs >= 0 else { return }
        if Self.inflated(rttMs: rttSampleMs, baselineRTTMs: baselineRTTMs) {
            kbps = max(floorKbps, kbps / 2)
        } else if achievedKbps >= kbps * Self.rampUtilization {
            kbps = min(ceilingKbps, kbps * Self.rampFactor)
        }
    }
}

enum BulkAdmissionPolicy {
    static let maximumMessageBytes = 16 * 1024
    static let minimumMessageBytes = 2 * 1024
    static let maximumBufferedBytes: UInt64 = 32 * 1024
    static let freshness: TimeInterval = 3
    // Includes room for output audio and control even before audio counters are available.
    static let reservedKbps: Double = 128
    static let capacityShare = 0.3
    static let spareShare = 0.5
    static let directCeilingKbps: Double = 16_000
    static let relayCeilingKbps: Double = 1_500
    /// A fresh selected LAN pair with measured low RTT may use a bounded policy allowance. On the host it
    /// applies only while the estimate is allocation- or app-limited and RTT is calm. NOT a measured capacity.
    static let lanBytesPerSecond: Double = 1_000_000
    static let allocationLimitedShare = 0.8
    static let maximumSenderQueueMs: Double = 100
    static let creditWindow: TimeInterval = 0.03
    static let messageWindow: TimeInterval = 0.05
    /// A legitimate path change (cellular handover) must not leave files paused against an old minimum.
    static let baselineRTTWindow: TimeInterval = 15
    /// DF10 fast lane: on a calm LAN with the video ladder at rung 0, files keep up to 2 MiB queued (Chrome
    /// Remote Desktop keeps 1 MiB) at a bounded allowance. Queued input still pauses admission, and dcSCTP sends
    /// whole messages per stream in turn, so input waits behind at most one file message, not the queue.
    static let fastLaneBufferedBytes: UInt64 = 2 * 1024 * 1024
    static let fastLaneBytesPerSecond: Double = 25_000_000
    static let fastLaneMessageBytes = 64 * 1024
    static let wireOverhead = 1.08
    /// Internal kill switch (no UI): `defaults write <bundle id> farsideFileFastLaneDisabled -bool YES`.
    static let fastLaneDisabledKey = "farsideFileFastLaneDisabled"

    /// RFC 8841: the largest message the peer will take, 0 meaning no limit; nil when the SDP does not say.
    static func maxMessageSize(sdp: String) -> Int? {
        for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=max-message-size:") {
            return Int(line.dropFirst("a=max-message-size:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The same calm LAN that earns the 1 MB/s floor: selected LAN pair, low RTT, a calm window sample and, on the
    /// host, an estimate video is not using. Call only after `bytesPerSecond` admitted the observation.
    static func qualifiesForFastLane(_ observation: MediaCapacityObservation, baselineRTT: Double?) -> Bool {
        guard observation.route == "Direct", observation.routeDetail == "lan",
              observation.rttMs.map({ $0 <= 20 }) == true,
              observation.rttSampleMs.map({ $0 <= 20 && !BulkRateProbe.inflated(rttMs: $0, baselineRTTMs: baselineRTT) }) ?? true
        else { return false }
        guard let capacity = observation.capacityKbps else { return true }
        let media = max(0, (observation.videoKbps ?? 0) - (observation.bulkKbps ?? 0))
        return observation.senderMaxKbps.map { $0.isFinite && $0 > 0 && capacity >= $0 * allocationLimitedShare } == true
            || media <= capacity * allocationLimitedShare
    }

    static func bucketBytes(rate: Double) -> Double { max(Double(maximumMessageBytes), rate * creditWindow) }

    /// Smaller messages at low rates bound how long input can wait behind one file message.
    static func messageBytes(rate: Double) -> Int {
        guard rate.isFinite, rate > 0 else { return maximumMessageBytes }
        return min(maximumMessageBytes, max(minimumMessageBytes, Int(rate * messageWindow)))
    }

    static func bytesPerSecond(_ observation: MediaCapacityObservation, at now: TimeInterval,
                               baselineRTT: Double?) -> Double? {
        guard now.isFinite, observation.at.isFinite, now >= observation.at,
              now - observation.at <= freshness,
              ["Direct", "Relay"].contains(observation.route), !observation.governorDegraded else { return nil }
        if let queue = observation.senderQueueMs,
           !queue.isFinite || queue < 0 || queue >= maximumSenderQueueMs { return nil }
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
            let kbps = observation.probeKbps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? probe.startKbps
            return min(max(kbps, probe.floorKbps), probe.ceilingKbps) * 1_000 / 8
        }
        guard capacity.isFinite, capacity > 0 else { return nil }
        let measured = observation.videoKbps ?? 0
        let bulk = observation.bulkKbps ?? 0
        guard measured.isFinite, measured >= 0, bulk.isFinite, bulk >= 0 else { return nil }
        let media = max(0, measured - bulk)
        // GCC grows only to about 1.5x acknowledged throughput, so an estimate near the encoder ceiling or
        // well above what video uses says nothing about the LAN link. At the edge of Wi-Fi range the
        // estimate falls to what video needs (media near capacity) and the measured formula takes over.
        let calm = observation.rttSampleMs.map { $0 <= 20 && !BulkRateProbe.inflated(rttMs: $0, baselineRTTMs: baselineRTT) } ?? true
        let allocationLimited = observation.senderMaxKbps.map { $0.isFinite && $0 > 0 && capacity >= $0 * allocationLimitedShare } == true
            || media <= capacity * allocationLimitedShare
        let lanFloor = lan && calm && allocationLimited
        let spareKbps = capacity - media - reservedKbps
        guard spareKbps > 0 else { return lanFloor ? lanBytesPerSecond : nil }
        let kbps = min(capacity * capacityShare, spareKbps * spareShare,
                       relay ? relayCeilingKbps : directCeilingKbps)
        return max(kbps * 1_000 / 8, lanFloor ? lanBytesPerSecond : 0)
    }
}

/// Thread-safe: stats update on the media thread; file pumping runs on an I/O queue.
final class MediaResourceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: MediaCapacityObservation?
    private var rttSamples: [(at: TimeInterval, ms: Double)] = []
    private var tokens: Double = 0
    private var lastCredit: TimeInterval?
    private var ended = false
    private var replicatedGuests: (count: Int, at: TimeInterval, kbps: Double?) = (0, 0, 0)
    private var probe: BulkRateProbe?
    private var windowAdmittedBytes = 0
    private var windowAdmittedSends = 0
    private var windowQueueRefusals = 0
    private var windowMinimumBuffered: UInt64?
    private var windowStartBuffered: UInt64 = 0
    private var lastBuffered: UInt64?
    private let fastLaneEnabled: Bool
    private var ladderSteppedDown = false
    private var peerTakesLargeMessages = false

    init(fastLane: Bool = !UserDefaults.standard.bool(forKey: BulkAdmissionPolicy.fastLaneDisabledKey)) {
        fastLaneEnabled = fastLane
    }

    private var baselineRTT: Double? { rttSamples.map(\.ms).min() }

    func observe(_ next: MediaCapacityObservation) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        var next = next
        if let previous = observation, previous.route == next.route, previous.routeDetail == next.routeDetail {
            let elapsed = next.at - previous.at
            // Bytes that left the file queue, not bytes admitted into it: the 32 KiB queue would
            // otherwise hide a link slower than the allowance for a whole window.
            let drained = max(0, Double(windowAdmittedBytes) + Double(windowStartBuffered) - Double(lastBuffered ?? 0))
            let achieved = elapsed > 0 && elapsed <= BulkAdmissionPolicy.freshness ? drained * 8 / 1_000 / elapsed : nil
            let attempts = windowAdmittedSends + windowQueueRefusals
            let refused = attempts > 0 ? Double(windowQueueRefusals) / Double(attempts) : 0
            let standing = windowMinimumBuffered.map { $0 >= BulkAdmissionPolicy.maximumBufferedBytes / 2 } ?? false
            probe?.update(achievedKbps: achieved, rttSampleMs: next.rttSampleMs, baselineRTTMs: baselineRTT,
                          queueRefusedShare: refused, standingQueue: standing)
            // Transport bytes include each file packet's SCTP/DTLS/UDP/IP headers (~8% at full packets); without them
            // a fast-lane transfer reads as video in `videoKbps - bulkKbps` and pauses itself on the host.
            if next.totalTransportKbps != nil { next.bulkKbps = achieved.map { $0 * BulkAdmissionPolicy.wireOverhead } }
        } else {
            rttSamples = []; tokens = 0; lastCredit = next.at; lastBuffered = nil
            probe = BulkRateProbe(route: next.route)
        }
        if windowMinimumBuffered == nil { lastBuffered = nil } // An idle window says nothing about the queue now.
        windowAdmittedBytes = 0; windowAdmittedSends = 0; windowQueueRefusals = 0; windowMinimumBuffered = nil
        windowStartBuffered = lastBuffered ?? 0
        rttSamples.removeAll { !(next.at - $0.at < BulkAdmissionPolicy.baselineRTTWindow) }
        for rtt in [next.rttMs, next.rttSampleMs].compactMap({ $0 }) where rtt.isFinite && rtt >= 0 {
            rttSamples.append((next.at, rtt))
        }
        next.probeKbps = probe?.kbps
        observation = next
    }

    var probedKbps: Double? {
        lock.lock(); defer { lock.unlock() }
        return probe?.kbps
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

    /// Any rung below 0 (this host's own ladder, or the Mac's as reported to the phone) backs files off.
    func observeLadder(steppedDown: Bool) {
        lock.lock(); defer { lock.unlock() }
        ladderSteppedDown = steppedDown
    }

    func observePeerMaxMessageSize(_ bytes: Int?) {
        lock.lock(); defer { lock.unlock() }
        peerTakesLargeMessages = bytes.map { $0 == 0 || $0 >= BulkAdmissionPolicy.fastLaneMessageBytes } ?? false
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        ended = true; observation = nil; tokens = 0; lastCredit = nil; probe = nil
    }

    func messageBytes(at now: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        if fastLane(at: now), peerTakesLargeMessages { return BulkAdmissionPolicy.fastLaneMessageBytes }
        return BulkAdmissionPolicy.messageBytes(rate: admissionRate(at: now) ?? 0)
    }

    func queueBytes(at now: TimeInterval) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return fastLane(at: now) ? BulkAdmissionPolicy.fastLaneBufferedBytes : BulkAdmissionPolicy.maximumBufferedBytes
    }

    private func fastLane(at now: TimeInterval) -> Bool {
        guard fastLaneEnabled, !ladderSteppedDown, replicatedGuests.count == 0, let observation,
              admissionRate(at: now) != nil else { return false }
        return BulkAdmissionPolicy.qualifiesForFastLane(observation, baselineRTT: baselineRTT)
    }

    private func admissionRate(at now: TimeInterval) -> Double? {
        guard !ended, var observation,
              replicatedGuests.count == 0 || (replicatedGuests.count > 0 && replicatedGuests.count <= 2 &&
                replicatedGuests.at.isFinite && now >= replicatedGuests.at && now - replicatedGuests.at < 2 &&
                replicatedGuests.kbps.map { $0.isFinite && $0 >= 0 } == true) else { return nil }
        if replicatedGuests.count > 0 {
            // A host guest lane never inherits the receive-only bulk fallback or probe.
            guard observation.capacityKbps != nil, let total = observation.totalTransportKbps, total.isFinite, total >= 0,
                  let kbps = replicatedGuests.kbps else { return nil }
            observation.videoKbps = total + kbps
        }
        return BulkAdmissionPolicy.bytesPerSecond(observation, at: now, baselineRTT: baselineRTT)
    }

    /// `inputBuffered` is every input channel's queue (control and pointer); any queued input pauses bulk.
    func permits(bytes: Int, at now: TimeInterval, controlBuffered inputBuffered: UInt64?, fileBuffered: UInt64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        func refuse() -> Bool {
            // Congestion/staleness never accumulates a burst that fires when input resumes.
            tokens = 0; lastCredit = now
            return false
        }
        let fast = fastLane(at: now)
        let maximumBytes = fast && peerTakesLargeMessages ? BulkAdmissionPolicy.fastLaneMessageBytes : BulkAdmissionPolicy.maximumMessageBytes
        let maximumBuffered = fast ? BulkAdmissionPolicy.fastLaneBufferedBytes : BulkAdmissionPolicy.maximumBufferedBytes
        guard bytes > 0, bytes <= maximumBytes, let inputBuffered, let fileBuffered,
              let measured = admissionRate(at: now), let previous = lastCredit, now >= previous else { return refuse() }
        let rate = fast ? max(measured, BulkAdmissionPolicy.fastLaneBytesPerSecond) : measured
        guard inputBuffered == 0 else {
            // Input always wins: no credit accrues while input is queued, but credit already
            // earned survives the pause instead of restarting the bulk ramp from empty.
            lastCredit = now
            return false
        }
        tokens = min(BulkAdmissionPolicy.bucketBytes(rate: rate), tokens + min(1, now - previous) * rate)
        lastCredit = now
        windowMinimumBuffered = min(windowMinimumBuffered ?? fileBuffered, fileBuffered)
        lastBuffered = fileBuffered
        guard tokens >= Double(bytes) else { return false }
        guard fileBuffered <= maximumBuffered, UInt64(bytes) <= maximumBuffered - fileBuffered else {
            windowQueueRefusals += 1
            return false
        }
        tokens -= Double(bytes)
        windowAdmittedBytes += bytes; windowAdmittedSends += 1
        return true
    }
}
