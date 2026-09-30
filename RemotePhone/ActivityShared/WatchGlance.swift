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
        var glance = body(attributes: attributes, state: state, isStale: isStale, now: now)
        glance.accessibilityLabel = SessionActivityCopy.accessibilitySummary(for: state, stale: isStale)
        if attributes.isPreview {
            glance.note = "Sample · preview"
            glance.accessibilityLabel = "Sample. " + glance.accessibilityLabel
        }
        return glance
    }

    private static func body(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState,
                             isStale: Bool, now: Date) -> WatchGlance {
        func make(_ title: String, _ detail: WatchGlance.Detail, note: String? = nil) -> WatchGlance {
            WatchGlance(mark: .plain, title: title, detail: detail, note: note, accessibilityLabel: "")
        }
        if isStale { return make("Session ended?", .text("Check your iPhone.")) }
        switch state.phase {
        case .live:
            let started = attributes.startedAt
            return make("Live · \(attributes.macLabel)",
                          .clock(prefix: nil, interval: started...started.addingTimeInterval(8 * 60 * 60), countsDown: false),
                          note: "End it on your iPhone.")
        case .paused:
            if let grace = state.graceEndsAt, grace > now {
                return make("Paused", .clock(prefix: "Lets go in", interval: now...grace, countsDown: true))
            }
            return make("Paused", .text("Lets go soon."))
        case .reconnecting:
            return make("Reconnecting", .text("Hold on."))
        case .ended:
            switch state.endedReason ?? .user {
            case .user: return make("Session ended", .text("Mac handed back."))
            case .timeout: return make("Farside let go", .text("You were away."))
            case .macStopped: return make("Sharing stopped", .text("Stopped at the Mac."))
            case .error: return make("Session ended", .text("Nothing left open."))
            }
        }
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

    var state: State { State(rawValue: macState ?? "") ?? .notSeen }
    var seenAt: Date? { macSeenUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

enum MacGlanceLine {
    static func text(for presence: MacPresence?, isStale: Bool,
                     timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let presence else { return nil }
        let seen = presence.seenAt.map { $0.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()) }
        switch (isStale ? MacPresence.State.notSeen : presence.state, seen) {
        case (.awake, let seen?):
            let battery = presence.batteryPercent.flatMap { (1...100).contains($0) ? " · \($0)%" : nil } ?? ""
            return "Mac · seen \(seen)\(battery)"
        case (.asleep, let seen?):
            return "Mac · asleep since \(seen)"
        case (.asleep, nil):
            return "Mac · asleep"
        case (_, let seen?):
            return "Not seen since \(seen)"
        case (_, nil):
            return "Mac not seen lately"
        }
    }
}
