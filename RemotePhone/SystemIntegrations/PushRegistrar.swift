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
    func remove(deviceToken: String) async -> PushSubmission
}

extension PushRegistrationSink {
    func remove(deviceToken: String) async -> PushSubmission { .notSent("Push removal is not configured.") }
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
    private let baseURL: URL
    private let invitation: () -> PairInvitation?
    private let session: URLSession

    init?(baseURL: URL, invitation: @escaping () -> PairInvitation?) {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else { return nil }
        self.baseURL = baseURL
        self.invitation = invitation
        session = URLSession(configuration: .ephemeral, delegate: PushNoRedirect(), delegateQueue: nil)
    }

    func submit(_ registration: PushRegistration) async -> PushSubmission {
        guard let encoded = try? JSONEncoder().encode(registration),
              let object = try? JSONSerialization.jsonObject(with: encoded) else {
            return .notSent("Push registration could not be prepared.")
        }
        return await request("register", payload: ["registration": object])
    }

    func remove(deviceToken: String) async -> PushSubmission {
        await request("remove", payload: ["deviceToken": deviceToken])
    }

    private func request(_ path: String, payload: [String: Any]) async -> PushSubmission {
        guard let pair = invitation(), SecureRandom.isToken(pair.room), SecureRandom.isToken(pair.token) else {
            return .notSent("Pair your phone before using agent alerts.")
        }
        var value: [String: Any] = ["room": pair.room, "token": pair.token]
        value.merge(payload) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else {
            return .notSent("Push registration could not be prepared.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/push/\(path)"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                return .notSent("Push service did not confirm the request.")
            }
            if http.statusCode == (path == "remove" ? 204 : 200) { return .sent }
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

/// Collects the APNs address, stores it on this phone, and syncs explicit preferences with the
/// pairing-scoped service. A failed removal remains pending for the next launch.
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
    var sink: any PushRegistrationSink = UnconfiguredPushSink() {
        didSet { Task { await submit() } }
    }

    private let defaults: UserDefaults
    private let environmentOverride: String?
    private static let tokenKey = "push.deviceToken"
    private static let pendingRemovalKey = "push.pendingRemoval"
    private var currentToken: String?
    private var inFlight: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, environmentOverride: String? = nil) {
        self.defaults = defaults
        self.environmentOverride = environmentOverride
        // Earlier builds cached the token. It is only retained now for one authenticated removal.
        if let old = defaults.string(forKey: Self.tokenKey) {
            if defaults.string(forKey: Self.pendingRemovalKey) == nil {
                defaults.set(old, forKey: Self.pendingRemovalKey)
            }
            defaults.removeObject(forKey: Self.tokenKey)
        }
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

    func failed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    func forget() {
        if let deviceToken {
            defaults.set(deviceToken, forKey: Self.pendingRemovalKey)
            currentToken = nil
        }
        status = .idle
        lastSubmission = nil
        Task { await submit() }
    }

    /// The registration a service would store for this phone, or nil when there is no address yet.
    func registration(preferences: AgentAlertPreferences = AgentAlertPreferences(),
                      now: Date = Date()) -> PushRegistration? {
        guard let deviceToken, let environment = environmentOverride ?? Self.environment else { return nil }
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
        let next = Task { @MainActor in
            await previous?.value
            await self.syncOnce()
        }
        inFlight = next
        await next.value
    }

    private func syncOnce() async {
        if let pending = defaults.string(forKey: Self.pendingRemovalKey) {
            let result = await sink.remove(deviceToken: pending)
            lastSubmission = result
            if result == .sent {
                defaults.removeObject(forKey: Self.pendingRemovalKey)
            } else { return }
        }
        guard let deviceToken else { return }
        guard AgentAlertPreferences(defaults: defaults).alertsEnabled else {
            forget()
            return
        }
        guard let registration = registration() else {
            status = .failed("This build has no APNs environment.")
            return
        }
        let result = await sink.submit(registration)
        lastSubmission = result
        switch result {
        case .sent: status = .registered
        case .notSent(let reason): status = .failed(reason)
        }
    }
}
