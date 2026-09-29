import Foundation

/// Physical keys from a keyboard attached to the iPhone or iPad, identified by USB HID usage
/// (keyboard page 0x07), sent to the Mac by position. The Mac applies its own layout and input
/// method, exactly as if the same key were pressed on a Mac keyboard, so dead keys, IMEs and
/// shortcuts behave natively. Modifier keys travel as flags on the key or pointer action.
enum HardwareKeyMap {
    /// Key names every host understands (the original `key` table).
    static let legacyNames: Set<String> = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        .union(["return", "tab", "space", "delete", "escape", "left", "right", "down", "up"])

    /// HID usage → host key name. Anything not listed (Menu, Power, volume, F21–F24) stays on the phone.
    static let names: [Int: String] = {
        var table: [Int: String] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { table[0x04 + offset] = String(letter) }
        for (offset, digit) in "1234567890".enumerated() { table[0x1E + offset] = String(digit) }
        let fixed: [Int: String] = [
            0x28: "return", 0x29: "escape", 0x2A: "delete", 0x2B: "tab", 0x2C: "space",
            0x2D: "minus", 0x2E: "equal", 0x2F: "leftBracket", 0x30: "rightBracket", 0x31: "backslash",
            0x32: "backslash", 0x33: "semicolon", 0x34: "quote", 0x35: "grave", 0x36: "comma",
            0x37: "period", 0x38: "slash",
            0x46: "f13", 0x47: "f14", 0x48: "f15",
            0x49: "help", 0x4A: "home", 0x4B: "pageUp", 0x4C: "forwardDelete", 0x4D: "end", 0x4E: "pageDown",
            0x4F: "right", 0x50: "left", 0x51: "down", 0x52: "up",
            0x53: "keypadClear", 0x54: "keypadDivide", 0x55: "keypadMultiply", 0x56: "keypadMinus",
            0x57: "keypadPlus", 0x58: "keypadEnter", 0x62: "keypad0", 0x63: "keypadDecimal",
            0x64: "section", 0x67: "keypadEquals", 0x75: "help",
            0x85: "jisKeypadComma", 0x87: "jisUnderscore", 0x89: "jisYen", 0x90: "jisKana", 0x91: "jisEisu"
        ]
        table.merge(fixed) { _, new in new }
        for index in 0..<12 { table[0x3A + index] = "f\(index + 1)" }
        for index in 0..<8 { table[0x68 + index] = "f\(index + 13)" }
        for index in 0..<9 { table[0x59 + index] = "keypad\(index + 1)" }
        return table
    }()

    /// Left and right Control, Shift, Option and Command.
    static func isModifier(_ usage: Int) -> Bool { (0xE0...0xE7).contains(usage) }
    static let capsLock = 0x39

    static func name(forHIDUsage usage: Int) -> String? { names[usage] }

    static func needsExtendedKeys(_ name: String) -> Bool { !legacyNames.contains(name) }

    /// Keys a held press repeats, like a Mac keyboard. Escape, function and input-method keys do not.
    static func repeats(_ name: String) -> Bool {
        if name == "escape" || name == "help" || name == "keypadClear" || name.hasPrefix("jis") { return false }
        if name.count > 1, name.hasPrefix("f"), Int(name.dropFirst()) != nil { return false }
        return true
    }

    /// Caps Lock on the phone's keyboard capitalises letters as Shift would. With Command, Control
    /// or Option held it adds nothing, as on a Mac.
    static func modifiers(_ held: Set<String>, capsLock: Bool, for name: String) -> [String] {
        var result = held
        if capsLock, name.count == 1, name.first?.isLetter == true,
           held.isDisjoint(with: ["command", "control", "option"]) {
            result.insert("shift")
        }
        return order.filter(result.contains)
    }

    /// Canonical wire order for modifier names.
    static let order = ["command", "shift", "option", "control"]
}

