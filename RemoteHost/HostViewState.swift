import Foundation

struct HostPairedDeviceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let lastUsed: Date?
    let connected: Bool
}

struct HostGuestRow: Identifiable, Equatable {
    let id: String
    let fingerprint: String
    let status: String
    let pending: Bool
    let linkReady: Bool
}


struct HostCaptureScopeOption: Identifiable, Equatable {
    let id: String
    let name: String
}

struct HostDisplayOption: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

/// When the Mac itself is why sharing is interrupted, so the UI can say so plainly.
enum HostAvailabilityNote: Equatable {
    case displayAsleep, asleep, locked, switchedUser
}

/// A login item or LaunchAgent as System Settings sees it.
enum HostBackgroundItemState: Equatable {
    case on, off, needsApproval, unavailable

    /// Registered with the system, whether or not the person has approved it yet.
    var isRegistered: Bool { self == .on || self == .needsApproval }

    var diagnosticsText: String {
        switch self {
        case .on: "on"
        case .off: "off"
        case .needsApproval: "needs approval in Login Items"
        case .unavailable: "unavailable"
        }
    }
}

struct HostViewState: Equatable {
    var macName = "This Mac"
    /// How this app appears in Finder and in System Settings' permission lists.
    var appListName = "Farside"
    var screenRecording: HostPermissionStatus = .unchecked
    /// The right to control this Mac (posting events). System Settings lists it under Accessibility,
    /// so the UI names it that.
    var accessibility: HostPermissionStatus = .unchecked
    /// Accessibility (AX) itself, which only the focus features and the curtain need.
    var focusAccessibility: HostPermissionStatus = .unchecked
    var screenRecordingSettingsOpened = false
    var accessibilitySettingsOpened = false
    var accessibilitySkipped = false
    var status: HostStatus = .starting
    var setupStep: HostSetupStep = .screenRecording
    var hasPairedPhone = false
    var pairedDevices: [HostPairedDeviceRow] = []
    var pairingRequested = false
    var pairing: HostPairingState = .idle
    var pairingComparisonCode: String? = nil
    var pendingPairingPhoneName: String? = nil
    var canBeginPairing = false
    var allowControl = true
    var keepAwake = false
    /// Keep-awake is on but paused because this Mac is running on battery.
    var keepAwakePausedOnBattery = false
    /// The person's saved choice; `loginItem` is what macOS has registered.
    var openAtLogin = false
    /// Open at login and keep-awake still need the person's confirmation of the current explanation.
    var consentPending = false
    var chimeOnConnect = true
    var wakeHelperHostID: String? = nil
    var wakeOwnerPairID: String? = nil
    var localOnly = false
    var allowSystemAudio = false
    var pausedUntil: Date?
    var session: HostSessionReadout?
    /// When the current phone session began, for the popover's elapsed time.
    var sessionStartedAt: Date?
    /// The paired phone as the Mac names it: its own name when it sent one, else "Your iPhone" (D39).
    var phoneName = PhoneDisplayName.fallback
    var availability: HostAvailabilityNote?
    var loginItem: HostBackgroundItemState = .off
    var automaticRecovery: HostBackgroundItemState = .off
    var privacyCurtain = false
    /// What the curtain is doing now, when that differs from the preference alone.
    var curtainStatus: String?
    /// A Couch-mode session: the phone steers with no picture.
    var couchMode = false
    /// Away mode: the Mac's preference, whether its explanation sheet was seen, and what it is doing now.
    var awayMode = false
    var awayIntroShown = false
    var away = HostAwayReadout()
    /// The Mac locked while sharing without anyone choosing to lock it.
    var lockWarning: HostLockWarning?
    /// Agent alerts (beta): a hook on this Mac tells the phone an agent needs a person.
    var agentAlerts = false
    /// One line about the last agent alert, or that the Mac is listening.
    var agentAlertsStatus: String?
    /// Diagnostics: drop a frame waiting for the encoder instead of queueing it (efficiency audit P1).
    var compatibilityVideoEncoder = false
    var newestFrameWins = true
    var crashLoopStopped = false
    var displays: [HostDisplayOption] = []
    var selectedDisplayID: UInt32 = 0
    var captureScopes: [HostCaptureScopeOption] = [.init(id: "display", name: "Entire display")]
    var selectedCaptureScopeID = "display"
    var captureScopeViewOnly = false
    var captureScopeNeedsSelection = false
    var guestViewingAvailable = false
    var guestRows: [HostGuestRow] = []
    var guestMessage: String?
    var detail: String?
    /// Setup's Pair step was skipped; pairing happens later from the menu bar.
    var pairingDeferred = false
    var serverRemovalBusy = false
    var serverRemovalPending = false
    var serverRemovalMessage: String?
    var localPairRemovalMessage: String?
    var allowBigText = true
    /// "Big Text on · looks like 1280 × 832" or "Restoring normal size…"; nil when Big Text is off.
    var bigTextStatus: String?
    var macOSMajor = HostSystemSettingsPane.currentMacOSMajor
    /// False after the person removed the menu bar icon; Farside keeps running.
    var menuBarIconShown = true
    /// Permissions a macOS update turned off, still to be switched back on.
    var permissionsTurnedOffByUpdate: [HostSystemSettingsPane] = []
    var diagnosticReports: [SessionDiagnosticReport] = []

