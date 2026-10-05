import Foundation

/// A "needs you" notification as the phone reads it: from a remote push, or from the local twin the
/// Settings "Send test alert" button and a Snooze reminder schedule. The payload schema is the one in
/// SYSTEM-INTEGRATIONS.md section 4.2, minus the agent name it once carried (Guideline 4.5.4):
///
///     {"aps": {"alert": {"title-loc-key": "AGENT_NEEDS_YOU_TITLE", "loc-key": "AGENT_NEEDS_YOU_BODY"},
///              "category": "AGENT_HELP", "thread-id": "mac-7f3a",
///              "interruption-level": "time-sensitive", "relevance-score": 1.0, "sound": "default"},
///      "hid": "h_20af", "pairing": "<opaque pairing identity>"}
///
/// Parsing is strict about what routes and lenient about what is merely extra. It never returns
/// text from the payload, and ignores `title-loc-args` an older service may still send.
struct AgentAlertPayload: Equatable {
    static let categoryIdentifier = "AGENT_HELP"
    static let outcomeCategoryIdentifier = "AGENT_OUTCOME"
    static let reminderCategoryIdentifier = "AGENT_HELP_REMINDER"

    enum Interruption: String, Equatable {
        case passive, active, timeSensitive = "time-sensitive", critical
    }

    var helpRequestID: String
    /// Full opaque identity of the pairing that produced this alert. Missing legacy alerts cannot
    /// report an answer or open the currently paired Mac.
    var pairingIdentity: String?
    var event: AgentAlertEvent
    var kind: AgentKind
    var threadID: String?
    var interruption: Interruption?
    /// A reminder Farside scheduled itself after Snooze. It is passive and asks nothing new.
    var isReminder: Bool
    /// The Settings "Send test alert" notification. It exercises the whole path with no agent.
    var isTest: Bool

    init(helpRequestID: String, kind: AgentKind, pairingIdentity: String? = nil,
         threadID: String? = nil, interruption: Interruption? = nil,
         isReminder: Bool = false, isTest: Bool = false, event: AgentAlertEvent = .needsUser) {
        self.event = event
        self.helpRequestID = helpRequestID
        self.pairingIdentity = pairingIdentity
        self.kind = kind
        self.threadID = threadID
        self.interruption = interruption
        self.isReminder = isReminder
        self.isTest = isTest
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let aps = userInfo["aps"] as? [String: Any],
              let category = aps["category"] as? String,
              [Self.categoryIdentifier, Self.reminderCategoryIdentifier, Self.outcomeCategoryIdentifier].contains(category),
              let id = userInfo["hid"] as? String, FarsideRoute.isValidID(id) else { return nil }
        if category == Self.outcomeCategoryIdentifier {
            guard let value = userInfo["event"] as? String, let understood = AgentAlertEvent(rawValue: value),
                  !understood.isAttention else { return nil }
            event = understood
        } else {
            guard userInfo["event"] == nil || userInfo["event"] as? String == AgentAlertEvent.needsUser.rawValue else { return nil }
            event = .needsUser
        }
        helpRequestID = id
        pairingIdentity = (userInfo["pairing"] as? String).flatMap { SecureRandom.isToken($0) ? $0 : nil }
        isReminder = category == Self.reminderCategoryIdentifier
        isTest = userInfo["test"] as? Bool == true

        kind = AgentKind(wire: userInfo["kind"] as? String)
        threadID = (aps["thread-id"] as? String).flatMap { FarsideRoute.isValidID($0) ? $0 : nil }
        interruption = (aps["interruption-level"] as? String).flatMap(Interruption.init(rawValue:))
    }

    /// The payload's `userInfo` for a local twin: exactly the fields the parser reads back. The kind
    /// travels as its wire spelling outside `alert`, so the system never displays it.
    var userInfo: [AnyHashable: Any] {
        var aps: [String: Any] = [
            "category": event.isAttention ? (isReminder ? Self.reminderCategoryIdentifier : Self.categoryIdentifier) : Self.outcomeCategoryIdentifier,
            "alert": ["title-loc-key": event.titleKey, "loc-key": event.bodyKey] as [String: Any]
        ]
        if let threadID { aps["thread-id"] = threadID }
        if let interruption { aps["interruption-level"] = interruption.rawValue }
        var result: [AnyHashable: Any] = ["aps": aps, "hid": helpRequestID]
        if !event.isAttention { result["event"] = event.rawValue }
        if kind != .other { result["kind"] = kind.rawValue }
        if let pairingIdentity { result["pairing"] = pairingIdentity }
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
