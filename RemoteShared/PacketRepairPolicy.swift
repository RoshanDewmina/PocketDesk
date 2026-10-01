import Foundation

/// Relay repair is prepared for explicit testing; changing it requires a fresh process because
/// the pinned public WebRTC field-trial API is process-wide, not an effective per-peer pacer API.
/// Release builds never send repair: the preference key and the trial are compiled out, while
/// receiving a peer's repair stream stays available through the default receiver capabilities.
enum PacketRepairPreferences {
    #if DEBUG
    static let key = "farsideRelayPacketRepair"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static var overrideForTesting: Bool?
    static let activeThisLaunch = resolve(debugBuild: PrototypeGates.isDebugBuild,
                                          stored: overrideForTesting ?? enabled)
    #else
    static let activeThisLaunch = resolve(debugBuild: PrototypeGates.isDebugBuild, stored: false)
    #endif
    static func resolve(debugBuild: Bool, stored: Bool) -> Bool { debugBuild && stored }
    static func maySend(native: Bool, provenLocal: Bool, selectedRelay: Bool) -> Bool {
        native && !provenLocal && selectedRelay && activeThisLaunch
    }
}

/// Compile-time gate shared by prototypes that must never reach a Release artifact.
enum PrototypeGates {
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif
}
