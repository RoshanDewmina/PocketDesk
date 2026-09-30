import Foundation

/// Observed total uplink is supplied by the owner association; per-guest GCC estimates are not added.
struct GuestBudgetObservation: Sendable {
    let at: TimeInterval
    let capacityKbps: Double?
    let ownerMediaKbps: Double
    let fileKbps: Double
    let fecKbps: Double
    let guestKbps: [String: Double]
    let controlBufferedBytes: UInt64?
    let rttMs: Double?
    let baselineRTTMs: Double?
    let pacerDelayMs: Double?
}

enum GuestBudgetPolicy {
    static let maximumGuests = 2
    static let maximumDimension = 1280
    static let maximumFPS = 15
    static let maximumKbps: Double = 1_000
    static let freshness: TimeInterval = 2

    static func boundedCeilingKbps(ownerCeiling: Double?, guest: GuestTransportObservation?, at now: TimeInterval) -> Double? {
        guard let ownerCeiling, ownerCeiling.isFinite, ownerCeiling >= 128,
              let guest, now.isFinite, guest.at.isFinite, now >= guest.at, now - guest.at < freshness,
              let rate = guest.totalKbps, rate.isFinite, rate >= 0,
              let capacity = guest.capacityKbps, capacity.isFinite, capacity >= 128 else { return nil }
        return min(maximumKbps, ownerCeiling, capacity)
    }
    static func ceilingKbps(for grantID: String, observation: GuestBudgetObservation, at now: TimeInterval) -> Double? {
        guard now.isFinite, observation.at.isFinite, now >= observation.at, now - observation.at < freshness,
              observation.controlBufferedBytes == 0,
              let capacity = observation.capacityKbps, capacity.isFinite, capacity > 0,
              let rtt = observation.rttMs, rtt.isFinite, rtt >= 0,
              let baseline = observation.baselineRTTMs, baseline.isFinite, baseline >= 0,
              rtt < baseline + max(50, baseline * 0.5),
              let delay = observation.pacerDelayMs, delay.isFinite, delay >= 0, delay < 50,
              observation.guestKbps.count <= maximumGuests,
              [observation.ownerMediaKbps, observation.fileKbps, observation.fecKbps].allSatisfy({ $0.isFinite && $0 >= 0 }),
              observation.guestKbps.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let others = observation.guestKbps.filter { $0.key != grantID }.values.reduce(0, +)
        // Preserve headroom for control, audio bursts/FEC/IDR; unknown capacity always denies guests.
        let residual = capacity * 0.7 - observation.ownerMediaKbps - observation.fileKbps - observation.fecKbps - others - 128
        guard residual >= 128 else { return nil }
        return min(maximumKbps, residual, (capacity * 0.7 - observation.ownerMediaKbps - observation.fileKbps - observation.fecKbps - 128) / Double(max(1, observation.guestKbps.count)))
    }
}

struct GuestTransportObservation: Sendable {
    let at: TimeInterval
    let totalKbps: Double?
    let capacityKbps: Double?
    let rttMs: Double?
    let baselineRTTMs: Double?
    let pacerDelayMs: Double?
    let controlBufferedBytes: UInt64?
}

/// A counter reset or selected-transport change needs two new samples. Never sums GCC capacity.
struct GuestTransportSampler {
    private var previous: (identity: String, timestamp: Double, bytes: Double)?
    private var baselineRTT: Double?
    mutating func sample(identity: String?, timestamp: Double?, bytesSent: Double?, rttMs: Double?) -> (kbps: Double?, baselineRTT: Double?) {
        guard let identity, !identity.isEmpty, let timestamp, timestamp.isFinite,
              let bytesSent, bytesSent.isFinite, bytesSent >= 0 else {
            previous = nil; baselineRTT = nil; return (nil, nil)
        }
        let old = previous
        previous = (identity, timestamp, bytesSent)
        guard let old, old.identity == identity, timestamp > old.timestamp,
              timestamp - old.timestamp >= 0.25, timestamp - old.timestamp <= 2,
              bytesSent >= old.bytes else {
            baselineRTT = nil; return (nil, nil)
        }
        if let rttMs, rttMs.isFinite, rttMs >= 0 { baselineRTT = min(baselineRTT ?? rttMs, rttMs) }
        return ((bytesSent - old.bytes) * 8 / 1000 / (timestamp - old.timestamp), baselineRTT)
    }
}
