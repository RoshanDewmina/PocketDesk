import Foundation

/// Remembers whether the desktop fills the screen or fits inside the safe area.
enum ViewportPreference {
    static let key = "viewportMode"

    static func stored(in defaults: UserDefaults = .standard) -> ViewportMode {
        defaults.string(forKey: key).flatMap(ViewportMode.init(rawValue:)) ?? .fill
    }

    static func store(_ mode: ViewportMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
