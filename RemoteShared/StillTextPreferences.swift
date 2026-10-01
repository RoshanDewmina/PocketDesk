import Foundation

/// Phone-owned still-text refinements, on by default with no setting. Each is asked for in the session
/// handshake, so a Mac that is not asked keeps the proven path. The keys are internal A/B overrides only:
/// an explicit false turns that refinement off from the next connection.
enum StillTextPreferences {
    static let sharpenKey = "farsideSharpenStillText"
    static let textClarityKey = "farsideTextClarity"
    static let settingValuesRetiredKey = "farsideStillTextSettingsRetired"
    /// Once per install: forgets values the removed Settings toggles wrote, so an earlier "off" cannot
    /// keep the new default away. Launch-argument overrides live in another domain and still apply.
    static func retireSettingValues(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: settingValuesRetiredKey) else { return }
        defaults.removeObject(forKey: sharpenKey); defaults.removeObject(forKey: textClarityKey)
        defaults.set(true, forKey: settingValuesRetiredKey)
    }
    static func requestedFeatures(sharpen: Bool, textClarity: Bool, fullColor: Bool) -> [String] {
        (HEVC444Policy.permitsRefinement(requested: sharpen, fullColor: fullColor) ? [SessionFeature.videoRefinement] : [])
            + (textClarity ? [SessionFeature.textClarity] : [])
    }
    static func requestedFeatures(_ defaults: UserDefaults = .standard) -> [String] {
        func on(_ key: String) -> Bool { defaults.object(forKey: key) == nil || defaults.bool(forKey: key) }
        return requestedFeatures(sharpen: on(sharpenKey), textClarity: on(textClarityKey),
                          fullColor: defaults.bool(forKey: HEVC444Policy.preferenceKey))
    }
}
