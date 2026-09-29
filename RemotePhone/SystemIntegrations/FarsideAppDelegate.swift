import SwiftUI
import UIKit
import UserNotifications
import os

/// Receives notification taps and actions. Set as the center's delegate before the app finishes
/// launching, so a tap that launches the app is not lost.
final class AgentNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let payload = AgentAlertPayload(userInfo: notification.request.content.userInfo) else {
            return [.banner, .list, .sound]
        }
        let deliveredAt = notification.date
        return await MainActor.run {
            AgentAlertCenter.shared.presentationOptions(for: payload, deliveredAt: deliveredAt)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let payload = AgentAlertPayload(userInfo: response.notification.request.content.userInfo),
              let action = AgentAlertCenter.Action(actionIdentifier: response.actionIdentifier) else { return }
        let deliveredAt = response.notification.date
        let identifier = response.notification.request.identifier
        await AgentAlertCenter.shared.respond(action, to: payload, deliveredAt: deliveredAt, notificationIdentifier: identifier)
    }
}

final class FarsideAppDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "com.roshan.PocketDesk.Remote", category: "push")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = AgentNotificationRouter.shared
        let alerts = AgentAlertCenter.shared
        alerts.registerCategories()
        alerts.registerForRemoteNotifications = { UIApplication.shared.registerForRemoteNotifications() }
        alerts.unregisterForRemoteNotifications = {
            UIApplication.shared.unregisterForRemoteNotifications()
            PushRegistrar.shared.forget()
        }
        // Only a person who turned alerts on has any reason to hold a push address.
        if alerts.preferences.alertsEnabled { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
        PushRegistrar.shared.failed(error)
    }
}
