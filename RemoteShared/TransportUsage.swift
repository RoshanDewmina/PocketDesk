import Foundation

/// Public getStats byte coverage for exactly one selected transport. Excludes any IP/UDP/billing inference.
struct TransportUsage: Codable, Equatable, Sendable {
    enum Coverage: String, Codable, Sendable { case selectedTransport }
    let generation: UUID // process-local; transport/candidate IDs stay inside the sampler
    let sampledAt: TimeInterval // monotonic receipt time
    let bytesSent: UInt64?
    let bytesReceived: UInt64?
    let sentKbps: Double?
    let receivedKbps: Double?
    let coverage: Coverage
}
struct TransportUsageSampler {
    private var generation = UUID()
    private var previous: (identity: String, timestamp: Double, sent: UInt64?, received: UInt64?)?
    private func count(_ number: Double?) -> UInt64? {
        guard let number, number.isFinite, number >= 0, number <= 9_007_199_254_740_991, number.rounded(.towardZero) == number else { return nil }
        return UInt64(number)
    }
    mutating func sample(identity: String?, timestamp: Double?, bytesSent: Double?, bytesReceived: Double?, at now: Double) -> TransportUsage? {
        guard let identity, !identity.isEmpty, let timestamp, timestamp.isFinite, now.isFinite else {
            previous = nil; generation = UUID(); return nil
        }
        let sent = count(bytesSent), received = count(bytesReceived)
        guard sent != nil || received != nil else { previous = nil; generation = UUID(); return nil }
        let old = previous
        let reset = old.map { $0.identity != identity || timestamp <= $0.timestamp ||
            (sent != nil && $0.sent != nil && sent! < $0.sent!) ||
            (received != nil && $0.received != nil && received! < $0.received!) } ?? true
        if reset { generation = UUID() }
        previous = (identity, timestamp, sent, received)
        func rate(_ value: UInt64?, _ prior: UInt64?) -> Double? {
            guard !reset, let old, let value, let prior, value >= prior,
                  timestamp - old.timestamp >= 0.25, timestamp - old.timestamp <= 2 else { return nil }
            return Double(value - prior) * 8 / 1000 / (timestamp - old.timestamp)
        }
        return TransportUsage(generation: generation, sampledAt: now, bytesSent: sent, bytesReceived: received,
            sentKbps: rate(sent, old?.sent), receivedKbps: rate(received, old?.received), coverage: .selectedTransport)
    }
}
