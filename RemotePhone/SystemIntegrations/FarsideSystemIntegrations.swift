import AppIntents
import Combine
import SwiftUI

/// Joins the phone model to everything the system reaches into: intents, links, notifications and the
/// session Live Activity. The model stays unaware of all of it; the app attaches it once, so a model
/// made in a unit test has no side effects.
@MainActor
final class FarsideSystemIntegrations {
    static let shared = FarsideSystemIntegrations()

    let activity: SessionActivityController
    /// The paired Mac as the Live Activity names it: an opaque id and the name. Tests replace it.
    var macIdentity: () -> (macId: String, name: String)? = { nil }
    private(set) weak var model: PhoneRemoteModel?
    private var observers: Set<AnyCancellable> = []
    private var advertisedRoom: String?
    private var lastSnapshot: SessionSnapshot?
    private var lastSessionActivityChoice = true

    init(activity: SessionActivityController? = nil) {
        let controller = activity ?? SessionActivityController(client: ActivityKitSessionClient())
        self.activity = controller
        controller.identity = { [weak self] in self?.macIdentity() }
    }

    func attach(_ model: PhoneRemoteModel) {
        guard self.model !== model else { return }
        self.model = model
        observers.removeAll()
        lastSnapshot = nil
        SessionIntentBridge.shared.handler = self
        MacStatusService.shared.currentSession = { [weak model] in
            guard let model else { return (false, false) }
            return (model.connection.connected, model.connection.isRunning)
        }
        AgentAlertCenter.shared.isSessionLive = { [weak model] in model?.connection.connected == true }
        macIdentity = { [weak model] in
            model?.connection.invitation.map { (PairedMacs.opaqueID(room: $0.room), $0.name) }
        }
        Task {
            await AgentAlertCenter.shared.refreshAccess()
            await activity.reconcileOnLaunch()
        }
        // objectWillChange fires before the change lands, so read the state one turn later.
        Publishers.Merge(model.objectWillChange.map { _ in () }, model.connection.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.modelChanged() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.modelChanged(force: true) }
            .store(in: &observers)
        lastSessionActivityChoice = activity.preferences().sessionLiveActivity
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.preferencesMayHaveChanged() }
            .store(in: &observers)
        modelChanged()
        #if DEBUG
        DebugLaunchSeeds.applyPresentations(to: AgentAlertCenter.shared)
        DebugLaunchSeeds.applyActivity(to: activity)
        #endif
    }

    /// Turning the Lock Screen session off ends a running activity at once, not at the next change.
    private func preferencesMayHaveChanged() {
        let choice = activity.preferences().sessionLiveActivity
        guard choice != lastSessionActivityChoice else { return }
        lastSessionActivityChoice = choice
        modelChanged(force: true)
    }

    private func modelChanged(force: Bool = false) {
        guard let model else { return }
        pairingMayHaveChanged()
        let snapshot = model.sessionSnapshot
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        activity.apply(snapshot)
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

/// Applies requests that arrive from outside the view hierarchy, and presents what they open.
struct FarsideSystemRoutes: ViewModifier {
    private enum ActiveSheet: Identifiable {
        case alert(AgentAlertPresentation)
        case settings

        var id: String {
            switch self {
            case .alert(let item): "alert.\(item.id)"
            case .settings: "settings"
            }
        }
    }

    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var onboarding: OnboardingFlow
    @ObservedObject private var inbox = SystemRequestInbox.shared
    @ObservedObject private var alerts = AgentAlertCenter.shared
    @State private var sheet: ActiveSheet?

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
            .onChange(of: alerts.presentation) { _, item in if let item { sheet = .alert(item) } }
            .onChange(of: alerts.showsSettings) { _, shown in if shown { sheet = .settings } }
            .sheet(item: sheetBinding, onDismiss: sheetDismissed) { active in
                switch active {
                case .alert(let item):
                    AgentAlertSheet(item: item, center: alerts, sessionLive: model.connection.connected,
                                    openMac: { alerts.presentation = nil; sheet = nil
                                        SystemRequestInbox.shared.post(.connect(macID: nil)) },
                                    close: { alerts.presentation = nil; sheet = nil })
                        .presentationDetents([.fraction(0.72), .large])
                        .farsideSheet()
                case .settings:
                    AgentAlertsSettingsSheet(center: alerts, registrar: .shared)
                }
            }
            .overlay(alignment: .top) {
                if let banner = alerts.banner {
                    AgentAlertBanner(item: banner, showName: alerts.preferences.showAgentName) { alerts.dismissBanner() }
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Farside.Motion.easeOut(), value: alerts.banner)
    }

    /// Nothing covers the first-run explanations: a sheet waits until they are gone.
    private var sheetBinding: Binding<ActiveSheet?> {
        Binding(get: { onboarding.step == nil ? sheet : nil }, set: { sheet = $0 })
    }

    private func sheetDismissed() {
        alerts.presentation = nil
        alerts.showsSettings = false
    }

    private func drain() {
        for request in inbox.drain() { handle(request) }
    }

    private func handle(_ request: SystemRequest) {
        switch request {
        case .connect:
            connectIfPossible()
        case .route(let route):
            switch route {
            case .agentAlert(let id): alerts.open(linkedRequest: id)
            case .openMac, .resumeSession: break
            }
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
