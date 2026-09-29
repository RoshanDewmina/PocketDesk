import Foundation

#if DEBUG
/// Launch switches for UI tests and simulator captures. They keep a paired Mac in memory, so a test
/// never touches the Keychain item a real pairing lives in and nothing outlives the run.
///
///     --ui-seed-pairing=Studio Mac    a paired Mac whose service address refuses connections at once
enum DebugLaunchSeeds {
    /// One invitation per process, so the model, the intents and Shortcuts all agree on the Mac's id.
    static let invitation: PairInvitation? = {
        guard let name = LaunchOptions.value("--ui-seed-pairing="), !name.isEmpty else { return nil }
        return try? HostPair.create(server: "ws://127.0.0.1:9/signal", name: name).invitation
    }()

    /// A store that starts with the seeded invitation and forgets it when the app quits.
    static func store() -> (any PairPersistence)? {
        invitation.map { InMemoryPairStore(invitation: $0) }
    }

    /// Presents what a notification tap or the Home row would, for captures and UI tests:
    ///
    ///     --ui-agent-settings                    the Agent alerts sheet
    ///     --ui-agent-alert=claude_code[:option]  the sheet a tap opens; options: test, reminder, old
    ///     --ui-agent-banner=codex                the quiet banner shown over a live session
    ///     --ui-session-live                      treat a session as live for alert presentation
    @MainActor
    static func applyPresentations(to alerts: AgentAlertCenter) {
        if LaunchOptions.has("--ui-session-live") { alerts.isSessionLive = { true } }
        if LaunchOptions.has("--ui-agent-settings") { alerts.showsSettings = true }
        if let spec = LaunchOptions.value("--ui-agent-alert=") {
            let parts = spec.split(separator: ":").map(String.init)
            var payload = AgentAlertPayload(helpRequestID: "h_ui01", kind: AgentKind(wire: parts.first), threadID: "mac-ui",
                                            interruption: .timeSensitive)
            let options = Set(parts.dropFirst())
            payload.isTest = options.contains("test")
            payload.isReminder = options.contains("reminder")
            let asked = Date().addingTimeInterval(options.contains("old") ? -40 * 60 : -90)
            alerts.open(payload, deliveredAt: asked)
        }
        if let spec = LaunchOptions.value("--ui-agent-banner=") {
            let payload = AgentAlertPayload(helpRequestID: "h_ui02", kind: AgentKind(wire: spec), threadID: "mac-ui")
            alerts.showBanner(AgentAlertPresentation(payload: payload, receivedAt: Date()))
        }
    }

    /// Starts a labelled sample Live Activity, held in one state for captures, or walking through all:
    ///
    ///     --ui-live-activity=live|paused|reconnecting|ended|tour
    @MainActor
    static func applyActivity(to controller: SessionActivityController) {
        guard let spec = LaunchOptions.value("--ui-live-activity=") else { return }
        if spec == "tour" {
            controller.startPreview()
        } else if let phase = FarsideSessionAttributes.Phase(rawValue: spec) {
            controller.startPreview(hold: phase)
        }
    }
}

final class InMemoryPairStore: PairPersistence {
    private var data: Data?

    init(invitation: PairInvitation) {
        data = try? JSONEncoder().encode(invitation)
    }

    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }

    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        try data.map { try JSONDecoder().decode(type, from: $0) }
    }

    func delete() throws { data = nil }
}
#endif

enum LaunchSeeds {
    /// The pairing store for a launch that seeds one, and nil (the Keychain) for every real launch.
    static func pairingStore() -> (any PairPersistence)? {
        #if DEBUG
        DebugLaunchSeeds.store()
        #else
        nil
        #endif
    }
}
