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
    /// The grant exists, but macOS stopped or declined the capture until someone at the Mac approves it.
    case captureNeedsApproval
    case needsPhone
    case pairing
    case approvalRequested
    case starting
    case reconnecting
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
        var reconnecting = false
        var connected = false
        var awaitingApproval = false
        var captureApprovalPending = false
        var controlEffective = false
        var unavailable = false
        var displayStatus: HostDisplayRefreshStatus = .ready
    }

    static func resolve(_ inputs: Inputs) -> Self {
        if inputs.connected { return inputs.controlEffective ? .controlling : .viewing }
        if inputs.awaitingApproval { return .approvalRequested }
        if !inputs.screenRecording.isGranted { return .needsScreenRecording }
        if inputs.pairingInProgress { return .pairing }
        if inputs.captureApprovalPending && inputs.hasPairedPhone && inputs.wantsSharing { return .captureNeedsApproval }
        if !inputs.hasPairedPhone { return .needsPhone }
        if !inputs.wantsSharing { return .paused }
        if !inputs.sharingActive && (inputs.unavailable || inputs.displayStatus == .failed || inputs.displayStatus == .unavailable) { return .unavailable }
        if inputs.sharingActive && inputs.hostRegistered { return .ready }
        if inputs.sharingActive && inputs.reconnecting { return .reconnecting }
        return .starting
    }

    var needsAttention: Bool {
        switch self {
        case .needsScreenRecording, .captureNeedsApproval, .needsPhone, .unavailable, .approvalRequested: true
        default: false
        }
    }

    var isSessionLive: Bool { self == .viewing || self == .controlling }

    var title: String {
        switch self {
        case .needsScreenRecording: "Needs Screen Recording"
        case .captureNeedsApproval: "Screen recording needs approval on this Mac"
        case .needsPhone: "No phone paired"
        case .pairing: "Waiting for your phone to scan"
        case .approvalRequested: "A phone wants to connect"
        case .starting: "Getting ready…"
        case .reconnecting: "Reconnecting to Farside service…"
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
        case .captureNeedsApproval: "Needs approval"
        case .needsPhone: "No phone paired"
        case .pairing: "Waiting for your phone"
        case .approvalRequested: "A phone wants to connect"
        case .starting: "Starting…"
        case .reconnecting: "Reconnecting…"
        case .ready: "Ready"
        case .paused: "Sharing is off"
        case .unavailable: "Offline"
        case .viewing: "Phone is viewing"
        case .controlling: "Phone is controlling"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .needsScreenRecording, .captureNeedsApproval, .needsPhone, .unavailable: "exclamationmark.triangle"
        case .approvalRequested: "person.crop.circle.badge.questionmark"
        case .paused: "pause.circle"
        case .viewing: "rectangle.inset.filled.and.person.filled"
        case .controlling: "cursorarrow.rays"
        case .reconnecting: "arrow.triangle.2.circlepath"
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

    /// The pane's title in Privacy & Security, as that macOS names it. macOS 27's Privacy &
    /// Security extension titles the Accessibility pane "Device Control and Data Access".
    func title(macOSMajor: Int) -> String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: macOSMajor >= 27 ? "Device Control and Data Access" : "Accessibility"
        }
    }

    static var currentMacOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
}

/// Permission instructions that name what System Settings shows: the pane and this app's entry.
enum HostPermissionCopy {
    /// System Settings lists an app under its Finder name, which follows the installed bundle's
    /// file name ("PocketDesk Host.app" keeps its old name so existing permission grants survive).
    static func listName(fromDisplayName name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func switchOn(_ pane: HostSystemSettingsPane, listName: String, macOSMajor: Int) -> String {
        "In \(pane.title(macOSMajor: macOSMajor)), switch on “\(listName)”."
    }

    static func recovery(_ pane: HostSystemSettingsPane, listName: String, macOSMajor: Int) -> String {
        let title = pane.title(macOSMajor: macOSMajor)
        switch pane {
        case .screenRecording:
            return "Switched on already? Quit and reopen Farside. Still nothing: in \(title), select “\(listName)”, "
                + "remove it with –, add it again with +, then reopen Farside."
        case .accessibility:
            return "In \(title), select “\(listName)”, remove it with –, then add it again with +."
        }
    }
}

enum HostPairingRefresh {
    /// A code shown on screen that runs out is replaced by a fresh one. A code that ended any other
    /// way (a declined phone) stays ended, and so does one whose refresh failed.
    static func shouldRefresh(from old: HostPairingState, to new: HostPairingState) -> Bool {
        if case .showingCode = old, new == .expired { return true }
        return false
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
        static let captureScopeRequiresSelection = "captureScopeRequiresSelection"
        static let accessibilitySkipped = "setupAccessibilitySkipped"
        static let pairingDeferred = "setupPairingDeferred"
        static let serviceAddress = "PocketDeskServiceURL"
        static let chimeOnConnect = "chimeOnConnect"
        static let privacyCurtain = "privacyCurtainWhileSharing"
        static let agentAlerts = "agentAlertsEnabled"
        static let allowFileTransfer = "allowFileTransfer"
        static let menuBarIconShown = "menuBarIconShown"
        static let osPermissionRecord = "osPermissionRecord"
        static let allowBigText = "allowBigTextFromPhone"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Freeze the migrated default once. A later login-item choice cannot enable idle
        // assertions implicitly; explicit prior true/false values always win.
        if defaults.object(forKey: Key.keepAwake) == nil {
            defaults.set(defaults.bool(forKey: "launchAtLoginDefaultApplied"), forKey: Key.keepAwake)
        }
        defaults.register(defaults: [Key.allowControl: true, Key.sharingEnabled: true,
                                     Key.chimeOnConnect: true, Key.allowBigText: true, Key.allowFileTransfer: true, Key.menuBarIconShown: true])
    }

