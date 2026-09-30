import Foundation

enum CouchTuning {
    static let speed: Double = 1.4
}

enum PhoneControlGate {
    struct Inputs: Equatable {
        var mode: SessionMode = .picture
        var privacyShield = false
        var contentConcealed = false
        var connected = false
        var controlAllowed = false
        var fresh = false
        var captureHealthy = false
        var hostModeIsCouch = false
        var statusAge: TimeInterval = .infinity
        var geometryEpoch: UInt64 = 0
        var nativeInteractionSupported = false
        var hasToken = false
        var tokenAge: TimeInterval = .infinity
    }

    static let couchStatusLimit: TimeInterval = 1

    static func canControl(_ i: Inputs) -> Bool {
        guard !i.privacyShield, !i.contentConcealed, i.connected, i.controlAllowed, i.geometryEpoch > 0 else { return false }
        switch i.mode {
        case .picture:
            return i.fresh && i.captureHealthy && (!i.nativeInteractionSupported || (i.hasToken && i.tokenAge < 1))
        case .couch:
            // No picture: the Mac's own fresh, couch-mode health report stands in for the frame.
            return i.captureHealthy && i.hostModeIsCouch && (0..<couchStatusLimit).contains(i.statusAge)
                && i.nativeInteractionSupported && i.hasToken && (0..<1).contains(i.tokenAge)
        }
    }
}

struct CouchAckWatchdog: Equatable {
    static let limit: TimeInterval = 0.3
    static let capacity = 128

    private struct Sent: Equatable { let ordinal: UInt64; let at: TimeInterval }
    private var pending: [Sent] = []

    var pendingCount: Int { pending.count }

    mutating func sent(ordinal: UInt64, at now: TimeInterval) {
        guard pending.count < Self.capacity else { return }
        pending.append(Sent(ordinal: ordinal, at: now))
    }

    mutating func acknowledged(through applied: UInt64) {
        pending.removeAll { $0.ordinal <= applied }
    }

    func stalled(at now: TimeInterval) -> Bool {
        guard let oldest = pending.first else { return false }
        return now - oldest.at > Self.limit
    }

    mutating func reset() { pending.removeAll() }
}

enum PhoneModeOutcome: Equatable {
    case picture, couch, couchUnsupported
    case refused(SessionModeRefusal)
}

enum PhoneModeResolver {
    static func resolve(requested: SessionMode, features: Set<String>, statusMode: String?, reason: String?) -> PhoneModeOutcome {
        guard features.contains(SessionFeature.couch) else { return requested == .couch ? .couchUnsupported : .picture }
        switch statusMode {
        case SessionMode.couch.rawValue: return .couch
        case SessionModeStatus.refused: return .refused(reason.flatMap(SessionModeRefusal.init(rawValue:)) ?? .notLocal)
        default: return .picture
        }
    }
}
