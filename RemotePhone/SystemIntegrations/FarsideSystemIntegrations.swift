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
    /// Only an admitted route may register a server-ended activity. Nil keeps the activity local.
    var activityRouteEpoch: () -> String? = { nil }
    var activityPushEnvironment: () -> SessionActivityPushEnvironment? = {
        SessionActivityPushEnvironment.configured()
    }
    private(set) weak var model: PhoneRemoteModel?
    private var observers: Set<AnyCancellable> = []
    private var advertisedRoom: String?
    private var lastActivityPushPairing: SessionActivityPushPairing?
    private var lastSnapshot: SessionSnapshot?
    private var lastSessionActivityChoice = true
    private var lastWidgetObservation: String?

    init(activity: SessionActivityController? = nil,
         activityPushSink: any SessionActivityPushSink = HTTPSessionActivityPushSink()) {
        let controller = activity ?? SessionActivityController(
            client: ActivityKitSessionClient(pushSink: activityPushSink))
        self.activity = controller
        controller.identity = { [weak self] in self?.macIdentity() }
        controller.pushPairing = { [weak self] in self?.currentActivityPushPairing() }
    }

    func attach(_ model: PhoneRemoteModel) {
        guard self.model !== model else { return }
        self.model = model
        activityRouteEpoch = { [weak model] in model?.connection.routePolicyEpoch }
        observers.removeAll()
        lastSnapshot = nil
        lastActivityPushPairing = nil
        SessionIntentBridge.shared.handler = self
        MacStatusService.shared.currentSession = { [weak model] in
            guard let model else { return (false, false) }
            return (model.connection.connected, model.connection.isRunning)
        }
        AgentAlertCenter.shared.isSessionLive = { [weak model] in model?.connection.connected == true }
        macIdentity = { [weak model] in
            guard let invitation = model?.connection.invitation, let id = PairedMacs.id(for: invitation) else { return nil }
            return (id, invitation.name)
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
        widgetMayHaveChanged(model, force: force)
        let pushPairing = currentActivityPushPairing()
        let pushChanged = pushPairing != lastActivityPushPairing
        if pushChanged {
            lastActivityPushPairing = pushPairing
            activity.pushContextDidChange()
        }
        let snapshot = model.sessionSnapshot
        guard force || pushChanged || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        activity.apply(snapshot)
    }

    private func currentActivityPushPairing() -> SessionActivityPushPairing? {
        guard let invitation = model?.connection.invitation,
              let pairingID = PairedMacs.id(for: invitation),
              let epoch = activityRouteEpoch(), let environment = activityPushEnvironment() else { return nil }
        return SessionActivityPushPairing(server: invitation.server, room: invitation.room,
                                          token: invitation.token, routeEpoch: epoch,
                                          pairingID: pairingID, environment: environment)
    }

    /// The Connect widget's snapshot follows only what changed: the paired Mac or an observed presence.
    private func widgetMayHaveChanged(_ model: PhoneRemoteModel, force: Bool) {
        let connection = model.connection
        let failure = connection.isRunning ? nil
            : FriendlyError.from(status: connection.status, previous: nil, macName: "")?.kind
        let observed = MacWidgetSync.observedPresence(connected: connection.connected, departure: model.lastDeparture,
                                                      failure: failure)
        let name = connection.invitation?.name
        let key = "\(connection.invitation?.room ?? "")|\(name ?? "")|\(observed?.rawValue ?? "")"
        guard force || key != lastWidgetObservation else { return }
        lastWidgetObservation = key
        MacWidgetSync.shared.update(macName: name, room: connection.invitation?.room, observed: observed)
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
        case connectPrompt(macID: String, invitation: PairInvitation)
        case serverData

        var id: String {
            switch self {
            case .alert(let item): "alert.\(item.id)"
            case .settings: "settings"
            case .connectPrompt: "connectPrompt"
            case .serverData: "serverData"
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
                if url.scheme == "farside", url.host == "pair" { model.stagePairingLink(url); return }
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
                                        guard let identity = item.payload.pairingIdentity,
                                              let mac = PairedMacs.mac(notificationIdentity: identity),
                                              mac.invitation?.notificationIdentity == identity else {
                                            model.error = "That alert’s Mac is no longer paired."
                                            return
                                        }
                                        connectExplicitly(macID: mac.id, expected: mac.invitation) },
                                    close: { alerts.presentation = nil; sheet = nil })
                        .presentationDetents([.fraction(0.72), .large])
                        .farsideSheet()
                case .settings:
                    AgentAlertsSettingsSheet(center: alerts, registrar: .shared)
                case .connectPrompt(let macID, let invitation):
                    ConnectPromptSheet(macName: invitation.name,
                                       connect: {
                                           sheet = nil
                                           guard PairedMacs.mac(withID: macID)?.invitation == invitation else {
                                               model.error = "That pairing changed. Select your Mac again."
                                               return
                                           }
                                           connectExplicitly(macID: macID, expected: invitation)
                                       },
                                       close: { sheet = nil })
                        .presentationDetents([.medium])
                        .farsideSheet()
                case .serverData:
                    ServerDataRemovalView(connection: model.connection, access: AnywhereAccess.shared).farsideSheet()
                }
            }
            .overlay(alignment: .top) {
                if let banner = alerts.banner {
                    AgentAlertBanner(item: banner) { alerts.dismissBanner() }
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
        case .connect(let macID):
            if let macID {
                connectExplicitly(macID: macID, expected: nil)
            } else {
                connectIfPossible()
            }
        case .route(let route):
            switch route {
            case .agentAlert(let id): alerts.open(linkedRequest: id)
            case .openMac:
                let connection = model.connection
                if ConnectPromptSheet.macName(paired: connection.invitation?.name,
                                                         connected: connection.connected, running: connection.isRunning) != nil {
                    if let invitation = connection.invitation, let id = PairedMacs.id(for: invitation) {
                        sheet = .connectPrompt(macID: id, invitation: invitation)
                    }
                }
            case .resumeSession: break
            }
        }
    }

    private func connectExplicitly(macID: String, expected: PairInvitation?) {
        guard let target = PairedMacs.mac(withID: macID), let invitation = target.invitation,
              expected == nil || invitation == expected,
              model.selectPairedMac(id: target.id), model.connection.invitation == invitation else {
            model.error = "That Mac is no longer paired or could not be selected."
            return
        }
        connectIfPossible()
    }

    /// The same path as the Connect button, including a pending server-data removal; a system request
    /// never restarts an attempt that is already under way.
    private func connectIfPossible() {
        ConnectGate.connect(model: model, onboarding: onboarding, restartsRunning: false) { sheet = .serverData }
    }
}

extension View {
    func farsideSystemRoutes(model: PhoneRemoteModel, onboarding: OnboardingFlow) -> some View {
        modifier(FarsideSystemRoutes(model: model, onboarding: onboarding))
    }
}
