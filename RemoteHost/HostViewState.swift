import Foundation

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
    var pairingRequested = false
    var pairing: HostPairingState = .idle
    var canBeginPairing = false
    var allowControl = true
    var keepAwake = true
    var openAtLogin = false
    var chimeOnConnect = true
    var allowFileTransfer = true
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
    /// Agent alerts (beta): a hook on this Mac tells the phone an agent needs a person.
    var agentAlerts = false
    /// One line about the last agent alert, or that the Mac is listening.
    var agentAlertsStatus: String?
    /// Diagnostics: drop a frame waiting for the encoder instead of queueing it (efficiency audit P1).
    var newestFrameWins = true
    var crashLoopStopped = false
    var displays: [HostDisplayOption] = []
    var selectedDisplayID: UInt32 = 0
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
    var removeServerRoom: () -> Void = {}
    var stopSharing: () -> Void = {}
    var pauseSharing: () -> Void = {}
    var resumeSharing: () -> Void = {}
    var setAllowControl: (Bool) -> Void = { _ in }
    var setKeepAwake: (Bool) -> Void = { _ in }
    var setChimeOnConnect: (Bool) -> Void = { _ in }
    var setLocalOnly: (Bool) -> Void = { _ in }
    var setAllowSystemAudio: (Bool) -> Void = { _ in }
    var setAllowFileTransfer: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var setAutomaticRecovery: (Bool) -> Void = { _ in }
    var openLoginItems: () -> Void = {}
    var setPrivacyCurtain: (Bool) -> Void = { _ in }
    var setAllowBigText: (Bool) -> Void = { _ in }
    var restoreNormalSize: () -> Void = {}
    var setAgentAlerts: (Bool) -> Void = { _ in }
    var copyAgentHookSetup: () -> Void = {}
    var resetAgentAlertLink: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var setNewestFrameWins: (Bool) -> Void = { _ in }
    var selectDisplay: (UInt32) -> Void = { _ in }
    var setMenuBarIconShown: (Bool) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    static let preview = HostActions()
}
