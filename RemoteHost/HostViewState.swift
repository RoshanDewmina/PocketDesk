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
    var accessibility: HostPermissionStatus = .unchecked
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
    var pausedUntil: Date?
    var session: HostSessionReadout?
    var availability: HostAvailabilityNote?
    var loginItem: HostBackgroundItemState = .off
    var automaticRecovery: HostBackgroundItemState = .off
    var privacyCurtain = false
    /// What the curtain is doing now, when that differs from the preference alone.
    var curtainStatus: String?
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
    var macOSMajor = HostSystemSettingsPane.currentMacOSMajor

    var controlNeedsAccessibility: Bool { allowControl && !accessibility.isGranted }
    var selectedDisplayName: String? { displays.first { $0.id == selectedDisplayID }?.name }
    var curtainNeedsAccessibility: Bool { privacyCurtain && !accessibility.isGranted }
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
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var setAutomaticRecovery: (Bool) -> Void = { _ in }
    var openLoginItems: () -> Void = {}
    var setPrivacyCurtain: (Bool) -> Void = { _ in }
    var setAwayMode: (Bool) -> Void = { _ in }
    var coverNow: () -> Void = {}
    var dismissLockWarning: () -> Void = {}
    var openLockScreenSettings: () -> Void = {}
    var setAgentAlerts: (Bool) -> Void = { _ in }
    var copyAgentHookSetup: () -> Void = {}
    var resetAgentAlertLink: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var selectDisplay: (UInt32) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    static let preview = HostActions()
}
