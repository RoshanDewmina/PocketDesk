import Foundation

/// Whether Away mode was on the last time each paired Mac reported it, for the Mac list and the
/// lock notice after a session ends. Keyed by a digest of the room so defaults never hold the room.
struct AwayMemory {
    static let defaultsKey = "awayLastKnownByMac"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func macKey(room: String) -> String { String(SecureRandom.digest("farside-away|" + room).prefix(24)) }

    func wasOn(forRoom room: String) -> Bool {
        guard let raw = load()[Self.macKey(room: room)] else { return false }
        return AwayModeState(reported: raw) != .off
    }

    func remember(_ state: AwayModeState, forRoom room: String) {
        var all = load()
        all[Self.macKey(room: room)] = state == .off ? nil : state.rawValue
        save(all)
    }

    func forget(room: String) {
        var all = load()
        all[Self.macKey(room: room)] = nil
        save(all)
    }

    private func load() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func save(_ all: [String: String]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(all, forKey: Self.defaultsKey)
        }
    }
}
