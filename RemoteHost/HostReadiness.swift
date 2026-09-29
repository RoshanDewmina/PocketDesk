import Foundation

enum HostSetupStep: Int, CaseIterable, Comparable {
    case screenRecording
    case accessibility
    case pairPhone
    case done

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func current(
        screenRecording: HostPermissionStatus,
        accessibility: HostPermissionStatus,
        accessibilitySkipped: Bool,
        hasPairedPhone: Bool,
        pairingRequested: Bool
    ) -> Self {
        if !screenRecording.isGranted { return .screenRecording }
        if !accessibility.isGranted && !accessibilitySkipped { return .accessibility }
        if !hasPairedPhone || pairingRequested { return .pairPhone }
        return .done
    }
}

enum HostStatus: Equatable {
    case needsScreenRecording
    case needsPhone
    case pairing
    case approvalRequested
    case starting
    case ready
    case paused
    case unavailable
    case viewing
    case controlling

    struct Inputs: Equatable {
        var screenRecording: HostPermissionStatus = .unchecked
        var hasPairedPhone = false
        var pairingInProgress = false
        var wantsSharing = true
        var sharingActive = false
        var hostRegistered = false
        var connected = false
        var awaitingApproval = false
        var controlEffective = false
        var unavailable = false
        var displayStatus: HostDisplayRefreshStatus = .ready
    }

    static func resolve(_ inputs: Inputs) -> Self {
        if inputs.connected { return inputs.controlEffective ? .controlling : .viewing }
        if inputs.awaitingApproval { return .approvalRequested }
        if !inputs.screenRecording.isGranted { return .needsScreenRecording }
        if inputs.pairingInProgress { return .pairing }
        if !inputs.hasPairedPhone { return .needsPhone }
        if !inputs.wantsSharing { return .paused }
        if !inputs.sharingActive && (inputs.unavailable || inputs.displayStatus == .failed || inputs.displayStatus == .unavailable) { return .unavailable }
        if inputs.sharingActive && inputs.hostRegistered { return .ready }
        return .starting
    }

    var needsAttention: Bool {
        switch self {
        case .needsScreenRecording, .needsPhone, .unavailable, .approvalRequested: true
        default: false
        }
    }

    var isSessionLive: Bool { self == .viewing || self == .controlling }

    var title: String {
        switch self {
        case .needsScreenRecording: "Needs Screen Recording"
        case .needsPhone: "No phone paired"
        case .pairing: "Waiting for your phone to scan"
        case .approvalRequested: "A phone wants to connect"
        case .starting: "Getting ready…"
        case .ready: "Ready"
        case .paused: "Sharing is off"
        case .unavailable: "Sharing needs attention"
        case .viewing: "Your phone is viewing this Mac"
        case .controlling: "Your phone is controlling this Mac"
        }
    }

    var menuTitle: String {
        switch self {
        case .needsScreenRecording: "Needs attention"
        case .needsPhone: "No phone paired"
        case .pairing: "Waiting for your phone"
        case .approvalRequested: "A phone wants to connect"
        case .starting: "Starting…"
        case .ready: "Ready"
        case .paused: "Sharing is off"
        case .unavailable: "Offline"
        case .viewing: "Phone is viewing"
        case .controlling: "Phone is controlling"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .needsScreenRecording, .needsPhone, .unavailable: "exclamationmark.triangle"
        case .approvalRequested: "person.crop.circle.badge.questionmark"
        case .paused: "pause.circle"
        case .viewing: "rectangle.inset.filled.and.person.filled"
        case .controlling: "cursorarrow.rays"
        case .pairing, .starting, .ready: "macbook.and.iphone"
        }
    }
}

enum HostPairingState: Equatable {
    case idle
    case needsService
    case showingCode(String, expires: Date)
    case expired
    case confirmReplace
    case awaitingApproval
}

enum HostDisplayChoice {
    static func preferred(available: [UInt32], previous: UInt32, main: UInt32) -> UInt32 {
        if available.contains(previous) { return previous }
        if available.contains(main) { return main }
        return available.first ?? 0
    }
}

enum HostSystemSettingsPane: String {
    case screenRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"

    var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

struct HostAutoStartGate: Equatable {
    private(set) var suppressed = false

    mutating func suspend() { suppressed = true }
    mutating func clear() { suppressed = false }

    func shouldStart(
        wantsSharing: Bool,
        sharingActive: Bool,
        otherAccessRunning: Bool,
        screenRecordingGranted: Bool,
        displayReady: Bool,
        hasPairedPhone: Bool,
        serviceConfigured: Bool
    ) -> Bool {
        wantsSharing && !suppressed && !sharingActive && !otherAccessRunning &&
            screenRecordingGranted && displayReady && hasPairedPhone && serviceConfigured
    }
}

struct HostPreferences {
    private enum Key {
        static let allowControl = "allowControl"
        static let keepAwake = "keepAwakeWhileSharing"
        static let sharingEnabled = "sharingEnabled"
        static let accessibilitySkipped = "setupAccessibilitySkipped"
        static let serviceAddress = "PocketDeskServiceURL"
        static let chimeOnConnect = "chimeOnConnect"
        static let privacyCurtain = "privacyCurtainWhileSharing"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.allowControl: true, Key.keepAwake: true, Key.sharingEnabled: true,
                                     Key.chimeOnConnect: true])
    }

    /// A short sound when a phone connects, so someone at the Mac always knows.
    var chimeOnConnect: Bool {
        get { defaults.bool(forKey: Key.chimeOnConnect) }
        nonmutating set { defaults.set(newValue, forKey: Key.chimeOnConnect) }
    }

    var allowControl: Bool {
        get { defaults.bool(forKey: Key.allowControl) }
        nonmutating set { defaults.set(newValue, forKey: Key.allowControl) }
    }

    var keepAwake: Bool {
        get { defaults.bool(forKey: Key.keepAwake) }
        nonmutating set { defaults.set(newValue, forKey: Key.keepAwake) }
    }

    var sharingEnabled: Bool {
        get { defaults.bool(forKey: Key.sharingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.sharingEnabled) }
    }

    var accessibilitySkipped: Bool {
        get { defaults.bool(forKey: Key.accessibilitySkipped) }
        nonmutating set { defaults.set(newValue, forKey: Key.accessibilitySkipped) }
    }

    /// Off unless the person turns it on; covering the Mac's screen is never a surprise.
    var privacyCurtain: Bool {
        get { defaults.bool(forKey: Key.privacyCurtain) }
        nonmutating set { defaults.set(newValue, forKey: Key.privacyCurtain) }
    }

    var serviceAddress: String? {
        get {
            let value = defaults.string(forKey: Key.serviceAddress)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        nonmutating set { defaults.set(newValue, forKey: Key.serviceAddress) }
    }

    static func resolveServiceAddress(saved: String?, preference: String?, bundled: String?) -> String? {
        for candidate in [saved, preference, bundled] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               PairInvitation.validServer(value) {
                return value
            }
        }
        return nil
    }
}
