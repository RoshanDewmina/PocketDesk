import Foundation
import SwiftUI
import UserNotifications

/// What the person answered, ready to tell the service that holds the request.
///
/// Push delivery needs a service that keeps help requests (SYSTEM-INTEGRATIONS.md section 6), and none
/// exists yet, so nothing is sent. The responses are kept in order so the day that service exists the
/// phone already says the right thing, and tests can read exactly what would be sent.
struct AgentAlertResponse: Equatable {
    enum Kind: String { case opened, snoozed, declined, dismissed }
    var helpRequestID: String
    var kind: Kind
    var at: Date
}

@MainActor
final class AgentAlertReports {
    static let shared = AgentAlertReports()
    private(set) var queued: [AgentAlertResponse] = []
    static let capacity = 32

    func record(_ response: AgentAlertResponse) {
        queued.append(response)
        if queued.count > Self.capacity { queued.removeFirst(queued.count - Self.capacity) }
    }
}

/// Decides what a "needs you" notification does: which surface it takes over, what Snooze and Not now
/// mean, and when the phone stays quiet. Routing never grants authority: opening a request shows a
/// sheet, and nothing connects until the person chooses to.
@MainActor
final class AgentAlertCenter: ObservableObject {
    static let shared = AgentAlertCenter()

    enum Action: Equatable {
        case open, snooze, notNow, dismissed

        init?(actionIdentifier: String) {
            switch actionIdentifier {
            case UNNotificationDefaultActionIdentifier: self = .open
            case AgentNotification.snoozeAction: self = .snooze
            case AgentNotification.notNowAction: self = .notNow
            case UNNotificationDismissActionIdentifier: self = .dismissed
            default: return nil
            }
        }
    }

    enum EnableResult: Equatable {
        case enabled
        /// iOS has not asked yet: explain first, then call `requestAndEnable`.
        case needsPriming
        /// The person said no in iOS Settings, where only they can change it.
        case deniedInSettings
    }

    /// The sheet for a tapped notification or link.
    @Published var presentation: AgentAlertPresentation?
    /// A quiet banner over a live session, where the picture already shows the Mac.
    @Published private(set) var banner: AgentAlertPresentation?
    @Published var showsSettings = false
    @Published private(set) var access: NotificationAccess = .unknown
    @Published private(set) var timeSensitive: UNNotificationSetting = .notSupported

    var center: any AgentNotificationScheduling
    var preferences: AgentAlertPreferences
    var reports: AgentAlertReports
    /// Whether a session with the Mac is live right now. The app installs it.
    var isSessionLive: () -> Bool = { false }
    /// Whether the app is in front. False while it holds a session in the background.
    var isForeground: () -> Bool = { UIApplication.shared.applicationState == .active }
    var now: () -> Date = { Date() }
    var registerForRemoteNotifications: () -> Void = {}
    var unregisterForRemoteNotifications: () -> Void = {}

    private let defaults: UserDefaults
    private var bannerTask: Task<Void, Never>?
    private var seenFromMac: [String] = []
    static let bannerSeconds: Double = 12
    private static let snoozedKey = "agentAlerts.snoozedIDs"
    private static let declinedKey = "agentAlerts.declinedIDs"
    private static let rememberedIDs = 64

    init(center: (any AgentNotificationScheduling)? = nil, defaults: UserDefaults = .standard,
         reports: AgentAlertReports? = nil) {
        self.center = center ?? SystemNotificationCenter()
        self.defaults = defaults
        self.preferences = AgentAlertPreferences(defaults: defaults)
        self.reports = reports ?? .shared
    }

    // MARK: Remembered answers

    private func remembered(_ key: String) -> [String] { defaults.stringArray(forKey: key) ?? [] }

    private func remember(_ id: String, in key: String) {
        var ids = remembered(key).filter { $0 != id }
        ids.append(id)
        defaults.set(Array(ids.suffix(Self.rememberedIDs)), forKey: key)
    }

    func wasSnoozed(_ id: String) -> Bool { remembered(Self.snoozedKey).contains(id) }
    func wasDeclined(_ id: String) -> Bool { remembered(Self.declinedKey).contains(id) }

    // MARK: Setup and permission

    func registerCategories() {
        center.setCategories(AgentNotification.categories())
    }

    func refreshAccess() async {
        let current = await center.access()
        access = current.access
        timeSensitive = current.timeSensitive
    }

    /// Turning alerts on is the moment to ask iOS, never launch. Off removes what is scheduled and
    /// forgets this phone's push address.
    func setAlertsEnabled(_ on: Bool) async -> EnableResult {
        guard on else {
            preferences.alertsEnabled = false
            center.removePending(remembered(Self.snoozedKey).map(AgentNotification.reminderIdentifier))
            unregisterForRemoteNotifications()
            return .enabled
        }
        await refreshAccess()
        switch access {
        case .allowed:
            preferences.alertsEnabled = true
            registerForRemoteNotifications()
            return .enabled
        case .denied:
            return .deniedInSettings
        case .notDetermined, .unknown:
            return .needsPriming
        }
    }

