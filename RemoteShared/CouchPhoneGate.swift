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

    static func canControl(_ inputs: Inputs) -> Bool { false }
}

struct CouchAckWatchdog: Equatable {
    static let limit: TimeInterval = 0.3
    static let capacity = 128

    var pendingCount: Int { 0 }
    mutating func sent(ordinal: UInt64, at now: TimeInterval) {}
    mutating func acknowledged(through applied: UInt64) {}
    func stalled(at now: TimeInterval) -> Bool { false }
    mutating func reset() {}
}

enum PhoneModeOutcome: Equatable {
    case picture, couch, couchUnsupported
    case refused(SessionModeRefusal)
}

enum PhoneModeResolver {
    static func resolve(requested: SessionMode, features: Set<String>, statusMode: String?, reason: String?) -> PhoneModeOutcome {
        .picture
    }
}
