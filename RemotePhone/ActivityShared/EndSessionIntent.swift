import ActivityKit
import AppIntents
import Foundation
import os

/// What the End session intent reaches. The app installs a handler once its model exists. Without one
/// (the system launched the process only to run the intent, or the intent ran in another process) the
/// intent still ends every session activity, so a Lock Screen never keeps a stale kill switch.
@MainActor
protocol SessionIntentHandling: AnyObject {
    /// Releases the Mac and ends the Live Activity. Called for Siri, Shortcuts, the Action button and
    /// the Live Activity's End button.
    func endSessionFromIntent() async -> SessionEndOutcome
}

enum SessionEndOutcome: Equatable {
    case ended
    case nothingToEnd
}

@MainActor
final class SessionIntentBridge {
    static let shared = SessionIntentBridge()
    private let log = Logger(subsystem: "com.roshan.PocketDesk.Remote", category: "session-intent")
    weak var handler: (any SessionIntentHandling)?

    func endSession() async -> SessionEndOutcome {
        log.info("End session intent in \(ProcessInfo.processInfo.processName, privacy: .public), handler: \(self.handler != nil)")
        if let handler { return await handler.endSessionFromIntent() }
        let ended = await SessionActivityStore.endAll(.user)
        return ended ? .ended : .nothingToEnd
    }
}

/// Reads and ends this app's session activities. Shared so the intent works wherever it runs.
enum SessionActivityStore {
    /// How long an ended activity stays on the Lock Screen: long enough to read why, never the
    /// platform's four-hour default.
    static func dismissalDelay(for reason: FarsideSessionAttributes.EndReason) -> TimeInterval {
        reason == .user ? 6 : 90
    }

    @discardableResult
    static func endAll(_ reason: FarsideSessionAttributes.EndReason) async -> Bool {
        let showing = Activity<FarsideSessionAttributes>.activities
        for activity in showing {
            await end(activity, reason: reason)
        }
        return !showing.isEmpty
    }

    static func end(_ activity: Activity<FarsideSessionAttributes>, reason: FarsideSessionAttributes.EndReason) async {
        let final = ActivityContent(state: FarsideSessionAttributes.ContentState.ended(reason), staleDate: nil)
        let policy: ActivityUIDismissalPolicy = .after(Date().addingTimeInterval(dismissalDelay(for: reason)))
        await activity.end(final, dismissalPolicy: policy)
    }
}

/// Ends the current session. Always allowed: it only moves toward safety, so it must work from a
/// locked phone, from the Lock Screen and from the Action button without an unlock.
struct EndSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "End session" }
    static var description: IntentDescription? {
        IntentDescription("Ends your Farside session.")
    }
    static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SessionIntentBridge.shared.endSession() {
        case .ended: return .result(dialog: "Session ended.")
        case .nothingToEnd: return .result(dialog: "There is no open session.")
        }
    }
}
