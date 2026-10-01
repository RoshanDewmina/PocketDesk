import Foundation

/// Phone-owned, default-off picture refinements. Each is asked for in the session handshake, so a
/// change applies from the next connection and a Mac that is not asked keeps the proven path.
enum StillTextPreferences {
    static let sharpenKey = "farsideSharpenStillText"
    static let textClarityKey = "farsideTextClarity"
    static func requestedFeatures(sharpen: Bool, textClarity: Bool, fullColor: Bool) -> [String] {
        (HEVC444Policy.permitsRefinement(requested: sharpen, fullColor: fullColor) ? [SessionFeature.videoRefinement] : [])
            + (textClarity ? [SessionFeature.textClarity] : [])
    }
    static func requestedFeatures(_ defaults: UserDefaults = .standard) -> [String] {
        requestedFeatures(sharpen: defaults.bool(forKey: sharpenKey), textClarity: defaults.bool(forKey: textClarityKey),
                          fullColor: defaults.bool(forKey: HEVC444Policy.preferenceKey))
    }
}
