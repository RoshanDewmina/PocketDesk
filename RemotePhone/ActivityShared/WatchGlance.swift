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
    /// Drawn after the title as ` · <suffix>` and redacted like the Lock Screen's line: it carries the Mac's
    /// name when the person opted in to showing it.
    var sensitiveTitleSuffix: String? = nil

    var displayTitle: String { [title, sensitiveTitleSuffix].compactMap { $0 }.joined(separator: " · ") }
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
        func make(_ title: String, _ detail: WatchGlance.Detail, note: String? = nil, suffix: String? = nil) -> WatchGlance {
            WatchGlance(mark: .plain, title: title, detail: detail, note: note, accessibilityLabel: "", sensitiveTitleSuffix: suffix)
        }
        if isStale { return make("Session ended?", .text("Check your iPhone.")) }
        switch state.phase {
        case .live:
            let started = attributes.startedAt
            return make("Live",
                        .clock(prefix: nil, interval: started...started.addingTimeInterval(8 * 60 * 60), countsDown: false),
                        note: "End it on your iPhone.", suffix: attributes.macLabel)
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
/// optional, and an unknown state or a field of the wrong type decodes as absent, because a state that
/// fails to decode silently stops a Live Activity from updating.
struct MacPresence: Codable, Hashable {
    enum State: String { case awake, asleep, notSeen }

    var macState: String?
    var macSeenUnix: Int?
    var batteryPercent: Int?
    var power: String?

    init(macState: String? = nil, macSeenUnix: Int? = nil, batteryPercent: Int? = nil, power: String? = nil) {
        self.macState = macState
        self.macSeenUnix = macSeenUnix
        self.batteryPercent = batteryPercent
        self.power = power
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macState = try? container.decodeIfPresent(String.self, forKey: .macState)
        macSeenUnix = try? container.decodeIfPresent(Int.self, forKey: .macSeenUnix)
        batteryPercent = try? container.decodeIfPresent(Int.self, forKey: .batteryPercent)
        power = try? container.decodeIfPresent(String.self, forKey: .power)
    }

    var state: State { State(rawValue: macState ?? "") ?? .notSeen }
    var seenAt: Date? { macSeenUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

enum MacGlanceLine {
    static func text(for presence: MacPresence?, isStale: Bool,
                     timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let presence else { return nil }
        // A narrow am/pm marker ("12:59 p", not "12:59 PM") keeps 12-hour locales inside 40 mm.
        let style = Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
            .hour(.defaultDigits(amPM: .narrow)).minute()
        let seen = presence.seenAt.map { $0.formatted(style) }
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
