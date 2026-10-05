import Foundation

/// Compiled only in the isolated Workspace trial. Production targets never opt in by preferences.
enum FarsideBeta {
    static var isEnabled: Bool {
        #if FARSIDE_WORKSPACE_BETA
        true
        #else
        false
        #endif
    }
    static let label = "BETA • Workspace + Smart Zoom"
    static var urlScheme: String { isEnabled ? "farside-beta" : "farside" }
    static var trustService: String {
        isEnabled ? "PocketDesk.Remote.WorkspaceBeta.Trust.v1" : "PocketDesk.Remote.Trust.v1"
    }
}

/// Coarse status only; no window titles, application content or restoration journal crosses the wire.
enum WorkspaceBetaPhase: String, Codable, Equatable {
    case idle, preparing, active, restoring, blocked
}
