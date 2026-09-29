import Combine
import Foundation
import UIKit

/// This phone's push address and preferences, in the shape the service registry keeps
/// (SYSTEM-INTEGRATIONS.md section 6.3). No Mac name, no agent text, no screen content.
struct PushRegistration: Codable, Equatable {
    var deviceToken: String
    var environment: String
    var alertsEnabled: Bool
    var timeSensitive: Bool
    var showAgentName: Bool
    var locale: String
    var appBuild: String
    var osMajor: Int
    var updatedAt: Int
}

enum PushSubmission: Equatable {
    case sent
    /// Not sent, and why. Nothing is retried in the background: the next launch tries again.
    case notSent(String)
}

@MainActor
protocol PushRegistrationSink: AnyObject {
    func submit(_ registration: PushRegistration) async -> PushSubmission
    func disableAlerts() async -> PushSubmission
}

extension PushRegistrationSink {
    func disableAlerts() async -> PushSubmission { .notSent("Push removal is not configured.") }
}

/// Safe default until the app installs its HTTPS registry sink.
@MainActor
final class UnconfiguredPushSink: PushRegistrationSink {
    func submit(_ registration: PushRegistration) async -> PushSubmission {
        .notSent("No Farside push service is configured.")
    }
}

/// An HTTPS, pairing-scoped push registry. Its proof is only the phone token, never the screen key.
@MainActor
final class HTTPPushRegistrationSink: PushRegistrationSink {
    let target: PushPairingTarget
    private let session: URLSession

    init(target: PushPairingTarget) {
        self.target = target
        session = URLSession(configuration: .ephemeral, delegate: PushNoRedirect(), delegateQueue: nil)
    }

    func submit(_ registration: PushRegistration) async -> PushSubmission {
        guard let encoded = try? JSONEncoder().encode(registration),
              let object = try? JSONSerialization.jsonObject(with: encoded) else {
            return .notSent("Push registration could not be prepared.")
        }
        return await request("register", payload: ["registration": object])
    }

    func disableAlerts() async -> PushSubmission {
        await request("preferences", payload: ["alertsEnabled": false])
    }

    private func request(_ path: String, payload: [String: Any]) async -> PushSubmission {
        var value: [String: Any] = ["room": target.room, "token": target.token]
        value.merge(payload) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else {
            return .notSent("Push registration could not be prepared.")
        }
        var request = URLRequest(url: target.origin.appendingPathComponent("v1/push/\(path)"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                return .notSent("Push service did not confirm the request.")
            }
            if http.statusCode == 200 { return .sent }
            return .notSent("Push service did not confirm the request.")
        } catch { return .notSent("Push service is unavailable. Try again later.") }
    }
}

private final class PushNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Retains the current APNs address only in memory and syncs explicit preferences with the
/// pairing-scoped service. A failed opt-out keeps only the old pairing proof in Keychain.
struct PendingPushDisable: Codable, Hashable {
    let target: PushPairingTarget
}

@MainActor
final class PushRegistrar: ObservableObject {
    static let shared = PushRegistrar()

    enum Status: Equatable {
        case idle
        case registered
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSubmission: PushSubmission?
    var sinkForTarget: (PushPairingTarget) -> any PushRegistrationSink = { HTTPPushRegistrationSink(target: $0) }
    private(set) var target: PushPairingTarget?

    private let defaults: UserDefaults
    private let removalStore: any PairPersistence
    private let environmentOverride: String?
    private static let tokenKey = "push.deviceToken"
    private static let pendingRemovalKey = "push.pendingRemoval"
    private var currentToken: String?
    private var volatileRemovals: [PendingPushDisable] = []
    private var normalizedPending = false
    private var inFlight: Task<Void, Never>?
    private var submissionSequence = 0

    init(defaults: UserDefaults = .standard, environmentOverride: String? = nil,
         removalStore: any PairPersistence = PairStore(account: "phone.push-removal.v1")) {
        self.defaults = defaults
        self.environmentOverride = environmentOverride
        self.removalStore = removalStore
        // Legacy unbound cached addresses cannot safely be sent under an arbitrary new pairing.
        defaults.removeObject(forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.pendingRemovalKey)
    }

