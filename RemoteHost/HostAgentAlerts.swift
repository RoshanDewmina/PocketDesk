import Foundation

/// The Mac's side of agent alerts: switches the bridge on and off, decides what each alert becomes, and
/// hands it to the phone. Off until the person turns it on, and it forwards only a kind, a request id and
/// a time. When a phone session is live the alert travels over the control channel; otherwise the
/// pairing-scoped service may hand a generic alert to APNs.
@MainActor
final class HostAgentAlerts: ObservableObject {
    enum HookScriptInstallResult: Equatable {
        case installed(URL)
        case missingBundledScript
        case writeFailed
    }

    /// Emergency rollback for the hook-copy failure fix. Set before launch to restore the previous
    /// placeholder-and-copy behavior; unset (the default) keeps the failure safe.
    static let hookCopyFailureDisabled = UserDefaults.standard.bool(forKey: "farsideAgentHookCopyFailureDisabled")

    struct Record: Equatable {
        var kind: AgentKind
        var event: AgentAlertEvent
        var at: Date
        var disposition: AgentAlertDisposition
    }

    @Published private(set) var isOn: Bool
    @Published private(set) var completedOn: Bool
    @Published private(set) var failedOn: Bool
    @Published private(set) var last: Record?
    @Published private(set) var failure: String?
    @Published private(set) var hookSetupFailure: String?

    var now: () -> Date = { Date() }
    /// A phone is connected and in a live session, so the control channel can carry the alert.
    var isPhoneLive: () -> Bool = { false }
    var hasPairedPhone: () -> Bool = { false }
    /// Hands the alert to the live control channel. False when it could not be sent.
    var deliverToPhone: (AgentAlertFrame) -> Bool = { _ in false }
    var push: any AgentPushRelay = UnconfiguredAgentPushRelay()
    var canUsePush: () -> Bool = { false }
    var pushIdentity: () -> String? = { nil }
    var record: (String) -> Void = { _ in }

    private var gate = AgentAlertGate()
    private var deliveryRevision: UInt64 = 0
    private var bridge: AgentAlertBridge?
    private let directory: URL
    private var preferences: HostPreferences

    init(preferences: HostPreferences = HostPreferences(), directory: URL = AgentAlertBridge.defaultDirectory) {
        self.preferences = preferences
        self.directory = directory
        isOn = preferences.agentAlerts
        completedOn = preferences.completedAlerts
        failedOn = preferences.failedAlerts
    }

    var discoveryFile: URL { directory.appendingPathComponent(AgentAlertBridge.fileName) }

    /// Starts the bridge when alerts were left on, at launch.
    func startIfEnabled() async {
        guard anyEnabled else { return }
        await startBridge()
    }

    func setEnabled(_ on: Bool) async {
        preferences.agentAlerts = on
        isOn = on
        deliveryRevision &+= 1
        if anyEnabled { if bridge == nil { await startBridge() } } else { stopBridge() }
    }

    var anyEnabled: Bool { isOn || completedOn || failedOn }
    private func accepts(_ event: AgentAlertEvent) -> Bool {
        switch event {
        case .needsUser: isOn
        case .completed: completedOn
        case .failed: failedOn
        }
    }
    func setOutcome(_ event: AgentAlertEvent, enabled: Bool) async {
        switch event {
        case .needsUser: await setEnabled(enabled); return
        case .completed: preferences.completedAlerts = enabled; completedOn = enabled
        case .failed: preferences.failedAlerts = enabled; failedOn = enabled
        }
        deliveryRevision &+= 1
        if anyEnabled { if bridge == nil { await startBridge() } } else { stopBridge() }
    }

    func shutDown() {
        stopBridge()
    }

    /// New token, so every hook configured with the old one stops working until it re-reads the file.
    func resetLink() {
        do {
            deliveryRevision &+= 1
            try bridge?.rotateToken()
            record("Agent alert link reset")
        } catch {
            failure = "Could not reset the agent link."
        }
    }

    private func startBridge() async {
        stopBridge()
        let revision = deliveryRevision
        let bridge = AgentAlertBridge(directory: directory) { [weak self] alert in
            guard let self else { return .disabled }
            return await self.receive(alert)
        }
        do {
            try await bridge.start()
            guard anyEnabled, deliveryRevision == revision else { bridge.stop(); return }
            self.bridge = bridge
            failure = nil
            record("Agent alerts on: listening on this Mac only")
        } catch {
            failure = "Agent alerts could not start listening."
            record("Agent alerts could not start")
        }
    }

