import Foundation

/// A "needs you" notification as the phone reads it: from a remote push, or from the local twin the
/// Settings "Send test alert" button and a Snooze reminder schedule. The payload schema is the one in
/// SYSTEM-INTEGRATIONS.md section 4.2:
///
///     {"aps": {"alert": {"title-loc-key": "AGENT_NEEDS_YOU_TITLE", "title-loc-args": ["Claude Code"],
///                        "loc-key": "AGENT_NEEDS_YOU_BODY"},
///              "category": "AGENT_HELP", "thread-id": "mac-7f3a",
///              "interruption-level": "time-sensitive", "relevance-score": 1.0, "sound": "default"},
///      "hid": "h_20af"}
///
/// Parsing is strict about what routes and lenient about what is merely extra. It never returns
/// text from the payload except a name from the fixed agent list.
struct AgentAlertPayload: Equatable {
    static let categoryIdentifier = "AGENT_HELP"
    static let reminderCategoryIdentifier = "AGENT_HELP_REMINDER"

    enum Interruption: String, Equatable {
        case passive, active, timeSensitive = "time-sensitive", critical
    }

    var helpRequestID: String
    var kind: AgentKind
    var threadID: String?
    var interruption: Interruption?
    /// A reminder Farside scheduled itself after Snooze. It is passive and asks nothing new.
    var isReminder: Bool
    /// The Settings "Send test alert" notification. It exercises the whole path with no agent.
    var isTest: Bool

    init(helpRequestID: String, kind: AgentKind, threadID: String? = nil, interruption: Interruption? = nil,
         isReminder: Bool = false, isTest: Bool = false) {
        self.helpRequestID = helpRequestID
        self.kind = kind
        self.threadID = threadID
        self.interruption = interruption
        self.isReminder = isReminder
        self.isTest = isTest
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let aps = userInfo["aps"] as? [String: Any],
              let category = aps["category"] as? String,
              category == Self.categoryIdentifier || category == Self.reminderCategoryIdentifier,
              let id = userInfo["hid"] as? String, FarsideRoute.isValidID(id) else { return nil }
        helpRequestID = id
        isReminder = category == Self.reminderCategoryIdentifier
        isTest = userInfo["test"] as? Bool == true

        let alert = aps["alert"] as? [String: Any]
        let names = alert?["title-loc-args"] as? [Any]
        if let name = names?.first as? String {
            kind = AgentKind(displayName: name)
        } else {
            kind = AgentKind(wire: userInfo["kind"] as? String)
        }
        threadID = (aps["thread-id"] as? String).flatMap { FarsideRoute.isValidID($0) ? $0 : nil }
        interruption = (aps["interruption-level"] as? String).flatMap(Interruption.init(rawValue:))
    }

    /// The payload's `userInfo` for a local twin: exactly the fields the parser reads back.
    var userInfo: [AnyHashable: Any] {
        var aps: [String: Any] = [
            "category": isReminder ? Self.reminderCategoryIdentifier : Self.categoryIdentifier,
            "alert": ["title-loc-key": "AGENT_NEEDS_YOU_TITLE", "title-loc-args": [kind.displayName],
                      "loc-key": "AGENT_NEEDS_YOU_BODY"] as [String: Any]
        ]
        if let threadID { aps["thread-id"] = threadID }
        if let interruption { aps["interruption-level"] = interruption.rawValue }
        var result: [AnyHashable: Any] = ["aps": aps, "hid": helpRequestID]
        if isTest { result["test"] = true }
        return result
    }
}

/// One help request on screen: the sheet for a tap, or the banner over a live session.
struct AgentAlertPresentation: Identifiable, Equatable {
    /// Requests are asked about for this long. Older ones still open, worded honestly.
    static let freshFor: TimeInterval = 15 * 60

    enum Freshness: Equatable {
        case fresh
        case old
    }

    var id: String { payload.helpRequestID }
    var payload: AgentAlertPayload
    var receivedAt: Date

    func freshness(at now: Date) -> Freshness {
        now.timeIntervalSince(receivedAt) > Self.freshFor ? .old : .fresh
    }

    /// "just now", "2 min ago", "1 hr ago": short, and never a fake precision.
    static func ageText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 45 { return "just now" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hr ago" : "\(hours) hr ago"
    }
}
