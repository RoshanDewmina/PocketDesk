import Foundation

/// Relay repair is prepared for explicit testing; changing it requires a fresh process because
/// the pinned public WebRTC field-trial API is process-wide, not an effective per-peer pacer API.
enum PacketRepairPreferences {
    static let key = "farsideRelayPacketRepair"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    #if DEBUG
    static var overrideForTesting: Bool?
    #endif
    static let activeThisLaunch: Bool = {
        #if DEBUG
        if let overrideForTesting { return overrideForTesting }
        #endif
        return enabled
    }()
    static func maySend(native: Bool, provenLocal: Bool, selectedRelay: Bool) -> Bool {
        native && !provenLocal && selectedRelay && activeThisLaunch
    }
}
