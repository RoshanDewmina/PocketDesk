import Foundation

struct PersonalShortcut: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    let bundleID: String
    let key: String
    let modifiers: [String]
    var valid: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.count <= 40 && label.utf8.count <= 256 && label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) && !bundleID.isEmpty && bundleID.utf8.count <= 255 && ScopedChordPolicy.valid(key: key, modifiers: modifiers) }
}
struct ShortcutWorkspaceProfile: Codable, Equatable {
    var order: [String]
    var hidden: Set<String>
    var custom: [PersonalShortcut] = []
}
struct ShortcutWorkspaceStore {
    static let defaultsKey = "workspaceShortcutProfiles.v1"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func appLabel(_ bundle: String, current: FrontmostApp?) -> String {
        if current?.bundleID == bundle, let name = current?.displayName { return name }
        let names = ["com.apple.Safari":"Safari", "com.google.Chrome":"Chrome", "com.apple.finder":"Finder", "com.apple.mail":"Mail",
                     "com.apple.Notes":"Notes", "com.apple.iChat":"Messages", "com.tinyspeck.slackmacgap":"Slack", "com.microsoft.Word":"Word",
                     "com.microsoft.Excel":"Excel", "com.microsoft.Powerpoint":"PowerPoint", "com.apple.iWork.Pages":"Pages", "com.apple.iWork.Keynote":"Keynote",
                     "com.microsoft.VSCode":"Visual Studio Code", "com.apple.dt.Xcode":"Xcode", "com.spotify.client":"Spotify", "com.apple.Photos":"Photos", "com.apple.Preview":"Preview"]
        return names[bundle] ?? bundle.components(separatedBy: ".").last ?? "Mac app"
    }
    static func catalogID(_ chip: ShortcutChip) -> String {
        SecureRandom.digest("shortcut-catalog-v1|" + chip.key + "|" + chip.modifiers.sorted().joined(separator: ",") + "|" + chip.label)
    }
    static func profileKey(host: PhoneHostTrust, bundleID: String) -> String { AwayMemory.macKey(host: host) + ":" + SecureRandom.digest(bundleID) }
    func profile(host: PhoneHostTrust, bundleID: String, catalog: [ShortcutChip]) -> ShortcutWorkspaceProfile {
        if let value = load()[Self.profileKey(host: host, bundleID: bundleID)], value.custom.allSatisfy({ $0.bundleID == bundleID }) { return value }
        return .init(order: catalog.map(Self.catalogID), hidden: [])
    }
    func visible(host: PhoneHostTrust, bundleID: String, catalog: [ShortcutChip]) -> [ShortcutChip] {
        let profile = profile(host: host, bundleID: bundleID, catalog: catalog)
        let byID = Dictionary(catalog.map { (Self.catalogID($0), $0) }, uniquingKeysWith: { first, _ in first })
        let known = profile.order + catalog.map(Self.catalogID).filter { !profile.order.contains($0) }
        return Array(known.filter { !profile.hidden.contains($0) }.compactMap { byID[$0] }.prefix(6))
    }
    @discardableResult
    func save(_ profile: ShortcutWorkspaceProfile, host: PhoneHostTrust, bundleID: String) -> Bool {
        guard profile.order.count <= 32, Set(profile.order).count == profile.order.count, profile.hidden.count <= 32,
              profile.custom.count <= 12, profile.custom.allSatisfy({ $0.valid && $0.bundleID == bundleID }), Set(profile.custom.map(\.id)).count == profile.custom.count else { return false }
        var all = load()
        let key = Self.profileKey(host: host, bundleID: bundleID)
        guard all[key] != nil || all.count < 128 else { return false }
        all[key] = profile
        guard let data = try? JSONEncoder().encode(all), data.count <= 256 * 1024 else { return false }
        defaults.set(data, forKey: Self.defaultsKey); return true
    }
    func restoreDefaults(host: PhoneHostTrust, bundleID: String) {
        var all = load(); all.removeValue(forKey: Self.profileKey(host: host, bundleID: bundleID)); persist(all)
    }
    func forget(host: PhoneHostTrust) {
        let prefix = AwayMemory.macKey(host: host) + ":"
        persist(load().filter { !$0.key.hasPrefix(prefix) })
    }
    private func persist(_ all: [String: ShortcutWorkspaceProfile]) {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    private func load() -> [String: ShortcutWorkspaceProfile] {
        guard let data = defaults.data(forKey: Self.defaultsKey), data.count <= 256 * 1024,
              let all = try? JSONDecoder().decode([String: ShortcutWorkspaceProfile].self, from: data), all.count <= 128 else { return [:] }
        return all.filter { _, value in value.order.count <= 32 && Set(value.order).count == value.order.count && value.hidden.count <= 32 &&
            value.custom.count <= 12 && value.custom.allSatisfy(\.valid) && Set(value.custom.map(\.id)).count == value.custom.count }
    }
}
