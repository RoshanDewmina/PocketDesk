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
        guard let width = entry(forRoom: room, display: display, among: displays)?.looksLikeWidth, width > 0 else { return nil }
        return width
    }

    /// Zero records an explicit Off choice, distinct from a phone/display with no history.
    func hasSavedChoice(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Bool {
        entry(forRoom: room, display: display, among: displays) != nil
    }

    private func entry(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Entry? {
        let candidates = entries(room).filter { Self.resolves($0.display, to: display, among: displays) }
        if let exact = candidates.first(where: { $0.display.id == display.id }) { return exact }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func remember(_ width: Double?, forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {
        var all = load()
        let key = Self.macKey(room: room)
        var kept = (all[key] ?? []).filter { !Self.resolves($0.display, to: display, among: displays) }
        if width == nil || (width.map { $0.isFinite && BigTextLimits.widthRange.contains($0) } == true) {
            kept.append(Entry(display: DisplayMemory.Choice(id: display.id, name: display.name), looksLikeWidth: width ?? 0))
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

enum BigTextAutoLevel {
    /// One tuning constant: landscape-ish iPhone use targets 1,280–1,440 logical Mac points.
    static let targetWidth: Double = 1440
    static let disabledKey = "disableBigTextAutoLevel"

    static func choose(phonePixels: PixelSize, baselineWidth: Double, steps: [ScaleStep]) -> Double? {
        guard (try? phonePixels.validate()) != nil, baselineWidth.isFinite,
              BigTextLimits.widthRange.contains(baselineWidth) else { return nil }
        // A 2× Mac mode near half the phone's long pixel edge avoids needless downsampling.
        // The clamp keeps small/large phones readable; orientation never changes the saved choice.
        let desired = min(targetWidth, max(targetWidth * 8 / 9, Double(phonePixels.longEdge) / 2))
        guard baselineWidth > desired else { return nil }
        return steps.filter { (try? $0.validate(below: baselineWidth)) != nil }.min { a, b in
            let left = abs(a.width - desired), right = abs(b.width - desired)
            return left == right ? a.width > b.width : left < right
        }?.width
    }
}
