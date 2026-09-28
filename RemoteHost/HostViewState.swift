import Foundation

struct HostDisplayOption: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

struct HostViewState: Equatable {
    var macName = "This Mac"
    var screenRecording: HostPermissionStatus = .unchecked
    var accessibility: HostPermissionStatus = .unchecked
    var screenRecordingSettingsOpened = false
    var accessibilitySettingsOpened = false
    var status: HostStatus = .starting
    var setupStep: HostSetupStep = .screenRecording
    var hasPairedPhone = false
    var pairingRequested = false
    var pairing: HostPairingState = .idle
    var canBeginPairing = false
    var allowControl = true
    var keepAwake = true
    var openAtLogin = false
    var displays: [HostDisplayOption] = []
    var selectedDisplayID: UInt32 = 0
    var detail: String?

    var controlNeedsAccessibility: Bool { allowControl && !accessibility.isGranted }
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
    var resumeSharing: () -> Void = {}
    var setAllowControl: (Bool) -> Void = { _ in }
    var setKeepAwake: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var selectDisplay: (UInt32) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    static let preview = HostActions()
}
