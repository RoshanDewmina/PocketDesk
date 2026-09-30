import Foundation

/// What the Home Screen widget may know about the paired Mac, shared through the App Group: its display
/// name, the last presence the app observed and when, and when it was last reached. Never keys, tokens,
/// rooms, addresses or screen content. Compiled into the app and the widget extension.
struct MacWidgetSnapshot: Codable, Equatable {
    enum Presence: String, Codable, Equatable {
        /// Connected, or its Farside answered a check.
        case awake
        /// The Mac itself said it went to sleep, was locked, or another user took over.
        case asleep, locked, otherUser
        /// The Mac answered but said Screen Recording is off.
        case screenRecordingOff
        /// The Mac answered but said macOS paused its screen recording until approved there.
        case screenRecordingApproval
        /// A check or an attempt went unanswered. The cause is unknown.
        case notAnswering

        var label: String {
            switch self {
            case .awake: "Awake"
            case .asleep: "Asleep"
            case .locked: "Locked"
            case .otherUser: "Another user"
            case .screenRecordingOff: "Screen Recording off"
            case .screenRecordingApproval: "Approve on Mac"
            case .notAnswering: "Not answering"
            }
        }
    }

    static let appGroup = "group.com.roshan.PocketDesk"
    static let defaultsKey = "macWidgetSnapshot"
    static let maximumNameLength = 64

    var macName: String
    var presence: Presence?
    var presenceAt: Date?
    var lastReached: Date?

    init(macName: String, presence: Presence? = nil, presenceAt: Date? = nil, lastReached: Date? = nil) {
        self.macName = String(macName.prefix(Self.maximumNameLength))
        self.presence = presence
        self.presenceAt = presence == nil ? nil : presenceAt
        self.lastReached = lastReached
    }

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Nil when the group is unavailable, empty or holds something unreadable: the widget then says "Your Mac".
    static func load(from defaults: UserDefaults? = sharedDefaults) -> MacWidgetSnapshot? {
        guard let data = defaults?.data(forKey: defaultsKey), data.count <= 4096,
              let snapshot = try? JSONDecoder().decode(MacWidgetSnapshot.self, from: data),
              !snapshot.macName.isEmpty, snapshot.macName.count <= maximumNameLength else { return nil }
        return snapshot
    }

    /// Writes the snapshot, or clears it when nil. Returns true when what is stored changed.
    @discardableResult
    static func store(_ snapshot: MacWidgetSnapshot?, in defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard let defaults else { return false }
        guard snapshot != load(from: defaults) else { return false }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        return true
    }
}
