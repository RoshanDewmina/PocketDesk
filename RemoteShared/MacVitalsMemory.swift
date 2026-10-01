import Foundation

/// The last low battery each Mac reported, kept per Mac so switching Macs never shows or erases another's.
struct MacVitalsMemory {
    struct LastSeen: Codable, Equatable {
        var percent: Int
        var at: Date
    }

    static let defaultsKey = "macVitalsLastSeenByMac"
    static let legacyDefaultsKey = "macVitalsLastSeen"
    static let lifetime: TimeInterval = 12 * 60 * 60
    static let threshold = 10
    // Tolerates small clock skew; anything further ahead would otherwise outlive `lifetime`.
    static let futureTolerance: TimeInterval = 5 * 60
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The single shared reading predates per-Mac keys; it can't be attributed to a Mac.
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    static func macKey(room: String?) -> String { String(SecureRandom.digest("farside-vitals|" + (room ?? "")).prefix(24)) }

    func record(_ vitals: MacVitals?, at date: Date, room: String?) {
        guard let vitals, vitals.onBattery, let percent = vitals.batteryPercent, percent <= Self.threshold else {
            forget(room: room)
            return
        }
        var all = load()
        all[Self.macKey(room: room)] = LastSeen(percent: percent, at: date)
        save(all)
    }

    func lastSeen(room: String?, now: Date) -> LastSeen? {
        guard let seen = load()[Self.macKey(room: room)],
              now.timeIntervalSince(seen.at) <= Self.lifetime,
              seen.at.timeIntervalSince(now) <= Self.futureTolerance else {
            forget(room: room)
            return nil
        }
        return seen
    }

    func forget(room: String?) {
        var all = load()
        guard all.removeValue(forKey: Self.macKey(room: room)) != nil else { return }
        save(all)
    }

    private func load() -> [String: LastSeen] {
        defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: LastSeen].self, from: $0) } ?? [:]
    }

    private func save(_ all: [String: LastSeen]) {
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func homeNote(_ seen: LastSeen) -> String { "Last seen on battery · \(seen.percent)%" }
    static func sleepNote(_ seen: LastSeen) -> String { "It was on battery at \(seen.percent)%, which may be why." }
}
