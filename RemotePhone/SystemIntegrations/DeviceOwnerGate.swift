import Foundation
import LocalAuthentication

/// What the device-owner check reported. `unavailable` means this iPhone has no passcode, so there is
/// no owner to check.
enum DeviceOwnerCheck: Equatable {
    case passed, refused, unavailable
}

/// Face ID, Touch ID or Optic ID, with the device passcode as the fallback.
@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    var biometryName: String { get }
    func authenticate(reason: String) async -> DeviceOwnerCheck
}

@MainActor
final class LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    nonisolated static let shared = LocalDeviceOwnerAuthenticator()

    nonisolated init() {}

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func authenticate(reason: String) async -> DeviceOwnerCheck {
        // A fresh context each time, so an earlier success is never reused for a later request.
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet ? .unavailable : .refused
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .passed : .refused
        } catch {
            return .refused
        }
    }
}

/// "Require Face ID to connect": off unless the person turns it on on this iPhone.
struct PhoneSecurityPreferences {
    private static let key = "security.requireOwnerToConnect"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var requireOwnerToConnect: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The optional owner check in front of Connect and Forget this Mac. It runs only when a person starts
/// one of those, never on a view rebuild, a reconnect inside a session, or anything already running.
@MainActor
struct DeviceOwnerGate {
    enum Purpose: Equatable {
        case connect(macName: String?)
        case forgetMac
        case changeSetting

        var reason: String {
            switch self {
            case .connect(let name): "Connect to \(name ?? "your Mac")"
            case .forgetMac: "Forget this Mac on this iPhone"
            case .changeSetting: "Change who can connect to your Mac"
            }
        }
    }

    enum Outcome: Equatable {
        /// The setting is off: nothing was asked.
        case notRequired
        case passed
        case refused
        /// The setting is on but this iPhone has no passcode, so nobody can be checked.
        case unavailable

        var allows: Bool { self == .notRequired || self == .passed }
    }

    var preferences = PhoneSecurityPreferences()
    var authenticator: any DeviceOwnerAuthenticating = LocalDeviceOwnerAuthenticator.shared

    static var live: DeviceOwnerGate { DeviceOwnerGate() }

    func check(_ purpose: Purpose) async -> Outcome {
        guard preferences.requireOwnerToConnect else { return .notRequired }
        switch await authenticator.authenticate(reason: purpose.reason) {
        case .passed: return .passed
        case .refused: return .refused
        case .unavailable: return .unavailable
        }
    }

    /// Turning the setting on proves the owner is here and a passcode exists. Turning it off asks too,
    /// unless the passcode was since removed: then nothing could pass and the setting would lock Connect.
    func setRequired(_ on: Bool) async -> Bool {
        guard on != preferences.requireOwnerToConnect else { return true }
        let result = await authenticator.authenticate(reason: DeviceOwnerGate.Purpose.changeSetting.reason)
        guard result == .passed || (!on && result == .unavailable) else { return false }
        preferences.requireOwnerToConnect = on
        return true
    }

    /// The line shown when the check blocked Connect or Forget.
    static func message(for outcome: Outcome, purpose: Purpose, biometryName: String) -> String? {
        switch outcome {
        case .notRequired, .passed:
            return nil
        case .refused:
            return purpose == .forgetMac ? "\(biometryName) didn’t confirm it’s you, so this Mac is still paired."
                : "\(biometryName) didn’t confirm it’s you, so nothing was sent to your Mac."
        case .unavailable:
            return "Set a passcode on this iPhone, or turn off Require \(biometryName) in Settings → Security."
        }
    }
}