    private func stopBridge() {
        deliveryRevision &+= 1
        bridge?.stop()
        bridge = nil
        gate = AgentAlertGate()
    }

    /// One alert from a hook.
    func receive(_ alert: AgentAlert) async -> AgentAlertDisposition {
        guard accepts(alert.event) else { return .disabled }
        let disposition = await dispatch(alert)
        last = Record(kind: alert.kind, event: alert.event, at: now(), disposition: disposition)
        return disposition
    }

    private func dispatch(_ alert: AgentAlert) async -> AgentAlertDisposition {
        guard hasPairedPhone() else { return .noPhone }
        switch gate.decide(sessionHash: alert.sessionHash, now: now(), event: alert.event, runHash: alert.runHash, eventID: alert.id) {
        case .duplicate:
            return .duplicate
        case .rateLimited:
            record("An agent alert was held back: too many this hour")
            return .rateLimited
        case .admit:
            break
        }
        if isPhoneLive(), deliverToPhone(alert.frame) {
            record(alert.event.isAttention ? "Told your iPhone that \(alert.kind.displayName) needs you" : "Told your iPhone a task \(alert.event.rawValue)")
            return .forwarded
        }
        guard canUsePush(), let identity = pushIdentity() else { return .pushUnavailable }
        let revision = deliveryRevision
        let outcome = await push.deliver(alert)
        guard revision == deliveryRevision, accepts(alert.event), canUsePush(), pushIdentity() == identity else { return .pushUnavailable }
        switch outcome {
        case .sent:
            record(alert.event.isAttention ? "Notification accepted for your iPhone: \(alert.kind.displayName) needs you" : "Notification accepted for your iPhone: a task \(alert.event.rawValue)")
            return .pushed
        case .unavailable(let reason):
            record("Could not reach a phone that is not in a session: \(reason)")
            return .pushUnavailable
        }
    }

    nonisolated static let scriptName = "farside-notify"

