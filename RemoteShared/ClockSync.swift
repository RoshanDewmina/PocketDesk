import Foundation

/// One Cristian round trip carried on a `heartbeat`: the phone stamps `phoneMs`, the host echoes it
/// with its own receive and send times (mach milliseconds, the same clock as the bench marker).
struct ClockProbe: Codable, Equatable {
    var phoneMs: Double
    var hostReceivedMs: Double? = nil
    var hostSentMs: Double? = nil

    var isEcho: Bool { hostReceivedMs != nil && hostSentMs != nil }

    func validate() throws {
        let values = [phoneMs, hostReceivedMs, hostSentMs].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1e13 }),
              (hostReceivedMs == nil) == (hostSentMs == nil),
              (hostSentMs ?? 0) >= (hostReceivedMs ?? 0) else { throw RemoteError.invalidMessage }
    }
}

struct ClockSyncEstimate: Equatable {
    /// Host clock minus phone clock, in ms.
    var offsetMs: Double
    /// Half the round trip of the sample the offset came from.
    var uncertaintyMs: Double
    var samples: Int
}

/// Diagnostic only: the phone's serialization/send time in the calibrated host clock domain.
/// Never used for input freshness, admission, ordering or posting authority.
struct InputSendTiming: Codable, Equatable {
    var sendHostMs: Double
    var uncertaintyMs: Double
    static let maximumClockAgeMs = 30_000.0
    static let maximumUncertaintyMs = 1_000.0
    static let maximumLatencyMs = 30_000.0
    static let disabledDefaultsKey = "PocketDeskInputSendTimingDisabled"

    static func calibrated(phoneMs: Double, estimate: ClockSyncEstimate?, observedAtMs: Double?) -> Self? {
        guard let estimate, let observedAtMs,
              phoneMs.isFinite, observedAtMs.isFinite, (0...1e13).contains(phoneMs), (0...1e13).contains(observedAtMs),
              phoneMs >= observedAtMs, phoneMs - observedAtMs <= maximumClockAgeMs,
              estimate.samples > 0, estimate.offsetMs.isFinite, abs(estimate.offsetMs) <= 1e13 else { return nil }
        let result = Self(sendHostMs: phoneMs + estimate.offsetMs, uncertaintyMs: estimate.uncertaintyMs)
        return result.isValid ? result : nil
    }

    var isValid: Bool {
        sendHostMs.isFinite && (0...1e13).contains(sendHostMs) &&
        uncertaintyMs.isFinite && (0...Self.maximumUncertaintyMs).contains(uncertaintyMs)
    }

    func latency(arrivedHostMs: Double) -> Double? {
        guard isValid, arrivedHostMs.isFinite, (0...1e13).contains(arrivedHostMs) else { return nil }
        let duration = arrivedHostMs - sendHostMs
        // Even negatives within the uncertainty are omitted, rather than counted as synthetic zeros.
        guard (0...Self.maximumLatencyMs).contains(duration) else { return nil }
        return duration
    }
}

/// Keeps the lowest-round-trip probe of a sliding window; its offset is the estimate and half its
/// round trip the uncertainty (the asymmetry of the path is unknown but bounded by it).
struct ClockSyncEstimator {
    var windowMs: Double = 30_000
    var maximumRoundTripMs: Double = 2_000
    static let outstandingLimit = 8
    private var samples: [(at: Double, offset: Double, rtt: Double)] = []
    private var outstanding: [Double] = []

    /// The phone sent a probe stamped `phoneMs`; only an echo of an outstanding probe is recorded.
    mutating func sent(phoneMs: Double) {
        outstanding.append(phoneMs)
        if outstanding.count > Self.outstandingLimit { outstanding.removeFirst(outstanding.count - Self.outstandingLimit) }
    }

    /// Records an echoed probe received by the phone at `t3` (phone ms). False when it is not an
    /// echo, matches no probe this estimator sent, or its timing is impossible.
    @discardableResult
    mutating func record(_ echo: ClockProbe, receivedAtPhoneMs t3: Double) -> Bool {
        guard let t1 = echo.hostReceivedMs, let t2 = echo.hostSentMs else { return false }
        let t0 = echo.phoneMs
        guard let index = outstanding.firstIndex(of: t0) else { return false }
        outstanding.remove(at: index)
        let rtt = (t3 - t0) - (t2 - t1)
        guard t3 >= t0, rtt >= 0, rtt <= maximumRoundTripMs else { return false }
        samples.append((at: t3, offset: ((t1 - t0) + (t2 - t3)) / 2, rtt: rtt))
        samples.removeAll { t3 - $0.at > windowMs }
        return true
    }

    func estimate(now: Double) -> ClockSyncEstimate? { observation(now: now)?.estimate }

    /// The selected lowest-RTT sample's receive time, not the time a cached estimate was read.
    func observation(now: Double) -> (estimate: ClockSyncEstimate, atMs: Double)? {
        guard now.isFinite else { return nil }
        let live = samples.filter { now >= $0.at && now - $0.at <= windowMs }
        guard let best = live.min(by: { $0.rtt < $1.rtt }) else { return nil }
        return (ClockSyncEstimate(offsetMs: best.offset, uncertaintyMs: best.rtt / 2, samples: live.count), best.at)
    }

    mutating func reset() {
        samples.removeAll()
        outstanding.removeAll()
    }
}
