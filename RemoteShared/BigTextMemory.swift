import Foundation

struct BigTextMemory {
    struct Entry: Codable, Equatable {
        var display: DisplayMemory.Choice
        var looksLikeWidth: Double
    }

    static let defaultsKey = "bigTextByMac"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func macKey(room: String) -> String { String(SecureRandom.digest("farside-bigtext|" + room).prefix(24)) }

    func width(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Double? {
        let candidates = entries(room).filter { Self.resolves($0.display, to: display, among: displays) }
        if let exact = candidates.first(where: { $0.display.id == display.id }) { return exact.looksLikeWidth }
        return candidates.count == 1 ? candidates[0].looksLikeWidth : nil
    }

    func remember(_ width: Double?, forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {
        var all = load()
        let key = Self.macKey(room: room)
        var kept = (all[key] ?? []).filter { !Self.resolves($0.display, to: display, among: displays) }
        if let width, width.isFinite, (1...20_000).contains(width) {
            kept.append(Entry(display: DisplayMemory.Choice(id: display.id, name: display.name), looksLikeWidth: width))
        }
        all[key] = kept.isEmpty ? nil : kept
        save(all)
    }

    func forget(room: String) {
        var all = load()
        all[Self.macKey(room: room)] = nil
        save(all)
    }

    // Display IDs are reassigned across reboots, so an id hit counts only when the name agrees too;
    // otherwise a level saved for one monitor would be applied to whichever monitor now has that id.
    private static func resolves(_ choice: DisplayMemory.Choice, to display: DisplayDescriptor,
                                 among displays: [DisplayDescriptor]) -> Bool {
        guard let found = DisplayMemory.match(choice, in: displays) else { return false }
        return found.id == display.id && found.name == choice.name
    }

    private func entries(_ room: String) -> [Entry] { load()[Self.macKey(room: room)] ?? [] }

    private func load() -> [String: [Entry]] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [Entry]].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: [Entry]]) {
        guard !all.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
