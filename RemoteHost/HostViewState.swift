import Foundation

struct HostDisplayOption: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

/// When the Mac itself is why sharing is interrupted, so the UI can say so plainly.
enum HostAvailabilityNote: Equatable {
    case displayAsleep, asleep, locked, switchedUser
}

struct HostViewState: Equatable {
    var macName = "This Mac"
    /// How this app appears in Finder and, possibly, System Settings lists.
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
    var displays: [HostDisplayOption] = []
    var selectedDisplayID: UInt32 = 0
    var detail: String?

    var controlNeedsAccessibility: Bool { allowControl && !accessibility.isGranted }
    var selectedDisplayName: String? { displays.first { $0.id == selectedDisplayID }?.name }
}

@MainActor
struct HostActions {
    var openSystemSettings: (HostSystemSettingsPane) -> Void = { _ in }
    var relaunch: () -> Void = {}
    var skipAccessibility: () -> Void = {}
    var beginPairing: () -> Void = {}
    var setServiceAddress: (String) -> Void = { _ in }
    var approvePhone: () -> Void = {}
    var declinePhone: () -> Void = {}
    var copyPairingCode: () -> Void = {}
    var cancelPairing: () -> Void = {}
    var finishSetup: () -> Void = {}
    var pairNewPhone: () -> Void = {}
    var removePhone: () -> Void = {}
    var stopSharing: () -> Void = {}
    var pauseSharing: () -> Void = {}
    var resumeSharing: () -> Void = {}
    var setAllowControl: (Bool) -> Void = { _ in }
    var setKeepAwake: (Bool) -> Void = { _ in }
    var setChimeOnConnect: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var selectDisplay: (UInt32) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    static let preview = HostActions()
}