    var deviceToken: String? { currentToken }

    static var environment: String? {
        switch Bundle.main.object(forInfoDictionaryKey: "FarsideAPNSEnvironment") as? String {
        case "development": "sandbox"
        case "production": "production"
        default: nil
        }
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    func received(token: Data) {
        guard AgentAlertPreferences(defaults: defaults).alertsEnabled else {
            Task { await submit() }
            return
        }
        currentToken = Self.hex(token)
        status = .idle
        Task { await submit() }
    }

    func configure(invitation: PairInvitation?) {
        let next = invitation.flatMap(PushPairingTarget.init)
        guard next != target else { return }
        let hadPair = target != nil
        status = .idle
        if hadPair { stageCurrentDisable() }
        target = next
        if hadPair { currentToken = nil }
        Task { await submit() }
    }

    func failed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    func forget() {
        status = .idle
        stageCurrentDisable()
        lastSubmission = nil
        Task { await submit() }
    }

    private func stageCurrentDisable() {
        guard let target else { currentToken = nil; return }
        let pending = PendingPushDisable(target: target)
        currentToken = nil
        do {
            var saved = try removalStore.read([PendingPushDisable].self) ?? []
            if !saved.contains(pending) { saved.append(pending) }
            try removalStore.save(saved)
        } catch {
            if !volatileRemovals.contains(pending) { volatileRemovals.append(pending) }
            status = .failed("Alert opt-out could not be saved. Unlock this iPhone and retry.")
        }
    }

    /// The registration a service would store for this phone, or nil when there is no address yet.
    func registration(preferences supplied: AgentAlertPreferences? = nil,
                      now: Date = Date()) -> PushRegistration? {
        guard let deviceToken, let environment = environmentOverride ?? Self.environment else { return nil }
        let preferences = supplied ?? AgentAlertPreferences(defaults: defaults)
        return PushRegistration(
            deviceToken: deviceToken,
            environment: environment,
            alertsEnabled: preferences.alertsEnabled,
            timeSensitive: preferences.breakThroughFocus,
            showAgentName: preferences.showAgentName,
            locale: Locale.current.identifier,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            updatedAt: Int(now.timeIntervalSince1970)
        )
    }

    func submit() async {
        let previous = inFlight
        submissionSequence += 1
        let sequence = submissionSequence
        let next = Task { @MainActor in
            await previous?.value
            await self.syncOnce()
            if self.submissionSequence == sequence { self.inFlight = nil }
        }
        inFlight = next
        await next.value
    }

    private func syncOnce() async {
        var saved: [PendingPushDisable]
        do { saved = try removalStore.read([PendingPushDisable].self) ?? [] }
        catch {
            status = .failed("Alert opt-out is waiting for Keychain. Unlock this iPhone and retry.")
            return
        }
        if !normalizedPending, !saved.isEmpty {
            // This also strips the device-token field from cleanup records written by the
            // earlier beta adapter; the pairing proof alone is sufficient now.
            do { try removalStore.save(saved); normalizedPending = true }
            catch {
                status = .failed("Alert opt-out is waiting for Keychain. Unlock this iPhone and retry.")
                return
            }
        }
        // Re-enabling the same pairing supersedes an offline opt-out. Remove its retry before a
        // fresh registration so an old retry can never erase the newly enabled address.
        if AgentAlertPreferences(defaults: defaults).alertsEnabled, let target {
            let keep = saved.filter { $0.target != target }
            if keep.count != saved.count {
                do {
                    if keep.isEmpty { try removalStore.delete() } else { try removalStore.save(keep) }
                    saved = keep
                } catch {
                    status = .failed("Alert preferences are waiting for Keychain. Unlock this iPhone and retry.")
                    return
                }
            }
            volatileRemovals.removeAll { $0.target == target }
        }
        var removalFailed = false
        var removalFailureMessage: String?
        let removals = Array(Set(saved + volatileRemovals))
        for pending in removals {
            let result = await sinkForTarget(pending.target).disableAlerts()
            lastSubmission = result
            if result == .sent {
                do {
                    var current = try removalStore.read([PendingPushDisable].self) ?? []
                    current.removeAll { $0 == pending }
                    if current.isEmpty { try removalStore.delete() } else { try removalStore.save(current) }
                    volatileRemovals.removeAll { $0 == pending }
                } catch {
                    removalFailureMessage = "Alert opt-out was confirmed, but local cleanup needs Keychain."
                    removalFailed = true
                }
            } else {
                removalFailureMessage = "Alert opt-out is pending. Retry when the service is available."
                removalFailed = true
            }
        }
        if let removalFailureMessage { status = .failed(removalFailureMessage) }
        else if !removals.isEmpty { status = .idle }
        guard let deviceToken else { return }
        guard AgentAlertPreferences(defaults: defaults).alertsEnabled else {
            forget()
            return
        }
        guard let registration = registration() else {
            status = .failed("This build has no APNs environment.")
            return
        }
        guard let target else { return }
        let result = await sinkForTarget(target).submit(registration)
        guard self.target == target, self.currentToken == deviceToken,
              AgentAlertPreferences(defaults: defaults).alertsEnabled else { return }
        lastSubmission = result
        switch result {
        case .sent: status = removalFailed ? .failed("An older pairing still needs alert opt-out.") : .registered
        case .notSent(let reason): status = .failed(reason)
        }
    }
}

/// Binds the beta alert adapters to the phone's current pairing and HTTPS origin.
@MainActor
final class AgentPushIntegration {
    static let shared = AgentPushIntegration()

