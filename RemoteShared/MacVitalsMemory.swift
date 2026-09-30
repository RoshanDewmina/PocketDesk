import Foundation

struct MacVitalsMemory {
    struct LastSeen: Codable, Equatable {
        var percent: Int
        var at: Date
    }

    static let defaultsKey = "macVitalsLastSeen"
    static let lifetime: TimeInterval = 12 * 60 * 60
    static let threshold = 10
    // Tolerates small clock skew; anything further ahead would otherwise outlive `lifetime`.
    static let futureTolerance: TimeInterval = 5 * 60
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ vitals: MacVitals?, at date: Date) {
        guard let vitals, vitals.onBattery, let percent = vitals.batteryPercent, percent <= Self.threshold,
              let data = try? JSONEncoder().encode(LastSeen(percent: percent, at: date)) else {
            forget()
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func lastSeen(now: Date) -> LastSeen? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let seen = try? JSONDecoder().decode(LastSeen.self, from: data),
              now.timeIntervalSince(seen.at) <= Self.lifetime,
              seen.at.timeIntervalSince(now) <= Self.futureTolerance else {
            forget()
            return nil
        }
        return seen
    }

    func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    static func homeNote(_ seen: LastSeen) -> String { "Last seen on battery · \(seen.percent)%" }
    static func sleepNote(_ seen: LastSeen) -> String { "It was on battery at \(seen.percent)%, which may be why." }
}
