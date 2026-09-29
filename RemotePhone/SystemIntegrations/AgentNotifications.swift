import Foundation
import UserNotifications

/// What the person chose about agent alerts, session Live Activities and their names on the Lock
/// Screen. Every default is the private one: nothing is on until the person turns it on, except the
/// session Live Activity, which only ever exists while they hold a session.
struct AgentAlertPreferences {
    enum Key {
        static let alerts = "agentAlerts.enabled"
        static let breakThroughFocus = "agentAlerts.breakThroughFocus"
        static let showAgentName = "agentAlerts.showAgentName"
        static let showMacName = "lockScreen.showMacName"
        static let sessionActivity = "lockScreen.sessionActivity"
    }

    var defaults: UserDefaults = .standard

    private func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    /// Agent alerts (beta). Off until the person turns them on, which is also when iOS is asked.
    var alertsEnabled: Bool {
        get { flag(Key.alerts, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.alerts) }
    }

    /// Time Sensitive delivery: lights the screen through Focus. iOS lets the person turn it off.
    var breakThroughFocus: Bool {
        get { flag(Key.breakThroughFocus, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.breakThroughFocus) }
    }

    /// Show "Claude Code needs you" rather than "An agent needs you". Only names from the fixed list.
    var showAgentName: Bool {
        get { flag(Key.showAgentName, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.showAgentName) }
    }

    /// Put the Mac's name on the Lock Screen and Dynamic Island. Off: "Your Mac".
    var showMacNameOnLockScreen: Bool {
        get { flag(Key.showMacName, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.showMacName) }
    }

    /// Show the session on the Lock Screen and in the Dynamic Island while the app is in the background.
    var sessionLiveActivity: Bool {
        get { flag(Key.sessionActivity, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.sessionActivity) }
    }
}

enum AgentNotification {
    static let snoozeAction = "SNOOZE_15"
    static let notNowAction = "NOT_NOW"
    static let titleKey = "AGENT_NEEDS_YOU_TITLE"
    static let bodyKey = "AGENT_NEEDS_YOU_BODY"
    static let testBodyKey = "AGENT_TEST_BODY"
    static let reminderBodyKey = "AGENT_REMINDER_BODY"
    /// Shown instead of the body when the person hides previews. Generic on purpose.
    static let hiddenPreviewPlaceholder = "An agent needs you."
    static let snoozeDelay: TimeInterval = 15 * 60

    static func reminderIdentifier(for id: String) -> String { "agent-snooze-\(id)" }

    /// One category with two background actions, neither `.foreground` and neither destructive: the
    /// tap on the body is the way in, and a "Take over" button would only repeat it. Never `.authenticationRequired`
    /// either, because neither action touches the Mac.
    static func categories() -> Set<UNNotificationCategory> {
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze 15 min", options: [])
        let notNow = UNNotificationAction(identifier: notNowAction, title: "Not now", options: [])
        let help = UNNotificationCategory(
            identifier: AgentAlertPayload.categoryIdentifier,
            actions: [snooze, notNow],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: hiddenPreviewPlaceholder,
            options: [.customDismissAction, .hiddenPreviewsShowTitle]
        )
        // The one reminder after Snooze cannot be snoozed again.
        let reminder = UNNotificationCategory(
            identifier: AgentAlertPayload.reminderCategoryIdentifier,
            actions: [notNow],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: hiddenPreviewPlaceholder,
            options: [.customDismissAction, .hiddenPreviewsShowTitle]
        )
        return [help, reminder]
    }

    /// The notification for the Settings "Send test alert" button. It looks and routes like a real
    /// one, and says plainly that it is a test.
    static func testContent(preferences: AgentAlertPreferences, id: String = "h_test" + String(UUID().uuidString.prefix(4)).lowercased()) -> UNMutableNotificationContent {
        let payload = AgentAlertPayload(helpRequestID: id, kind: .other, threadID: "mac-test",
                                        interruption: preferences.breakThroughFocus ? .timeSensitive : .active, isTest: true)
        let content = UNMutableNotificationContent()
        content.title = String(format: NSLocalizedString(titleKey, comment: ""), AgentKind.genericName)
        content.body = NSLocalizedString(testBodyKey, comment: "")
        content.categoryIdentifier = AgentAlertPayload.categoryIdentifier
        content.threadIdentifier = "mac-test"
        content.userInfo = payload.userInfo
        content.sound = .default
        content.relevanceScore = 1
        content.interruptionLevel = preferences.breakThroughFocus ? .timeSensitive : .active
        return content
    }

    /// A "needs you" the Mac reported over the control channel while this app held the session in the
    /// background: the local twin of the push the service would send. Same words, same routing.
    static func alertContent(for payload: AgentAlertPayload, preferences: AgentAlertPreferences) -> UNMutableNotificationContent {
        var shown = payload
        shown.interruption = preferences.breakThroughFocus ? .timeSensitive : .active
        let content = UNMutableNotificationContent()
        let name = preferences.showAgentName ? payload.kind.displayName : AgentKind.genericName
        content.title = String(format: NSLocalizedString(titleKey, comment: ""), name)
        content.body = NSLocalizedString(bodyKey, comment: "")
        content.categoryIdentifier = AgentAlertPayload.categoryIdentifier
        content.threadIdentifier = payload.threadID ?? "mac-agent"
        content.userInfo = shown.userInfo
        content.sound = .default
        content.relevanceScore = 1
        content.interruptionLevel = preferences.breakThroughFocus ? .timeSensitive : .active
        return content
    }

    /// The single quiet reminder after Snooze. Passive: no light, no sound, no Focus break-through.
    static func reminderContent(for payload: AgentAlertPayload, showAgentName: Bool) -> UNMutableNotificationContent {
        var reminder = payload
        reminder.isReminder = true
        reminder.interruption = .passive
        let content = UNMutableNotificationContent()
        let name = showAgentName ? payload.kind.displayName : AgentKind.genericName
        content.title = String(format: NSLocalizedString(titleKey, comment: ""), name)
        content.body = NSLocalizedString(reminderBodyKey, comment: "")
        content.categoryIdentifier = AgentAlertPayload.reminderCategoryIdentifier
        content.threadIdentifier = payload.threadID ?? "mac-agent"
        content.userInfo = reminder.userInfo
        content.relevanceScore = 0.3
        content.interruptionLevel = .passive
        return content
    }
}

enum NotificationAccess: Equatable {
    case unknown, notDetermined, denied, allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .allowed
        @unknown default: self = .unknown
        }
    }
}

/// The parts of `UNUserNotificationCenter` Farside uses, so the logic around it is testable.
@MainActor
protocol AgentNotificationScheduling: AnyObject {
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func access() async -> (access: NotificationAccess, timeSensitive: UNNotificationSetting)
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async -> Bool
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
    func pendingIdentifiers() async -> [String]
}

@MainActor
final class SystemNotificationCenter: AgentNotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func access() async -> (access: NotificationAccess, timeSensitive: UNNotificationSetting) {
        let settings = await center.notificationSettings()
        return (NotificationAccess(settings.authorizationStatus), settings.timeSensitiveSetting)
    }

    func requestAuthorization() async -> Bool {
        // Never provisional: quiet delivery is wrong for "needs you". Never asked at launch.
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        do { try await center.add(request); return true } catch { return false }
    }

    func removePending(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}
