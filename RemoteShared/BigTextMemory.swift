import Foundation

struct BigTextMemory {
    struct Entry: Codable, Equatable {
        var display: DisplayMemory.Choice
        var looksLikeWidth: Double
    }

    static let defaultsKey = "bigTextByMac"
    private static let roomOwnersKey = "bigTextRoomOwners"
    static let stableMemoryDisabledKey = "disableBigTextStableMemory"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func macKey(room: String) -> String { String(SecureRandom.digest("farside-bigtext|" + room).prefix(24)) }

    /// UserDefaults belongs to this phone. Only an admitted trust record supplies the Mac key;
    /// neither a room alias nor a display name proves that two pairings are the same Mac.
    static func macKey(host: PhoneHostTrust) -> String {
        let identity = host.durableHostID.map { "host|" + $0 } ?? "record|" + host.id
        return String(SecureRandom.digest("farside-bigtext-v2|" + identity).prefix(24))
    }

    func migrate(host: PhoneHostTrust) {
        guard !defaults.bool(forKey: Self.stableMemoryDisabledKey) else { return }
        var all = load()
        let oldKey = Self.macKey(room: host.invitation.room), key = Self.macKey(host: host)
        let recordKey = String(SecureRandom.digest("farside-bigtext-v2|record|" + host.id).prefix(24))
        var owners = roomOwners()
        // Trust retains the local record ID when an existing legacy room gains a durable ID.
        // Only that exact admitted record may carry its preferences into the durable key.
        let recordEntries = recordKey == key ? [] : (all[recordKey] ?? [])
        if !recordEntries.isEmpty {
            for room in owners.filter({ $0.value == recordKey }).map(\.key) { owners[room] = key }
        }
        let roomBelongsToHost = owners[oldKey] == nil || owners[oldKey] == key
        let old = roomBelongsToHost ? (all[oldKey] ?? []) : []
        var stable = all[key] ?? []
        guard !old.isEmpty || !stable.isEmpty || !recordEntries.isEmpty else { return }
        // Stable choices, including explicit Off, win. A conflicting name is ambiguous;
        // importing the room entry must never replace or duplicate that saved preference.
        let durableNames = Set(stable.map { $0.display.name })
        stable.append(contentsOf: recordEntries.filter { !durableNames.contains($0.display.name) })
        let stableNames = Set(stable.map { $0.display.name })
        stable.append(contentsOf: old.filter { !stableNames.contains($0.display.name) })
        guard !recordEntries.isEmpty || all[key] != stable || (roomBelongsToHost && (all[oldKey] != stable || owners[oldKey] != key)) else { return }
        if !recordEntries.isEmpty { all[recordKey] = nil }
        all[key] = stable.isEmpty ? nil : stable
        // Keep the known room as a rollback shadow; a disabled stable-memory key uses it.
        if roomBelongsToHost {
            all[oldKey] = stable.isEmpty ? nil : stable
            owners[oldKey] = key
        }
        defaults.set(owners, forKey: Self.roomOwnersKey)
        save(all)
    }

    func width(forHost host: PhoneHostTrust, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Double? {
        guard let width = entry(forHost: host, display: display, among: displays)?.looksLikeWidth, width > 0 else { return nil }
        return width
    }

    func hasSavedChoice(forHost host: PhoneHostTrust, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Bool {
        entry(forHost: host, display: display, among: displays) != nil
    }

    private func entry(forHost host: PhoneHostTrust, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Entry? {
        if defaults.bool(forKey: Self.stableMemoryDisabledKey) {
            return entry(forRoom: host.invitation.room, display: display, among: displays)
        }
        migrate(host: host)
        return Self.entry(in: load()[Self.macKey(host: host)] ?? [], display: display, among: displays)
    }

    func remember(_ width: Double?, forHost host: PhoneHostTrust, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {
        if defaults.bool(forKey: Self.stableMemoryDisabledKey) {
            remember(width, forRoom: host.invitation.room, display: display, among: displays)
            return
        }
        migrate(host: host)
        let key = Self.macKey(host: host), roomKey = Self.macKey(room: host.invitation.room)
        var owners = roomOwners()
        var keys = [key]
        if owners[roomKey] == nil || owners[roomKey] == key {
            owners[roomKey] = key
            defaults.set(owners, forKey: Self.roomOwnersKey)
            keys.append(roomKey)
        }
        remember(width, keys: keys, display: display, among: displays)
    }

    func forget(host: PhoneHostTrust) {
        var all = load()
        let key = Self.macKey(host: host), roomKey = Self.macKey(room: host.invitation.room)
        var owners = roomOwners()
        all[key] = nil
        let knownRooms = owners.filter { $0.value == key }.map(\.key)
        for knownRoom in knownRooms {
            all[knownRoom] = nil
            owners[knownRoom] = nil
        }
        if owners[roomKey] == nil && !knownRooms.contains(roomKey) {
            all[roomKey] = nil
        }
        defaults.set(owners, forKey: Self.roomOwnersKey)
        save(all)
    }

    func width(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Double? {
        guard let width = entry(forRoom: room, display: display, among: displays)?.looksLikeWidth, width > 0 else { return nil }
        return width
    }

    /// Zero records an explicit Off choice, distinct from a phone/display with no history.
    func hasSavedChoice(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Bool {
        entry(forRoom: room, display: display, among: displays) != nil
    }

    private func entry(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Entry? {
        Self.entry(in: entries(room), display: display, among: displays)
    }

    private static func entry(in entries: [Entry], display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Entry? {
        let candidates = entries.filter { Self.resolves($0.display, to: display, among: displays) }
        if let exact = candidates.first(where: { $0.display.id == display.id }) { return exact }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func remember(_ width: Double?, forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {
        remember(width, keys: [Self.macKey(room: room)], display: display, among: displays)
    }

    private func remember(_ width: Double?, keys: [String], display: DisplayDescriptor, among displays: [DisplayDescriptor]) {
        var all = load()
        for key in keys {
            var kept = (all[key] ?? []).filter { !Self.resolves($0.display, to: display, among: displays) }
            if width == nil || (width.map { $0.isFinite && BigTextLimits.widthRange.contains($0) } == true) {
                kept.append(Entry(display: DisplayMemory.Choice(id: display.id, name: display.name), looksLikeWidth: width ?? 0))
            }
            all[key] = kept.isEmpty ? nil : kept
        }
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

    private func roomOwners() -> [String: String] {
        defaults.dictionary(forKey: Self.roomOwnersKey) as? [String: String] ?? [:]
    }

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