    private weak var model: PhoneRemoteModel?
    private var observers: Set<AnyCancellable> = []
    private var currentTarget: PushPairingTarget?
    private var previousPreferences: (enabled: Bool, timeSensitive: Bool, showName: Bool)?

    func attach(_ model: PhoneRemoteModel) {
        guard self.model !== model else { return }
        self.model = model
        AgentAlertCenter.shared.currentPairingIdentity = { [weak model] in
            #if DEBUG
            if let preview = DebugLaunchSeeds.alertPreviewIdentity { return preview }
            #endif
            guard AnywhereAccess.shared.phoneConnectionAllowed,
                  model?.connection.startAllowed?() != false else { return nil }
            return model?.connection.invitation?.notificationIdentity
        }
        observers.removeAll()
        model.connection.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        AnywhereAccess.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(force: true) }
            .store(in: &observers)
        refresh(force: true)
    }

    private func refresh(force: Bool = false) {
        let mayRegister = AnywhereAccess.shared.phoneConnectionAllowed && model?.connection.startAllowed?() != false
        let invitation = mayRegister ? model?.connection.invitation : nil
        let next = invitation.flatMap(PushPairingTarget.init)
        let pairChanged = next != currentTarget
        if pairChanged {
            currentTarget = next
            PushRegistrar.shared.configure(invitation: invitation)
            AgentAlertReports.shared.configure(target: next)
        }
        let preferences = AgentAlertPreferences()
        let current = (enabled: preferences.alertsEnabled,
                       timeSensitive: preferences.breakThroughFocus,
                       showName: preferences.showAgentName)
        let changed = previousPreferences.map {
            $0.enabled != current.enabled || $0.timeSensitive != current.timeSensitive || $0.showName != current.showName
        } ?? true
        let firstPreferenceRead = previousPreferences == nil
        let wasEnabled = previousPreferences?.enabled ?? false
        previousPreferences = current

        if !current.enabled {
            // After a relaunch APNs may not have returned any token. The current pairing proof is
            // enough to disable the server registration that a previous launch left behind.
            if wasEnabled || pairChanged || firstPreferenceRead { PushRegistrar.shared.forget() }
        } else if next != nil && (pairChanged || !wasEnabled || force) {
            // APNs may rotate the opaque token; each active launch asks iOS for the current one.
            UIApplication.shared.registerForRemoteNotifications()
        }
        if pairChanged || changed || force {
            Task {
                await PushRegistrar.shared.submit()
                await AgentAlertReports.shared.flush()
            }
        }
    }
}
