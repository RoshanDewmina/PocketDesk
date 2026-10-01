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
    /// Per-stats-entry cumulative counters, kept in memory only so stats IDs never reach a log or report.
    var mediaByEntry: [String: UInt64]? = nil
    var fileByEntry: [String: UInt64]? = nil
    private enum CodingKeys: String, CodingKey { case generation, sampledAt, bytesSent, bytesReceived, sentKbps, receivedKbps, coverage }
}

/// Cumulative bytes the selected transport's counters can attribute, both directions, per stats entry:
/// RTP payload and headers of every audio and video stream, and messages on the one-off file channel.
/// The rest of the transport (control, pointer, RTCP, DTLS/SCTP/ICE) is only known as the remainder.
enum TransportByteSplit {
    static func media(_ entries: [StreamStatsEntry]) -> [String: UInt64]? {
        var counts: [String: UInt64] = [:]
        for entry in entries where entry.type == "inbound-rtp" || entry.type == "outbound-rtp" {
            let inbound = entry.type == "inbound-rtp"
            guard let payload = entry.number(inbound ? "bytesReceived" : "bytesSent"),
                  let total = count(payload + (entry.number(inbound ? "headerBytesReceived" : "headerBytesSent") ?? 0)) else { return nil }
            counts[entry.id] = total
        }
        return counts
    }
    static func files(_ entries: [StreamStatsEntry], label: String) -> [String: UInt64]? {
        var counts: [String: UInt64] = [:]
        for entry in entries where entry.type == "data-channel" && entry.string("label") == label {
            guard let sent = entry.number("bytesSent"), let received = entry.number("bytesReceived"),
                  let total = count(sent + received) else { return nil }
            counts[entry.id] = total
        }
        return counts
    }
    /// Growth of entries present in both readings. A new entry starts its own baseline; one that
    /// vanished or restarted contributes nothing for that interval instead of voiding the whole split.
    static func growth(from old: [String: UInt64], to new: [String: UInt64]) -> UInt64 {
        new.reduce(0) { sum, item in
            guard let prior = old[item.key], item.value >= prior else { return sum }
            return sum &+ (item.value - prior)
        }
    }
    private static func count(_ value: Double) -> UInt64? {
        value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 ? UInt64(value.rounded(.towardZero)) : nil
    }
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
