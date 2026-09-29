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
}

/// The service that would receive registrations does not exist yet, so nothing leaves the phone.
@MainActor
final class UnconfiguredPushSink: PushRegistrationSink {
    func submit(_ registration: PushRegistration) async -> PushSubmission {
        .notSent("No Farside push service is configured.")
    }
}

/// Collects the APNs device token and prepares the registration a push service will need. It stores the
/// token on this phone only, never logs it, and sends nothing until a service exists. Turning alerts off
/// or removing the Mac forgets it.
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
    var sink: any PushRegistrationSink = UnconfiguredPushSink()

    private let defaults: UserDefaults
    private static let tokenKey = "push.deviceToken"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var deviceToken: String? { defaults.string(forKey: Self.tokenKey) }

    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    func received(token: Data) {
        defaults.set(Self.hex(token), forKey: Self.tokenKey)
        status = .registered
        Task { await submit() }
    }

    func failed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    func forget() {
        defaults.removeObject(forKey: Self.tokenKey)
        status = .idle
        lastSubmission = nil
    }

    /// The registration a service would store for this phone, or nil when there is no address yet.
    func registration(preferences: AgentAlertPreferences = AgentAlertPreferences(),
                      now: Date = Date()) -> PushRegistration? {
        guard let deviceToken else { return nil }
        return PushRegistration(
            deviceToken: deviceToken,
            environment: Self.environment,
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
        guard let registration = registration() else { return }
        lastSubmission = await sink.submit(registration)
    }
}
