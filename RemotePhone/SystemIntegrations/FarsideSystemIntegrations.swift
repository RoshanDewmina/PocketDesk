import AppIntents
import Combine
import SwiftUI

/// Joins the phone model to everything the system reaches into: intents, links, notifications and the
/// session Live Activity. The model stays unaware of all of it; the app attaches it once, so a model
/// made in a unit test has no side effects.
@MainActor
final class FarsideSystemIntegrations {
    static let shared = FarsideSystemIntegrations()

    private(set) weak var model: PhoneRemoteModel?
    private var observers: Set<AnyCancellable> = []
    private var advertisedRoom: String?

    func attach(_ model: PhoneRemoteModel) {
        guard self.model !== model else { return }
        self.model = model
        observers.removeAll()
        SessionIntentBridge.shared.handler = self
        MacStatusService.shared.currentSession = { [weak model] in
            guard let model else { return (false, false) }
            return (model.connection.connected, model.connection.isRunning)
        }
        model.connection.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pairingMayHaveChanged() }
            .store(in: &observers)
        pairingMayHaveChanged()
    }

    /// Siri and Shortcuts learn the Mac's name for spoken parameters, so tell them when it changes.
    private func pairingMayHaveChanged() {
        let room = model?.connection.invitation?.room
        guard room != advertisedRoom else { return }
        advertisedRoom = room
        FarsideShortcuts.updateAppShortcutParameters()
    }
}

extension FarsideSystemIntegrations: SessionIntentHandling {
    func endSessionFromIntent() async -> SessionEndOutcome {
        guard let model else {
            return await SessionActivityStore.endAll(.user) ? .ended : .nothingToEnd
        }
        let hadSession = model.connection.connected || model.connection.isRunning
        // Releases held input, tells the Mac and stops the coordinator. It works while the app is in
        // the background hold, which is exactly when the Lock Screen button is used.
        model.disconnect()
        let hadActivity = await SessionActivityStore.endAll(.user)
        return hadSession || hadActivity ? .ended : .nothingToEnd
    }
}

/// Applies requests that arrive from outside the view hierarchy.
struct FarsideSystemRoutes: ViewModifier {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var onboarding: OnboardingFlow
    @ObservedObject private var inbox = SystemRequestInbox.shared

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                if let route = FarsideRoute(url: url) { SystemRequestInbox.shared.post(.route(route)) }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let route = FarsideRoute(url: url) {
                    SystemRequestInbox.shared.post(.route(route))
                }
            }
            .onChange(of: inbox.pending, initial: true) { _, _ in drain() }
    }

    private func drain() {
        for request in inbox.drain() { handle(request) }
    }

    private func handle(_ request: SystemRequest) {
        switch request {
        case .connect:
            connectIfPossible()
        case .route:
            // Routes are navigation only. Opening the app is the navigation for the Mac and the session;
            // the alert sheet joins in with the notification work.
            break
        }
    }

    /// The same path as the Connect button: Local Network is explained once before the first attempt.
    private func connectIfPossible() {
        let connection = model.connection
        guard connection.invitation != nil, !connection.connected, !connection.isRunning else { return }
        model.error = ""
        onboarding.beforeConnect { connection.start() }
    }
}

extension View {
    func farsideSystemRoutes(model: PhoneRemoteModel, onboarding: OnboardingFlow) -> some View {
        modifier(FarsideSystemRoutes(model: model, onboarding: onboarding))
    }
}