    @discardableResult
    func requestAndEnable() async -> Bool {
        let granted = await center.requestAuthorization()
        await refreshAccess()
        guard granted, access == .allowed else { return false }
        preferences.alertsEnabled = true
        registerForRemoteNotifications()
        return true
    }

    /// "Send test alert": a local notification that looks and routes like a real one. It also gives
    /// App Review a way to see the feature without any agent.
    @discardableResult
    func sendTestAlert(after delay: TimeInterval = 1) async -> Bool {
        await refreshAccess()
        guard access == .allowed else { return false }
        let content = AgentNotification.testContent(preferences: preferences)
        let request = UNNotificationRequest(identifier: "agent-test-\(UUID().uuidString.prefix(8))", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false))
        return await center.add(request)
    }

    // MARK: Delivery

    /// While a session is live the picture already shows the Mac, so an alert becomes a quiet banner
    /// instead of covering it. A request the person already declined is not announced again.
    func presentationOptions(for payload: AgentAlertPayload, deliveredAt: Date) -> UNNotificationPresentationOptions {
        if wasDeclined(payload.helpRequestID) { return [] }
        if isSessionLive() {
            showBanner(AgentAlertPresentation(payload: payload, receivedAt: deliveredAt))
            return []
        }
        return payload.isReminder ? [.banner, .list] : [.banner, .list, .sound]
    }

    /// A tap, an action button or a swipe-away on a "needs you" notification.
    func respond(_ action: Action, to payload: AgentAlertPayload, deliveredAt: Date, notificationIdentifier: String?) async {
        let id = payload.helpRequestID
        switch action {
        case .open:
            reports.record(.init(helpRequestID: id, kind: .opened, at: now()))
            open(payload, deliveredAt: deliveredAt)
        case .snooze:
            reports.record(.init(helpRequestID: id, kind: .snoozed, at: now()))
            if let notificationIdentifier { center.removeDelivered([notificationIdentifier]) }
            // One reminder per request: a second Snooze is quietly the same as dismissing.
            guard !wasSnoozed(id), !wasDeclined(id) else { return }
            remember(id, in: Self.snoozedKey)
            let request = UNNotificationRequest(
                identifier: AgentNotification.reminderIdentifier(for: id),
                content: AgentNotification.reminderContent(for: payload, showAgentName: preferences.showAgentName),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: AgentNotification.snoozeDelay, repeats: false))
            _ = await center.add(request)
        case .notNow:
            reports.record(.init(helpRequestID: id, kind: .declined, at: now()))
            remember(id, in: Self.declinedKey)
            center.removePending([AgentNotification.reminderIdentifier(for: id)])
            if let notificationIdentifier { center.removeDelivered([notificationIdentifier]) }
            if presentation?.id == id { presentation = nil }
            if banner?.id == id { banner = nil }
        case .dismissed:
            // A swipe is not a decision: the agent is still waiting and the app still lists it.
            reports.record(.init(helpRequestID: id, kind: .dismissed, at: now()))
        }
    }

    func open(_ payload: AgentAlertPayload, deliveredAt: Date) {
        banner = nil
        presentation = AgentAlertPresentation(payload: payload, receivedAt: deliveredAt)
    }

    /// From a link that names only the request. The link carries no agent name, so it says "An agent".
    func open(linkedRequest id: String) {
        open(AgentAlertPayload(helpRequestID: id, kind: .other), deliveredAt: now())
    }

    /// An alert the Mac sent over the control channel, which only exists while a session is live. With the
    /// app in front it is one quiet banner over the picture; while the app holds the session in the
    /// background it becomes the notification a push would have been. Alerts must be on, a request is
    /// announced once, and a declined one never again.
    func receive(fromMac frame: AgentAlertFrame) {
        guard frame.isUnderstood, preferences.alertsEnabled, !wasDeclined(frame.id),
              !seenFromMac.contains(frame.id) else { return }
        seenFromMac.append(frame.id)
        if seenFromMac.count > 32 { seenFromMac.removeFirst(seenFromMac.count - 32) }
        let payload = AgentAlertPayload(helpRequestID: frame.id, kind: frame.agentKind)
        if isForeground() {
            showBanner(AgentAlertPresentation(payload: payload, receivedAt: frame.raisedDate))
        } else {
            let request = UNNotificationRequest(
                identifier: "agent-mac-\(frame.id)",
                content: AgentNotification.alertContent(for: payload, preferences: preferences),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            Task { _ = await center.add(request) }
        }
    }

    func showBanner(_ item: AgentAlertPresentation) {
        guard !wasDeclined(item.id) else { return }
        banner = item
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.bannerSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }
}
