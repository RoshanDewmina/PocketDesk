import Foundation

struct MacVitalsMemory {
    struct LastSeen: Codable, Equatable {
        var percent: Int
        var at: Date
    }

    static let defaultsKey = "macVitalsLastSeen"
    static let lifetime: TimeInterval = 12 * 60 * 60
    static let threshold = 10
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ vitals: MacVitals?, at date: Date) {}
    func lastSeen(now: Date) -> LastSeen? { nil }
    func forget() {}
    static func homeNote(_ seen: LastSeen) -> String { "" }
    static func sleepNote(_ seen: LastSeen) -> String { "" }
}
