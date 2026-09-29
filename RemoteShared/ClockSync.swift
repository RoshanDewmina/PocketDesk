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

/// Keeps the lowest-round-trip probe of a sliding window; its offset is the estimate and half its
/// round trip the uncertainty (the asymmetry of the path is unknown but bounded by it).
struct ClockSyncEstimator {
    var windowMs: Double = 30_000
    var maximumRoundTripMs: Double = 2_000
    private var samples: [(at: Double, offset: Double, rtt: Double)] = []

    /// Records an echoed probe received by the phone at `t3` (phone ms). False when it is not an
    /// echo or its timing is impossible.
    @discardableResult
    mutating func record(_ echo: ClockProbe, receivedAtPhoneMs t3: Double) -> Bool {
        guard let t1 = echo.hostReceivedMs, let t2 = echo.hostSentMs else { return false }
        let t0 = echo.phoneMs
        let rtt = (t3 - t0) - (t2 - t1)
        guard t3 >= t0, rtt >= 0, rtt <= maximumRoundTripMs else { return false }
        samples.append((at: t3, offset: ((t1 - t0) + (t2 - t3)) / 2, rtt: rtt))
        samples.removeAll { t3 - $0.at > windowMs }
        return true
    }

    func estimate(now: Double) -> ClockSyncEstimate? {
        let live = samples.filter { now - $0.at <= windowMs }
        guard let best = live.min(by: { $0.rtt < $1.rtt }) else { return nil }
        return ClockSyncEstimate(offsetMs: best.offset, uncertaintyMs: best.rtt / 2, samples: live.count)
    }

    mutating func reset() { samples.removeAll() }
}
