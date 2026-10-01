import Foundation

/// Historical display-only state, scoped to the exact local record and owner grant. It never
/// authorizes control or reconnect, and old room-only defaults are deliberately not read.
struct AwayMemory {
    static let defaultsKey = "awayLastKnownByOwnerRecord.v2"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func macKey(host: PhoneHostTrust) -> String {
        let grant = host.ownerPairID ?? "legacy-credential:" + SecureRandom.digest(host.invitation.token + "|" + host.invitation.key.base64EncodedString())
        return SecureRandom.digest("away-memory-v2|" + host.id + "|" + grant + "|" + host.invitation.server)
    }
    func wasOn(host: PhoneHostTrust) -> Bool {
        guard let raw = load()[Self.macKey(host: host)] else { return false }
        return AwayModeState(reported: raw) != .off
    }
    func remember(_ state: AwayModeState, host: PhoneHostTrust) {
        var all = load()
        all[Self.macKey(host: host)] = state == .off ? nil : state.rawValue
        while all.count > 32 { all.removeValue(forKey: all.keys.sorted().first!) }
        if all.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set(all, forKey: Self.defaultsKey) }
    }
    private func load() -> [String: String] {
        let values = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        guard values.count <= 32 else { return [:] }
        return values.filter { SecureRandom.isToken($0.key) && AwayModeState(rawValue: $0.value) != nil }
    }
}
