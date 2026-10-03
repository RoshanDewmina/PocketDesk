import Foundation

/// Phone-owned still-text refinements, with no setting. Text clarity is asked for by default. The lossless
/// refinement patch is not: it switches the whole session to BGRA capture and checks the centre of every
/// frame on the encoder queue, about 2 ms + 7 ms a frame in a Debug build (perf-push/crisp NOTES). Each is
/// asked for in the session handshake, so a Mac that is not asked keeps the proven path. The keys are
/// internal A/B overrides only, applied from the next connection.
enum StillTextPreferences {
    static let sharpenKey = "farsideSharpenStillText"
    static let textClarityKey = "farsideTextClarity"
    static let settingValuesRetiredKey = "farsideStillTextSettingsRetired"
    /// Once per install: forgets both values the removed Settings toggles wrote, so text clarity returns to
    /// on and refinement to off (no setting is left to change either). Launch-argument overrides live in
    /// another domain and still apply.
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
        return requestedFeatures(sharpen: defaults.bool(forKey: sharpenKey), textClarity: on(textClarityKey),
                          fullColor: defaults.bool(forKey: HEVC444Policy.preferenceKey))
    }
}

struct ShortcutChip: Equatable, Identifiable {
    let label: String
    let key: String
    let modifiers: [String]

    var id: String { label }
}

enum ShortcutCatalog {
    static let apps: [String: [ShortcutChip]] = [
        "com.apple.Safari": [
            ShortcutChip(label: "New tab", key: "t", modifiers: ["command"]),
            ShortcutChip(label: "Close tab", key: "w", modifiers: ["command"]),
            ShortcutChip(label: "Reopen tab", key: "t", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Find on page", key: "f", modifiers: ["command"])
        ],
        "com.google.Chrome": [
            ShortcutChip(label: "New tab", key: "t", modifiers: ["command"]),
            ShortcutChip(label: "Close tab", key: "w", modifiers: ["command"]),
            ShortcutChip(label: "Reopen tab", key: "t", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Address bar", key: "l", modifiers: ["command"]),
            ShortcutChip(label: "Find on page", key: "f", modifiers: ["command"])
        ],
        "com.apple.finder": [
            ShortcutChip(label: "New window", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "New folder", key: "n", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Quick Look", key: "space", modifiers: []),
            ShortcutChip(label: "Find files", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "Get info", key: "i", modifiers: ["command"])
        ],
        "com.apple.mail": [
            ShortcutChip(label: "New email", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Send email", key: "d", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Reply", key: "r", modifiers: ["command"]),
            ShortcutChip(label: "Reply all", key: "r", modifiers: ["command", "shift"])
        ],
        "com.apple.Notes": [
            ShortcutChip(label: "New note", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Find in notes", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "Duplicate note", key: "d", modifiers: ["command"]),
            ShortcutChip(label: "New folder", key: "n", modifiers: ["command", "shift"])
        ],
        "com.apple.iChat": [
            ShortcutChip(label: "New message", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Find conversations", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "Show messages window", key: "0", modifiers: ["command"]),
            ShortcutChip(label: "Close window", key: "w", modifiers: ["command"])
        ],
        "com.tinyspeck.slackmacgap": [
            ShortcutChip(label: "Compose message", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Search Slack", key: "g", modifiers: ["command"]),
            ShortcutChip(label: "Find in conversation", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "Browse DMs", key: "k", modifiers: ["command", "shift"])
        ],
        "com.microsoft.Word": [
            ShortcutChip(label: "Find in document", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "Save document", key: "s", modifiers: ["command"]),
            ShortcutChip(label: "Undo", key: "z", modifiers: ["command"]),
            ShortcutChip(label: "Bold text", key: "b", modifiers: ["command"])
        ],
        "com.microsoft.Excel": [
            ShortcutChip(label: "New workbook", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Save workbook", key: "s", modifiers: ["command"]),
            ShortcutChip(label: "Undo", key: "z", modifiers: ["command"]),
            ShortcutChip(label: "Bold cells", key: "b", modifiers: ["command"])
        ],
        "com.microsoft.Powerpoint": [
            ShortcutChip(label: "New presentation", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Save presentation", key: "s", modifiers: ["command"]),
            ShortcutChip(label: "Start slideshow", key: "return", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Find in presentation", key: "f", modifiers: ["command"])
        ],
        "com.apple.iWork.Pages": [
            ShortcutChip(label: "New document", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Save document", key: "s", modifiers: ["command"]),
            ShortcutChip(label: "Print document", key: "p", modifiers: ["command"]),
            ShortcutChip(label: "Find in document", key: "f", modifiers: ["command"])
        ],
        "com.apple.iWork.Keynote": [
            ShortcutChip(label: "New presentation", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Save presentation", key: "s", modifiers: ["command"]),
            ShortcutChip(label: "Play slideshow", key: "p", modifiers: ["command", "option"]),
            ShortcutChip(label: "Find in presentation", key: "f", modifiers: ["command"])
        ],
        "com.microsoft.VSCode": [
            ShortcutChip(label: "Command palette", key: "p", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Quick open", key: "p", modifiers: ["command"]),
            ShortcutChip(label: "Find in file", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "New file", key: "n", modifiers: ["command"])
        ],
        "com.apple.dt.Xcode": [
            ShortcutChip(label: "Open quickly", key: "o", modifiers: ["command", "shift"]),
            ShortcutChip(label: "Find in project", key: "f", modifiers: ["command", "shift"]),
            ShortcutChip(label: "New file", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Build project", key: "b", modifiers: ["command"])
        ],
        "com.spotify.client": [
            ShortcutChip(label: "Play or pause", key: "space", modifiers: []),
            ShortcutChip(label: "Open search", key: "k", modifiers: ["command"]),
            ShortcutChip(label: "Filter Spotify", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "Shuffle", key: "s", modifiers: ["option"]),
            ShortcutChip(label: "Repeat", key: "r", modifiers: ["option"])
        ],
        "com.apple.Photos": [
            ShortcutChip(label: "Find photos", key: "f", modifiers: ["command"]),
            ShortcutChip(label: "New album", key: "n", modifiers: ["command"]),
            ShortcutChip(label: "Rotate photo left", key: "r", modifiers: ["command"]),
            ShortcutChip(label: "Import photos", key: "i", modifiers: ["command", "shift"])
        ],
        "com.apple.Preview": [
            ShortcutChip(label: "Open file", key: "o", modifiers: ["command"]),
            ShortcutChip(label: "Save file", key: "s", modifiers: ["command"]),
            ShortcutChip(label: "Print file", key: "p", modifiers: ["command"]),
            ShortcutChip(label: "Actual size", key: "0", modifiers: ["command", "option"])
        ]
    ]

    static let generic: [ShortcutChip] = [
        ShortcutChip(label: "Copy", key: "c", modifiers: ["command"]),
        ShortcutChip(label: "Paste", key: "v", modifiers: ["command"]),
        ShortcutChip(label: "Undo", key: "z", modifiers: ["command"]),
        ShortcutChip(label: "Find", key: "f", modifiers: ["command"])
    ]

    static func chips(for bundleID: String?) -> [ShortcutChip] {
        guard let bundleID else { return generic }
        return apps[bundleID] ?? generic
    }
}
