import Foundation
import ServiceManagement

/// A background item the host registers with the system: itself as a login item, or the
/// watchdog LaunchAgent bundled inside it.
protocol HostBackgroundService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregisterAndWait() async throws
}

extension SMAppService: HostBackgroundService {
    func unregisterAndWait() async throws {
        try await unregister()
    }
}

extension HostBackgroundItemState {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .on
        case .requiresApproval: self = .needsApproval
        case .notRegistered: self = .off
        case .notFound: self = .unavailable
        @unknown default: self = .unavailable
        }
    }
}

enum HostInstallLocation {
    /// Background items are turned on automatically only for a copy in an Applications folder:
    /// never for a development build or an app macOS is running from a translocated path.
    static func isInstalled(bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        let path = WatchdogFiles.normalized(bundlePath)
        guard !path.contains("/AppTranslocation/") else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(WatchdogFiles.normalized(home) + "/Applications/")
    }
}

enum HostBackgroundPolicy {
    enum RecoveryAction: Equatable { case none, register, reregister, unregister }

    /// New installations require an explicit choice. Existing system registrations stay intact.
    static func shouldEnableLoginByDefault(setupComplete: Bool, defaultApplied: Bool, installed: Bool,
                                           state: HostBackgroundItemState) -> Bool {
        false
    }

    /// Automatic recovery follows the saved choice. An updated helper is re-registered, as
    /// ServiceManagement requires when a LaunchAgent's executable changes.
    static func recoveryAction(wanted: Bool, setupComplete: Bool, installed: Bool,
                               state: HostBackgroundItemState, registeredFingerprint: String?,
                               currentFingerprint: String?) -> RecoveryAction {
        guard wanted else { return state.isRegistered ? .unregister : .none }
        guard setupComplete, installed, currentFingerprint != nil else { return .none }
        switch state {
        case .off, .unavailable: return .register
        case .on, .needsApproval: return registeredFingerprint == currentFingerprint ? .none : .reregister
        }
    }
}

/// Owns the host's two background items and their persisted preferences.
@MainActor
final class HostBackgroundServices {
    static let agentPlistName = "com.roshan.PocketDesk.RemoteHost.watchdog.plist"
    static let helperExecutableName = "FarsideWatchdog"

    private enum Key {
        static let loginDefaultApplied = "launchAtLoginDefaultApplied"
        static let recoveryWanted = "automaticRecoveryEnabled"
        static let registeredHelper = "automaticRecoveryHelperFingerprint"
        static let explicitChoicePolicy = "backgroundChoicePolicyV2"
        static let loginWanted = "openAtLoginWanted"
    }

    let loginItem: HostBackgroundService
    let recoveryAgent: HostBackgroundService
    let installed: Bool
    let helperFingerprint: String?
    private let defaults: UserDefaults
    private(set) var loginState: HostBackgroundItemState = .off
    private(set) var recoveryState: HostBackgroundItemState = .off
    private var recoveryOperation: Task<Void, Never>?

    init(loginItem: HostBackgroundService, recoveryAgent: HostBackgroundService,
         defaults: UserDefaults, installed: Bool, helperFingerprint: String?) {
        self.loginItem = loginItem
        self.recoveryAgent = recoveryAgent
        self.defaults = defaults
        self.installed = installed
        self.helperFingerprint = helperFingerprint
        refresh()
        // Migrate once, before registering defaults. Preserve old installed setup's implicit
        // recovery choice and actual registered helpers; never overwrite an explicit false.
        if !defaults.bool(forKey: Key.explicitChoicePolicy) {
            if defaults.object(forKey: Key.recoveryWanted) == nil {
                let legacyEnabled = defaults.bool(forKey: Key.loginDefaultApplied) || recoveryState.isRegistered
                defaults.set(legacyEnabled, forKey: Key.recoveryWanted)
            }
            defaults.set(true, forKey: Key.explicitChoicePolicy)
        }
        // An install from before the saved wish keeps whatever macOS already has registered.
        if defaults.object(forKey: Key.loginWanted) == nil {
            defaults.set(loginState.isRegistered, forKey: Key.loginWanted)
        }
    }

    static func live(bundle: Bundle = .main) -> HostBackgroundServices {
        HostBackgroundServices(
            loginItem: SMAppService.mainApp,
            recoveryAgent: SMAppService.agent(plistName: agentPlistName),
            defaults: .standard,
            installed: HostInstallLocation.isInstalled(bundlePath: bundle.bundlePath),
            helperFingerprint: fingerprint(ofHelperIn: bundle)
        )
    }