    /// A short sound when a phone connects, so someone at the Mac always knows.
    var chimeOnConnect: Bool {
        get { defaults.bool(forKey: Key.chimeOnConnect) }
        nonmutating set { defaults.set(newValue, forKey: Key.chimeOnConnect) }
    }

    /// Files from the paired phone may land in Downloads › Farside, and the phone may ask for a file
    /// someone picks on this Mac. On by default (owner decision, 30 Sep 2026).
    var allowFileTransfer: Bool {
        get { defaults.bool(forKey: Key.allowFileTransfer) }
        nonmutating set { defaults.set(newValue, forKey: Key.allowFileTransfer) }
    }

    var allowControl: Bool {
        get { defaults.bool(forKey: Key.allowControl) }
        nonmutating set { defaults.set(newValue, forKey: Key.allowControl) }
    }

    var keepAwake: Bool {
        get { defaults.bool(forKey: Key.keepAwake) }
        nonmutating set { defaults.set(newValue, forKey: Key.keepAwake) }
    }

    /// A narrow target is intentionally not restored by PID or window ID on relaunch.
    var captureScopeRequiresSelection: Bool {
        get { defaults.bool(forKey: Key.captureScopeRequiresSelection) }
        nonmutating set { defaults.set(newValue, forKey: Key.captureScopeRequiresSelection) }
    }

    var sharingMayResumeWithoutScopeSelection: Bool { sharingEnabled && !captureScopeRequiresSelection }

    var sharingEnabled: Bool {
        get { defaults.bool(forKey: Key.sharingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.sharingEnabled) }
    }

    var accessibilitySkipped: Bool {
        get { defaults.bool(forKey: Key.accessibilitySkipped) }
        nonmutating set { defaults.set(newValue, forKey: Key.accessibilitySkipped) }
    }

    /// Setup's "Skip for now" on the Pair step: pair later from the menu bar.
    var pairingDeferred: Bool {
        get { defaults.bool(forKey: Key.pairingDeferred) }
        nonmutating set { defaults.set(newValue, forKey: Key.pairingDeferred) }
    }

    /// Off unless the person turns it on; covering the Mac's screen is never a surprise.
    var privacyCurtain: Bool {
        get { defaults.bool(forKey: Key.privacyCurtain) }
        nonmutating set { defaults.set(newValue, forKey: Key.privacyCurtain) }
    }

    /// Off unless the person turns it on: nothing on this Mac listens for an agent until they say so.
    var agentAlerts: Bool {
        get { defaults.bool(forKey: Key.agentAlerts) }
        nonmutating set { defaults.set(newValue, forKey: Key.agentAlerts) }
    }

    /// False once the person removes the icon from the menu bar; Settings puts it back.
    var menuBarIconShown: Bool {
        get { defaults.bool(forKey: Key.menuBarIconShown) }
        nonmutating set { defaults.set(newValue, forKey: Key.menuBarIconShown) }
    }

    var osPermissionRecord: HostOSPermissionRecord? {
        get { defaults.data(forKey: Key.osPermissionRecord).flatMap { try? JSONDecoder().decode(HostOSPermissionRecord.self, from: $0) } }
        nonmutating set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.osPermissionRecord) }
    }

    var allowBigText: Bool {
        get { defaults.bool(forKey: Key.allowBigText) }
        nonmutating set { defaults.set(newValue, forKey: Key.allowBigText) }
    }

    var serviceAddress: String? {
        get {
            let value = defaults.string(forKey: Key.serviceAddress)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        nonmutating set { defaults.set(newValue, forKey: Key.serviceAddress) }
    }

    /// Diagnostics identify the public deployment without printing a private service address.
    static func serviceEnvironment(for server: String?) -> String {
        guard let server, PairInvitation.validServer(server), let url = URL(string: server), let host = url.host else { return "not configured" }
        guard url.scheme?.lowercased() == "wss", url.port == nil || url.port == 443,
              url.path == "/signal", url.query == nil, url.fragment == nil else { return "private or custom" }
        switch host.lowercased() {
        case "signal-staging.getfarside.com": return "staging"
        case "signal.getfarside.com": return "production"
        default: return "private or custom"
        }
    }

    /// An explicit new pairing uses the selected service; an existing connection keeps its saved service.
    static func resolvePairingServiceAddress(saved: String?, preference: String?, bundled: String?) -> String? {
        resolveServiceAddress(saved: preference, preference: saved, bundled: bundled)
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

enum HostFeatureList {
    static func features(base: [String], allowBigText: Bool, accessibility: Bool,
                         peerFeatures: Set<String>? = nil, requestedMode: SessionMode = .picture) -> [String] {
        let full = allowBigText && accessibility ? base + [SessionFeature.displayScale] : base
        var seen = Set<String>()
        let unique = full.filter { seen.insert($0).inserted }
        guard let peerFeatures else { return Array(unique.prefix(32)) }
        if peerFeatures.contains(SessionFeature.extendedFeatureList) {
            let known = SessionFeature.host + [SessionFeature.couch, SessionFeature.displayScale]
            let prioritized = known.filter { unique.contains($0) } + unique.filter { !known.contains($0) }
            return Array(prioritized.filter { $0 != SessionFeature.causalInput || peerFeatures.contains(SessionFeature.causalInput) }.prefix(32))
        }
        let legacy = SessionFeature.legacyHost.filter { unique.contains($0) }
        if requestedMode == .couch, unique.contains(SessionFeature.couch) {
            return [SessionFeature.couch] + legacy.prefix(15)
        }
        return Array(legacy.prefix(16))
    }
}
