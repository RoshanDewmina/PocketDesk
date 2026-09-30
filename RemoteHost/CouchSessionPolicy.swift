import Foundation
import CoreGraphics

enum HostSessionState: Equatable {
    case picture, couch
    case refused(SessionModeRefusal)

    var wireMode: String { "picture" }
    var wireReason: String? { nil }
    func issuesTokens(healthy: Bool) -> Bool { false }
}

struct CouchAdmissionInputs: Equatable {
    var routeLocal = false
    var provenLinkActive = false
    var allowControl = false
    var accessibility: HostPermissionStatus = .unchecked
}

enum CouchAdmission {
    static func decide(_ inputs: CouchAdmissionInputs) -> SessionModeRefusal? { .notLocal }
}

struct CouchHealthInputs: Equatable {
    var routeLocal = false
    var provenLinkActive = false
    var heartbeatAge: TimeInterval?
    var screenLocked = false
    var consoleUserActive = true
    var allowControl = false
    var accessibility: HostPermissionStatus = .unchecked
    var phonePaused = false
}

enum CouchHealth {
    static let heartbeatLimit: TimeInterval = 0.75
    static func isHealthy(_ inputs: CouchHealthInputs) -> Bool { false }
}

extension HostControlPolicy {
    static func isEnabled(userConsent: Bool, accessibilityPermission: HostPermissionStatus,
                          session: HostSessionState, captureHealthy: Bool, couchHealthy: Bool) -> Bool { false }
}

extension RemoteInputLease {
    static let pictureDuration: TimeInterval = 2
    static let couchDuration: TimeInterval = 1
}

enum HostCouchDisplays {
    struct Display: Equatable {
        var id: UInt32
        var bounds: CGRect
        var mirrorsAnother: Bool
    }

    static func rects(_ displays: [Display], main: UInt32) -> [CGRect] { [] }
    static func current() -> [CGRect] { [] }
}
