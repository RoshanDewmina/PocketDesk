import Foundation

/// What a Live Activity shows in its `.small` family (Watch Smart Stack and CarPlay): at most three
/// lines and no controls. A plain value so the session activity today and LA2 later draw the same way.
struct WatchGlance: Equatable {
    enum Mark: Equatable { case plain, needsYou }

    enum Detail: Equatable {
        case text(String)
        /// A system-drawn clock, so the glance stays right between updates.
        case clock(prefix: String?, interval: ClosedRange<Date>, countsDown: Bool)
    }

    var mark: Mark
    var title: String
    var detail: Detail
    var note: String?
    var accessibilityLabel: String
}

enum SessionGlance {
    static func glance(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState,
                       isStale: Bool, now: Date = .now) -> WatchGlance {
        WatchGlance(mark: .plain, title: "", detail: .text(""), note: nil, accessibilityLabel: "")
    }
}

/// Mac presence as LA2's content state will carry it (names from the Mac vitals spec). Every field is
/// optional and an unknown state decodes as not seen, because a state that fails to decode silently
/// stops a Live Activity from updating.
struct MacPresence: Codable, Hashable {
    enum State: String { case awake, asleep, notSeen }

    var macState: String?
    var macSeenUnix: Int?
    var batteryPercent: Int?
    var power: String?

    var state: State { .notSeen }
    var seenAt: Date? { nil }
}

enum MacGlanceLine {
    static func text(for presence: MacPresence?, isStale: Bool,
                     timeZone: TimeZone = .current, locale: Locale = .current) -> String? { nil }
}
