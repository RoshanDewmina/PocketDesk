import Foundation

/// How one-finger touches drive the Mac pointer while controlling. View mode (local pan and
/// zoom) is separate and unchanged by this choice.
enum TouchInputMode: String, CaseIterable, Identifiable {
    /// The screen is a trackpad: the pointer moves relative to the finger. Precise on small targets.
    case trackpad
    /// The pointer goes where you touch: tap clicks there, drag click-drags from there.
    case direct

    static let key = "touchInputMode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .direct: "Direct"
        }
    }
}

/// The Touch, pointer-size and follow pickers left the UI on 1 Oct 2026. A value chosen there earlier
/// would otherwise persist with no way back, so each lands on the default once; `defaults write` and
/// launch arguments after that are honoured as usual.
enum HiddenSettingsMigration {
    static let key = "settings.hiddenSurface.1"
    static let hiddenKeys = [TouchInputMode.key, PointerSizePreference.key, PointerFollowStyle.key]

    static func run(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        hiddenKeys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(true, forKey: key)
    }
}
