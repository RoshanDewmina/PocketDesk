import Foundation

/// First-picture recovery only. Receiving packets or rendering nothing is not sufficient evidence:
/// the negotiated HEVC stream must deliver complete frames continuously without ever decoding one.
struct HEVCDecodeWatchdog {
    enum Codec: String, Equatable {
        case main = "HEVC Main"
        case fullColor444 = "HEVC Main444"

        static func negotiated(mimeType: String?, fmtp: String?) -> Codec? {
            guard mimeType?.lowercased() == "video/h265", let fmtp else { return nil }
            var profile: String?
            for parameter in fmtp.split(separator: ";", omittingEmptySubsequences: true) {
                let parts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty else { return nil }
                if key == "profile-id" {
                    guard profile == nil else { return nil }
                    profile = value
                }
            }
            switch profile {
            case "1": return .main
            case "4": return .fullColor444
            default: return nil
            }
        }
    }

    struct Identity: Equatable {
        let inboundID: String
        let codecID: String
        let codec: Codec
    }

    struct Observation {
        let identity: Identity
        /// The native inbound entry's producer timestamp, not the time a polling callback runs.
        let timestamp: TimeInterval
        let framesReceived: Double
        let framesDecoded: Double

        var isValid: Bool {
            !identity.inboundID.isEmpty && !identity.codecID.isEmpty && timestamp.isFinite && timestamp > 0 &&
                framesReceived.isFinite && framesReceived >= 0 && framesReceived.rounded() == framesReceived &&
                framesDecoded.isFinite && framesDecoded >= 0 && framesDecoded.rounded() == framesDecoded
        }
    }

    static let gracePeriod: TimeInterval = 5
    /// Statistics normally arrive once per second. A long unobserved interval cannot prove continuity.
    static let maximumSampleGap: TimeInterval = 2.5
    private var identity: Identity?
    private var previous: Observation?
    private var receivingSince: TimeInterval?
    private var hasDecoded = false
    private(set) var fired = false

    mutating func observe(_ observation: Observation?) -> Codec? {
        guard !fired else { return nil }
        guard let observation, observation.isValid else {
            previous = nil; receivingSince = nil
            return nil
        }
        if identity != observation.identity {
            identity = observation.identity
            previous = nil; receivingSince = nil; hasDecoded = false
        }
        if let previous, observation.timestamp == previous.timestamp { return nil }
        if observation.framesDecoded > 0 { hasDecoded = true }
        defer { previous = observation }
        guard !hasDecoded, let previous else { receivingSince = nil; return nil }
        let elapsed = observation.timestamp - previous.timestamp
        guard elapsed > 0, elapsed <= Self.maximumSampleGap,
              observation.framesReceived >= previous.framesReceived,
              observation.framesDecoded >= previous.framesDecoded else {
            receivingSince = nil
            return nil
        }
        guard observation.framesReceived > previous.framesReceived else {
            receivingSince = nil
            return nil
        }
        if receivingSince == nil { receivingSince = previous.timestamp }
        guard let receivingSince, observation.timestamp - receivingSince >= Self.gracePeriod else { return nil }
        fired = true // Latch before an outward callback can retire or reenter this peer.
        return observation.identity.codec
    }
}
