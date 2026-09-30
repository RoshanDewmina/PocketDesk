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

    func width(forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> Double? { nil }
    func remember(_ width: Double?, forRoom room: String, display: DisplayDescriptor, among displays: [DisplayDescriptor]) {}
    func forget(room: String) {}
}