    /// Copies the hook script next to the discovery file. An agent's configuration points there, so it
    /// keeps working when the app is updated or moved.
    func installScript(from bundled: URL?) -> HookScriptInstallResult {
        guard let bundled else { return .missingBundledScript }
        let destination = directory.appendingPathComponent(Self.scriptName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let script = try Data(contentsOf: bundled)
            if (try? Data(contentsOf: destination)) != script {
                try script.write(to: destination, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            return .installed(destination)
        } catch {
            return .writeFailed
        }
    }

    /// Builds the setup text and writes it only after a successful install. The injected writer keeps
    /// the failure path testable without touching the system pasteboard.
    @discardableResult
    func copyHookSetup(from bundled: URL?, failureDisabled: Bool, writeToClipboard: (String) -> Void) -> Bool {
        let scriptPath: String
        switch installScript(from: bundled) {
        case .installed(let url):
            hookSetupFailure = nil
            scriptPath = url.path
        case .missingBundledScript where failureDisabled:
            scriptPath = "/path/to/\(Self.scriptName)"
        case .writeFailed where failureDisabled:
            scriptPath = "/path/to/\(Self.scriptName)"
        case .missingBundledScript:
            hookSetupFailure = "Agent hook setup could not be copied because its script is missing."
            return false
        case .writeFailed:
            hookSetupFailure = "Agent hook setup could not be copied because the script could not be installed."
            return false
        }
        writeToClipboard(Self.hookSetup(scriptPath: scriptPath))
        return true
    }

    /// One line for Settings: that the Mac is listening, or what the last alert did.
    func statusLine(now: Date = Date()) -> String? {
        if let hookSetupFailure { return hookSetupFailure }
        guard anyEnabled else { return nil }
        if let failure { return failure }
        guard let last else { return "Listening on this Mac only" }
        let seconds = Int(max(0, now.timeIntervalSince(last.at)))
        let age = seconds < 45 ? "just now" : seconds < 3600 ? "\((seconds + 30) / 60) min ago" : "\(seconds / 3600) hr ago"
        let outcome: String
        switch last.disposition {
        case .forwarded: outcome = "told your iPhone"
        case .pushed: outcome = "notification accepted for your iPhone"
        case .duplicate: outcome = "already told"
        case .rateLimited: outcome = "held back: too many this hour"
        case .noPhone: outcome = "no phone is paired"
        case .pushUnavailable: outcome = "your iPhone is not in a session, and push is not on yet"
        case .disabled, .ignored: outcome = "ignored"
        }
        return last.event.isAttention ? "\(last.kind.displayName) asked \(age) · \(outcome)" : "A task \(last.event.rawValue) \(age) · \(outcome)"
    }

    // MARK: Setup text

    /// The hook setup the Mac offers to copy. It shows the exact files an agent would read, and what the
    /// hook sends, so nothing is written to an agent's configuration without the person seeing it.
    nonisolated static func hookSetup(scriptPath: String) -> String {
        """
        Farside agent alerts: hook setup

        What it does: when an agent on this Mac needs a person, its hook runs farside-notify, which tells
        Farside on this Mac, which tells your iPhone. It sends only the agent's kind and a hash of its
        session id. Never a prompt, a file name or the agent's own words.

        Script: \(scriptPath)

        Claude Code: add to ~/.claude/settings.json (or a project's .claude/settings.json)
        \(hooksJSON(agent: "claude-code", scriptPath: scriptPath))

        Codex: add to ~/.codex/hooks.json, then review and trust it with /hooks
        \(hooksJSON(agent: "codex", scriptPath: scriptPath))

        For a local job wrapper, report only its actual exit status with a new opaque run id each time:
        "\(scriptPath)" --agent other --session JOB_ID --run RUN_ID --exit-status "$status" --no-stdin
        Capture status=$? immediately after your local job. Stop and idle hooks never mean success.
        Completion and failure alerts each need their own opt-in on the Mac and iPhone.

        The same JSON is printed by: "\(scriptPath)" --print-hooks claude-code
        """
    }

    /// Codex has no Notification event, so its hook file carries only the permission request.
    nonisolated static func hooksJSON(agent: String, scriptPath: String) -> String {
        let command = "\"\(scriptPath)\" --agent \(agent)"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let permission = #"{ "hooks": [ { "type": "command", "command": "\#(escaped)", "timeout": 5 } ] }"#
        if agent == "codex" {
            return """
            {
              "hooks": {
                "PermissionRequest": [
                  \(permission)
                ]
              }
            }
            """
        }
        return """
        {
          "hooks": {
            "PermissionRequest": [
              \(permission)
            ],
            "Notification": [
              { "matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog",
                "hooks": [ { "type": "command", "command": "\(escaped)", "timeout": 5 } ] }
            ]
          }
        }
        """
    }
}

/// APNs acceptance is the only positive result. It cannot prove that iOS displayed a notification.
actor HTTPAgentPushRelay: AgentPushRelay {
    private let url: URL
    private let room: String
    private let hostToken: String
    private let session: URLSession

    init?(pair: HostPair) {
        guard pair.paired, let origin = PushPairingTarget.origin(for: pair.invitation.server),
              SecureRandom.isToken(pair.invitation.room), SecureRandom.isToken(pair.hostToken),
              SecureRandom.digest(pair.hostToken) == pair.invitation.room else { return nil }
        url = origin.appendingPathComponent("v1/push/event")
        room = pair.invitation.room
        hostToken = pair.hostToken
        session = URLSession(configuration: .ephemeral, delegate: AgentPushNoRedirect(), delegateQueue: nil)
    }

    func deliver(_ alert: AgentAlert) async -> AgentPushOutcome {
        guard (!alert.event.isAttention || alert.kind == .claudeCode || alert.kind == .codex),
              (alert.event.isAttention || alert.runHash.map(AgentAlert.isSessionHash) == true),
              alert.id.hasPrefix("h_"),
              alert.id.count == 14,
              AgentAlert.isSessionHash(alert.sessionHash) else {
            return .unavailable("This agent event cannot use push.")
        }
        var body: [String: Any] = [
            "room": room, "hostToken": hostToken, "id": alert.id,
            "kind": alert.kind.rawValue, "event": alert.event.rawValue,
            "sessionHash": alert.sessionHash,
            "raisedAt": Int(alert.raisedAt.timeIntervalSince1970.rounded())
        ]
        if let runHash = alert.runHash { body["runHash"] = runHash }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .unavailable("Could not prepare agent alert.")
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url,
                  http.statusCode == 202,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return .unavailable("Push service did not accept this notification.")
            }
            switch result["state"] {
            case "accepted": return .sent
            case "held": return .unavailable("The service held back a repeated or excess alert.")
            default: return .unavailable("Push service did not accept this notification.")
            }
        } catch {
            return .unavailable("Push service is unavailable.")
        }
    }
}

private final class AgentPushNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