    var controlNeedsAccessibility: Bool { allowControl && !accessibility.isGranted }
    var selectedDisplayName: String? { displays.first { $0.id == selectedDisplayID }?.name }
    var curtainNeedsAccessibility: Bool { privacyCurtain && focusAccessibility == .denied }
}

@MainActor
struct HostActions {
    var openSystemSettings: (HostSystemSettingsPane) -> Void = { _ in }
    var relaunch: () -> Void = {}
    var skipAccessibility: () -> Void = {}
    var skipPairing: () -> Void = {}
    var beginPairing: () -> Void = {}
    var setServiceAddress: (String) -> Void = { _ in }
    var approvePhone: () -> Void = {}
    var declinePhone: () -> Void = {}
    var copyPairingCode: () -> Void = {}
    var cancelPairing: () -> Void = {}
    var finishSetup: () -> Void = {}
    var pairNewPhone: () -> Void = {}
    var removePhone: () -> Void = {}
    var removePairedDevice: (String) -> Void = { _ in }
    var removeServerRoom: () -> Void = {}
    var stopSharing: () -> Void = {}
    var pauseSharing: () -> Void = {}
    var resumeSharing: () -> Void = {}
    var setAllowControl: (Bool) -> Void = { _ in }
    var setKeepAwake: (Bool) -> Void = { _ in }
    var setChimeOnConnect: (Bool) -> Void = { _ in }
    var setLocalOnly: (Bool) -> Void = { _ in }
    var setAllowSystemAudio: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var confirmBackgroundChoices: (_ openAtLogin: Bool, _ keepAwake: Bool) -> Void = { _, _ in }
    var setAutomaticRecovery: (Bool) -> Void = { _ in }
    var openLoginItems: () -> Void = {}
    var setPrivacyCurtain: (Bool) -> Void = { _ in }
    var setAllowBigText: (Bool) -> Void = { _ in }
    var restoreNormalSize: () -> Void = {}
    var setAwayMode: (Bool) -> Void = { _ in }
    var coverNow: () -> Void = {}
    var dismissLockWarning: () -> Void = {}
    var openLockScreenSettings: () -> Void = {}
    var setAgentAlerts: (Bool) -> Void = { _ in }
    var copyAgentHookSetup: () -> Void = {}
    var resetAgentAlertLink: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var deleteDiagnosticReport: (UUID) -> Void = { _ in }
    var setCompatibilityVideoEncoder: (Bool) -> Void = { _ in }
    var setNewestFrameWins: (Bool) -> Void = { _ in }
    var selectDisplay: (UInt32) -> Void = { _ in }
    var refreshCaptureScopes: () -> Void = {}
    var createGuestLink: () -> Void = {}
    var copyGuestLink: (String) -> Void = { _ in }
    var approveGuest: (String) -> Void = { _ in }
    var revokeGuest: (String) -> Void = { _ in }
    var selectCaptureScope: (String) -> Void = { _ in }
    var setMenuBarIconShown: (Bool) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    static let preview = HostActions()
}