/// iPadOS keeps some Mac shortcuts for itself (⌘Tab, ⌘Space, ⌘H, screenshots, …) or its window
/// commands (⌘W, ⌘M, ⌘Q). Pressing ⌃⌥ in place of ⌘ sends the Mac shortcut instead.
struct ShortcutRemap: Equatable, Identifiable {
    let key: String
    let sends: [String]
    let title: String
    /// What the person presses, for the Controls list: "⌃⌥Tab".
    let chord: String
    /// What the Mac receives: "⌘Tab".
    let result: String

    var id: String { key }

    static let trigger: Set<String> = ["control", "option"]

    static let defaults: [ShortcutRemap] = [
        ShortcutRemap(key: "tab", sends: ["command"], title: "App Switcher", chord: "⌃⌥Tab", result: "⌘Tab"),
        ShortcutRemap(key: "space", sends: ["command"], title: "Spotlight", chord: "⌃⌥Space", result: "⌘Space"),
        ShortcutRemap(key: "h", sends: ["command"], title: "Hide App", chord: "⌃⌥H", result: "⌘H"),
        ShortcutRemap(key: "q", sends: ["command"], title: "Quit App", chord: "⌃⌥Q", result: "⌘Q"),
        ShortcutRemap(key: "w", sends: ["command"], title: "Close Window", chord: "⌃⌥W", result: "⌘W"),
        ShortcutRemap(key: "m", sends: ["command"], title: "Minimize Window", chord: "⌃⌥M", result: "⌘M"),
        ShortcutRemap(key: "comma", sends: ["command"], title: "App Settings", chord: "⌃⌥,", result: "⌘,"),
        ShortcutRemap(key: "d", sends: ["command", "option"], title: "Show or Hide Dock", chord: "⌃⌥D", result: "⌥⌘D"),
        ShortcutRemap(key: "3", sends: ["command", "shift"], title: "Screenshot", chord: "⌃⌥3", result: "⇧⌘3"),
        ShortcutRemap(key: "4", sends: ["command", "shift"], title: "Screenshot Selection", chord: "⌃⌥4", result: "⇧⌘4"),
        ShortcutRemap(key: "5", sends: ["command", "shift"], title: "Screenshot Options", chord: "⌃⌥5", result: "⇧⌘5")
    ]

    /// The Mac chord for a press, remapped when it is ⌃⌥ (optionally with ⇧) plus a listed key.
    static func resolve(key: String, modifiers: [String], enabled: Bool) -> (key: String, modifiers: [String]) {
        guard enabled else { return (key, modifiers) }
        let held = Set(modifiers)
        guard held.isSuperset(of: trigger), held.subtracting(trigger).isSubset(of: ["shift"]),
              let remap = defaults.first(where: { $0.key == key }) else { return (key, modifiers) }
        var sends = Set(remap.sends)
        if held.contains("shift") { sends.insert("shift") }
        return (key, HardwareKeyMap.order.filter(sends.contains))
    }
}

/// Auto-repeat for a held key. The phone repeats rather than holding a Mac key down, so a lost
/// connection can never leave a key stuck on the Mac. Only the most recent key repeats.
struct HardwareKeyRepeat {
    static let delay: TimeInterval = 0.5
    static let interval: TimeInterval = 0.07

    private struct Active {
        let usage: Int
        let key: String
        let modifiers: [String]
        var next: TimeInterval
    }

    private var active: Active?

    var isRepeating: Bool { active != nil }

    mutating func pressed(usage: Int, key: String, modifiers: [String], at time: TimeInterval) {
        active = HardwareKeyMap.repeats(key)
            ? Active(usage: usage, key: key, modifiers: modifiers, next: time + Self.delay) : nil
    }

    mutating func released(usage: Int) {
        if active?.usage == usage { active = nil }
    }

    mutating func cancel() { active = nil }

    /// The key to send again at `time`, if one is due. Late ticks never burst: one repeat per call.
    mutating func due(at time: TimeInterval) -> (key: String, modifiers: [String])? {
        guard var current = active, time >= current.next else { return nil }
        current.next = max(current.next + Self.interval, time + Self.interval / 2)
        active = current
        return (current.key, current.modifiers)
    }
}