    /// Size and modification time of the bundled helper: changes with every installed update.
    static func fingerprint(ofHelperIn bundle: Bundle) -> String? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlistName)")
        guard FileManager.default.fileExists(atPath: plist.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)-\(Int64(modified.timeIntervalSince1970))"
    }

    var recoveryWanted: Bool { defaults.bool(forKey: Key.recoveryWanted) }
    /// The person's own open-at-login choice; `loginState` is what macOS has registered.
    var loginWanted: Bool { defaults.bool(forKey: Key.loginWanted) }

    func refresh() {
        loginState = HostBackgroundItemState(loginItem.status)
        recoveryState = HostBackgroundItemState(recoveryAgent.status)
    }

    /// Runs when setup is complete (and at each later launch). Returns a problem to report, if any.
    @discardableResult
    func applyDefaults(setupComplete: Bool) -> String? {
        refresh()
        var problem: String?
        if HostBackgroundPolicy.shouldEnableLoginByDefault(
            setupComplete: setupComplete,
            defaultApplied: defaults.bool(forKey: Key.loginDefaultApplied),
            installed: installed, state: loginState
        ) {
            defaults.set(true, forKey: Key.loginDefaultApplied)
            problem = register(loginItem, what: "open at login")
        } else if setupComplete && installed && loginState.isRegistered {
            defaults.set(true, forKey: Key.loginDefaultApplied)
        }
        if let recoveryProblem = reconcileRecovery(setupComplete: setupComplete) { problem = problem ?? recoveryProblem }
        refresh()
        return problem
    }

    @discardableResult
    func setLoginItem(_ enabled: Bool) -> String? {
        defaults.set(true, forKey: Key.loginDefaultApplied)
        defaults.set(enabled, forKey: Key.loginWanted)
        let problem: String?
        if enabled {
            problem = register(loginItem, what: "open at login")
        } else {
            problem = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.loginItem.unregisterAndWait()
                self.refresh()
                self.onChange?()
            }
        }
        refresh()
        return problem
    }

    @discardableResult
    func setRecovery(_ enabled: Bool, setupComplete: Bool) -> String? {
        defaults.set(enabled, forKey: Key.recoveryWanted)
        if enabled && !installed {
            // An explicit choice is honoured anywhere; only the automatic default needs /Applications.
            return register(recoveryAgent, what: "automatic recovery", recordFingerprint: true)
        }
        return reconcileRecovery(setupComplete: setupComplete || enabled)
    }

    /// Notified after asynchronous unregistration finishes.
    var onChange: (() -> Void)?

    private func reconcileRecovery(setupComplete: Bool) -> String? {
        let action = HostBackgroundPolicy.recoveryAction(
            wanted: recoveryWanted, setupComplete: setupComplete, installed: installed,
            state: recoveryState, registeredFingerprint: defaults.string(forKey: Key.registeredHelper),
            currentFingerprint: helperFingerprint)
        switch action {
        case .none:
            return nil
        case .register:
            return register(recoveryAgent, what: "automatic recovery", recordFingerprint: true)
        case .reregister:
            recoveryOperation?.cancel()
            recoveryOperation = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.recoveryAgent.unregisterAndWait()
                _ = self.register(self.recoveryAgent, what: "automatic recovery", recordFingerprint: true)
                self.refresh()
                self.onChange?()
            }
            return nil
        case .unregister:
            recoveryOperation?.cancel()
            recoveryOperation = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.recoveryAgent.unregisterAndWait()
                self.defaults.removeObject(forKey: Key.registeredHelper)
                self.refresh()
                self.onChange?()
            }
            return nil
        }
    }

    private func register(_ service: HostBackgroundService, what: String, recordFingerprint: Bool = false) -> String? {
        do {
            try service.register()
        } catch let error as NSError where error.code == Int(kSMErrorAlreadyRegistered) {
            // Already registered is the state we want.
        } catch {
            refresh()
            return "Couldn’t turn on \(what): \(error.localizedDescription)"
        }
        if recordFingerprint, let helperFingerprint { defaults.set(helperFingerprint, forKey: Key.registeredHelper) }
        refresh()
        return nil
    }
}
