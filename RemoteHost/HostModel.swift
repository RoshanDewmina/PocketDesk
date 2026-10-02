import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement
import SystemConfiguration
import os

/// Kept until both the server deletion and local Keychain cleanup have completed.
private struct PendingHostRoomRemoval: Codable {
    var request: ServerDataRemovalRequest
    var serverConfirmed: Bool
}

private enum HostRoomRemovalCleanupError: LocalizedError {
    case pairingChanged, localPairingRetained

    var errorDescription: String? {
        switch self {
        case .pairingChanged: "The saved pairing changed. Local cleanup needs attention before sharing can resume."
        case .localPairingRetained: "The local pairing could not be removed from Keychain. Unlock this Mac and retry."
        }
    }
}

@MainActor
final class RemoteHostModel: ObservableObject {
    #if DEBUG
    // E2E mode swaps in isolated trust and preferences; see HostE2E.swift.
    let connection = RemoteCoordinator(isHost: true, store: HostE2E.active?.pairStore,
                                       retryBaseNanoseconds: RemoteCoordinator.hostRetryBaseNanoseconds,
                                       maximumRetryDelayNanoseconds: RemoteCoordinator.hostMaximumRetryDelayNanoseconds,
                                       retriesIndefinitely: true)
    #else
    let connection = RemoteCoordinator(isHost: true,
                                       retryBaseNanoseconds: RemoteCoordinator.hostRetryBaseNanoseconds,
                                       maximumRetryDelayNanoseconds: RemoteCoordinator.hostMaximumRetryDelayNanoseconds,
                                       retriesIndefinitely: true)
    #endif
    private let networkPath = NetworkPathWatcher()
    private var serviceRegistered = false
    private var serviceReconnecting = false
    let browserSession = BrowserMediaSession()
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var selected: CGDirectDisplayID = 0 {
        didSet {
            if selected != oldValue {
                clipboard.stopAutomaticSync()
                pointerLocator.reset()
                releaseRemoteInput(notifyPhone: true)
                input.invalidateQueued(); inputFreshness.expireTokens()
                input.resetNativeSequence()
                browserSession.stop()
            }
        }
    }
    @Published private(set) var pairingCode = ""
    @Published private(set) var pairingExpires: Date?
    @Published private(set) var pairingExpired = false
    @Published private(set) var pairingRequested = false
    @Published private var controlConsent: HostControlConsentState
    @Published private(set) var detail: String?
    @Published private(set) var serverRemovalBusy = false
    @Published private(set) var serverRemovalPending = false
    @Published private(set) var serverRemovalMessage: String?
    @Published private(set) var active = false {
        didSet { reconcileAutomaticClipboard() }
    }
    @Published private(set) var localPairRemovalMessage: String?
    @Published private(set) var wantsSharing: Bool
    @Published private(set) var screenRecordingPermission: HostPermissionStatus = .unchecked
    /// Control's truth is the right to post events; Accessibility (AX) is read only for the focus
    /// features and the curtain. Both are cached and refreshed on timers, never per input event.
    @Published private(set) var inputAccess = HostInputAccess.unchecked
    private let postingGrantSnapshot = HostPostingGrantSnapshot()
    private lazy var inputAccessCache = HostInputAccessCache(probe: RemoteHostModel.probeInputAccess,
                                                            postingGrant: postingGrantSnapshot)
    /// macOS stopped or declined the capture although Screen Recording is granted.
    @Published private(set) var captureApproval = HostCaptureApproval()
    private var captureApprovalCheck: Task<Void, Never>?
    @Published private(set) var permissionsTurnedOffByUpdate: [HostSystemSettingsPane] = []
    @Published private(set) var menuBarIconShown: Bool
    @Published private(set) var screenRecordingSettingsOpened = false
    @Published private(set) var accessibilitySettingsOpened = false
    @Published private(set) var accessibilitySkipped: Bool
    /// Setup's Pair step was skipped: pairing waits for the menu bar, and setup stops presenting itself.
    @Published private(set) var pairingDeferred: Bool
    @Published private(set) var displayRefreshStatus: HostDisplayRefreshStatus = .notChecked
    @Published private(set) var keepAwakeEnabled: Bool
    @Published private(set) var keepAwakeActive = false
    @Published private(set) var onBattery = false
    @Published private(set) var consentPending = false
    @Published private(set) var displayAsleep = false
    @Published private(set) var openAtLogin = false
    @Published private(set) var chimeOnConnect: Bool
    @Published private(set) var allowSystemAudio = true
    private var phoneAudioRequested = false
    private var usesPhoneAudioRequest: Bool {
        connection.peerFeatures.contains(SessionFeature.phoneAudio) && !UserDefaults.standard.bool(forKey: "phoneAudioRequestDisabled")
    }
    private var systemAudioAllowedNow: Bool {
        HostPhoneAudioPolicy.permits(negotiated: usesPhoneAudioRequest, phoneRequested: phoneAudioRequested,
            macAllowed: allowSystemAudio, legacyAllowed: preferences.legacySystemAudioAllowed,
            currentPicture: connection.connected && active && sessionState == .picture && !sessionRefused,
            suspended: liveViewOnly || away.isLocking || phonePause.isPaused, narrowScope: captureScopeViewOnly)
    }
    private func reconcileSystemAudio() {
        let enabled = systemAudioAllowedNow
        guard connection.media?.systemAudioEnabled != enabled else { return }
        connection.media?.setSystemAudioEnabled(enabled)
        capture.setSystemAudioEnabled(enabled)
    }
    @Published private(set) var timedPause = HostTimedPause()
    @Published private(set) var unavailableReason: HostAvailabilityNote?
    @Published private(set) var loginItemState: HostBackgroundItemState = .off
    @Published private(set) var recoveryState: HostBackgroundItemState = .off
    @Published private(set) var curtainPreference: Bool
    @Published private(set) var curtainState: PrivacyCurtainState = .off
    @Published private(set) var crashLoopStopped = false
    @Published private var autoStart = HostAutoStartGate()
    let events = HostEventLog()
    /// Agent alerts (beta): a hook on this Mac says an agent needs a person, and this tells the phone.
    let agentAlerts = HostAgentAlerts()
    private var agentPushPair: HostPair?
    /// Alerts waiting for the next `capture` status; each rides one message, once.
    private var agentAlertOutbox: [AgentAlertFrame] = []
    #if DEBUG
    // E2E mode: inert login/recovery items and an isolated watchdog record; see HostE2E.swift.
    private let background = HostE2E.active?.backgroundServices ?? HostBackgroundServices.live()
    private let watchdog = HostE2E.active.map { $0.makeWatchdogReporter() } ?? HostWatchdogReporter.live()
    #else
    private let background = HostBackgroundServices.live()
    private let watchdog = HostWatchdogReporter.live()
    #endif
    private var hangWatchdog: HostHangWatchdog?
    private let curtain = PrivacyCurtainController()
    private var curtainRaising = false
    private var curtainLocallyDismissed = false
    private var curtainRaiseFailed = false
    private var captureUnhealthySince: TimeInterval?
    /// Registered without Screen Recording only so the paired phone learns why it cannot connect.
    private var listeningWithoutSharing = false
    /// Set when this launch followed an unexpected exit; told to the first phone that connects.
    private var recoveryNoticePending = false
    private var recoveryNoticeDelivered = false
    private var setupWasComplete = false
    private var sessionsThisLaunch = 0
    /// Input admission counts since launch, by outcome; no content.
    private var inputCounts: [String: Int] = [:]
    private var sessionStartedAt: Date?
    private var lastSessionDuration: TimeInterval?
    #if DEBUG
    private let preferences = HostPreferences(defaults: HostE2E.active?.defaults ?? .standard)
    private let hostPairStore = HostE2E.active?.pairStore ?? PairStore(account: "host")
    // The E2E harness must never read or overwrite the owner's removal proof.
    private let serverRemovalStore = PairStore(account: HostE2E.active.map { "host.e2e.room-removal.\($0.runID)" } ?? "host.room-removal.v1")
    #else
    private let preferences = HostPreferences()
    private let hostPairStore = PairStore(account: "host")
    private let serverRemovalStore = PairStore(account: "host.room-removal.v1")
    #endif
    private var pendingServerRemoval: PendingHostRoomRemoval?
    private var serverRemovalReadFailed = false
    private lazy var input = HostInputExecutor(driver: RemoteInputDriver(isTrusted: { [snapshot = postingGrantSnapshot] in
        snapshot.allowsPosting(at: ProcessInfo.processInfo.systemUptime, legacyProbe: {
            InputCadenceTrace.permission("post-legacy", probe: CGPreflightPostEventAccess)
        })
    }))
    private let capture = RemoteCapture()
    // A default-off route: none of the adapter/AX work is initialized on ordinary launches.
    private var virtualDisplayEnabled: Bool {
        #if DEBUG
        return (HostE2E.active?.defaults ?? .standard).bool(forKey: "farsideVirtualDisplayEnabled")
        #else
        return UserDefaults.standard.bool(forKey: "farsideVirtualDisplayEnabled")
        #endif
    }
    private var virtualDisplayJournalURL: URL {
        #if DEBUG
        if let harness = HostE2E.active {
            return FileManager.default.temporaryDirectory.appendingPathComponent("FarsideE2E-\(harness.runID)/virtual-display-window-restore.json")
        }
        #endif
        return VirtualDisplayWindowKeeper.defaultJournalURL
    }
    private lazy var virtualDisplay = SessionVirtualDisplay()
    private lazy var virtualWindows = VirtualDisplayWindowKeeper(journalURL: virtualDisplayJournalURL)
    private var virtualDisplaySource: SCDisplay?
    private var virtualDisplayRequested: VirtualDisplaySpecification?
    private var virtualDisplayTask: Task<Void, Never>?
    private var virtualDisplayGrace: Task<Void, Never>?
    private var virtualDisplayGeneration: UInt64 = 0
    private var virtualDisplayBlocked = false
    private var virtualDisplayWasUsed = false
    private var virtualDisplayChanging = false
    private var virtualDisplayRecoveryPending = false
    private var virtualDisplayLastRetiredAt = -Double.infinity
    private var virtualDisplayRetirementPending = false
    private var virtualDisplayResumeMode: SessionMode?
    private var virtualDisplayQuitPending = false
    private var virtualDisplayLastRestoreRetry: TimeInterval = 0
    private var virtualDisplayAcceptedRequest: VirtualDisplaySpecification?
    private var virtualDisplayNegotiationDeadline: Task<Void, Never>?
    private var virtualDisplayResizeHoldSupported = false
    private var virtualDisplayResizeBegin: VirtualDisplayResizeBegin?
    private weak var virtualDisplayResizePeer: PeerMedia?
    private var virtualDisplayResizeDeadline: TimeInterval = 0
    private var usesVirtualDisplay: Bool { virtualDisplaySource != nil }
    private var virtualDisplaySourceResumable: Bool {
        guard let source = virtualDisplaySource,
              virtualDisplayAcceptedRequest == virtualDisplayRequested else { return false }
        return virtualDisplay.isReady(for: source)
    }
    private let guests = HostGuestController()
    private var guestContext: HostGuestContext? {
        guard active, captureHealthy, sessionState == .picture, !screenLocked, !terminating,
              !phonePause.isPaused, !liveViewOnly, !away.isLocking, !captureScopeNeedsSelection, screenRecordingPermission.isGranted,
              let owner = connection.guestOwnerContext, let invitation = connection.invitation,
              let hostID = invitation.durableHostID, var url = URLComponents(string: invitation.server) else { return nil }
        url.scheme = url.scheme == "wss" ? "https" : "http"; url.path = ""; url.query = nil; url.fragment = nil
        guard let origin = url.string, GuestValidation.origin(origin) else { return nil }
        return HostGuestContext(room: invitation.room, hostID: hostID, origin: origin, ownerSessionID: owner.session,
            scopeEpoch: String(captureScopeEpoch), geometryEpoch: String(inputEpoch.value), scopeKind: captureScopeKind.rawValue,
            deadline: owner.deadline)
    }
    func createGuestLink() { guests.create() }
    func copyGuestLink(_ id: String) { guests.copyLink(id) }
    func approveGuest(_ id: String) { guests.approve(id) }
    func revokeGuest(_ id: String) { guests.end(id) }

    private lazy var bigText = BigTextController(
        switcher: LiveDisplayModeSwitcher(), windows: BigTextWindowKeeper(access: LiveWindowAccess()),
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in _ = try? await Task.sleep(for: .seconds(seconds)) })
    // The CoreGraphics callback holds this monitor unretained, so it lives as long as the host.
    private lazy var reconfigurationMonitor = DisplayReconfigurationMonitor { [weak self] event in
        guard let self else { return }
        self.bigText.observe(event)
        if self.bigTextOwnsScreenChanges, !event.flags.contains(.beginConfigurationFlag) {
            self.curtain.refitDuringDisplayChange()
        }
    }
    private var bigTextLastRestoreRetry: TimeInterval = 0
    private var bigTextScreenSnapshot: BigTextScreenSnapshot?
    private var bigTextResuming = false
    /// A Big Text change began and nothing has refreshed the display list since.
    private var bigTextNeedsRefresh = false
    private var bigTextRefreshTask: Task<Void, Never>?
    private var bigTextRefreshGeneration: UInt64 = 0
    /// Bumped whenever the display list is thrown away, so a slower Big Text fetch never revives it.
    private var displaySnapshotGeneration: UInt64 = 0
    /// G12: one per capture session while the ladder switch is on.
    private var loadMonitor: HostLoadMonitor?
    private var vitalsMonitor: MacVitalsMonitor?
    private var phoneLoad: PhoneLoadFeedback?
    private var phoneLoadReceivedAt: TimeInterval?
    private var ladderState: LadderState?
    private var busyState: BusyState?
    private let wakeTargets = HostWakeTargetStore()
    private lazy var lanWake = HostLANWakeService(resolve: { [weak self] id in
        try? self?.wakeTargets.read().first { $0.id == id }
    }, send: { LANMagicPacketSender().send($0) })
    private let powerAssertions = HostPowerAssertions()
    private let displayWake = HostDisplayWake()
    private var screenLocked = false {
        didSet { reconcileAutomaticClipboard() }
    }
    private var couchSessionSnapshot = CouchSessionSnapshotCache()
    private var unavailabilityTeardown: Task<Void, Never>?
    private var timedPauseTask: Task<Void, Never>?
    private let clipboard = HostClipboardService()
    private let fileTransfer = HostFileTransferService()
    private var phonePause = HostPhonePause()
    private var lifecycleTimer: Timer?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var connectionObserver: AnyCancellable?
    /// D39: the live session's activity for the popover and the menu-bar mark.
    let activity = HostActivityFeed()
    lazy var menuGlyph = HostMenuBarGlyph(activity: activity)
    private var roundTripObserver: AnyCancellable?
    private var agentAlertObservers: Set<AnyCancellable> = []
    private var captureTask: Task<Void, Never>?
    private var captureAttempt: UInt64 = 0
    private var inputEpoch = RemoteInputEpoch()
    private var inputFreshness = NativeInputFreshness()
    private var textFocusRevision: UInt64 = 0
    private var textFocusTask: Task<Void, Never>?
    private let textFocusCursor = HostCursorShapeSampler()
    private var axPrewarmEdge = HostAXPrewarmEdge()
    private let axSessionGeneration = HostAXSessionGeneration()
    private var captureHealthy = false {
        didSet { reconcileAutomaticClipboard() }
    }
    private var sessionState: HostSessionState = .picture {
        didSet { reconcileAutomaticClipboard() }
    }
    private var couchHealthy = false
    private var lastPhoneHeartbeatAt: TimeInterval?
    private var pendingModeReason: SessionModeRefusal?
    private let couchHUD = CouchHUD()
    private var refusalTeardown: Task<Void, Never>?
    /// A display change during Couch requires a fresh catalog before an explicit Picture switch.
    private var displaysStaleFromCouch = false
    private var pendingPictureRefresh: CouchPictureRefreshTicket?
    private weak var pendingPictureRefreshPeer: PeerMedia?
    private var pictureRefreshTimeout: Task<Void, Never>?
    private var sessionHealthy: Bool {
        switch sessionState {
        case .picture: captureHealthy && awayPictureClear
        case .couch: couchHealthy
        case .refused: false
        }
    }
    private var sessionRefused: Bool {
        if case .refused = sessionState { return true }
        return false
    }
    private var capturedDisplayID: CGDirectDisplayID?
    private var pointerLocator = HostPointerLocator()
    private let pointerTelemetry = HostPointerTelemetry()
    private var displayRefreshTask: Task<Void, Never>?
    private var displayRefreshGeneration = HostPermissionRefreshGeneration()
    private var terminating = false {
        didSet { reconcileAutomaticClipboard() }
    }

  private var liveViewOnly = false {
      didSet { reconcileAutomaticClipboard() }
  }
    private var sessionControlAllowed: Bool { allowControl && !liveViewOnly && !away.isLocking && awayPictureClear }
    private let captureScopes = HostCaptureScope()
    private var captureScopeRefreshTask: Task<Void, Never>?
    private var captureScopeSelectionTask: Task<Void, Never>?
    private var captureScopeSelectionGeneration: UInt64 = 1
    @Published private var captureScopeTarget: HostCaptureTarget?
    @Published private var captureScopeNeedsSelection = false
    @Published private var captureScopeEpoch: UInt64 = 1
    @Published private var captureScopeOptions: [HostCaptureScopeOption] = [.init(id: "display", name: "Entire display")]
    private var captureScopeKind: CaptureScopeFrame.Kind {
        captureScopeTarget?.kind ?? (captureScopeNeedsSelection ? .window : .display)
    }
    private var captureScopeViewOnly: Bool { captureScopeKind != .display }
    private var captureScopeStatus: CaptureScopeFrame {
        CaptureScopeFrame(epoch: captureScopeEpoch, kind: captureScopeKind,
            label: captureScopeKind == .display ? "Entire display" : (captureScopeKind == .application ? "Shared application" : "Shared window"),
            viewOnly: captureScopeViewOnly)
    }

    var allowControl: Bool { !captureScopeViewOnly && controlConsent.isAllowed }

    func refreshCaptureScopes() {
        captureScopeRefreshTask?.cancel()
        captureScopeRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.captureScopes.refresh(displayID: self.selected)
                guard !Task.isCancelled else { return }
                self.captureScopeOptions = self.captureScopes.options
                if let target = self.captureScopeTarget, self.captureScopes.target(id: target.id) == nil {
                    self.captureScopeLost()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.detail = "Couldn’t list shared content. Refresh and choose a live app or window."
            }
        }
    }

    /// Selecting content stops sharing first. Share Again is the owner's explicit restart consent.
    func selectCaptureScope(_ id: String) {
        if virtualDisplayWasUsed { virtualDisplayBlocked = true; retireVirtualDisplay() }
        captureScopeSelectionGeneration &+= 1
        let generation = captureScopeSelectionGeneration
        captureScopeSelectionTask?.cancel()
        phoneAudioRequested = false
        connection.media?.setSystemAudioEnabled(false)
        capture.setSystemAudioEnabled(false)
        guests.endAll()
        _ = capture.stop() // synchronous frame fence, before any await or peer teardown
        clipboard.reset()
        fileTransfer.reset()
        stopSharing()
        advanceEpoch()
        captureScopeEpoch &+= 1
        if captureScopeEpoch == 0 { captureScopeEpoch = 1 }
        captureScopeTarget = nil
        captureScopeNeedsSelection = id != HostCaptureScope.displayID
        preferences.captureScopeRequiresSelection = captureScopeNeedsSelection
        if id == HostCaptureScope.displayID {
            detail = "Entire display selected. Share again when ready."
            return
        }
        guard let target = captureScopes.target(id: id) else {
            detail = "That content is unavailable. Refresh and choose it again."
            return
        }
        captureScopeSelectionTask = Task { [weak self] in
            do {
                _ = try await HostCaptureScope.resolve(target)
                guard let self, !Task.isCancelled, generation == self.captureScopeSelectionGeneration else { return }
                self.captureScopeTarget = target
                self.captureScopeNeedsSelection = false
                self.detail = "View-only content selected. Audio, control and transfers are off. Share again when ready."
            } catch {
                guard let self, !Task.isCancelled, generation == self.captureScopeSelectionGeneration else { return }
                self.detail = "That content closed or its app quit. Refresh and choose a live target."
            }
        }
    }

    private func captureScopeLost() {
        selectCaptureScope("unavailable")
        detail = "Shared content is unavailable. Choose it again on this Mac; sharing has stopped."
    }
    var controlPermission: HostPermissionStatus { inputAccess.postEvents }

    nonisolated static func probeInputAccess() -> HostInputAccess {
        HostInputAccess(postEvents: InputCadenceTrace.permission("post", probe: CGPreflightPostEventAccess) ? .granted : .denied,
                        accessibility: InputCadenceTrace.permission("AX", probe: AXIsProcessTrusted) ? .granted : .denied)
    }
    var hasPairedPhone: Bool { connection.hostPair?.paired == true }
    var serviceAddress: String? {
        HostPreferences.resolveServiceAddress(
            saved: connection.invitation?.server,
            preference: preferences.serviceAddress,
            bundled: Bundle.main.object(forInfoDictionaryKey: "PocketDeskServiceURL") as? String
        )
    }
    var canPair: Bool {
        displayRefreshStatus == .ready && screenRecordingPermission.isGranted && HostPairingPreflight.isEligible(
            selectedDisplayID: selected,
            availableDisplayIDs: displays.map(\.displayID)
        )
    }
    var needsSetup: Bool { setupStep != .done }
    var presentsSetupAtLaunch: Bool { HostLaunchPolicy.presentsSetup(step: setupStep, pairingDeferred: pairingDeferred) }

    func presentsConsentAtLaunch(launchedAsLoginItem: Bool) -> Bool {
        HostLaunchPolicy.presentsConsent(step: setupStep, consentPending: consentPending,
                                         launchedAsLoginItem: launchedAsLoginItem,
                                         loginItemRegistered: loginItemState.isRegistered)
    }

    var setupStep: HostSetupStep {
        .current(
            screenRecording: screenRecordingPermission,
            accessibility: controlPermission,
            accessibilitySkipped: accessibilitySkipped,
            hasPairedPhone: hasPairedPhone,
            pairingRequested: pairingRequested
        )
    }

    private var pairingInProgress: Bool {
        !pairingCode.isEmpty && !pairingExpired && connection.hostPair?.paired == false
            && (connection.hostPair?.invitation.expires ?? .distantPast) > Date()
    }

    var status: HostStatus {
        HostStatus.resolve(.init(
            screenRecording: screenRecordingPermission,
            hasPairedPhone: hasPairedPhone,
            pairingInProgress: pairingInProgress,
            wantsSharing: wantsSharing,
            sharingActive: active,
            hostRegistered: connection.hostRegistered,
            reconnecting: connection.reconnecting,
            connected: connection.connected,
            awaitingApproval: connection.awaitingApproval,
            captureApprovalPending: captureApproval.isPending,
            controlEffective: sessionControlAllowed && controlPermission.isGranted && sessionHealthy,
            unavailable: autoStart.suppressed,
            displayStatus: displayRefreshStatus
        ))
    }

    var pairingState: HostPairingState {
        if connection.awaitingApproval { return .awaitingApproval }
        if !pairingCode.isEmpty, let pair = connection.hostPair, !pair.paired {
            // Rejection, timeout and malformed enrollment retire the invitation immediately.
            let expires = pair.invitation.expires
            return pairingExpired || expires <= Date() ? .expired : .showingCode(pairingCode, expires: expires)
        }
        if serviceAddress == nil { return .needsService }
        if hasPairedPhone && pairingRequested { return .confirmReplace }
        return .idle
    }

    /// The name set in System Settings, read from configd. `Host.current()` resolves the host's
    /// addresses and can block the main thread, and `viewState` is rebuilt on every model change.
    nonisolated static var computerName: String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    var viewState: HostViewState {
        let status = status
        return HostViewState(
            macName: Self.computerName ?? "this Mac",
            appListName: Self.appListName,
            screenRecording: screenRecordingPermission,
            accessibility: controlPermission,
            focusAccessibility: inputAccess.accessibility,
            screenRecordingSettingsOpened: screenRecordingSettingsOpened,
            accessibilitySettingsOpened: accessibilitySettingsOpened,
            accessibilitySkipped: accessibilitySkipped,
            status: status,
            setupStep: setupStep,
            hasPairedPhone: hasPairedPhone,
            pairingRequested: pairingRequested,
            pairing: pairingState,
            pairingComparisonCode: connection.pairingComparisonCode,
            pendingPairingPhoneName: connection.pendingPairingPhoneName,
            canBeginPairing: canPair && serviceAddress != nil && !serverRemovalPending,
            allowControl: allowControl,
            keepAwake: keepAwakeEnabled,
            keepAwakePausedOnBattery: keepAwakeEnabled && onBattery,
            openAtLogin: openAtLogin,
            consentPending: consentPending,
            chimeOnConnect: chimeOnConnect,
            wakeHelperHostID: hasPairedPhone ? connection.invitation?.durableHostID : nil,
            wakeOwnerPairID: hasPairedPhone ? connection.invitation?.ownerPairID : nil,
            localOnly: connection.localOnly,
            allowSystemAudio: preferences.systemAudioPermission(phoneRequests: !connection.connected || usesPhoneAudioRequest),
            pausedUntil: timedPause.resumesAt,
            session: status.isSessionLive ? HostSessionReadout.parse(connection.diagnostics) : nil,
            sessionStartedAt: status.isSessionLive ? sessionStartedAt : nil,
            phoneName: PhoneDisplayName.display(connection.peerName),
            availability: availabilityNote,
            loginItem: loginItemState,
            automaticRecovery: recoveryState,
            privacyCurtain: !captureScopeViewOnly && curtainPreference,
            curtainStatus: Self.curtainStatus(curtainState, displays: NSScreen.screens.count),
            couchMode: sessionState == .couch && connection.connected,
            awayMode: awayModeEnabled, awayIntroShown: awayIntroShown, away: away.readout(available: awayAvailable), lockWarning: lockWarning,
            agentAlerts: agentAlerts.isOn,
            agentAlertsStatus: agentAlerts.statusLine(),
            compatibilityVideoEncoder: VideoEncoderCompatibility.isOn,
            newestFrameWins: NewestFrameWinsSwitch.isOn,
            crashLoopStopped: crashLoopStopped,
            displays: displays.map { HostDisplayOption(id: $0.displayID, name: Self.displayName(for: $0.displayID)) },
            selectedDisplayID: selected,
            captureScopes: captureScopeOptions,
            selectedCaptureScopeID: captureScopeTarget?.id ?? (captureScopeNeedsSelection ? "unavailable" : HostCaptureScope.displayID),
            captureScopeViewOnly: captureScopeViewOnly,
            captureScopeNeedsSelection: captureScopeNeedsSelection,
            guestViewingAvailable: guestContext != nil, guestRows: guests.rows, guestMessage: guests.message,
            detail: detail,
            pairingDeferred: pairingDeferred,
            serverRemovalBusy: serverRemovalBusy,
            serverRemovalPending: serverRemovalPending,
            serverRemovalMessage: serverRemovalMessage,
            localPairRemovalMessage: localPairRemovalMessage,
            allowBigText: !captureScopeViewOnly && preferences.allowBigText,
            bigTextStatus: bigTextStatus,
            menuBarIconShown: menuBarIconShown,
            permissionsTurnedOffByUpdate: permissionsTurnedOffByUpdate,
            diagnosticReports: diagnosticReports
        )
    }

    private var bigTextEndedForLifecycle = false
    private var deliberatePeerEnding = false
    private var acceptedPhonePauseEpoch: UInt64?

    private var bigTextStatus: String? {
        if bigText.restorePending || bigText.phase == .restoring { return "Restoring normal size…" }
        guard let current = bigText.current else { return nil }
        return "Big Text on · looks like \(current.width) × \(current.height)"
    }

    private var availabilityNote: HostAvailabilityNote? {
        if screenLocked { return .locked }
        if let unavailableReason { return unavailableReason }
        return displayAsleep && active ? .displayAsleep : nil
    }

    /// The installed bundle keeps its original file name so macOS permission grants survive the
    /// rename; setup mentions it because System Settings may list the app under that name.
    private static let appListName: String =
        HostPermissionCopy.listName(fromDisplayName: FileManager.default.displayName(atPath: Bundle.main.bundlePath))

    private var latestSenderStatistics: StreamStatsReport?
    private var diagnosticRecorder = DiagnosticSessionRecorder()
    private let diagnosticStore = SessionDiagnosticStore()
    @Published private var diagnosticReports: [SessionDiagnosticReport] = []

    init() {
        #if DEBUG
        connection.allowsCausalInput = HostE2E.active == nil
        #endif
        controlConsent = HostControlConsentState(isAllowed: preferences.allowControl)
        keepAwakeEnabled = preferences.keepAwake
        consentPending = preferences.consentPending()
        chimeOnConnect = preferences.chimeOnConnect
        allowSystemAudio = preferences.allowSystemAudio
        captureScopeNeedsSelection = preferences.captureScopeRequiresSelection
        wantsSharing = preferences.sharingMayResumeWithoutScopeSelection
        if preferences.captureScopeRequiresSelection { preferences.sharingEnabled = false }
        accessibilitySkipped = preferences.accessibilitySkipped
        diagnosticReports = diagnosticStore.load()
        pairingDeferred = preferences.pairingDeferred
        curtainPreference = preferences.privacyCurtain
        awayModeEnabled = preferences.awayMode
        awayIntroShown = preferences.awayIntroShown
        menuBarIconShown = preferences.menuBarIconShown
        loadPendingServerRemoval()
        refreshBackgroundStates()
        background.onChange = { [weak self] in self?.refreshBackgroundStates() }
        onBattery = powerAssertions.battery.onBattery
        powerAssertions.battery.onChange = { [weak self] in self?.updatePowerAssertions() }
        if !powerAssertions.battery.start() {
            events.record(.error, "Power source notifications unavailable; battery state rechecked on wake and sharing changes")
        }
        NativeCodecCapability.warmUp()
        NativeHEVCCapability.warmUp()
        NativeHEVC444Capability.warmUp()
        startWatchdog()
        startAwayMode()
        browserSession.canAcquire = { [weak self] in guard let self else { return false }; return !self.captureScopeViewOnly && !self.away.isLocking && !self.away.wantsCover && !self.active && !self.connection.connected }
        if preferences.localOnly { connection.setLocalOnly(true) }
        connection.restore()
        if FileManager.default.fileExists(atPath: virtualDisplayJournalURL.path) {
            virtualDisplayRecoveryPending = true
            Task { [weak self] in
                guard let self else { return }
                self.virtualDisplayRecoveryPending = !(await self.virtualWindows.recover())
                if self.virtualDisplayRecoveryPending { self.detail = "Window restoration from the previous phone workspace needs attention." }
                else { self.reconcileSharing() }
            }
        }
        connection.startAllowed = { [weak self] in self?.serverRemovalPending == false && self?.captureScopeNeedsSelection == false && self?.virtualDisplayRecoveryPending == false }
        connection.shareBlocker = { [weak self] in
            MacShareBlocker.current(screenRecordingGranted: CGPreflightScreenCaptureAccess(),
                                    captureApprovalPending: self?.captureApproval.isPending == true)
        }
        connection.onAuthenticated = { [weak self] in
            self?.virtualDisplayGrace?.cancel(); self?.virtualDisplayGrace = nil
            self?.virtualDisplayNegotiationDeadline?.cancel()
            self?.virtualDisplayNegotiationDeadline = nil
            self?.virtualDisplayBlocked = false
            self?.virtualDisplayResizeHoldSupported = false
            self?.cancelVirtualDisplayResizeHold()
            self?.bigTextEndedForLifecycle = false
            self?.deliberatePeerEnding = false
            self?.acceptedPhonePauseEpoch = nil
            // Each authenticated peer must advertise its own current canvas. Restore the
            // retained workspace before physical-first capability/viewport renegotiation.
            if let self, self.virtualDisplayWasUsed { self.retireVirtualDisplay(resume: .picture) }
            self?.phoneConnected()
        }
        connection.onEnded = { [weak self] in
            if self?.bigTextEndedForLifecycle == true { self?.bigText.sessionEnded(.sessionEnded) }
            else { self?.bigText.connectionLost() }
            self?.endCapture()
            if self?.virtualDisplayWasUsed == true {
                self?.retireVirtualDisplay(afterGrace: self?.bigTextEndedForLifecycle != true && self?.terminating != true)
            }
            self?.reconcileAvailabilityAfterCoordinatorReset()
        }
        connection.onControl = { [weak self] data in self?.receive(data) }
        connection.onCausalRecovery = { [weak self] in self?.releaseRemoteInput(notifyPhone: true) }
        connection.onCausalContext = { [weak self] context in
            guard let self else { return }
            self.releaseRemoteInput(notifyPhone: false)
            self.input.beginCausalContext(context)
            self.inputFreshness.noteCausalUpgrade()
        }
        connection.onCausalInput = { [weak self] context, action in self?.receiveCausalInput(context, semantic: action) }
        connection.onCausalRejected = { [weak self] action in
            if action.action == "text" { self?.sendTextResult(for: action.key, accepted: false) }
        }
        clipboard.transport = { [weak self] frame in
            guard let self, !self.captureScopeViewOnly, self.connection.connected else { return false }
            return self.connection.sendControl(RemoteAction(action: "clipboard", epoch: self.inputEpoch.value, clipboard: frame))
        }
        clipboard.bufferedAmount = { [weak self] in self?.connection.media?.controlBufferedAmount }
        clipboard.automaticPolicy = { [weak self] in self?.automaticClipboardAllowed == true }
        wireFileTransfer()
        connectionObserver = connection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.connectionDidChange() }
        }
        roundTripObserver = connection.$diagnostics.sink { [weak self] line in
            guard let self, self.connection.connected else { return }
            self.activity.record(roundTripMs: HostSessionReadout.parse(line)?.roundTripMs)
        }
        wireAgentAlerts()
        networkPath.onChange = { [weak self] in self?.connection.networkPathChanged() }
        networkPath.start()
        guests.context = { [weak self] in self?.guestContext }
        guests.ownerPeer = { [weak self] in self?.connection.media }
        guests.send = { [weak self] frame in self?.connection.sendGuest(frame) ?? false }
        guests.changed = { [weak self] in self?.objectWillChange.send() }
        guests.start()
        connection.onGuest = { [weak self] frame in self?.guests.receive(frame) }
        connection.onGuestAuthorityEnded = { [weak self] in self?.guests.endAll() }
        let guestFanout = guests.fanout
        capture.onGuestFrame = { buffer, at in guestFanout.deliver(buffer, at: at) }
        capture.onGuestSourceFence = { guestFanout.fence() }
        capture.onGuestSourceChanged = { [weak self] in self?.guests.endAll() }
        capture.onFailure = { [weak self] error in self?.captureFailed(error) }
        capture.onHealth = { [weak self] healthy in self?.captureHealthChanged(healthy) }
        capture.onExclusionLost = { [weak self] in
            guard let self, self.curtain.phase != .down else { return }
            if self.away.wantsCover {
                self.awayExclusion.invalidate()
                self.input.withAuthority {
                    self.input.enabled = false
                    self.input.invalidateQueued(); self.inputFreshness.expireTokens()
                    self.releaseRemoteInput(notifyPhone: false)
                }
                self.captureHealthChanged(false)
                self.sendCaptureHealth(false)
                self.excludeCoverFromCapture()
                return
            }
            self.curtain.lift()
            self.reconcileCurtain()
        }
        curtain.ownsScreenChange = { [weak self] in
            guard let self else { return false }
            return self.bigTextOwnsScreenChanges || (self.virtualDisplayWasUsed && self.virtualDisplay.physicalTopologyUnchanged)
        }
        curtain.excludesDisplay = { [weak self] id in
            guard let self, self.virtualDisplayWasUsed else { return false }
            return self.virtualDisplay.isOwnedDisplay(id)
        }
        curtain.onLocalLift = { [weak self] in self?.curtainLiftedLocally() }
        curtain.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            if self.away.wantsCover && phase == .up {
                self.awayExclusion.invalidate()
                self.input.withAuthority {
                    self.input.enabled = false
                    self.input.invalidateQueued(); self.inputFreshness.expireTokens()
                    self.releaseRemoteInput(notifyPhone: false)
                }
            }
            self.reconcileCurtain()
            if self.away.wantsCover && phase == .up { self.excludeCoverFromCapture() }
        }
        pointerTelemetry.send = { [weak self] action in self?.connection.sendControl(action) ?? false }
        pointerTelemetry.setCaptureShowsCursor = { [weak self] shows in
            guard let self, self.sessionState == .picture else { return }
            self.capture.setShowsCursor(shows)
        }
        pointerTelemetry.captureShowsCursor = { [weak self] in self?.capture.cursorInVideo ?? true }
        capture.onCursorVisibility = { [weak self] shows in
            guard let self else { return }
            self.pointerTelemetry.captureCursorChanged(showsCursor: shows)
            self.sendCaptureHealth(self.sessionHealthy)
        }
        capture.onCaptureRegion = { [weak self] region in
            guard let self else { return }
            self.connection.media?.captureRegion = region
            self.connection.media?.captureSharpness = self.capture.deliveredSharpness
            self.sendCaptureHealth(self.sessionHealthy)
        }
        let workspaceEvents: [(Notification.Name, HostSleepPolicy.Event)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            (NSWorkspace.screensDidSleepNotification, .displaySlept),
            (NSWorkspace.screensDidWakeNotification, .displayWoke)
        ]
        for (name, event) in workspaceEvents {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleAvailability(event) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, let app else { return }
                self.prewarmAXTree(for: app)
            }
        })
        for (name, event) in [(HostScreenLock.locked, HostSleepPolicy.Event.screenLocked),
                              (HostScreenLock.unlocked, HostSleepPolicy.Event.screenUnlocked)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleAvailability(event) }
            })
        }
        if HostScreenLock.isLocked() { handleAvailability(.screenLocked) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (self.virtualDisplayWasUsed || ProcessInfo.processInfo.systemUptime - self.virtualDisplayLastRetiredAt < 2),
                   self.virtualDisplay.physicalTopologyUnchanged {
                    self.curtain.refitDuringDisplayChange()
                    if !self.virtualDisplayChanging && !self.virtualDisplay.ownedDisplayPresent && self.usesVirtualDisplay {
                        self.virtualDisplayFallback()
                    }
                } else if self.virtualDisplayWasUsed && self.virtualDisplay.ownsScreenChanges {
                    // A physical hot-plug/mode change is foreign, even during our transition.
                    self.retireVirtualDisplay()
                    self.handleScreenChange()
                } else if self.bigTextHandlingScreenChanges {
                    self.bigText.handleScreenChangeNotification(
                        refit: { self.curtain.refitDuringDisplayChange() },
                        foreign: { self.handleScreenChange() })
                } else if self.bigTextOwnsScreenChanges {
                    self.curtain.refitDuringDisplayChange()
                } else if self.sessionState == .couch && self.connection.connected {
                    self.displaysStaleFromCouch = true
                    self.releaseRemoteInput(notifyPhone: true)
                    let rects = HostCouchDisplays.current()
                    guard !rects.isEmpty else { self.stop(); return }
                    self.input.configure(displays: rects)
                } else {
                    self.handleScreenChange()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.captureApproval.checkSoon(at: ProcessInfo.processInfo.systemUptime)
                self.pollPermissions()
                self.refreshBackgroundStates()
            }
        })
        bigText.host = self
        reconfigurationMonitor.start()
        screenRecordingPermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        inputAccess = inputAccessCache.current
        evaluateUpgradeRegrant()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollPermissions()
                let now = ProcessInfo.processInfo.systemUptime
                if !self.screenLocked, self.inputAccess.accessibility.isGranted,
                   now - self.virtualDisplayLastRestoreRetry >= 30 {
                    if self.virtualDisplayRecoveryPending {
                        self.virtualDisplayLastRestoreRetry = now
                        self.virtualDisplayRecoveryPending = !(await self.virtualWindows.recover())
                        if !self.virtualDisplayRecoveryPending { self.reconcileSharing() }
                    } else if self.virtualDisplayRetirementPending &&
                                self.virtualDisplayGrace == nil && self.virtualDisplayTask == nil {
                        self.virtualDisplayLastRestoreRetry = now
                        self.retireVirtualDisplay(resume: self.virtualDisplayResumeMode)
                    }
                }
                if self.bigText.restorePending, !self.bigText.isChanging, !self.screenLocked,
                   now - self.bigTextLastRestoreRetry >= 30 {
                    self.bigTextLastRestoreRetry = now
                    self.bigText.retryPendingRestore()
                }
            }
        }
        permissionTimer?.tolerance = 0.2
        if screenRecordingPermission.isGranted { loadDisplays() } else { reconcileSharing() }
        #if DEBUG
        HostE2E.active?.attach(self)
        #endif
    }

    // MARK: Setup

    func openSystemSettings(_ pane: HostSystemSettingsPane) {
        switch pane {
        case .screenRecording:
            screenRecordingSettingsOpened = true
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            accessibilitySettingsOpened = true
            _ = CGRequestPostEventAccess()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        NSWorkspace.shared.open(pane.url)
    }

    func skipAccessibility() {
        accessibilitySkipped = true
        preferences.accessibilitySkipped = true
    }

    func deferPairing() {
        pairingDeferred = true
        preferences.pairingDeferred = true
    }

    private func clearDeferredPairing() {
        guard pairingDeferred else { return }
        pairingDeferred = false
        preferences.pairingDeferred = false
    }

    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            detail = "Couldn’t reopen automatically. Quit Farside from the menu bar and open it again."
        }
    }

    // MARK: Pairing

    func requestPairing() {
        guard removalAllowsSharing else { return }
        pairingRequested = true
        clearDeferredPairing()
    }

    func cancelPairing() {
        pairingRequested = false
    }

    func setServiceAddress(_ value: String) {
        guard removalAllowsSharing else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PairInvitation.validServer(trimmed) else { return }
        preferences.serviceAddress = trimmed
        objectWillChange.send()
        beginPairing()
    }

    func beginPairing() {
        guard removalAllowsSharing else { return }
        guard let serviceAddress = HostPreferences.resolvePairingServiceAddress(
            saved: connection.invitation?.server,
            preference: preferences.serviceAddress,
            bundled: Bundle.main.object(forInfoDictionaryKey: "PocketDeskServiceURL") as? String
        ) else { objectWillChange.send(); return }
        guard !browserSession.controller.running else { detail = "Browser access is on. Stop it before pairing a phone."; return }
        guard canPair, let display = validatedSelectedDisplay() else {
            detail = "Farside needs Screen Recording and a display to share before pairing."
            return
        }
        releaseRemoteInput(notifyPhone: true)
        do {
            guard let invitation = try HostPairingPreflight.createInvitation(
                selectedDisplayID: selected,
                availableDisplayIDs: displays.map(\.displayID),
                create: {
                    try connection.createPair(server: serviceAddress, name: Self.computerName ?? "My Mac")
                }
            ) else { return }
            preferences.serviceAddress = serviceAddress
            localPairRemovalMessage = nil
            pairingCode = try invitation.code()
            pairingExpires = invitation.expires
            pairingExpired = false
            cancelTimedPause()
            wantsSharing = true
            preferences.sharingEnabled = true
            autoStart.clear()
            active = false
            start(display: display)
        } catch {
            detail = error.localizedDescription
        }
    }

    func copyPairingCode() {
        guard !pairingCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
    }

    func approvePhone() { connection.approve() }

    func declinePhone() {
        connection.reject()
        pairingExpired = true
    }

    func removeServerRoom() {
        guard !serverRemovalBusy else { return }
        if serverRemovalReadFailed { loadPendingServerRemoval() }
        guard !serverRemovalReadFailed else { return }

        let pending: PendingHostRoomRemoval
        if let saved = pendingServerRemoval {
            pending = saved
        } else {
            guard let pair = connection.hostPair,
                  let base = ServerDataRemovalRequest.service(for: pair.invitation.server),
                  let origin = ServerDataRemovalRequest.origin(base) else {
                serverRemovalMessage = "No HTTPS service room is available. Remove Phone only forgets local pairing."
                return
            }
            let request = ServerDataRemovalRequest(kind: .room, serviceOrigin: origin,
                                                  identifier: pair.invitation.room, proof: pair.hostToken)
            do {
                _ = try request.httpRequest()
                pending = PendingHostRoomRemoval(request: request, serverConfirmed: false)
                try serverRemovalStore.save(pending)
                pendingServerRemoval = pending
                serverRemovalPending = true
            } catch {
                serverRemovalMessage = "Couldn’t save the removal proof on this Mac. Unlock it and try again; sharing was not changed."
                return
            }
        }
        stopSharing()
        serverRemovalBusy = true
        serverRemovalMessage = pending.serverConfirmed ? "Finishing local pairing cleanup…" : "Waiting for server confirmation…"
        Task { @MainActor in
            defer { serverRemovalBusy = false }
            do {
                if !pending.serverConfirmed {
                    try await HTTPServerDataRemover().remove(pending.request)
                    // A relaunch after server confirmation must retry local cleanup without
                    // depending on the removed room's server record still being present.
                    let confirmed = PendingHostRoomRemoval(request: pending.request, serverConfirmed: true)
                    try serverRemovalStore.save(confirmed)
                    pendingServerRemoval = confirmed
                }
                try finishConfirmedServerRemoval(pending.request)
                serverRemovalMessage = "Room removal confirmed. Purchase records and security blocks are retained under the privacy policy."
            } catch {
                serverRemovalMessage = "Room removal is still pending: \(error.localizedDescription) Sharing stays off; retry from Server Data."
            }
        }
    }

    private func finishConfirmedServerRemoval(_ request: ServerDataRemovalRequest) throws {
        // `connection.restore()` may have failed while Keychain was locked at launch. Read the
        // persistent pairing itself before deciding that an absent in-memory pair is cleaned up.
        if let persisted = try hostPairStore.read(HostPair.self) {
            guard persisted.hostToken == request.proof, persisted.invitation.room == request.identifier else {
                throw HostRoomRemovalCleanupError.pairingChanged
            }
            if connection.hostPair == nil { connection.restore() }
        }
        if let pair = connection.hostPair {
            guard pair.hostToken == request.proof, pair.invitation.room == request.identifier else {
                throw HostRoomRemovalCleanupError.pairingChanged
            }
            connection.revoke()
            guard connection.hostPair == nil else { throw HostRoomRemovalCleanupError.localPairingRetained }
        }
        if let _ = try hostPairStore.read(HostPair.self) {
            throw HostRoomRemovalCleanupError.localPairingRetained
        }
        // If this delete fails, keep the confirmed record and retry cleanup on the next tap.
        try serverRemovalStore.delete()
        pendingServerRemoval = nil
        serverRemovalPending = false
        clearPairingCode()
        pairingRequested = false
    }

    private func loadPendingServerRemoval() {
        do {
            pendingServerRemoval = try serverRemovalStore.read(PendingHostRoomRemoval.self)
            serverRemovalReadFailed = false
            serverRemovalPending = pendingServerRemoval != nil
            if let pendingServerRemoval {
                wantsSharing = false
                preferences.sharingEnabled = false
                serverRemovalMessage = pendingServerRemoval.serverConfirmed
                    ? "Server removal was confirmed. Retry to finish local pairing cleanup."
                    : "Room removal is pending. Sharing is off; retry from Server Data."
            }
        } catch {
            // A locked Keychain is an unknown state, not evidence that there is no pending removal.
            serverRemovalReadFailed = true
            serverRemovalPending = true
            wantsSharing = false
            preferences.sharingEnabled = false
            serverRemovalMessage = "Couldn’t read the saved room removal. Unlock this Mac and retry; sharing stays off."
        }
    }

    private var removalAllowsSharing: Bool {
        if serverRemovalReadFailed { loadPendingServerRemoval() }
        guard !serverRemovalPending else {
            detail = "Finish the pending server room removal before pairing or sharing again."
            return false
        }
        return true
    }

    func revoke() {
        guard removalAllowsSharing else { return }
        localPairRemovalMessage = nil
        // Keep a failed local deletion from silently restarting its retained pairing.
        cancelTimedPause()
        wantsSharing = false
        preferences.sharingEnabled = false
        if !browserSession.controller.running { stop() }
        let removed = connection.revoke()
        localPairRemovalMessage = removed
            ? "Phone pairing removed from this Mac."
            : "Couldn’t confirm removal. Phone sharing is off. Unlock this Mac and retry Remove."
        clearPairingCode()
        pairingRequested = false
    }

    private func clearPairingCode() {
        pairingCode = ""
        pairingExpires = nil
        pairingExpired = false
    }

    private func connectionDidChange() {
        reconcileAutomaticClipboard()
        recordServiceTransition()
        refreshAgentPushRelay()
        if hasPairedPhone { clearDeferredPairing() }
        guard !pairingCode.isEmpty, hasPairedPhone else { return }
        clearPairingCode()
        pairingRequested = false
    }

    private func recordServiceTransition() {
        let registered = connection.hostRegistered, reconnecting = connection.reconnecting
        defer { serviceRegistered = registered; serviceReconnecting = reconnecting }
        if registered && !serviceRegistered {
            events.record(.service, serviceReconnecting ? "Registered again with the Farside service" : "Registered with the Farside service")
        } else if reconnecting && !serviceReconnecting {
            events.record(.service, "Lost the Farside service (\(connection.signalingLossReason ?? "unknown")); reconnecting")
        }
    }

    // MARK: Sharing

    /// Changes only the route: the session on the old route ends and sharing, if on, restarts on the new one.
    func setLocalOnly(_ enabled: Bool) {
        guard connection.localOnly != enabled else { return }
        if active || listeningWithoutSharing { stop() }
        connection.setLocalOnly(enabled)
        preferences.localOnly = enabled
        events.record(.sharing, enabled ? "Local network only on" : "Local network only off")
        reconcileSharing()
    }

    func stopSharing() {
        cancelTimedPause()
        wantsSharing = false
        preferences.sharingEnabled = false
        events.record(.sharing, "Stop Sharing")
        stop()
        if !hasPairedPhone { clearPairingCode() }
    }

    func resumeSharing() {
        guard !captureScopeNeedsSelection else { detail = "Choose a live app or window, or explicitly select Entire display, before sharing."; return }
        guard removalAllowsSharing else { return }
        cancelTimedPause()
        if crashLoopStopped {
            crashLoopStopped = false
            watchdog?.requestCrashLoopReset()
            events.record(.recovery, "Resumed after a crash-loop stop")
        }
        wantsSharing = true
        preferences.sharingEnabled = true
        autoStart.clear()
        detail = nil
        unavailableReason = nil
        if captureApproval.isPending {
            captureApproval.checkSoon(at: ProcessInfo.processInfo.systemUptime)
            checkCaptureApproval()
        }
        if displayRefreshStatus != .ready { loadDisplays() } else { reconcileSharing() }
    }

    /// Stop Sharing now and Resume Sharing by itself later, unless the user resumes or stops
    /// first. Only this in-memory timer resumes: after a relaunch sharing simply stays off.
    func pauseSharing(for duration: TimeInterval = HostTimedPause.standard) {
        stopSharing()
        let resumesAt = timedPause.begin(at: Date(), duration: duration)
        timedPauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, duration)))
            guard let self, !Task.isCancelled, self.timedPause.isCurrent(resumesAt) else { return }
            self.resumeSharing()
        }
    }

    private func cancelTimedPause() {
        timedPauseTask?.cancel()
        timedPauseTask = nil
        timedPause.cancel()
    }

    func setAllowSystemAudio(_ enabled: Bool) {
        guard !enabled || !captureScopeViewOnly else { return }
        guard allowSystemAudio != enabled || preferences.legacySystemAudioAllowed != enabled else { return }
        allowSystemAudio = enabled
        preferences.allowSystemAudio = enabled
        reconcileSystemAudio()
    }

    /// File transfer needs a full-control sharing scope and a current, unpaused session (MS05: no Mac setting).
    /// Received files only land quarantined in Downloads › Farside, never opened; Mac-to-phone needs a pick here.
    private var fileTransferRefusal: HostFileTransferService.Refusal? {
        // Emergency internal kill switch only removes authority; it cannot bypass consent.
        if UserDefaults.standard.bool(forKey: "farsideDisableFileEffects") { return .controlDisabled }
        return HostFileTransferService.refusal(viewOnlyScope: captureScopeViewOnly, connected: connection.connected && !sessionRefused, sharing: active,
            controlAllowed: sessionControlAllowed,
            paused: phonePause.isPaused, liveViewOnly: liveViewOnly, locking: away.isLocking, lockFailed: awayLockFailed)
    }

    /// One line per refusal with every input, so a device report names the condition (no file names).
    private func logFileRefusal(_ refusal: HostFileTransferService.Refusal) -> String {
        SessionLog.log.error("file refused: \(refusal.rawValue, privacy: .public) connected=\(self.connection.connected, privacy: .public) active=\(self.active, privacy: .public) paused=\(self.phonePause.isPaused, privacy: .public) liveViewOnly=\(self.liveViewOnly, privacy: .public) away=\(Self.awayPhaseDescription(self.away.machine.phase), privacy: .public) scopeViewOnly=\(self.captureScopeViewOnly, privacy: .public) listening=\(self.listeningWithoutSharing, privacy: .public)")
        return refusal.rawValue
    }

    private func wireFileTransfer() {
        let engine = fileTransfer.engine
        engine.sendControl = { [weak self] frame in
            guard let self, self.connection.connected else { return false }
            return self.connection.sendControl(RemoteAction(action: "file", epoch: self.inputEpoch.value, file: frame))
        }
        engine.link = { [weak self] in self?.connection.media }
        engine.isRelayed = { [weak self] in self?.connection.media?.isRelayRoute ?? false }
        fileTransfer.refusal = { [weak self] in self.map { $0.fileTransferRefusal?.status } ?? .notAllowed }
        fileTransfer.refusalReason = { [weak self] in
            guard let self, let refusal = self.fileTransferRefusal else { return nil }
            return self.logFileRefusal(refusal)
        }
        connection.fileTransfer = engine
    }

    func setChimeOnConnect(_ enabled: Bool) {
        chimeOnConnect = enabled
        preferences.chimeOnConnect = enabled
    }

    private func phoneConnected() {
        // A connected phone with sharing off breaks files (and causal input) silently; say so for device reports.
        if !active { SessionLog.log.error("phone connected while sharing is not active (listening=\(self.listeningWithoutSharing, privacy: .public))") }
        axSessionGeneration.advance()
        away.refresh()
        bigText.retryPendingRestore()
        switch connection.peerRequestedMode {
        case .picture: beginCapture()
        case .couch:
            if let refusal = CouchAdmission.decide(couchAdmissionInputs) { beginRefused(refusal) } else { beginCouch() }
        }
        guard chimeOnConnect, connection.connected, !terminating else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    private func reconcileSharing() {
        guard removalAllowsSharing else { return }
        if MacShareBlocker.shouldListenWithoutSharing(
            wantsSharing: wantsSharing,
            suppressed: autoStart.suppressed,
            sharingActive: active,
            listening: listeningWithoutSharing,
            otherAccessRunning: browserSession.controller.running,
            screenRecordingGranted: screenRecordingPermission.isGranted,
            captureApprovalPending: captureApproval.isPending,
            hasPairedPhone: hasPairedPhone,
            serviceConfigured: serviceAddress != nil
        ) {
            listeningWithoutSharing = true
            events.record(.sharing, captureApproval.isPending
                ? "Listening while screen recording waits for approval, so the phone can be told why"
                : "Listening without Screen Recording so the phone can be told why")
            connection.start()
            return
        }
        guard !captureApproval.isPending else { return }
        guard autoStart.shouldStart(
            wantsSharing: wantsSharing,
            sharingActive: active,
            otherAccessRunning: browserSession.controller.running,
            screenRecordingGranted: screenRecordingPermission.isGranted,
            displayReady: displayRefreshStatus == .ready,
            hasPairedPhone: hasPairedPhone,
            serviceConfigured: serviceAddress != nil
        ), let display = validatedSelectedDisplay() else { return }
        start(display: display)
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        guard !captureScopeViewOnly else { return }
        guard id != selected, displays.contains(where: { $0.displayID == id }) else { return }
        let wasActive = active
        if wasActive { stop() }
        selected = id
        refreshCaptureScopes()
        if wasActive { reconcileSharing() }
    }

    func setControl(_ enabled: Bool) {
        guard !captureScopeViewOnly else { return }
        controlConsent.setAllowed(enabled)
        preferences.allowControl = enabled
        applyControlState(notifyPhone: true)
        sendCaptureHealth(captureHealthy)
    }

    func setKeepAwake(_ enabled: Bool) {
        keepAwakeEnabled = enabled
        preferences.keepAwake = enabled
        updatePowerAssertions()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        if let problem = background.setLoginItem(enabled) {
            detail = problem
            events.record(.error, problem)
        }
        events.record(.settings, "Open at login \(enabled ? "on" : "off")")
        refreshBackgroundStates()
    }

    /// The one-time choice from setup. Automatic recovery is a separate choice and stays as it was.
    func confirmBackgroundChoices(openAtLogin wanted: Bool, keepAwake: Bool) {
        setKeepAwake(keepAwake)
        if let problem = background.applyLoginChoice(wanted) {
            detail = problem
            events.record(.error, problem)
        }
        refreshBackgroundStates()
        preferences.acceptedConsentVersion = HostPreferences.consentVersion
        consentPending = false
        events.record(.settings, "Background choices confirmed: open at login \(wanted ? "on" : "off"), "
                      + "keep awake \(keepAwake ? "on" : "off")")
    }

    func setAutomaticRecovery(_ enabled: Bool) {
        if let problem = background.setRecovery(enabled, setupComplete: setupStep == .done) {
            detail = problem
            events.record(.error, problem)
        }
        events.record(.settings, "Automatic recovery \(enabled ? "on" : "off")")
        updateHangWatchdog(curtainUp: curtain.phase != .down)
        refreshBackgroundStates()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The Mac's "hide screen while sharing" preference; the phone changes the same preference.
    func setPrivacyCurtain(_ enabled: Bool) {
        guard !captureScopeViewOnly else { return }
        curtainPreference = enabled
        preferences.privacyCurtain = enabled
        if enabled {
            curtainLocallyDismissed = false
            curtainRaiseFailed = false
        }
        events.record(.curtain, "Hide screen while sharing \(enabled ? "on" : "off")")
        reconcileCurtain()
    }

    func setAllowBigText(_ allowed: Bool) {
        guard !captureScopeViewOnly else { return }
        preferences.allowBigText = allowed
        events.record(.settings, "Allow a connected phone to change text size \(allowed ? "on" : "off")")
        if !allowed { bigText.sessionEnded(.restoreButton) }
        sendCaptureHealth(captureHealthy)
        objectWillChange.send()
    }

    func restoreNormalSize() {
        bigText.sessionEnded(.restoreButton)
    }

    func deleteDiagnosticReport(_ id: UUID) { diagnosticStore.delete(id); diagnosticReports = diagnosticStore.load() }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport(), forType: .string)
        events.record(.settings, "Diagnostics copied")
    }

    // MARK: Agent alerts (beta)

    private func wireAgentAlerts() {
        agentAlerts.isPhoneLive = { [weak self] in self?.connection.connected == true && self?.active == true }
        agentAlerts.hasPairedPhone = { [weak self] in self?.hasPairedPhone == true }
        agentAlerts.deliverToPhone = { [weak self] frame in self?.deliverAgentAlert(frame) ?? false }
        agentAlerts.canUsePush = { [weak self] in
            guard let self else { return false }
            return self.hasPairedPhone && !self.serverRemovalPending && !self.serverRemovalReadFailed && !self.serverRemovalBusy
        }
        agentAlerts.pushIdentity = { [weak self] in
            guard let self, let pair = self.connection.hostPair, pair.paired,
                  !self.serverRemovalPending, !self.serverRemovalReadFailed, !self.serverRemovalBusy else { return nil }
            return SecureRandom.digest(pair.hostToken + "|" + pair.invitation.token + "|" + pair.invitation.server)
        }
        agentAlerts.record = { [weak self] text in self?.events.record(.session, text) }
        refreshAgentPushRelay()
        agentAlerts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &agentAlertObservers)
        Task { @MainActor [weak self] in await self?.agentAlerts.startIfEnabled() }
    }

    private func refreshAgentPushRelay() {
        let pair = connection.hostPair?.paired == true && !serverRemovalPending && !serverRemovalReadFailed && !serverRemovalBusy
            ? connection.hostPair : nil
        if pair?.hostToken == agentPushPair?.hostToken &&
            pair?.invitation == agentPushPair?.invitation && pair?.paired == agentPushPair?.paired { return }
        agentPushPair = pair
        if let pair, let relay = HTTPAgentPushRelay(pair: pair) { agentAlerts.push = relay }
        else { agentAlerts.push = UnconfiguredAgentPushRelay() }
    }

    func setAgentAlerts(_ enabled: Bool) {
        events.record(.settings, "Agent alerts \(enabled ? "on" : "off")")
        Task { @MainActor [weak self] in await self?.agentAlerts.setEnabled(enabled) }
    }

    func setCompatibilityVideoEncoder(_ enabled: Bool) {
        guard VideoEncoderCompatibility.isOn != enabled else { return }
        VideoEncoderCompatibility.isOn = enabled
        events.record(.settings, "Compatibility video encoder \(enabled ? "on" : "off") for next session")
        objectWillChange.send()
    }

    /// Takes effect at the next encoded frame; no reconnect needed.
    func setNewestFrameWins(_ enabled: Bool) {
        guard NewestFrameWinsSwitch.isOn != enabled else { return }
        NewestFrameWinsSwitch.isOn = enabled
        events.record(.settings, "Newest frame wins \(enabled ? "on" : "off")")
        objectWillChange.send()
    }

    func resetAgentAlertLink() {
        agentAlerts.resetLink()
    }

    func copyAgentHookSetup() {
        let bundled = Bundle.main.url(forResource: HostAgentAlerts.scriptName, withExtension: nil, subdirectory: "agent-hooks")
        let path = agentAlerts.installScript(from: bundled)?.path ?? "/path/to/\(HostAgentAlerts.scriptName)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HostAgentAlerts.hookSetup(scriptPath: path), forType: .string)
        events.record(.settings, "Agent hook setup copied")
    }

    /// Sends the alert on the control channel now, behind any earlier ones still queued. False when no
    /// phone is in a session or the channel would not take it, so the caller can fall back to a push.
    private func deliverAgentAlert(_ frame: AgentAlertFrame) -> Bool {
        guard connection.connected, active else { return false }
        agentAlertOutbox.append(frame)
        if agentAlertOutbox.count > 4 { agentAlertOutbox.removeFirst(agentAlertOutbox.count - 4) }
        var attempts = 0
        while agentAlertOutbox.contains(where: { $0.id == frame.id }), attempts < 4, connection.connected {
            attempts += 1
            sendCaptureHealth(sessionHealthy)
        }
        let delivered = !agentAlertOutbox.contains { $0.id == frame.id }
        agentAlertOutbox.removeAll { $0.id == frame.id }
        return delivered
    }

    func diagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ledger = watchdog?.ledger
        let boot = watchdog?.record.bootSession
        let sameBoot = ledger?.bootSession != nil && ledger?.bootSession == boot
        var snapshot = HostDiagnosticsSnapshot()
        snapshot.appVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        snapshot.appBuild = info["CFBundleVersion"] as? String ?? "?"
        snapshot.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        snapshot.hardwareModel = HostHardware.model
        snapshot.installedInApplications = background.installed
        snapshot.appUptime = Date().timeIntervalSince(watchdog?.launchedAt ?? Date())
        snapshot.screenRecording = screenRecordingPermission.isGranted ? "allowed" : "not allowed"
        snapshot.captureApproval = captureApproval.isPending ? "waiting for approval on this Mac" : "not needed"
        snapshot.postEvents = controlPermission.isGranted ? "allowed"
            : (accessibilitySkipped ? "not allowed (skipped in setup)" : "not allowed")
        snapshot.accessibility = inputAccess.accessibility.isGranted ? "allowed" : "not allowed"
        snapshot.menuBarIcon = menuBarIconShown ? "shown" : "hidden"
        snapshot.permissionsTurnedOffByUpdate = permissionsTurnedOffByUpdate.map {
            $0.title(macOSMajor: HostSystemSettingsPane.currentMacOSMajor)
        }
        snapshot.loginItem = loginItemState.diagnosticsText
        snapshot.automaticRecovery = background.recoveryWanted ? recoveryState.diagnosticsText : "off"
        snapshot.status = status.title
        snapshot.sharingWanted = wantsSharing
        snapshot.sharingActive = active
        snapshot.phonePaired = hasPairedPhone
        snapshot.phoneConnected = connection.connected
        snapshot.controlEffective = sessionControlAllowed && controlPermission.isGranted && sessionHealthy
        snapshot.keepAwake = keepAwakeEnabled
        snapshot.displayCount = displays.count
        snapshot.detail = detail
        snapshot.localPairRemovalFailure = connection.pairingRemovalFailure
        snapshot.serviceEnvironment = HostPreferences.serviceEnvironment(for: connection.invitation?.server)
        snapshot.serviceRegistration = HostServiceRegistration.describe(
            registered: connection.hostRegistered, reconnecting: connection.reconnecting,
            attempt: connection.retryAttempt, lossReason: connection.signalingLossReason)
        snapshot.curtainPreference = curtainPreference
        snapshot.curtainState = curtainState.rawValue
        snapshot.recoveredThisLaunch = watchdog?.assessment.recoveredFromUnexpectedExit ?? false
        snapshot.previousExit = watchdog?.assessment.previousExit?.rawValue
        snapshot.safeMode = crashLoopStopped
        snapshot.watchdogRelaunchesThisBoot = sameBoot ? ledger?.relaunches ?? 0 : 0
        snapshot.watchdogLastExit = sameBoot ? ledger?.lastExit?.rawValue : nil
        snapshot.watchdogLastExitAt = sameBoot ? ledger?.lastExitAt : nil
        snapshot.watchdogStoppedAt = sameBoot ? ledger?.stoppedAt : nil
        snapshot.sessionsThisLaunch = sessionsThisLaunch
        snapshot.lastSessionDuration = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? lastSessionDuration
        snapshot.route = connection.connected ? connection.diagnostics : nil
        snapshot.input = connection.inputSummary + " host=[" + inputCounts.keys.sorted().map { "\($0)=\(inputCounts[$0] ?? 0)" }.joined(separator: " ") + "]"
        snapshot.localProof = connection.localProofSummary
        snapshot.lastSessionFailure = connection.lastSessionFailure
        snapshot.streamQuality = capture.appliedQuality?.title
        snapshot.stream = latestSenderStatistics.map(Self.streamDescription)
        snapshot.tuning = StreamTuning.current.liveSummary
        snapshot.localSessionReport = diagnosticStore.load().first?.preview
        snapshot.events = events.entries
        return HostDiagnosticsReport.render(snapshot)
    }

    /// Negotiated level, sent size and encoder from the latest sender statistics (G13).
    static func streamDescription(_ report: StreamStatsReport) -> String {
        var parts: [String] = []
        if let width = report.sentWidth, let height = report.sentHeight, width > 0 { parts.append("\(width)×\(height)") }
        if let codec = report.codec {
            let level = report.h264ProfileLevel.map { profile -> String in
                guard profile.count == 6, let byte = UInt8(profile.suffix(2), radix: 16) else { return profile }
                return "level \(byte / 10).\(byte % 10)"
            }
            parts.append([codec.replacingOccurrences(of: "video/", with: ""), level].compactMap { $0 }.joined(separator: " "))
        }
        if let encoder = report.encoderImplementation {
            parts.append(encoder + (report.powerEfficientEncoder == true ? " (hardware)" : ""))
        }
        if let fps = report.encodedFPS { parts.append("\(Int(fps.rounded())) fps") }
        if let latency = report.encodeLatencyMs { parts.append("VT latency \(latency) ms") }
        parts.append("decoder probe: " + NativeCodecCapability.outcomeDescription)
        return parts.joined(separator: " · ")
    }

    private func refreshBackgroundStates() {
        background.refresh()
        loginItemState = background.loginState
        recoveryState = background.recoveryState
        openAtLogin = background.loginWanted
        updateHangWatchdog(curtainUp: curtain.phase != .down)
        if away.host != nil { away.refresh() }
    }

    /// Reconcile existing background choices; setup alone never enables a new background item.
    private func applyBackgroundDefaults() {
        if let problem = background.applyDefaults(setupComplete: true) { events.record(.error, problem) }
        refreshBackgroundStates()
        updateHangWatchdog(curtainUp: curtain.phase != .down)
    }

    // MARK: Watchdog and recovery

    private func startWatchdog() {
        let hang = HostHangWatchdog.retainingUnconfirmedCover(onHang: watchdog.map {
            HostWatchdogReporter.hangHandler(files: $0.files, launchID: $0.record.launchID, bootSession: $0.record.bootSession)
        } ?? { _ in _exit(3) })
        hang.update(curtainUp: false, recoveryEnabled: recoveryHelperRunning)
        hangWatchdog = hang
        hang.start()
        guard let watchdog else {
            events.record(.launch, "Launched; watchdog state unavailable")
            return
        }
        watchdog.start()
        let assessment = watchdog.assessment
        recoveryNoticePending = assessment.recoveredFromUnexpectedExit
        if assessment.recoveredFromUnexpectedExit {
            events.record(.recovery, "Restarted after the previous run ended unexpectedly (\(assessment.previousExit?.rawValue ?? "unknown"))")
        } else {
            events.record(.launch, "Launched")
        }
        if assessment.safeMode {
            crashLoopStopped = true
            autoStart.suspend()
            detail = Self.crashLoopDetail
            events.record(.recovery, "Stopped after repeated crashes; sharing paused until resumed")
        }
    }

    /// Ending a stalled host only helps when the helper is registered to reopen it.
    private var recoveryHelperRunning: Bool { background.recoveryWanted && background.recoveryState == .on }

    // A display left on a Big Text mode reverts only when this process exits, so a hang while it is
    // engaged gets the curtain's short threshold (HangWatchdogPolicy treats both alike).
    private func updateHangWatchdog(curtainUp: Bool) {
        hangWatchdog?.update(curtainUp: curtainUp, recoveryEnabled: recoveryHelperRunning,
                             bigTextEngaged: bigText.isEngaged, displayChanging: bigText.isChanging)
    }

    private static let crashLoopDetail = "Farside stopped after repeated crashes. Sharing is paused until you resume it."
    /// A recovery notice is still worth telling a phone that connects within this window.
    private static let recoveryNoticeLifetime: TimeInterval = 60 * 60

    private var recoveryEventForPhone: String? {
        guard recoveryNoticePending,
              Date().timeIntervalSince(watchdog?.launchedAt ?? .distantPast) < Self.recoveryNoticeLifetime
        else { return nil }
        return HostLifecycleEvent.recovered.rawValue
    }

    // MARK: Away mode

    @Published private(set) var awayModeEnabled: Bool
    @Published private(set) var awayIntroShown: Bool
    @Published private(set) var lockWarning: HostLockWarning?
    private var lockWarnings = HostLockWarningTracker()
    private let awayAvailable = AwayModeGate.isEnabled()
    private lazy var away: AwayModeController = AwayModeController(dependencies: .init(
        locker: RemoteHostModel.makeAwayLocker(),
        power: SystemPowerSource(),
        isManaged: { ManagedLockPolicy.isManaged() },
        inputMonitor: SystemAwayInputMonitor(),
        ticker: TimerAwayTicker(),
        now: { ProcessInfo.processInfo.systemUptime },
        wallClock: { Date() }
    ))
    private var lastAwayPhase: AwayPhase = .off
    /// An Away cover that found no screen waits for the next Away change or display change,
    /// instead of retrying on every curtain reconcile.
    private var awayCoverRaiseFailed = false
    private var awayMarkerCommitted = false
    private var awayCoverWasWanted = false
    private var awayMarkerFailed = false
    private var awayExclusion = AwayExclusionState()
    private var awayPictureClear: Bool {
        !away.wantsCover || sessionState != .picture ||
            awayExclusion.matches(windowIDs: curtain.windowIDs, captureAttempt: captureAttempt)
    }

    private static func makeAwayLocker() -> HostScreenLocking {
        #if DEBUG
        if HostE2E.active != nil { return InertAwayLocker() }
        #endif
        return SystemScreenLocker()
    }

    /// Runs straight after the watchdog, before anything can refresh Away mode, so a relaunch
    /// after a crash under the cover locks while covered. Fails closed even if the gate is now off.
    private func startAwayMode() {
        away.host = self
        curtain.onScreensChanged = { [weak self] in
            self?.away.end(.screensChanged)
            self?.excludeCoverFromCapture()
        }
        if watchdog?.assessment.lockFirst == true {
            events.record(.recovery, "Locking after an unexpected exit while Away mode covered the screen")
            away.lockFirstAfterRelaunch()
        }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            let uptime = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { self?.lockWarnings.screenSaverStarted(uptime: uptime) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockWarnings.screenSaverStopped() }
        })
        away.refresh()
    }

    func setAwayMode(_ enabled: Bool) {
        guard !enabled || awayAvailable else { return }
        if enabled { awayMarkerFailed = false }
        awayModeEnabled = enabled
        preferences.awayMode = enabled
        if enabled {
            awayIntroShown = true
            preferences.awayIntroShown = true
        } else {
            away.turnOffAtMac()
        }
        events.record(.settings, "Away mode \(enabled ? "on" : "off")")
        away.refresh()
    }

    func coverNow() {
        away.coverNow()
    }

    func dismissLockWarning() {
        lockWarning = nil
    }

    func openLockScreenSettings() {
        NSWorkspace.shared.open(HostAwayCopy.lockScreenSettingsURL)
    }

    func awayConditions() -> AwayConditions {
        AwayConditions(enabled: awayAvailable && awayModeEnabled,
                       sharingWanted: wantsSharing,
                       sharingActive: active && !captureScopeViewOnly && sessionState == .picture,
                       accessibility: inputAccess.accessibility.isGranted && inputAccess.postEvents.isGranted,
                       screenLocked: screenLocked,
                       phoneConnected: connection.connected && !phonePause.isPaused,
                       safeMode: crashLoopStopped || captureScopeNeedsSelection || captureScopeViewOnly,
                       recoveryRunning: recoveryHelperRunning && watchdog != nil, recoveryRecordReady: !awayMarkerFailed)
    }

    func awayStateChanged() {
        reconcileAutomaticClipboard()
        // Every new cover needs a fresh atomic write, even if an earlier marker clear failed.
        let isNewCover = away.wantsCover && !awayCoverWasWanted
        awayCoverWasWanted = away.wantsCover
        if away.wantsCover && (isNewCover || !awayMarkerCommitted) {
            guard watchdog?.setAwayCoverUp(true) == true else {
                awayMarkerFailed = true
                awayRecord("Cover refused: recovery record could not be saved")
                away.refuseUncommittedCover()
                return
            }
            awayMarkerCommitted = true
        } else if !away.wantsCover && awayMarkerCommitted {
            // Only positive lock verification or an uncovered disarm can retire this marker.
            if watchdog?.setAwayCoverUp(false) == true { awayMarkerCommitted = false }
        }
        awayCoverRaiseFailed = false
        if away.machine.phase != lastAwayPhase {
            lastAwayPhase = away.machine.phase
            awayRecord(Self.awayPhaseDescription(lastAwayPhase))
        }
        if !awayPictureClear || away.isLocking {
            input.withAuthority {
                input.enabled = false
                input.invalidateQueued(); inputFreshness.expireTokens()
                releaseRemoteInput(notifyPhone: false)
            }
        }
        reconcileCurtain()
        updatePowerAssertions()
        sendCaptureHealth(sessionHealthy)
        objectWillChange.send()
    }

    /// Synchronous final authority fence precedes the platform shortcut, including local input.
    func awayWillRequestLock() {
        input.withAuthority {
            input.enabled = false
            input.invalidateQueued(); inputFreshness.expireTokens()
            releaseRemoteInput(notifyPhone: false)
        }
        if input.held { connection.dropPeerSession() }
        guests.endAll(); browserSession.stop()
        invalidateTextFocus(); clipboard.reset(); fileTransfer.reset()
        connection.media?.setSystemAudioEnabled(false); capture.setSystemAudioEnabled(false)
        sendCaptureHealth(false)
    }

    func awayRecord(_ message: String) {
        events.record(.curtain, "Away mode: " + message)
    }

    private static func awayPhaseDescription(_ phase: AwayPhase) -> String {
        switch phase {
        case .off: "off"
        case .armedPresent: "armed"
        case .armedCovered: "covered"
        case .locking(let reason): "locking (\(reason.rawValue))"
        case .lockFailed(let reason): "lock not confirmed (\(reason.rawValue)); cover kept"
        }
    }

    private var awayLockFailed: Bool {
        if case .lockFailed = away.machine.phase { return true }
        return false
    }

    private var awayCoverRetryHeld: Bool { away.wantsCover && awayCoverRaiseFailed }

    /// The curtain's controller keeps these between raises, so every reconcile sets them again.
    private func applyAwayCurtainSettings() {
        let covering = away.wantsCover && awayMarkerCommitted
        curtain.escapeLiftEnabled = !covering
        curtain.liftsOnScreenChange = !covering
        let style: PrivacyCurtainStyle = covering ? (awayLockFailed ? .awayLockFailed : .away) : .sharing
        if curtain.style != style { curtain.setStyle(style) }
    }

    /// The Away cover never waits on the stream and a lost stream never undoes it; while a phone
    /// is watching, the cover is still kept out of its picture where capture allows.
    private var awayCoverHooks: PrivacyCurtainController.CaptureHooks {
        PrivacyCurtainController.CaptureHooks(
            exclude: { [weak self] ids in await self?.excludeAwayCover(ids) ?? true },
            signature: { nil }
        )
    }

    private func excludeAwayCover(_ ids: Set<CGWindowID>) async -> Bool {
        guard active, connection.connected, !terminating else { return false }
        let attempt = captureAttempt, peer = connection.media, generation = awayExclusion.generation
        let excluded = await capture.excludeWindows(ids)
        guard attempt == captureAttempt, connection.media === peer, ids == curtain.windowIDs else { return false }
        guard awayExclusion.confirm(excluded ? AwayExclusionReceipt(windowIDs: ids, captureAttempt: attempt) : nil,
                                    generation: generation) else { return false }
        if !excluded && away.wantsCover {
            // The cover stays opaque; conceal the remote picture instead of promising exclusion.
            captureHealthChanged(false)
            sendCaptureHealth(false)
        }
        applyControlState(notifyPhone: true)
        return excluded
    }

    /// A phone that connects while the Mac is covered sees the desktop, not the cover.
    private func excludeCoverFromCapture() {
        guard curtain.phase != .down else { return }
        let ids = curtain.windowIDs
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.away.wantsCover { _ = await self.excludeAwayCover(ids) }
            else { _ = await self.capture.excludeWindows(ids) }
        }
    }

    private func awayScreensChanged() {
        guard awayCoverRaiseFailed else { return }
        awayCoverRaiseFailed = false
        reconcileCurtain()
    }

    private func receiveLockMac(current: Bool, controlEffective: Bool) {
        // Locking the Mac needs the same authority as covering or controlling it.
        guard awayAvailable, current, controlEffective, !phonePause.isPaused, !liveViewOnly,
              !captureScopeViewOnly, !ManagedLockPolicy.isManaged(),
              advertisedFeatures.contains(SessionFeature.away),
              connection.presentationDeadline(at: ProcessInfo.processInfo.systemUptime) != nil else {
            sendCaptureHealth(sessionHealthy)
            return
        }
        events.record(.curtain, "Phone asked to lock this Mac")
        away.end(.phoneRequest)
    }

    /// Classified before Away mode refreshes, which forgets that Farside asked for the lock.
    private func noteUnexpectedLock() {
        guard let warning = lockWarnings.screenLocked(
            at: Date(), uptime: ProcessInfo.processInfo.systemUptime,
            sharingWanted: wantsSharing, awayArmed: away.machine.isArmed,
            lockRequestedByFarside: away.lockRequestedByFarside,
            idleSeconds: HostIdle.systemIdleSeconds()
        ) else { return }
        lockWarning = warning
        switch warning {
        case .lockedWhileSharing:
            events.record(.availability, "This Mac locked while sharing without anyone choosing to lock it")
        case .screenSaverLocked(_, let awayArmed):
            events.record(.availability, "The screen saver locked this Mac while sharing\(awayArmed ? " with Away mode on" : "")")
        }
    }

    // MARK: Privacy curtain

    private func reconcileCurtain() {
        applyAwayCurtainSettings()
        let now = ProcessInfo.processInfo.systemUptime
        let inputs = PrivacyCurtainInputs(
            preference: !captureScopeViewOnly && curtainPreference,
            sessionLive: active && connection.connected && !terminating,
            captureHealthy: captureHealthy,
            unhealthyFor: captureUnhealthySince.map { now - $0 } ?? 0,
            displayAsleep: displayAsleep,
            phonePaused: phonePause.isPaused,
            screenLocked: screenLocked,
            accessibilityGranted: inputAccess.accessibility.isGranted,
            locallyDismissed: curtainLocallyDismissed,
            raiseFailed: curtainRaiseFailed,
            safeMode: crashLoopStopped,
            displayReconfiguring: bigText.isChanging || bigTextResuming || bigTextNeedsRefresh || virtualDisplayChanging,
            awayCovered: away.wantsCover && awayMarkerCommitted
        )
        switch PrivacyCurtainPolicy.desired(inputs, currentlyUp: curtain.phase != .down) {
        case .up where curtain.phase == .down && !curtainRaising && !awayCoverRetryHeld:
            raiseCurtain()
        case .down where curtain.phase != .down:
            curtain.lift()
        default:
            break
        }
        let covering = curtain.phase != .down
        watchdog?.setCurtainUp(covering)
        updateHangWatchdog(curtainUp: covering)
        let state = PrivacyCurtainPolicy.protocolState(inputs, up: curtain.phase == .up)
        if state != curtainState {
            curtainState = state
            sendCaptureHealth(sessionHealthy)
        }
    }

    private func raiseCurtain() {
        curtainRaising = true
        let raisingAway = away.wantsCover && awayMarkerCommitted
        let hooks = raisingAway ? awayCoverHooks : PrivacyCurtainController.CaptureHooks(
            exclude: { [weak self] ids in await self?.capture.excludeWindows(ids) ?? false },
            signature: { [weak self] in await self?.capture.lumaSignature() }
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.curtain.raise(hooks: hooks)
            self.curtainRaising = false
            switch result {
            case .raised:
                self.events.record(.curtain, "Curtain up on \(NSScreen.screens.count) display(s)")
            case .exclusionFailed, .verificationFailed, .noScreens:
                if raisingAway { self.awayCoverRaiseFailed = true } else { self.curtainRaiseFailed = true }
                self.events.record(.error, "Cover could not be prepared: \(result)")
            case .cancelled:
                break
            }
            self.reconcileCurtain()
        }
    }

    private func curtainLiftedLocally() {
        curtainLocallyDismissed = true
        events.record(.curtain, "Lifted at the Mac with Esc ×3")
    }

    /// Lifts synchronously; used where sharing ends, before anything else is torn down.
    private func liftCurtain() {
        if curtain.phase != .down && !away.wantsCover { curtain.lift() }
        let covered = curtain.phase != .down
        watchdog?.setCurtainUp(covered)
        updateHangWatchdog(curtainUp: covered)
    }

    private static func curtainStatus(_ state: PrivacyCurtainState, displays: Int) -> String? {
        switch state {
        case .off, .pending: nil
        case .up: "Covering \(displays == 1 ? "your display" : "\(displays) displays"). Your phone still sees the desktop."
        case .liftedLocally: "Lifted at this Mac for the current session."
        case .unavailable: "Needs Accessibility, so Esc can always lift it."
        case .failed: "Couldn’t confirm the phone’s picture stayed clear, so the screen stayed visible."
        }
    }

    private func start(display: SCDisplay) {
        guard !captureScopeNeedsSelection else { return }
        guard removalAllowsSharing else { return }
        releaseRemoteInput(notifyPhone: true)
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        input.enabled = false
        active = true
        listeningWithoutSharing = false
        detail = nil
        updatePowerAssertions()
        connection.start()
        reconcileStartResult()
    }

    func stop() {
        retireVirtualDisplay()
        guests.endAll()
        bigText.sessionEnded(.sessionEnded)
        liftCurtain()
        invalidateTextFocus()
        unavailabilityTeardown?.cancel(); unavailabilityTeardown = nil
        browserSession.stop()
        releaseRemoteInput(notifyPhone: true)
        sendCaptureHealth(false)
        active = false
        listeningWithoutSharing = false
        releaseKeepAwake()
        connection.stop()
        away.refresh()
    }

    func prepareForTermination(reply: @escaping (Bool) -> Void) -> Bool {
        guard virtualDisplayWasUsed else { return away.prepareForQuit(reply: reply) }
        virtualDisplayQuitPending = true
        retireVirtualDisplay()
        Task { [weak self] in
            guard let self else { reply(true); return }
            await self.virtualDisplayTask?.value
            if self.virtualWindows.hasPendingRestore || self.virtualDisplay.ownsScreenChanges {
                self.virtualDisplayQuitPending = false
                reply(false)
                return
            }
            if !self.away.prepareForQuit(reply: reply) { reply(true) }
        }
        return true
    }

    func stopForTermination() {
        guard !away.wantsCover else { return }
        guests.endAll()
        bigText.restoreForTermination()
        reconfigurationMonitor.stop()
        liftCurtain()
        #if DEBUG
        HostE2E.active?.terminating()
        #endif
        invalidateTextFocus()
        browserSession.stop()
        agentAlerts.shutDown()
        terminating = true
        permissionTimer?.invalidate()
        input.enabled = false
        releaseRemoteInputSynchronously()
        sendCaptureHealth(false)
        active = false
        releaseKeepAwake()
        connection.stop()
        // An intentional quit: the watchdog helper must not reopen Farside.
        watchdog?.markCleanExit()
    }

    // MARK: Permissions and displays

    /// Asks macOS for both input rights again. Called from timers and app activation only.
    @discardableResult
    private func refreshInputAccess() -> Bool {
        guard inputAccessCache.refresh() else { return false }
        inputAccess = inputAccessCache.current
        applyControlState(notifyPhone: true)
        sendCaptureHealth(sessionHealthy)
        return true
    }

    private func evaluateUpgradeRegrant() {
        let outcome = HostUpgradeRegrant.evaluate(
            record: preferences.osPermissionRecord,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            screenRecording: screenRecordingPermission.isGranted,
            control: controlPermission.isGranted
        )
        if outcome.record != preferences.osPermissionRecord { preferences.osPermissionRecord = outcome.record }
        if outcome.missing != permissionsTurnedOffByUpdate {
            if !outcome.missing.isEmpty { events.record(.settings, "macOS update turned off \(outcome.missing.map(\.rawValue))") }
            permissionsTurnedOffByUpdate = outcome.missing
        }
    }

    func setMenuBarIconShown(_ shown: Bool) {
        guard shown != menuBarIconShown else { return }
        menuBarIconShown = shown
        preferences.menuBarIconShown = shown
        events.record(.settings, shown ? "Menu bar icon shown" : "Menu bar icon hidden; Farside keeps running")
    }

    /// macOS stopped or declined the capture. The Mac stays registered and tells the phone why; it
    /// shares again only after a check finds capture allowed.
    private func captureNeedsApproval() {
        captureApproval.begin(at: ProcessInfo.processInfo.systemUptime)
        sendCaptureHealth(false)
        stop()
        pollPermissions()
        guard screenRecordingPermission.isGranted else {
            clearCaptureApproval()
            invalidateDisplays(status: .permissionDenied)
            return
        }
        detail = nil
        events.record(.sharing, "Screen recording needs approval on this Mac")
        reconcileSharing()
    }

    private func checkCaptureApproval() {
        guard captureApproval.isPending, captureApprovalCheck == nil else { return }
        guard screenRecordingPermission.isGranted, CaptureStopReason.systemAllowsCapture else {
            captureApproval.checkFailed(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        captureApprovalCheck = Task { [weak self] in
            // Listing shareable content fails with the same refusal while capture is not allowed, and
            // starts no capture and no recording indicator.
            let allowed = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
            guard let self else { return }
            self.captureApprovalCheck = nil
            guard self.captureApproval.isPending else { return }
            guard allowed else {
                self.captureApproval.checkFailed(at: ProcessInfo.processInfo.systemUptime)
                return
            }
            self.events.record(.sharing, "Screen recording allowed again; sharing resumes")
            self.clearCaptureApproval()
            self.loadDisplays()
        }
    }

    private func clearCaptureApproval() {
        captureApprovalCheck?.cancel()
        captureApprovalCheck = nil
        captureApproval.clear()
    }

    /// The ScreenCaptureKit code only; never a message that could name windows or content.
    private static func captureErrorCode(_ error: Error) -> String {
        if error is CaptureNotCapturingError { return "not capturing" }
        let error = error as NSError
        return error.domain == SCStreamErrorDomain ? "SCStreamError \(error.code)" : "other"
    }

    private func pollPermissions() {
        if serverRemovalReadFailed { loadPendingServerRemoval() }
        let screen: HostPermissionStatus = InputCadenceTrace.permission("screen", probe: CGPreflightScreenCaptureAccess) ? .granted : .denied
        let screenChanged = screen != screenRecordingPermission
        if screenChanged {
            screenRecordingPermission = screen
            if screen.isGranted {
                // A fresh grant is itself the approval macOS was waiting for.
                clearCaptureApproval()
                loadDisplays()
            } else {
                if sessionState == .couch {
                    let pictureRequested = pendingPictureRefresh != nil
                    cancelPictureRefresh()
                    invalidateDisplays(status: .permissionDenied)
                    if pictureRequested { pendingModeReason = .screenRecording }
                    sendCaptureHealth(sessionHealthy)
                } else {
                    stop()
                    invalidateDisplays(status: .permissionDenied)
                    reconcileSharing()
                }
            }
        }
        if refreshInputAccess() || screenChanged { evaluateUpgradeRegrant() }
        if captureApproval.isDue(at: ProcessInfo.processInfo.systemUptime) { checkCaptureApproval() }
        if let pairingExpires, !pairingExpired, !pairingCode.isEmpty, pairingExpires <= Date() {
            pairingExpired = true
        }
        let locked = HostScreenLock.isLocked()
        if locked != screenLocked { handleAvailability(locked ? .screenLocked : .screenUnlocked) }
        let setupComplete = setupStep == .done
        if setupComplete && !setupWasComplete { applyBackgroundDefaults() }
        setupWasComplete = setupComplete
    }

    func loadDisplays() {
        guard CouchCatalogRefresh.allowed(active: active, session: sessionState,
                                           browserRunning: browserSession.controller.running) else { return }
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        let previousSelection = selected
        let generation = displayRefreshGeneration.begin()
        displayRefreshStatus = .checking

        guard CGPreflightScreenCaptureAccess() else {
            screenRecordingPermission = .denied
            invalidateDisplays(status: .permissionDenied)
            if sessionState == .couch {
                finishPictureRefresh()
            } else {
                reconcileSharing()
            }
            return
        }

        displayRefreshTask = Task { [weak self] in
            guard let self else { return }
            let enumeration: HostDisplayEnumeration<SCDisplay>
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                enumeration = .success(content.displays)
            } catch {
                enumeration = .failure
            }

            guard !Task.isCancelled, self.displayRefreshGeneration.accepts(generation) else { return }
            let result = HostPermissionRefreshResult.resolve(
                screenRecordingGranted: CGPreflightScreenCaptureAccess(),
                accessibilityGranted: self.controlPermission.isGranted,
                displayEnumeration: enumeration
            )
            guard CouchCatalogRefresh.allowed(active: self.active, session: self.sessionState,
                                               browserRunning: self.browserSession.controller.running) else {
                self.displayRefreshTask = nil
                return
            }
            self.applyPermissionRefresh(result, previousSelection: previousSelection)
            self.displayRefreshTask = nil
            if self.sessionState == .couch {
                self.finishPictureRefresh()
            } else {
                self.reconcileSharing()
            }
        }
    }

    private func applyPermissionRefresh(
        _ result: HostPermissionRefreshResult<SCDisplay>,
        previousSelection: CGDirectDisplayID
    ) {
        screenRecordingPermission = result.screenRecording
        refreshInputAccess()
        displays = result.displays
        displaysStaleFromCouch = false
        displayRefreshStatus = result.displayStatus
        selected = HostDisplayChoice.preferred(
            available: displays.map(\.displayID),
            previous: previousSelection,
            main: CGMainDisplayID()
        )
        switch result.displayStatus {
        case .unavailable:
            detail = "macOS reported no display to share. Check the display connection."
        case .failed:
            detail = "Farside couldn’t list this Mac’s displays. Try again."
        default:
            break
        }
    }

    private func invalidateDisplays(status: HostDisplayRefreshStatus) {
        displaySnapshotGeneration &+= 1
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        displayRefreshGeneration.invalidate()
        displays = []
        displaysStaleFromCouch = false
        selected = 0
        displayRefreshStatus = status
    }

    private func validatedSelectedDisplay() -> SCDisplay? {
        guard CGPreflightScreenCaptureAccess() else {
            screenRecordingPermission = .denied
            invalidateDisplays(status: .permissionDenied)
            return nil
        }
        guard displayRefreshStatus == .ready else { return nil }
        return displays.first(where: { $0.displayID == selected })
    }

    private static func displayName(for id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }

    // MARK: Control

    private func applyControlState(notifyPhone: Bool) {
        let effective = sessionControlAllowed && controlPermission.isGranted
        if !effective || !inputAccess.accessibility.isGranted { invalidateTextFocus() }
        if sessionState == .couch { refreshCouchHealth() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: sessionControlAllowed,
            accessibilityPermission: controlPermission,
            session: sessionState,
            captureHealthy: captureHealthy,
            couchHealthy: couchHealthy
        )
        if !effective {
            releaseRemoteInput(notifyPhone: notifyPhone)
            clipboard.reset()
            fileTransfer.revoke()
        }
        reconcileAutomaticClipboard()
        if notifyPhone, connection.connected {
            _ = connection.sendControl(RemoteAction(action: "viewing", x: effective ? 1 : 0, epoch: inputEpoch.value))
        }
        reconcileCurtain()
        away.refresh()
    }

    // MARK: Capture session

    private func beginCapture(keepingExclusions: Bool = false) {
        if virtualDisplayRetirementPending && virtualDisplayTask == nil {
            detail = "Restoring the phone workspace before sharing again."
            return
        }
        if virtualDisplayChanging, let pending = virtualDisplayTask {
            let peer = connection.media
            let attempt = captureAttempt
            Task { [weak self] in
                await pending.value
                guard let self, self.connection.media === peer, self.connection.connected, self.active,
                      self.captureAttempt == attempt,
                      !self.virtualDisplayWasUsed || self.usesVirtualDisplay,
                      !self.phonePause.isPaused, !self.terminating else { return }
                self.beginCapture(keepingExclusions: keepingExclusions)
            }
            return
        }
        if usesVirtualDisplay && !virtualDisplaySourceResumable {
            virtualDisplayFallback()
            return
        }
        guard !captureScopeNeedsSelection else { stop(); return }
        guard CGPreflightScreenCaptureAccess() else {
            screenRecordingPermission = .denied
            stop()
            invalidateDisplays(status: .permissionDenied)
            return
        }
        guard CaptureStopReason.systemAllowsCapture else {
            captureNeedsApproval()
            return
        }
        if displaysStaleFromCouch { restartForDisplaysChangedInCouch(); return }
        guard let display = virtualDisplaySource ?? displays.first(where: { $0.displayID == selected }), let peer = connection.media else { stop(); return }
        if HostScreenLock.isLocked() { handleAvailability(.screenLocked); return }
        peer.requestRefinementCapture(refinementNegotiated && !away.isLocking)
        peer.setSystemAudioEnabled(systemAudioAllowedNow)
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
            sessionsThisLaunch += 1
            events.record(.session, "Phone connected")
        }
        captureUnhealthySince = nil
        peer.onSenderStatistics = { [weak self, weak peer] report in
            guard let self, let peer, self.connection.media === peer else { return }
            self.diagnosticRecorder.observe(report, at: ProcessInfo.processInfo.systemUptime)
            self.latestSenderStatistics = report
            self.observeLoad(report, peer: peer)
        }
        #if DEBUG
        if let e2e = HostE2E.active {
            peer.onStreamStatistics = { [weak e2e] report in e2e?.recordStats(report) }
            e2e.event("capture.begin", ["display": display.frame, "displayID": display.displayID])
        }
        #endif
        wakeDisplayForRemoteSession()
        updatePowerAssertions()
        captureAttempt &+= 1
        if captureAttempt == 0 { captureAttempt = 1 }
        let attempt = captureAttempt
        phonePause.clear()
        acceptedPhonePauseEpoch = nil
        capturedDisplayID = display.displayID
        pointerLocator.reset()
        captureTask?.cancel()
        releaseRemoteInput(notifyPhone: true)
        sessionState = .picture
        couchHealthy = false
        input.changeLeaseDuration(to: RemoteInputLease.pictureDuration, at: ProcessInfo.processInfo.systemUptime)
        couchHUD.hide()
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        captureHealthy = false
        input.enabled = false
        advanceEpoch()
        pointerTelemetry.begin(displayFrame: display.frame, epoch: inputEpoch.value)

        startLifecycleTimer()

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.captureStartIsCurrent(attempt, peer: peer), !Task.isCancelled else { return }
                let owner = try await self.capture.start(display: display, peer: peer,
                    keepingExclusions: !self.captureScopeViewOnly && keepingExclusions, target: self.captureScopeTarget,
                    virtualDisplay: self.usesVirtualDisplay ? self.virtualDisplay.specification : nil,
                    beforeStart: { [weak self] geometry in
                        guard let self else { return false }
                        let preflight = [
                            RemoteAction(action: "geometry", x: geometry.size.width, y: geometry.size.height, epoch: self.inputEpoch.value,
                                virtualDisplayResizeToken: self.currentVirtualDisplayResizeToken(peer: peer)),
                            RemoteAction(action: "viewing", x: self.sessionControlAllowed && self.controlPermission.isGranted ? 1 : 0, epoch: self.inputEpoch.value),
                            RemoteAction(action: "capture", x: 0, epoch: self.inputEpoch.value,
                                virtualDisplayResizeToken: self.currentVirtualDisplayResizeToken(peer: peer), captureScope: self.captureScopeStatus)
                        ]
                        return CaptureStartPreflight.send(preflight,
                            whileCurrent: { [weak self] in self?.captureStartIsCurrent(attempt, peer: peer) == true },
                            using: { [weak self] action in self?.connection.sendControl(action) == true })
                    })
                guard self.captureStartIsCurrent(attempt, peer: peer), !Task.isCancelled else {
                    _ = self.capture.stop(ifOwnedBy: owner)
                    return
                }
                if !self.captureScopeViewOnly && !self.usesVirtualDisplay {
                    if self.virtualDisplayEnabled && !self.virtualDisplayBlocked {
                        self.waitForVirtualDisplayViewport()
                    } else { self.bigText.sessionResumed() }
                }
                // A successful stream owns the actual successor epoch. The phone independently
                // releases its frozen pixels only after that tagged source physically presents.
                self.clearVirtualDisplayResizeHold()
                self.excludeCoverFromCapture()
                self.away.refresh()
                self.beginLoadMonitor(peer: peer)
            } catch is CancellationError {
                return
            } catch {
                guard self.captureAttempt == attempt else { return }
                if error is HostCaptureScopeError, self.captureScopeViewOnly { self.captureScopeLost(); return }
                self.events.record(.error, "Capture could not start (\(Self.captureErrorCode(error)))")
                if CaptureStopReason.classify(error) == .needsApproval {
                    self.captureNeedsApproval()
                    return
                }
                if self.virtualDisplayWasUsed && !self.virtualDisplayRetirementPending {
                    self.virtualDisplayFallback()
                    return
                }
                self.stop()
                self.autoStart.suspend()
                self.detail = "Screen sharing couldn’t start. Try again."
            }
        }
    }

    /// What a display change does to a Picture session today, deferred until the picture is wanted.
    private func restartForDisplaysChangedInCouch() {
        events.record(.sharing, "Displays changed during Couch mode; restarting sharing before showing the picture")
        stop()
        invalidateDisplays(status: .notChecked)
        loadDisplays()
    }

    private func startLifecycleTimer() {
        lifecycleTimer?.invalidate()
        // Idle checks are one second apart; refresh before enabling an active session so the
        // posting queue never starts with an expired observation from the idle interval.
        refreshInputAccess()
        let lifecycleTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconcileAXPrewarm()
                self.reconcileAutomaticClipboard()
                if self.phonePause.isPaused {
                    if self.phonePause.isExpired(at: ProcessInfo.processInfo.systemUptime) { self.expirePhonePause() }
                    return
                }
                self.input.expireMomentum()
                if self.input.leaseExpired(at: ProcessInfo.processInfo.systemUptime) {
                    let releasedHold = self.input.externalHoldID
                    let releaseEpoch = self.inputEpoch.value
                    if !self.input.held || self.input.release() {
                        self.input.cancelLease()
                        self.sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch)
                    }
                }
                if self.sessionState == .couch { self.refreshCouchHealth() }
                self.sendCaptureHealth(self.sessionHealthy)
                self.refreshInputAccess()
                self.reconcileCurtain()
            }
        }
        self.lifecycleTimer = lifecycleTimer
        RunLoop.main.add(lifecycleTimer, forMode: .common)
    }

    /// No screen capture, encoder, load monitor, viewport, cursor hiding or curtain: the person watches the Mac itself.
    private func beginCouch(restoringBigText: Bool = true) {
        if virtualDisplayWasUsed {
            retireVirtualDisplay(resume: .couch)
            return
        }
        if restoringBigText { bigText.sessionEnded(.restoreButton) }
        cancelPictureRefresh()
        guard connection.connected, connection.media != nil else { stop(); return }
        if HostScreenLock.isLocked() { handleAvailability(.screenLocked); return }
        active = true
        listeningWithoutSharing = false
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
            sessionsThisLaunch += 1
            events.record(.session, "Phone connected in Couch mode")
        }
        refusalTeardown?.cancel(); refusalTeardown = nil
        liftCurtain()
        wakeDisplayForRemoteSession()
        updatePowerAssertions()
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
        guests.endAll()
        _ = capture.stop()
        phonePause.clear()
        acceptedPhonePauseEpoch = nil
        capturedDisplayID = nil
        pointerLocator.reset()
        releaseRemoteInput(notifyPhone: true)
        let rects = HostCouchDisplays.current()
        guard let main = rects.first else { stop(); return }
        input.configure(displays: rects)
        input.changeLeaseDuration(to: RemoteInputLease.couchDuration, at: ProcessInfo.processInfo.systemUptime)
        captureHealthy = false
        couchHealthy = false
        input.enabled = false
        sessionState = .couch
        advanceEpoch()
        pointerTelemetry.begin(displayFrame: main, epoch: inputEpoch.value)
        startLifecycleTimer()
        _ = connection.sendControl(RemoteAction(action: "geometry", x: main.width, y: main.height, epoch: inputEpoch.value))
        _ = connection.sendControl(RemoteAction(action: "viewing", x: sessionControlAllowed && controlPermission.isGranted ? 1 : 0,
                                                epoch: inputEpoch.value))
        refreshCouchHealth()
        sendCaptureHealth(couchHealthy)
        couchHUD.show()
        #if DEBUG
        HostE2E.active?.event("couch.begin", ["displays": rects.count])
        #endif
    }

    /// The phone hears why on one `capture` status, then the peer session ends; the host keeps listening.
    private func beginRefused(_ reason: SessionModeRefusal) {
        sessionState = .refused(reason)
        advanceEpoch()
        input.enabled = false
        sendCaptureHealth(false)
        events.record(.session, "Couch mode refused: \(reason.rawValue)")
        #if DEBUG
        HostE2E.active?.event("couch.refused", ["reason": reason.rawValue])
        #endif
        refusalTeardown?.cancel()
        refusalTeardown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.sessionRefused else { return }
            self.connection.dropPeerSession()
        }
    }

    private var couchAdmissionInputs: CouchAdmissionInputs {
        CouchAdmissionInputs(routeLocal: connection.routeIsLocal, provenLinkActive: connection.provenLocalLinkActive,
                             allowControl: sessionControlAllowed, accessibility: controlPermission)
    }

    private var couchHealthInputs: CouchHealthInputs {
        let now = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        let defaults = HostE2E.active?.defaults ?? .standard
        #else
        let defaults = UserDefaults.standard
        #endif
        let session = couchSessionSnapshot.snapshot(
            at: now,
            cacheEnabled: !defaults.bool(forKey: CouchSessionSnapshotCache.disabledDefaultsKey),
            query: { CGSessionCopyCurrentDictionary() as? [String: Any] })
        return CouchHealthInputs(
            routeLocal: connection.routeIsLocal, provenLinkActive: connection.provenLocalLinkActive,
            heartbeatAge: lastPhoneHeartbeatAt.map { now - $0 },
            screenLocked: screenLocked || session.screenLocked, consoleUserActive: session.consoleUserActive,
            allowControl: sessionControlAllowed, accessibility: controlPermission, phonePaused: phonePause.isPaused)
    }

    /// Returns the fresh value; on a healthy → unhealthy edge input stops and tokens expire at once.
    @discardableResult
    private func refreshCouchHealth() -> Bool {
        guard sessionState == .couch else { couchHealthy = false; return false }
        // A pending sleep/lock/user-switch teardown must not be re-admitted by the next tick before it stops the session.
        let healthy = unavailabilityTeardown == nil && !bigTextHandlingScreenChanges && CouchHealth.isHealthy(couchHealthInputs)
        if couchHealthy && !healthy {
            invalidateTextFocus()
            releaseRemoteInput(notifyPhone: true)
            input.invalidateQueued(); inputFreshness.expireTokens()
        }
        couchHealthy = healthy
        input.enabled = HostControlPolicy.isEnabled(userConsent: sessionControlAllowed, accessibilityPermission: controlPermission,
                                                    session: sessionState, captureHealthy: captureHealthy, couchHealthy: healthy)
        reconcileAutomaticClipboard()
        return healthy
    }

    private static func consoleUserActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? false
    }

    private func endCapture() {
        away.refresh()
        axPrewarmEdge = HostAXPrewarmEdge()
        HostTextFocusChanges.shared.setSessionActive(false)
        let generation = axSessionGeneration, ended = generation.current
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        Task.detached(priority: .utility) {
            _ = await HostAXWebPrewarm().sessionEnded(voiceOverOn: voiceOver,
                                                      stillCurrent: { generation.current == ended })
        }
        if diagnosticRecorder.samples > 0 {
            try? diagnosticStore.save(diagnosticRecorder.finish(at: ProcessInfo.processInfo.systemUptime, additional: [
                .init(.hostScreenRecording, CGPreflightScreenCaptureAccess() ? 1 : 0),
                .init(.hostPostEvents, CGPreflightPostEventAccess() ? 1 : 0),
                .init(.hostAccessibility, inputAccess.accessibility.isGranted ? 1 : 0)]))
            diagnosticReports = diagnosticStore.load()
        }
        diagnosticRecorder = DiagnosticSessionRecorder()
        cancelPictureRefresh()
        liftCurtain()
        curtainLocallyDismissed = false
        curtainRaiseFailed = false
        captureUnhealthySince = nil
        if let sessionStartedAt {
            lastSessionDuration = Date().timeIntervalSince(sessionStartedAt)
            events.record(.session, "Phone disconnected after \(HostDiagnosticsReport.duration(lastSessionDuration ?? 0))")
            self.sessionStartedAt = nil
        }
        activity.reset()
        if recoveryNoticeDelivered {
            recoveryNoticePending = false
            recoveryNoticeDelivered = false
        }
        #if DEBUG
        HostE2E.active?.event("capture.end")
        #endif
        invalidateTextFocus()
        phonePause.clear()
        acceptedPhonePauseEpoch = nil
        liveViewOnly = false
        clipboard.reset()
        fileTransfer.reset()
        releaseRemoteInput(notifyPhone: false)
        input.endCausalContext(); inputFreshness.invalidate()
        input.resetNativeSequence()
        lifecycleTimer?.invalidate(); lifecycleTimer = nil
        captureHealthy = false
        capturedDisplayID = nil
        pointerLocator.reset()
        pointerTelemetry.end()
        input.enabled = false
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
        guests.endAll()
        _ = capture.stop()
        couchHUD.hide()
        sessionState = .picture
        couchHealthy = false
        lastPhoneHeartbeatAt = nil
        pendingModeReason = nil
        refusalTeardown?.cancel(); refusalTeardown = nil
        updatePowerAssertions()
        reconcileCurtain()
    }

    private func captureFailed(_ error: Error) {
        if usesVirtualDisplay && CaptureStopReason.classify(error) != .needsApproval {
            virtualDisplayFallback()
            return
        }
        guests.endAll()
        if error is HostCaptureScopeError, captureScopeViewOnly { captureScopeLost(); return }
        #if DEBUG
        HostE2E.active?.event("capture.failed", ["screenRecording": CGPreflightScreenCaptureAccess()])
        #endif
        if CaptureStopReason.classify(error) == .needsApproval {
            events.record(.error, "Capture stopped by macOS (\(Self.captureErrorCode(error)))")
            captureNeedsApproval()
            return
        }
        stop()
        pollPermissions()
        if screenRecordingPermission.isGranted {
            autoStart.suspend()
            detail = "Screen sharing stopped unexpectedly. Try again."
            events.record(.error, "Capture stopped unexpectedly")
        } else {
            invalidateDisplays(status: .permissionDenied)
        }
    }

    private func countInput(_ key: String) {
        inputCounts[key, default: 0] += 1
        let count = inputCounts[key] ?? 0
        if InputLog.sampled(count) {
            InputLog.log.info("host input \(key, privacy: .public) count=\(count, privacy: .public)")
        }
    }

    private func receiveCausalInput(_ context: InputCausalEnvelope, semantic: RemoteAction?) {
        let arrivedMs = connection.currentControlArrivalMs
        guard connection.connected, active, context.epoch == inputEpoch.value, !sessionRefused, !phonePause.isPaused && !liveViewOnly,
              let peer = connection.media else {
            _ = connection.recoverCausalInput(context)
            if let semantic, semantic.action == "text" { sendTextResult(for: semantic.key, accepted: false) }
            return
        }
        if let semantic, semantic.action == "release" {
            input.withAuthority {
                let scope = input.releaseScope(for: semantic)
                let scopedIdleCleanup = scope == nil && semantic.epoch == inputEpoch.value && semantic.interaction?.version == 1
                if scopedIdleCleanup || inputFreshness.acceptsRelease(semantic, epoch: inputEpoch.value, activeHold: scope) {
                    releaseRemoteInput(notifyPhone: false)
                    input.discardCausalPrefix(context)
                    connection.acknowledgeCausalInput(context, applied: input.appliedOrdinal)
                } else { _ = connection.recoverCausalInput(context) }
            }
            return
        }
        guard (semantic?.pencil == nil && context.segments.allSatisfy({ $0.action.pencil == nil })) ||
            (sessionState == .picture && connection.peerFeatures.contains(SessionFeature.pencilInput)) else {
            _ = connection.recoverCausalInput(context)
            return
        }
        invalidateTextFocus()
        if sessionState == .couch { refreshCouchHealth() }
        input.enabled = HostControlPolicy.isEnabled(userConsent: sessionControlAllowed, accessibilityPermission: controlPermission,
                                                   session: sessionState, captureHealthy: captureHealthy, couchHealthy: couchHealthy)
        let steps = context.segments.map { segment in
            HostInputExecutor.Admitted(action: segment.action, upgraded: true,
                                       expires: inputFreshness.postingDeadline(for: segment.action, epoch: inputEpoch.value))
        }
        if sessionState == .couch, context.segments.contains(where: { $0.action.action == "moveTo" }) {
            _ = connection.recoverCausalInput(context)
            return
        }
        let admittedSemantic = semantic.map { action in
            HostInputExecutor.Admitted(action: action, upgraded: true,
                                       expires: inputFreshness.postingDeadline(for: action, epoch: inputEpoch.value))
        }
        let preparation = semantic.map { $0.action == "key" && $0.key == "c" && $0.modifiers == ["command"] } == true && input.enabled
            ? clipboard.prepareForCopyShortcut(automatic: automaticClipboardAllowed) : nil
        let accepted = input.post(owner: self, peer: peer, isLive: { $0.connection.media === $1 }, submit: { [input] authority, completion in
            input.submitCausal(context, steps: steps, semantic: admittedSemantic, preparation: preparation, traceArrivalMs: arrivedMs,
                               routeAuthority: authority, completion: completion)
        }, deliver: { (model: RemoteHostModel, receipt: HostInputExecutor.BatchReceipt) in
            guard model.input.currentGeneration == receipt.generation else { return }
            for (action, result) in receipt.results {
                model.pointerTelemetry.moveProcessed(action)
                model.finishInput(action, outcome: result.outcome, upgraded: true, now: ProcessInfo.processInfo.systemUptime,
                                  point: result.point, activeHold: result.externalHold, startedMs: result.startedMs,
                                  endedMs: result.endedMs, arrivedMs: arrivedMs)
            }
            if receipt.failed || receipt.intervention {
                if let semantic, semantic.action == "text" { model.sendTextResult(for: semantic.key, accepted: false) }
                _ = model.connection.recoverCausalInput(context)
            } else { model.connection.acknowledgeCausalInput(context, applied: receipt.applied) }
        })
        if !accepted {
            if let semantic, semantic.action == "text" { sendTextResult(for: semantic.key, accepted: false) }
            _ = connection.recoverCausalInput(context)
        }
    }

    private func receive(_ data: Data) {
        guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else {
            countInput("rejected-parse"); connection.endPhoneInputSession("Invalid phone input."); return
        }
        countInput("received")
        if action.action == "wakeRequest" { receiveWakeRequest(action); return }
        guard SharedCaptureScopePolicy.permits(action.action, kind: captureScopeKind) else {
            countInput("rejected-capture-scope"); return
        }
        guard action.pencil == nil || (sessionState == .picture && connection.peerFeatures.contains(SessionFeature.pencilInput)) else { return }
        if action.action == "release" || Self.userInputActions.contains(action.action) {
            invalidateTextFocus()
        }
        if action.action == "release" {
            input.withAuthority {
                if inputFreshness.acceptsRelease(action, epoch: inputEpoch.value, activeHold: input.releaseScope(for: action)) {
                    releaseRemoteInput(notifyPhone: false)
                }
            }
            return
        }
        if action.action == "heartbeat" {
            if usesPhoneAudioRequest, action.isRegularPhoneHeartbeat, action.epoch == inputEpoch.value, connection.connected, active, !sessionRefused {
                phoneAudioRequested = action.macAudioRequested == true && sessionState == .picture &&
                    !captureScopeViewOnly && !liveViewOnly && !away.isLocking && !phonePause.isPaused
                reconcileSystemAudio()
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, sessionHealthy,
               connection.peerFeatures.contains(SessionFeature.videoLTR), let feedback = action.videoFeedback {
                connection.media?.videoFeedback.receive(feedback, epoch: action.epoch)
            }
            lastPhoneHeartbeatAt = ProcessInfo.processInfo.systemUptime
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, let quality = action.streamQuality {
                capture.setQuality(quality)
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, let pixels = action.screenPixels {
                capture.setClientPixels(pixels)
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, action.isRegularPhoneHeartbeat {
                virtualDisplayResizeHoldSupported = action.virtualDisplayResizeHoldSupported == true
                    && action.virtualDisplayViewport != nil && action.virtualDisplayViewportUnavailable != true
                    && advertisedFeatures.contains(SessionFeature.virtualDisplay)
                if let viewport = action.virtualDisplayViewport { requestVirtualDisplay(viewport) }
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value,
               action.virtualDisplayViewportUnavailable == true && virtualDisplayWasUsed { virtualDisplayFallback() }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, !captureScopeViewOnly, !usesVirtualDisplay, StreamTuning.current.viewportCapture,
               ViewportCapturePolicy.describesViewport(action) {
                // A regular heartbeat without a viewport means the phone can no longer describe its
                // visible area. Return to the whole display instead of retaining an old crop.
                capture.setViewport(action.viewport)
                connection.media?.captureSharpness = capture.deliveredSharpness
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value {
                phoneLoad = action.phoneLoad
                phoneLoadReceivedAt = action.phoneLoad == nil ? nil : ProcessInfo.processInfo.systemUptime
            }
            if let probe = action.clock, !probe.isEcho, (try? probe.validate()) != nil {
                let received = min(MachClock.nowMs(), connection.media?.controlArrivalMs ?? .infinity)
                _ = connection.sendControl(RemoteAction(
                    action: "heartbeat", epoch: action.epoch,
                    clock: ClockProbe(phoneMs: probe.phoneMs, hostReceivedMs: received, hostSentMs: MachClock.nowMs())
                ))
            }
            if action.isRegularPhoneHeartbeat {
                pointerTelemetry.phoneHeartbeat(action.pointerSync, epoch: action.epoch,
                                                at: ProcessInfo.processInfo.systemUptime)
            }
            if !captureScopeViewOnly { receivePointerProbe(action) }
            return
        }
        if action.action == RemoteAction.modeAction {
            receiveModeRequest(action)
            return
        }
        if RemoteAction.sessionExtensionActions.contains(action.action) {
            receiveSessionExtension(action)
            return
        }
        if RemoteAction.displayActions.contains(action.action) {
            receiveDisplaySelection(action)
            return
        }
        if sessionRefused {
            countInput("rejected-refused")
            if action.action == "text" { sendTextResult(for: action.key, accepted: false) }
            return
        }

        pointerTelemetry.moveProcessed(action)
        guard Self.userInputActions.contains(action.action), inputEpoch.accepts(action) else {
            countInput(Self.userInputActions.contains(action.action) ? "rejected-epoch" : "rejected-unknown-action")
            if inputFreshness.upgraded || action.interaction != nil {
                releaseRemoteInput(notifyPhone: true)
                connection.endPhoneInputSession("The phone sent input from an old session. Reconnecting.")
            } else {
                releaseRemoteInput(notifyPhone: true)
            }
            if action.action == "text" { sendTextResult(for: action.key, accepted: false) }
            return
        }
        // The driver's bounds in Couch are the union of every display, so an absolute point has no safe meaning.
        if sessionState == .couch, action.action == "moveTo" {
            countInput("rejected-couch-moveTo")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let admission = inputFreshness.admit(action, epoch: inputEpoch.value, now: now)
        if admission == .terminate {
            countInput("rejected-freshness-terminate")
            releaseRemoteInput(notifyPhone: true)
            connection.endPhoneInputSession("The phone’s input session expired. Reconnecting.")
            return
        }
        if input.leaseExpired(at: now) {
            countInput("rejected-lease-expired")
            releaseRemoteInput(notifyPhone: true)
            if action.action == "text" { sendTextResult(for: action.key, accepted: false) }
            return
        }

        if sessionState == .couch { refreshCouchHealth() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: sessionControlAllowed,
            accessibilityPermission: controlPermission,
            session: sessionState,
            captureHealthy: captureHealthy,
            couchHealthy: couchHealthy
        )
        let arrivedMs = connection.currentControlArrivalMs
        let expires = inputFreshness.postingDeadline(for: action, epoch: inputEpoch.value)
        let admittedGeneration = input.currentGeneration
        #if DEBUG
        if let e2e = HostE2E.active {
            let outcome = input.withAuthority { () -> RemoteInputOutcome in
                let pointer = input.nextPointerBase(now: now)
                let (fenced, verdict) = e2e.fence(action, held: input.held, pointer: pointer)
                if action.action == "key", action.key == "c", action.modifiers == ["command"], input.enabled, fenced != nil {
                    clipboard.prepareForCopyShortcut()
                }
                let result = fenced.map { input.handle($0, upgraded: admission == .upgraded, now: now, pointerSnapshot: pointer) }
                    ?? RemoteInputOutcome(textRequestID: action.action == "text" ? action.key : nil)
                e2e.recordInput(action, accepted: result.accepted, fence: verdict, clickPoint: result.clickPoint)
                return result
            }
            finishInput(action, outcome: outcome, upgraded: admission == .upgraded, now: now,
                        point: input.lastPoint, activeHold: input.externalHoldID, startedMs: MachClock.nowMs(),
                        endedMs: MachClock.nowMs(), arrivedMs: arrivedMs)
            return
        }
        #endif
        guard let peer = connection.media else { return }
        let preparation = action.action == "key" && action.key == "c" && action.modifiers == ["command"] && input.enabled
            ? clipboard.prepareForCopyShortcut(automatic: automaticClipboardAllowed) : nil
        let submitted = input.post(owner: self, peer: peer, isLive: { $0.connection.media === $1 }, submit: { [input] authority, completion in
            input.submit(action, upgraded: admission == .upgraded, expires: expires, expectedGeneration: admittedGeneration,
                         preparation: preparation, routeAuthority: authority, completion: completion)
        }, deliver: { (model: RemoteHostModel, receipt: HostInputExecutor.Receipt) in
            guard model.input.accepts(receipt) else { return }
            model.finishInput(action, outcome: receipt.outcome, upgraded: admission == .upgraded,
                              now: ProcessInfo.processInfo.systemUptime, point: receipt.point,
                              activeHold: receipt.externalHold, startedMs: receipt.startedMs,
                              endedMs: receipt.endedMs, arrivedMs: arrivedMs)
        })
        if !submitted {
            releaseRemoteInput(notifyPhone: true)
            connection.endPhoneInputSession("Input queue was full. Reconnecting.")
        }
    }

    private func finishInput(_ action: RemoteAction, outcome: RemoteInputOutcome, upgraded: Bool,
                             now: TimeInterval, point: CGPoint, activeHold: String?, startedMs: Double,
                             endedMs: Double, arrivedMs: Double?) {
        connection.media?.counters.inputHandled(
            mainDelayMs: arrivedMs.map { max(0, startedMs - $0) },
            postMs: max(0, endedMs - startedMs))
        countInput(outcome.accepted ? "posted" : (input.enabled ? "refused-by-driver" : "refused-control-disabled"))
        if outcome.accepted { activity.record(action: action.action) }
        if let id = action.inputRequestID, InputAppliedReceipt.actions.contains(action.action),
           connection.peerFeatures.contains(SessionFeature.extendedFeatureList) {
            _ = connection.sendControl(RemoteAction(action: "inputApplied", epoch: inputEpoch.value,
                inputAppliedReceipt: InputAppliedReceipt(requestID: id, kind: action.action, accepted: outcome.accepted)))
        }
        if action.action == "move" || action.action == "moveTo", outcome.accepted {
            pointerTelemetry.moveInjected(globalPoint: point, at: now)
        }
        if upgraded, action.action == "dragDown", !outcome.accepted,
           let notice = inputFreshness.rejectedDragDownNotice(
                action, activeHold: activeHold
           ) {
            _ = connection.sendControl(notice)
        }
        if upgraded, outcome.accepted,
           (action.action == "click" || action.action == "double"),
           HostTextFocusProbe.isValidID(action.textFocusProbe),
           let probe = action.textFocusProbe, let point = outcome.clickPoint {
            scheduleTextFocusProbe(probe, point: point, geometry: action.textFocusGeometry == true,
                issuedAt: HostTextFocusTicket.postedAt(receivedAt: now, postingStartedMs: startedMs,
                                                       clockNowMs: MachClock.nowMs()))
        } else if upgraded, outcome.accepted, action.action == "text" || action.action == "key",
                  action.textFocusGeometry == true, HostTextFocusProbe.isValidID(action.textFocusProbe),
                  let probe = action.textFocusProbe {
            scheduleTextFocusProbe(probe, point: nil, geometry: true, issuedAt: now)
        }
        if action.action == "text" {
            sendTextResult(for: action.key, accepted: outcome.accepted)
        }
    }

    /// `point` nil re-checks the focus after typed text; only geometry is ever measured or sent.
    private func scheduleTextFocusProbe(_ probe: String, point: CGPoint?, geometry: Bool, issuedAt: TimeInterval) {
        let log = HostTextFocusLog.logger
        guard let peer = connection.media else {
            log.info("probe dropped reason=noPeer")
            return
        }
        let ticket = HostTextFocusTicket(epoch: inputEpoch.value,
                                         revision: textFocusRevision, issuedAt: issuedAt)
        let displayFrame = geometry ? input.displayBounds : nil
        log.info("probe scheduled click=\(point != nil, privacy: .public) geometry=\(displayFrame != nil, privacy: .public)")
        let tapFocus = point != nil && HostTextFocusTapPolicy.enabled
        textFocusTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(tapFocus ? 40 : 100)) } catch {
                log.info("probe dropped reason=cancelledBeforeQuery")
                return
            }
            guard let self else { return }
            guard self.textFocusIsCurrent(ticket, peer: peer), !Task.isCancelled else {
                log.info("probe dropped reason=staleBeforeQuery")
                return
            }
            var focus: HostTextFocusResult
            if tapFocus {
                let deadline = issuedAt + HostTextFocusTapPolicy.window
                focus = .unfocused
                while ProcessInfo.processInfo.systemUptime < deadline {
                    guard self.textFocusIsCurrent(ticket, peer: peer), !Task.isCancelled else { return }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0.005 else { break }
                    focus = await HostTextFocusProbe.focus(at: point, geometry: displayFrame != nil,
                        tapIssuedAt: issuedAt, tapFocus: true, budget: min(0.12, remaining))
                    let now = ProcessInfo.processInfo.systemUptime
                    focus.editable = HostTextFocusTapPolicy.shouldOpen(tapIssuedAt: issuedAt, now: now,
                        ax: { focus }, cursor: {
                            // Sample only when AX needs a fallback, at the admitted tap point.
                            guard let tap = point, let cursorPoint = CGEvent(source: nil)?.location,
                                  hypot(cursorPoint.x - tap.x, cursorPoint.y - tap.y) <= 2 else { return nil }
                            return self.textFocusCursor.actualSystemShape()
                        })
                    if focus.editable {
                        focus.editable = ProcessInfo.processInfo.systemUptime <= deadline
                        break
                    }
                    guard deadline - now > 0.025 else { break }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                }
            } else {
                focus = await HostTextFocusProbe.focus(at: point, geometry: displayFrame != nil,
                                                        tapFocus: HostTextFocusTapPolicy.enabled)
            }
            let secure = await HostSecureFocus.isSecureNow()
            guard !Task.isCancelled else {
                log.info("probe dropped reason=cancelledDuringQuery")
                return
            }
            guard self.textFocusIsCurrent(ticket, peer: peer) else {
                log.info("probe dropped reason=staleAfterQuery")
                return
            }
            guard displayFrame == nil || self.input.displayBounds == displayFrame else {
                log.info("probe dropped reason=displayChanged")
                return
            }
            let rect = focus.editable ? focus.frame.flatMap { field in
                displayFrame.flatMap { FocusGeometry.make(field: field, anchor: focus.anchor,
                                                          displayFrame: $0, geometrySize: $0.size) }
            } : nil
            log.info("probe answered editable=\(focus.editable, privacy: .public) role=\(focus.role.rawValue, privacy: .public) engine=\(focus.engine.rawValue, privacy: .public) activated=\(focus.activation?.attribute.rawValue ?? "none", privacy: .public) retried=\(focus.retried, privacy: .public) axDropped=\(focus.dropped, privacy: .public) secure=\(secure, privacy: .public) rect=\(rect != nil, privacy: .public)")
            _ = self.connection.sendControl(RemoteAction(
                action: "heartbeat", epoch: ticket.epoch,
                textFocusProbe: probe, textFocusEditable: focus.editable, textFocusSecure: secure, textFocusRect: rect
            ))
        }
    }

    /// A live session the phone controls: connected, not paused, not view-only, input enabled.
    private var axPrewarmSessionActive: Bool {
        active && !terminating && connection.connected && !phonePause.isPaused &&
            sessionControlAllowed && input.enabled && controlPermission.isGranted
    }

    private var automaticClipboardAllowed: Bool {
        if sessionState == .couch {
            // Cached Couch health handles lock/console/permission events. These cheap
            // use-time checks fence link loss and heartbeat expiry between lifecycle ticks.
            guard connection.routeIsLocal, connection.provenLocalLinkActive,
                  unavailabilityTeardown == nil, !bigTextHandlingScreenChanges,
                  let heartbeat = lastPhoneHeartbeatAt,
                  (0..<CouchHealth.heartbeatLimit).contains(ProcessInfo.processInfo.systemUptime - heartbeat)
            else { return false }
        }
        return active && !terminating && connection.connected && connection.media != nil &&
            !sessionRefused && sessionHealthy && input.enabled &&
            controlPermission.isGranted && sessionControlAllowed && !screenLocked &&
            !phonePause.isPaused && !liveViewOnly && !captureScopeViewOnly &&
            !captureScopeNeedsSelection && !away.wantsCover && !away.isLocking &&
            connection.peerFeatures.contains(SessionFeature.clipboardSync) &&
            !UserDefaults.standard.bool(forKey: "clipboardAutoSyncDisabled")
    }

    private func reconcileAutomaticClipboard() {
        clipboard.reconcileAutomaticSync(allowed: automaticClipboardAllowed,
            peerSupports: connection.peerFeatures.contains(SessionFeature.clipboardSync))
    }

    /// Checked on the 4 Hz lifecycle tick: when control becomes effective, ask the app already in front.
    private func reconcileAXPrewarm() {
        HostTextFocusChanges.shared.setSessionActive(axPrewarmSessionActive && HostTextFocusTapPolicy.enabled)
        guard axPrewarmEdge.update(active: axPrewarmSessionActive) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        Task.detached(priority: .utility) {
            let pid = front?.processIdentifier
            _ = await HostAXWebPrewarm(sessionIsCurrent: {
                (!HostTextFocusTapPolicy.enabled || HostTextFocusChanges.shared.sessionIsActive) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }).controlStarted(frontmost: front)
        }
    }

    private func prewarmAXTree(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let launched = app.launchDate?.timeIntervalSince1970
        let bundleURL = app.bundleURL
        let sessionActive = axPrewarmSessionActive
        Task.detached(priority: .utility) {
            _ = await HostAXWebPrewarm(sessionIsCurrent: {
                (!HostTextFocusTapPolicy.enabled || HostTextFocusChanges.shared.sessionIsActive) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }).appActivated(pid: pid, launched: launched, bundleURL: bundleURL, sessionActive: sessionActive)
        }
    }

    private func textFocusIsCurrent(_ ticket: HostTextFocusTicket, peer: PeerMedia) -> Bool {
        ticket.isCurrent(epoch: inputEpoch.value, revision: textFocusRevision,
                         now: ProcessInfo.processInfo.systemUptime,
                         active: active && !terminating,
                         connected: connection.connected && connection.media === peer,
                         controlEnabled: sessionControlAllowed && input.enabled && inputAccess.accessibility.isGranted,
                         captureHealthy: sessionHealthy)
    }

    private func invalidateTextFocus() {
        textFocusRevision &+= 1
        textFocusTask?.cancel()
        textFocusTask = nil
    }

    private func captureHealthChanged(_ healthy: Bool) {
        if !healthy { guests.endAll() }
        guard sessionState == .picture else { return }
        // The capture reports every 0.4 s; the 4 Hz lifecycle timer already re-checks Accessibility,
        // reconciles the curtain and sends capture status, so only a change needs handling here.
        if healthy == captureHealthy && (healthy || captureUnhealthySince != nil) { return }
        if captureHealthy && !healthy {
            invalidateTextFocus()
            releaseRemoteInput(notifyPhone: true)
            input.invalidateQueued(); inputFreshness.expireTokens()
        }
        if healthy {
            captureUnhealthySince = nil
        } else if captureUnhealthySince == nil {
            captureUnhealthySince = ProcessInfo.processInfo.systemUptime
        }
        captureHealthy = healthy
        defer { reconcileCurtain() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: sessionControlAllowed,
            accessibilityPermission: controlPermission,
            session: sessionState,
            captureHealthy: healthy,
            couchHealthy: couchHealthy
        )
        reconcileAutomaticClipboard()
        sendCaptureHealth(healthy)
    }

    private func receiveWakeRequest(_ action: RemoteAction) {
        guard (try? action.validate()) != nil, let request = action.wakeRequest,
              let invitation = connection.invitation, let helper = invitation.durableHostID,
              let grant = invitation.ownerPairID, let peer = connection.media,
              let deadline = connection.presentationDeadline(), hasPairedPhone else { return }
        let receivedAt = connection.controlArrivedAt ?? connection.currentControlArrivalMs.map { $0 / 1000 } ?? ProcessInfo.processInfo.systemUptime
        let authority = HostWakeAuthority(helperHostID: helper, ownerPairID: grant,
            sessionID: connection.presentationSessionID.uuidString, epoch: action.epoch, validUntil: deadline)
        let reply = lanWake.request(request, receivedAt: receivedAt, authority: authority) { [self] expected, operation in
            input.withAuthority {
                let now = ProcessInfo.processInfo.systemUptime
                guard connection.media === peer, connection.invitation == invitation, hasPairedPhone,
                      connection.connected, active, !sessionRefused, !liveViewOnly, !away.isLocking, !captureScopeViewOnly, !phonePause.isPaused,
                      expected.epoch == inputEpoch.value, expected.sessionID == connection.presentationSessionID.uuidString,
                      expected.valid(at: now), connection.presentationDeadline(at: now) != nil else { return .denied }
                return peer.withInputPostingAuthority { operation() } ?? .denied
            }
        }
        guard connection.media === peer, connection.invitation == invitation else { return }
        _ = connection.sendControl(RemoteAction(action: "wakeReply", epoch: action.epoch, wakeReply: reply))
    }

    private func receivePointerProbe(_ action: RemoteAction) {
        guard let probe = action.pointerProbe,
              (try? action.validate()) != nil,
              connection.connected, active, captureHealthy,
              action.epoch == inputEpoch.value,
              let display = virtualDisplaySource ?? displays.first(where: {
                  $0.displayID == selected && $0.displayID == capturedDisplayID
              }),
              pointerLocator.admit(at: ProcessInfo.processInfo.systemUptime)
        else { return }

        let location = (CGEvent(source: nil)?.location).flatMap {
            HostPointerLocator.location(for: $0, in: display.frame)
        }
        _ = connection.sendControl(RemoteAction(
            action: "heartbeat", epoch: action.epoch,
            pointerProbe: probe, pointerLocation: location
        ))
    }

    // MARK: Ladder and busy state (G12)

    private func beginLoadMonitor(peer: PeerMedia) {
        phoneLoad = nil
        phoneLoadReceivedAt = nil
        ladderState = nil
        busyState = nil
        let tuning = StreamTuning.current
        loadMonitor = tuning.ladder ? HostLoadMonitor(targetFPS: peer.targetFPS, senderQueueGovernor: tuning.senderQueueGovernor,
                                                      applyGovernor: tuning.senderQueueGovernorApply) : nil
        vitalsMonitor?.stop()
        let vitals = MacVitalsMonitor(sources: LiveMacVitalsSources())
        vitals.start(now: ProcessInfo.processInfo.systemUptime)
        vitalsMonitor = vitals
        connection.media?.senderQueueGovernorStatus = nil
        connection.media?.senderQueueGovernorShedding = false
    }

    private func endLoadMonitor() {
        phoneLoad = nil
        phoneLoadReceivedAt = nil
        loadMonitor = nil
        connection.media?.senderQueueGovernorStatus = nil
        connection.media?.senderQueueGovernorShedding = false
        vitalsMonitor?.stop()
        vitalsMonitor = nil
        ladderState = nil
        busyState = nil
        capture.setLadder(nil)
    }

    /// Every host statistics second runs the ladder; a rung change is applied at the capture and both
    /// changes go to the phone on the next capture status.
    private func observeLoad(_ report: StreamStatsReport, peer: PeerMedia) {
        guard var monitor = loadMonitor, connection.connected else { return }
        let process = ProcessInfo.processInfo
        let longEdge = (ladderState?.rung ?? 0) == 0 ? [report.sentWidth, report.sentHeight].compactMap { $0 }.max() : nil
        let sample = HostLoadSample(report: report, targetFPS: peer.targetFPS, longEdge: longEdge,
                                    hostThermalState: HostLoadMonitor.thermalName(process.thermalState),
                                    lowPowerMode: process.isLowPowerModeEnabled)
        var sampleWithPhone = sample
        sampleWithPhone.phoneLoad = HostLoadMonitor.currentPhoneLoad(phoneLoad, receivedAt: phoneLoadReceivedAt,
                                                                    now: process.systemUptime)
        sampleWithPhone.provenLocalLink = peer.provenLocalLinkActive
        let change = monitor.tick(sample: sampleWithPhone, at: process.systemUptime)
        loadMonitor = monitor
        peer.senderQueueGovernorStatus = monitor.governorStatus
        peer.senderQueueGovernorShedding = monitor.governorShedding
        if let ladder = change.ladder {
            ladderState = ladder
            var applied = ladder
            if usesVirtualDisplay { applied.sizeFraction = 1 }
            capture.setLadder(applied)
            connection.media?.applyLadder(applied)
            events.record(.session, "Ladder rung \(ladder.rung): \(ladder.fps) fps × \(ladder.sizeFraction) (\(ladder.reason ?? "headroom"))")
        }
        if let busy = change.busy {
            busyState = busy
            connection.media?.busyState = busy
        }
        if change.ladder != nil || change.busy != nil { sendCaptureHealth(sessionHealthy) }
    }

    private var wakeHelperAvailable: Bool {
        guard hasPairedPhone, !captureScopeViewOnly, !liveViewOnly,
              let invitation = connection.invitation, let helper = invitation.durableHostID,
              let grant = invitation.ownerPairID, let targets = try? wakeTargets.read() else { return false }
        return targets.contains { $0.helperHostID == helper && $0.ownerPairID == grant && WakeLANInterface.current(named: $0.interfaceName) != nil }
    }

    /// The phone asks for refinement only under its internal override; full color on this Mac still wins.
    private var refinementNegotiated: Bool {
        HEVC444Policy.permitsRefinement(requested: connection.peerFeatures.contains(SessionFeature.videoRefinement),
                                        fullColor: connection.media?.fullColorCaptureEnabled == true)
    }

    /// A switched-off experiment is not advertised, so the phone never sends what the host would ignore.
    private var advertisedFeatures: [String] {
        let tuning = StreamTuning.current
        let base = SessionFeature.host.filter {
            if $0 == SessionFeature.phoneAudio && !usesPhoneAudioRequest { return false }
            if $0 == SessionFeature.clipboardSync && (!connection.peerFeatures.contains($0) || UserDefaults.standard.bool(forKey: "clipboardAutoSyncDisabled")) { return false }
            if ($0 == SessionFeature.videoLTR || $0 == SessionFeature.exactVideoTiming) && !connection.peerFeatures.contains($0) { return false }
            if $0 == SessionFeature.videoRefinement && !refinementNegotiated { return false }
            if $0 == SessionFeature.hostMomentum && !RemoteInputDriver.hostMomentumEnabled { return false }
            if $0 == SessionFeature.pencilInput && (!connection.allowsCausalInput || !connection.peerFeatures.contains(SessionFeature.pencilInput) || !connection.peerFeatures.contains(SessionFeature.causalInput)) { return false }
            if $0 == SessionFeature.causalInput && (!connection.allowsCausalInput || !connection.peerFeatures.contains(SessionFeature.causalInput)) { return false }
            return ($0 != SessionFeature.viewportCapture || tuning.viewportCapture) && ($0 != SessionFeature.ladder || tuning.ladder)
        } + [SessionFeature.couch]
            + (DeliberateSessionEnd.isEnabled() && connection.peerFeatures.contains(SessionFeature.deliberateEnd)
               ? [SessionFeature.deliberateEnd] : [])
            + (wakeHelperAvailable ? [SessionFeature.lanWake] : [])
            + (awayAvailable && !ManagedLockPolicy.isManaged() ? [SessionFeature.away] : [])
        return SharedCaptureScopePolicy.features(HostFeatureList.features(base: base,
            allowBigText: !captureScopeViewOnly && preferences.allowBigText,
            accessibility: inputAccess.accessibility.isGranted,
            peerFeatures: connection.peerFeatures, requestedMode: connection.peerRequestedMode,
            virtualDisplayEnabled: virtualDisplayEnabled && !virtualDisplayBlocked && !captureScopeViewOnly), kind: captureScopeKind)
    }

    private func sendCaptureHealth(_ requestedHealthy: Bool, presence: HostPresence? = nil, viewOnlyRequestID: String? = nil) {
        guard connection.connected else { return }
        // A caller's Couch flag can be up to one tick old; a token must reflect health at this moment.
        let healthy = sessionState == .couch ? requestedHealthy && refreshCouchHealth() : requestedHealthy && awayPictureClear
        let features = connection.peerFeatures, refines = refinementNegotiated
        connection.media?.videoFeedback.configure(allowed: healthy && !away.isLocking && sessionState == .picture && active && !phonePause.isPaused &&
            (features.contains(SessionFeature.videoLTR) || refines || features.contains(SessionFeature.exactVideoTiming)),
            ltr: features.contains(SessionFeature.videoLTR), refinement: refines, timing: features.contains(SessionFeature.exactVideoTiming), geometry: inputEpoch.value, scope: captureScopeEpoch)
        connection.media?.configureVideoRefinement(enabled: healthy && !away.isLocking && sessionState == .picture && active && !phonePause.isPaused && refines, geometry: inputEpoch.value, scope: captureScopeEpoch)
        let state = MacShareBlocker.sessionState(
            presence: presence ?? (displayAsleep ? .displayAsleep : nil),
            phoneUnderstands: features.contains(MacShareBlocker.feature) || features.contains(MacShareBlocker.approvalFeature),
            controlAllowed: sessionControlAllowed, accessibilityGranted: controlPermission.isGranted,
            captureApprovalPending: sessionState == .picture && captureApproval.isPending,
            phoneUnderstandsApproval: features.contains(MacShareBlocker.approvalFeature))
        // A routine unhealthy tick is not a different capture route. During this bounded,
        // explicitly authorized resize the tagged preflight carries retirement instead.
        // Every blocker/state boundary cancels before the ordinary status is delivered.
        if !healthy, let begin = virtualDisplayResizeBegin {
            let now = ProcessInfo.processInfo.systemUptime
            if virtualDisplayChanging, now < virtualDisplayResizeDeadline,
               presence == nil, state == nil, viewOnlyRequestID == nil,
               connection.media === virtualDisplayResizePeer, active, !terminating,
               !screenLocked, !phonePause.isPaused, !liveViewOnly, !away.isLocking,
               awayPictureClear, !captureApproval.isPending, sessionState == .picture,
               captureScopeKind == .display, captureScopeEpoch == begin.scopeEpoch,
               virtualDisplayEnabled, !virtualDisplayRetirementPending,
               virtualDisplay.displayID == begin.display, virtualDisplay.physicalTopologyUnchanged {
                return
            }
            cancelVirtualDisplayResizeHold()
        }
      let capability = !liveViewOnly && !away.isLocking && !captureScopeViewOnly && sessionState.issuesTokens(healthy: healthy) ? inputFreshness.capability(
            epoch: inputEpoch.value,
            now: ProcessInfo.processInfo.systemUptime,
            doubleClickInterval: min(2, max(0.1, NSEvent.doubleClickInterval))
        ) : nil
        let event = recoveryEventForPhone
        let alert = captureScopeViewOnly ? nil : agentAlertOutbox.first
        let sent = connection.sendControl(RemoteAction(
          action: "capture", liveViewOnly: connection.peerFeatures.contains(SessionFeature.extendedFeatureList) ? liveViewOnly : nil, liveViewOnlyRequestID: viewOnlyRequestID, x: healthy ? 1 : 0, epoch: inputEpoch.value,
            interaction: capability, pointerLocatorSupported: !captureScopeViewOnly,
            pointerSync: PointerSync(videoCursor: capture.cursorInVideo), streamQuality: capture.appliedQuality,
            features: advertisedFeatures, hostState: state,
            hostStream: connection.media?.takeHostSummary(),
            curtain: curtainState.rawValue, hostEvent: event,
            away: advertisedFeatures.contains(SessionFeature.away) ? away.protocolState.rawValue : nil,
            display: capturedDisplayID, agentAlert: alert,
            virtualDisplayActive: advertisedFeatures.contains(SessionFeature.virtualDisplay) ? usesVirtualDisplay : nil,
            captureRegion: capture.appliedCaptureRegion, ladder: ladderState, busy: busyState,
            macVitals: vitalsMonitor?.current(now: ProcessInfo.processInfo.systemUptime),
            mode: sessionState.wireMode, modeReason: pendingModeReason?.rawValue ?? sessionState.wireReason,
            captureScope: captureScopeStatus
        ))
        if sent && event != nil { recoveryNoticeDelivered = true }
        if sent && alert != nil { agentAlertOutbox.removeFirst() }
        if sent { pendingModeReason = nil }
    }

    // MARK: Session mode

    private func waitForVirtualDisplayViewport() {
        guard virtualDisplayNegotiationDeadline == nil else { return }
        virtualDisplayNegotiationDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.connection.connected,
                  !self.usesVirtualDisplay, !self.virtualDisplayChanging else { return }
            self.virtualDisplayNegotiationDeadline = nil
            self.virtualDisplayBlocked = true
            self.bigText.sessionResumed()
            self.sendCaptureHealth(self.sessionHealthy)
        }
    }

    private func requestVirtualDisplay(_ viewport: VirtualDisplayViewport) {
        guard virtualDisplayEnabled, !virtualDisplayBlocked, !virtualDisplayRetirementPending, !captureScopeViewOnly, !liveViewOnly,
              active, connection.connected, sessionState == .picture, !phonePause.isPaused, !terminating, !virtualDisplayQuitPending,
              inputAccess.accessibility.isGranted, advertisedFeatures.contains(SessionFeature.virtualDisplay),
              let spec = VirtualDisplaySpecification(viewport: viewport), let peer = connection.media else { return }
        guard !bigText.isEngaged && !bigText.isChanging && !bigText.restorePending else {
            virtualDisplayBlocked = true; return
        }
        // Codec constraints are preserved. Exact pixels at 60 are the fallback for a 120 request.
        guard RemoteCaptureConfiguration.virtualDisplayOutput(spec, budget: peer.nativeCaptureBudget, fps: 60) != nil else {
            if virtualDisplayWasUsed { virtualDisplayFallback() }
            else {
                virtualDisplayBlocked = true; bigText.sessionResumed()
                sendCaptureHealth(sessionHealthy)
            }
            return
        }
        virtualDisplayNegotiationDeadline?.cancel(); virtualDisplayNegotiationDeadline = nil
        if let begin = virtualDisplayResizeBegin,
           begin.pixelWidth != spec.width || begin.pixelHeight != spec.height {
            cancelVirtualDisplayResizeHold() // Cancel immediately, including while an await is in flight.
        }
        virtualDisplayRequested = spec
        if virtualDisplayTask != nil { return } // One owner drains size changes; newest request wins.
        if usesVirtualDisplay && virtualDisplayAcceptedRequest == spec { return }
        virtualDisplayGeneration &+= 1
        let generation = virtualDisplayGeneration
        virtualDisplayWasUsed = true
        virtualDisplayChanging = true
        // Retain the admitted peer until preparation settles. A reset before this task
        // starts must not leave a completed task installed as a permanent transition.
        virtualDisplayTask = Task { [weak self, peer] in
            guard let self else { return }
            let current = { [weak self, weak peer] in
                guard let self, let peer else { return false }
                return self.virtualDisplayGeneration == generation && self.connection.media === peer &&
                    self.active && self.connection.connected && self.sessionState == .picture &&
                    !self.phonePause.isPaused && !self.terminating && !self.screenLocked &&
                    !self.virtualDisplayQuitPending &&
                    !self.liveViewOnly && !self.captureScopeViewOnly
            }
            var failed = false
            var resizeHoldAttempted = !self.usesVirtualDisplay
            do {
                while current(), let wanted = self.virtualDisplayRequested {
                    let first = !self.usesVirtualDisplay
                    if let begin = self.virtualDisplayResizeBegin,
                       begin.pixelWidth != wanted.width || begin.pixelHeight != wanted.height {
                        self.cancelVirtualDisplayResizeHold() // Coalescing cannot renew frozen authority.
                    }
                    if !first, !resizeHoldAttempted {
                        resizeHoldAttempted = true
                        self.beginVirtualDisplayResizeHold(wanted, peer: peer)
                    }
                    self.input.enabled = false
                    self.releaseRemoteInput(notifyPhone: true)
                    self.captureHealthy = false
                    self.captureAttempt &+= 1
                    self.captureTask?.cancel(); self.captureTask = nil
                    self.endLoadMonitor()
                    let stop = self.capture.stop()
                    await stop?.value
                    guard current() else { break }
                    // WindowServer may reflow windows while adding a display. Persist the
                    // originals before the topology changes, rather than after creation.
                    if first { try await self.virtualWindows.prepareFrontmostWindows() }
                    guard current() else { break }
                    let display: SCDisplay
                    do { display = try await self.virtualDisplay.prepare(wanted, whileCurrent: current) }
                    catch {
                        guard wanted.refreshHz == 120, current() else { throw error }
                        display = try await self.virtualDisplay.prepare(wanted.at60Hz, whileCurrent: current)
                    }
                    guard current() else { break }
                    if let begin = self.virtualDisplayResizeBegin, begin.display != display.displayID {
                        self.cancelVirtualDisplayResizeHold()
                    }
                    if first { try await self.virtualWindows.moveFrontmostWindows(to: display.frame) }
                    else { try await self.virtualWindows.resize(to: display.frame) }
                    guard current() else { break }
                    self.virtualDisplaySource = display
                    self.virtualDisplayAcceptedRequest = wanted
                    if wanted == self.virtualDisplayRequested { break }
                }
            } catch {
                failed = true
                self.events.record(.error, "Phone-sized display unavailable; restoring normal picture")
            }
            guard self.virtualDisplayGeneration == generation else { return }
            self.virtualDisplayTask = nil
            self.virtualDisplayChanging = false
            // Unexpected disconnect owns the existing grace timer even if it happened
            // during an awaited resize. Keep the journal/display until that timer settles.
            if self.virtualDisplayGrace != nil, !self.connection.connected,
               !self.virtualDisplayQuitPending, !self.virtualDisplayRetirementPending { return }
            if failed { self.virtualDisplayFallback() }
            else if current() { self.beginCapture(keepingExclusions: true) }
            else {
                // A view-only/lock/session transition can invalidate preparation without
                // throwing. It must still restore the journal and remove the owned display.
                self.retireVirtualDisplay(resume: self.connection.connected && self.active &&
                    self.sessionState == .picture && !self.phonePause.isPaused && !self.terminating ? .picture : nil)
            }
        }
    }

    private func beginVirtualDisplayResizeHold(_ wanted: VirtualDisplaySpecification, peer: PeerMedia) {
        guard virtualDisplayResizeHoldSupported, virtualDisplayEnabled,
              let source = virtualDisplaySource, virtualDisplay.isReady(for: source),
              connection.media === peer, connection.connected, sessionState == .picture,
              active, !terminating, !virtualDisplayRetirementPending,
              !captureScopeViewOnly, !liveViewOnly, !screenLocked, !phonePause.isPaused,
              !displayAsleep, !away.isLocking, awayPictureClear, !captureApproval.isPending,
              screenRecordingPermission.isGranted, inputAccess.accessibility.isGranted,
              let display = virtualDisplaySource?.displayID else { return }
        let begin = VirtualDisplayResizeBegin(token: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            display: display, fromEpoch: inputEpoch.value, scopeEpoch: captureScopeEpoch,
            pixelWidth: wanted.width, pixelHeight: wanted.height)
        guard (try? begin.validate()) != nil,
              connection.sendControl(RemoteAction(action: "virtualDisplayResizeBegin", epoch: inputEpoch.value,
                  virtualDisplayResizeBegin: begin)) else { return }
        virtualDisplayResizeBegin = begin
        virtualDisplayResizePeer = peer
        virtualDisplayResizeDeadline = ProcessInfo.processInfo.systemUptime + 2
    }

    private func currentVirtualDisplayResizeToken(peer: PeerMedia) -> String? {
        guard let begin = virtualDisplayResizeBegin else { return nil }
        guard connection.media === peer, virtualDisplayResizePeer === peer,
              ProcessInfo.processInfo.systemUptime < virtualDisplayResizeDeadline,
              connection.connected, active, !terminating, sessionState == .picture,
              !virtualDisplayRetirementPending, !virtualDisplayBlocked, virtualDisplayEnabled,
              !screenLocked, !phonePause.isPaused, !liveViewOnly, !displayAsleep,
              !away.isLocking, awayPictureClear, !captureApproval.isPending,
              screenRecordingPermission.isGranted, inputAccess.accessibility.isGranted,
              usesVirtualDisplay, virtualDisplaySource?.displayID == begin.display,
              virtualDisplay.specification?.width == begin.pixelWidth,
              virtualDisplay.specification?.height == begin.pixelHeight,
              captureScopeKind == .display, captureScopeEpoch == begin.scopeEpoch,
              inputEpoch.value > begin.fromEpoch else {
            cancelVirtualDisplayResizeHold()
            return nil
        }
        return begin.token
    }

    private func clearVirtualDisplayResizeHold() {
        virtualDisplayResizeBegin = nil
        virtualDisplayResizePeer = nil
        virtualDisplayResizeDeadline = 0
    }

    private func cancelVirtualDisplayResizeHold() {
        guard let begin = virtualDisplayResizeBegin else { return }
        clearVirtualDisplayResizeHold()
        if connection.connected {
            _ = connection.sendControl(RemoteAction(action: "virtualDisplayResizeCancel", epoch: inputEpoch.value,
                virtualDisplayResizeToken: begin.token))
        }
    }

    /// Capture/input retire synchronously. Window restoration must finish before display removal.
    private func retireVirtualDisplay(afterGrace: Bool = false, resume: SessionMode? = nil) {
        virtualDisplayNegotiationDeadline?.cancel(); virtualDisplayNegotiationDeadline = nil
        virtualDisplayGrace?.cancel(); virtualDisplayGrace = nil
        cancelVirtualDisplayResizeHold()
        guard virtualDisplayWasUsed else { return }
        if afterGrace {
            virtualDisplayGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, !self.connection.connected else { return }
                self.retireVirtualDisplay()
            }
            return
        }
        if virtualDisplayRetirementPending, virtualDisplayTask != nil {
            virtualDisplayResumeMode = resume
            return
        }
        virtualDisplayGeneration &+= 1
        let generation = virtualDisplayGeneration
        virtualDisplayRetirementPending = true
        virtualDisplayResumeMode = resume
        virtualDisplayRequested = nil
        virtualDisplayAcceptedRequest = nil
        virtualDisplaySource = nil
        virtualDisplayChanging = true
        input.enabled = false
        releaseRemoteInput(notifyPhone: true)
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        captureHealthy = false
        let stopped = capture.stop()
        let previous = virtualDisplayTask
        virtualDisplayTask = Task { [weak self] in
            await previous?.value
            await stopped?.value
            guard let self else { return }
            guard self.virtualDisplayGeneration == generation else { return }
            // A false readiness probe is not proof of removal. Preserve originals until
            // current ownership/absence and the protected physical topology are known.
            let presence = await self.virtualDisplay.retirementPresence()
            guard self.virtualDisplayGeneration == generation else { return }
            if await self.virtualWindows.restore(after: presence,
                physicalTopologyUnchanged: self.virtualDisplay.physicalTopologyUnchanged) {
                do { try await self.virtualDisplay.stop() }
                catch { self.events.record(.error, "Phone-sized display removal needs retry") }
            }
            if !self.virtualWindows.hasPendingRestore && !self.virtualDisplay.ownsScreenChanges {
                self.virtualDisplayWasUsed = false
                self.virtualDisplayLastRetiredAt = ProcessInfo.processInfo.systemUptime
                self.virtualDisplayRetirementPending = false
            } else {
                self.detail = "Restoring the phone workspace. Window restoration will be retried."
                self.events.record(.error, "Phone workspace restoration remains pending")
            }
            if self.virtualDisplayGeneration == generation {
                self.virtualDisplayChanging = false
                self.virtualDisplayTask = nil
                if !self.virtualDisplayWasUsed, let mode = self.virtualDisplayResumeMode,
                   self.connection.connected, self.active, !self.phonePause.isPaused, !self.terminating {
                    self.virtualDisplayResumeMode = nil
                    if mode == .couch { self.beginCouch() }
                    else { self.beginCapture() }
                }
            }
        }
    }

    private func virtualDisplayFallback() {
        guard virtualDisplayWasUsed, !virtualDisplayRetirementPending else { return }
        virtualDisplayBlocked = true
        retireVirtualDisplay(resume: .picture)
    }

    private func receiveModeRequest(_ action: RemoteAction) {
        guard !away.isLocking, connection.connected, active, action.epoch == inputEpoch.value, !phonePause.isPaused && !liveViewOnly,
              let requested = action.mode.flatMap(SessionMode.init(rawValue:)) else { return }
        cancelPictureRefresh()
        switch (sessionState, requested) {
        case (.couch, .picture):
            guard CGPreflightScreenCaptureAccess() else {
                pendingModeReason = .screenRecording
                sendCaptureHealth(sessionHealthy)
                return
            }
            pendingPictureRefresh = CouchPictureRefreshTicket(epoch: inputEpoch.value,
                                                              issuedAt: ProcessInfo.processInfo.systemUptime)
            pendingPictureRefreshPeer = connection.media
            if !displaysStaleFromCouch && displayRefreshStatus == .ready
                && displays.contains(where: { $0.displayID == selected }) {
                finishPictureRefresh()
            } else {
                guard let ticket = pendingPictureRefresh else { return }
                pictureRefreshTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(CouchPictureRefreshTicket.maximumWait))
                    guard !Task.isCancelled, let self, self.pendingPictureRefresh?.id == ticket.id else { return }
                    let peerMatches = self.pendingPictureRefreshPeer.map { self.connection.media === $0 } ?? false
                    self.cancelPictureRefresh()
                    guard peerMatches, self.connection.connected, self.active, self.sessionState == .couch,
                          self.inputEpoch.value == ticket.epoch, !self.phonePause.isPaused else { return }
                    self.pendingModeReason = CGPreflightScreenCaptureAccess() ? .displayUnavailable : .screenRecording
                    self.sendCaptureHealth(self.sessionHealthy)
                }
                if displayRefreshTask == nil { loadDisplays() }
            }
        case (.picture, .couch):
            if let refusal = CouchAdmission.decide(couchAdmissionInputs) {
                pendingModeReason = refusal
                sendCaptureHealth(sessionHealthy)
                return
            }
            events.record(.session, "Phone switched to Couch mode")
            beginCouch()
        default:
            sendCaptureHealth(sessionHealthy)
        }
    }

    private func cancelPictureRefresh() {
        pendingPictureRefresh = nil
        pendingPictureRefreshPeer = nil
        pictureRefreshTimeout?.cancel()
        pictureRefreshTimeout = nil
    }

    private func finishPictureRefresh() {
        guard let ticket = pendingPictureRefresh else { return }
        guard let peer = pendingPictureRefreshPeer else { cancelPictureRefresh(); return }
        let sameSession = ticket.matchesSession(epoch: inputEpoch.value, samePeer: connection.media === peer,
                                               session: sessionState, connected: connection.connected,
                                               active: active, paused: phonePause.isPaused)
        let current = ticket.isCurrent(epoch: inputEpoch.value, now: ProcessInfo.processInfo.systemUptime,
                                       samePeer: connection.media === peer, session: sessionState,
                                       connected: connection.connected, active: active, paused: phonePause.isPaused)
        cancelPictureRefresh()
        guard sameSession else { return }
        guard current else {
            pendingModeReason = CGPreflightScreenCaptureAccess() ? .displayUnavailable : .screenRecording
            sendCaptureHealth(sessionHealthy)
            return
        }
        guard !HostScreenLock.isLocked(), Self.consoleUserActive() else { return }
        guard CGPreflightScreenCaptureAccess(), CaptureStopReason.systemAllowsCapture,
              !captureApproval.isPending else {
            pendingModeReason = .screenRecording
            sendCaptureHealth(sessionHealthy)
            return
        }
        if let refusal = CouchAdmission.decide(couchAdmissionInputs) {
            pendingModeReason = refusal
            sendCaptureHealth(sessionHealthy)
            return
        }
        guard refreshCouchHealth() else { return }
        guard displayRefreshStatus == .ready, displays.contains(where: { $0.displayID == selected }) else {
            pendingModeReason = .displayUnavailable
            sendCaptureHealth(sessionHealthy)
            return
        }
        events.record(.session, "Phone switched to the picture")
        beginCapture()
    }

    // MARK: Session extensions

    private func receiveSessionExtension(_ action: RemoteAction) {
        let current = connection.connected && active && action.epoch == inputEpoch.value && !sessionRefused && !deliberatePeerEnding
        let controlEffective = sessionControlAllowed && controlPermission.isGranted
        switch action.action {
        case "lockMac":
            receiveLockMac(current: current, controlEffective: controlEffective)
        case "wake":
            if current && controlEffective && !phonePause.isPaused && !liveViewOnly { wakeDisplayForRemoteSession(force: true) }
        case "viewOnly":
            guard !away.isLocking, current, sessionState == .picture, connection.peerFeatures.contains(SessionFeature.extendedFeatureList),
                  let next = action.liveViewOnly, !phonePause.isPaused else { return }
            let wasViewOnly = liveViewOnly
            let released = input.withAuthority { () -> Bool in
                // Close queued posting and release owned holds before publishing acknowledgment.
                input.enabled = false
                input.invalidateQueued(); inputFreshness.expireTokens()
                releaseRemoteInput(notifyPhone: false)
                guard !input.held else { return false }
                liveViewOnly = next
                return true
            }
            guard released else { connection.dropPeerSession(); return }
            if next && virtualDisplayWasUsed { virtualDisplayFallback() }
            invalidateTextFocus(); clipboard.reset(); fileTransfer.reset()
            // Restore only the Mac owner's existing producer consent when leaving live PiP.
            // Phone playback remains muted until the person explicitly enables it again.
            if next { phoneAudioRequested = false }
            reconcileSystemAudio()
            applyControlState(notifyPhone: true)
            sendCaptureHealth(sessionHealthy, viewOnlyRequestID: action.liveViewOnlyRequestID)
            if DeliberateSessionEnd.isEnabled() {
                if next {
                    bigTextEndedForLifecycle = true
                    bigText.sessionEnded(.sessionEnded)
                } else if wasViewOnly { bigTextEndedForLifecycle = false }
            }
            // Suspension retired the old capture audio epoch; enabling consent cannot revive it.
            // A real transition back starts a newly scoped stream/epoch, with owner consent intact.
            if wasViewOnly && systemAudioAllowedNow { beginCapture() }
        case "sessionEnd":
            // The control envelope already binds this to the authenticated current peer. A display
            // reconfiguration may advance the geometry epoch while End travels; close is still valid.
            guard connection.connected, active, !captureScopeViewOnly, DeliberateSessionEnd.isEnabled(),
                  connection.peerFeatures.contains(SessionFeature.deliberateEnd) else { return }
            deliberatePeerEnding = true
            pauseForPhoneBackground(ending: true)
            _ = connection.sendControl(RemoteAction(action: "sessionEnd", epoch: action.epoch))
        case "pause":
            if DeliberateSessionEnd.allowsBackgroundPause(epochMatches: action.epoch == inputEpoch.value,
                connected: connection.connected, sharing: active, sessionRefused: sessionRefused,
                ending: deliberatePeerEnding, peerFeatures: connection.peerFeatures,
                enabled: DeliberateSessionEnd.isEnabled()) {
                let wasPaused = phonePause.isPaused
                pauseForPhoneBackground()
                if !wasPaused && phonePause.isPaused { acceptedPhonePauseEpoch = action.epoch }
            }
        case "resume":
            if DeliberateSessionEnd.allowsForegroundResume(requestedEpoch: action.epoch, currentEpoch: inputEpoch.value,
                acceptedPauseEpoch: acceptedPhonePauseEpoch, paused: phonePause.isPaused,
                connected: connection.connected, sharing: active, sessionRefused: sessionRefused,
                ending: deliberatePeerEnding, peerFeatures: connection.peerFeatures,
                enabled: DeliberateSessionEnd.isEnabled()) { resumeAfterPhoneBackground() }
        case "clipboard":
            guard let frame = action.clipboard else { return }
            clipboard.receive(frame, allowed: current && !phonePause.isPaused && !liveViewOnly && controlEffective)
        case "file":
            if let frame = action.file { fileTransfer.receive(frame, current: current) }
        case "curtain":
            guard sessionState == .picture else {
                sendCaptureHealth(sessionHealthy)
                return
            }
            // Covering the Mac's own screen needs the same authority as controlling it.
            guard current, controlEffective, !phonePause.isPaused && !liveViewOnly,
                  let request = action.curtain.flatMap(PrivacyCurtainRequest.init(rawValue:)) else {
                sendCaptureHealth(sessionHealthy)
                return
            }
            events.record(.curtain, "Phone asked to \(request == .up ? "hide" : "show") the screen")
            setPrivacyCurtain(request == .up)
        default:
            break
        }
    }

    // MARK: Display selection

    private func receiveDisplaySelection(_ action: RemoteAction) {
        // The phone waits on a reply to every scale request, so a stale one learns the current epoch.
        if action.action == "displayScale", action.epoch != inputEpoch.value {
            return sendDisplayList(scaleError: .failed, scaleRequestID: action.scaleRequestID)
        }
        guard !away.isLocking, connection.connected, active, action.epoch == inputEpoch.value, !phonePause.isPaused && !liveViewOnly, !sessionRefused else { return }
        switch action.action {
        case "displays":
            sendDisplayList()
        case "display":
            guard sessionState == .picture else { sendDisplayList(); return }
            guard let requested = action.display else { return }
            let decision = HostDisplayCatalog.decide(
                requested: requested, available: displays.map(\.displayID), streaming: capturedDisplayID,
                controlEffective: sessionControlAllowed && controlPermission.isGranted)
            switch decision {
            case .resendList:
                sendDisplayList()
            case .switchTo(let id):
                events.record(.sharing, "Phone switched the shared display to \(Self.displayName(for: id))")
                switchSessionDisplay(to: id)
            }
        case "displayScale":
            guard sessionState == .picture, !virtualDisplayWasUsed,
                  !advertisedFeatures.contains(SessionFeature.virtualDisplay) else {
                return sendDisplayList(scaleError: .disabled, scaleRequestID: action.scaleRequestID)
            }
            guard let requested = action.display, let width = action.looksLikeWidth else { return }
            guard requested == selected, requested == capturedDisplayID,
                  displays.contains(where: { $0.displayID == requested }) else {
                return sendDisplayList(scaleError: .unsupported, scaleRequestID: action.scaleRequestID)
            }
            bigText.request(display: requested, looksLikeWidth: width, allowed: preferences.allowBigText,
                            accessibilityGranted: inputAccess.accessibility.isGranted, requestID: action.scaleRequestID)
        default:
            break
        }
    }

    /// The phone chose another display: stream it in the same session. A new epoch and geometry
    /// follow, so input meant for the old display can never land on the new one.
    private func switchSessionDisplay(to id: CGDirectDisplayID) {
        if virtualDisplayWasUsed { virtualDisplayBlocked = true; retireVirtualDisplay() }
        bigText.sessionEnded(.displaySwitched)
        liftCurtain()
        selected = id
        beginCapture()
        sendDisplayList()
    }

    private func sendDisplayList(scaleError: BigTextError? = nil, scaleRequestID: String? = nil) {
        guard connection.connected else { return }
        let entries = displays.map { display in
            HostDisplayCatalog.Display(
                id: display.displayID, name: Self.displayName(for: display.displayID),
                width: Double(display.frame.width), height: Double(display.frame.height),
                pixelWidth: CGDisplayCopyDisplayMode(display.displayID).map { $0.pixelWidth },
                pixelHeight: CGDisplayCopyDisplayMode(display.displayID).map { $0.pixelHeight },
                main: display.displayID == CGMainDisplayID())
        }
        var descriptors = HostDisplayCatalog.descriptors(entries)
        if preferences.allowBigText && inputAccess.accessibility.isGranted {
            descriptors = descriptors.map { descriptor in
                guard descriptor.id == selected else { return descriptor }
                let described = BigTextController.describe(descriptor, offer: bigText.offer(for: descriptor.id))
                // Mid-change the live mode can be neither the baseline nor a step, which the phone rejects.
                return (try? described.validate()) == nil ? descriptor : described
            }
        }
        _ = connection.sendControl(RemoteAction(action: "displays", epoch: inputEpoch.value,
                                                displays: descriptors, display: capturedDisplayID,
                                                scaleError: scaleError?.rawValue, scaleRequestID: scaleRequestID))
    }

    /// The phone is backgrounding: stop capture and input now, but keep the peer and its
    /// session slot so a quick return resumes without renegotiation.
    private func pauseForPhoneBackground(ending: Bool = false) {
        if virtualDisplayWasUsed { retireVirtualDisplay() }
        cancelPictureRefresh()
        guard !phonePause.isPaused && (ending || !liveViewOnly) else { return }
        liftCurtain()
        phoneAudioRequested = false
        phonePause.begin(at: ProcessInfo.processInfo.systemUptime)
        reconcileSystemAudio()
        clipboard.reset()
        fileTransfer.reset()
        invalidateTextFocus()
        releaseRemoteInput(notifyPhone: false)
        input.invalidateQueued(); inputFreshness.expireTokens()
        input.enabled = false
        captureHealthy = false
        capturedDisplayID = nil
        pointerLocator.reset()
        pointerTelemetry.end()
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
        guests.endAll()
        _ = capture.stop()
        couchHealthy = false
        updatePowerAssertions()
        reconcileCurtain()
        if DeliberateSessionEnd.isEnabled() {
            bigTextEndedForLifecycle = true
            bigText.sessionEnded(.sessionEnded)
        }
    }

    /// A fresh epoch, geometry and capture follow, so no pre-background input can apply.
    private func resumeAfterPhoneBackground() {
        guard phonePause.isPaused, !deliberatePeerEnding else { return }
        bigTextEndedForLifecycle = false
        phonePause.clear()
        acceptedPhonePauseEpoch = nil
        if sessionState == .couch { beginCouch() } else {
            connection.media?.counters.beginResumeCapture()
            connection.media?.rearmBandwidthSeed()
            beginCapture()
        }
    }

    private func expirePhonePause() {
        phonePause.clear()
        acceptedPhonePauseEpoch = nil
        connection.dropPeerSession()
    }

    // MARK: Sleep, lock and display availability

    private func handleAvailability(_ event: HostSleepPolicy.Event) {
        couchSessionSnapshot.observeAvailability(event)
        switch HostSleepPolicy.response(to: event) {
        case .tearDown(let presence):
            // Revoke before any lock bookkeeping or teardown guard, synchronously in the notification callback.
            input.enabled = false
            couchHealthy = false
            input.invalidateQueued(); inputFreshness.expireTokens()
            releaseRemoteInput(notifyPhone: true)
            if presence == .locked {
                guard !screenLocked else { return }
                guests.endAll()
                noteUnexpectedLock()
                screenLocked = true
            }
            autoStart.suspend()
            switch presence {
            case .locked: detail = "This Mac is locked. Sharing resumes when it’s unlocked."
            case .switchedUser: detail = "Another user is using this Mac. Sharing resumes when you switch back."
            default: detail = "This Mac went to sleep. Sharing resumes when it wakes."
            }
            unavailableReason = switch presence {
            case .locked: .locked
            case .switchedUser: .switchedUser
            case .sleeping: .asleep
            case .displayAsleep: .displayAsleep
            }
            tearDownForUnavailability(presence)
        case .recover:
            if event == .systemDidWake { updatePowerAssertions() }
            if event == .screenUnlocked {
                guard screenLocked else { return }
                screenLocked = false
            }
            connection.checkSignalingLiveness()
            if HostScreenLock.isLocked() { guests.endAll(); screenLocked = true; return }
            bigText.retryPendingRestore()
            autoStart.clear()
            detail = nil
            unavailableReason = nil
            reconcileSharing()
        case .displayAsleep:
            displayAsleep = true
            guard active, connection.connected else { return }
            releaseRemoteInput(notifyPhone: true)
            sendCaptureHealth(sessionHealthy)
        case .displayAwake:
            displayAsleep = false
            if connection.connected { sendCaptureHealth(sessionHealthy) }
        }
        away.refresh()
        reconcileCurtain()
    }

    /// Input stops at once; the phone gets the reason on the ordered channel just before the
    /// session closes, so it can say why instead of guessing.
    private func tearDownForUnavailability(_ presence: HostPresence) {
        liftCurtain()
        events.record(.availability, "Sharing paused: \(presence.rawValue)")
        guard connection.connected else {
            if active || connection.isRunning || browserSession.controller.running { stop() }
            return
        }
        invalidateTextFocus()
        pointerTelemetry.end()
        captureHealthy = false
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
        guests.endAll()
        _ = capture.stop()
        sendCaptureHealth(false, presence: presence)
        unavailabilityTeardown?.cancel()
        unavailabilityTeardown = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func wakeDisplayForRemoteSession(force: Bool = false) {
        guard force || displayAsleep || CGDisplayIsAsleep(selected) != 0 else { return }
        displayWake.declareRemoteActivity()
    }

    private func updatePowerAssertions() {
        if !powerAssertions.apply(keepAwake: keepAwakeEnabled && !awayLockFailed, sharing: active,
                                  phoneConnected: connection.connected && !phonePause.isPaused,
                                  awayArmed: away.holdsDisplayAwake) {
            detail = "Farside couldn’t keep this Mac awake. Normal sleep settings still apply."
        }
        if onBattery != powerAssertions.battery.onBattery { onBattery = powerAssertions.battery.onBattery }
        keepAwakeActive = powerAssertions.systemHeld
    }

    private func sendTextResult(for requestID: String, accepted: Bool) {
        guard !requestID.isEmpty, requestID.utf8.count <= 32 else { return }
        _ = connection.sendControl(RemoteAction(
            action: "textResult",
            x: accepted ? 1 : 0,
            key: requestID,
            epoch: inputEpoch.value
        ))
    }

    private func releaseRemoteInput(notifyPhone: Bool) {
        input.withAuthority {
            input.invalidateQueued()
            let releasedHold = input.externalHoldID
            let releaseEpoch = inputEpoch.value
            guard let holdID = input.holdID else {
                input.cancelLease()
                if notifyPhone { sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch) }
                return
            }
            if input.release() {
                input.cancelLease()
                if notifyPhone { sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch) }
            } else if !terminating {
                retryRelease(
                    holdID: holdID, releasedHold: releasedHold, epoch: releaseEpoch,
                    notifyPhone: notifyPhone, remaining: 8
                )
            }
        }
    }

    private func releaseRemoteInputSynchronously() {
        input.withAuthority {
            input.invalidateQueued()
            let releasedHold = input.externalHoldID
            let releaseEpoch = inputEpoch.value
            if input.held {
                for _ in 0..<8 {
                    if input.release() { break }
                }
            }
            input.cancelLease()
            sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch)
        }
    }

    private func retryRelease(
        holdID: UInt64, releasedHold: String?, epoch: UInt64,
        notifyPhone: Bool, remaining: Int
    ) {
        guard remaining > 0, !terminating else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, !self.terminating else { return }
            self.input.withAuthority {
            guard self.input.holdID == holdID else { return }
            if self.input.release() {
                self.input.cancelLease()
                if notifyPhone { self.sendReleaseNotice(releasedHold: releasedHold, epoch: epoch) }
            } else {
                self.retryRelease(
                    holdID: holdID, releasedHold: releasedHold, epoch: epoch,
                    notifyPhone: notifyPhone, remaining: remaining - 1
                )
            }
            }
        }
    }

    private func sendReleaseNotice(releasedHold: String?, epoch: UInt64) {
        guard connection.connected,
              let notice = inputFreshness.releaseNotice(epoch: epoch, releasedHold: releasedHold)
        else { return }
        _ = connection.sendControl(notice)
    }

    private func captureStartIsCurrent(_ attempt: UInt64, peer: PeerMedia) -> Bool {
        captureAttempt == attempt && connection.connected && connection.media === peer
    }

    private func advanceEpoch() {
        phoneAudioRequested = false
        if usesPhoneAudioRequest { reconcileSystemAudio() }
        clipboard.stopAutomaticSync()
        guests.endAll()
        // A transfer cannot continue across a new capture geometry. Tell the phone (it would otherwise show
        // progress until the stall timeout), before the epoch moves; with no phone there is nobody to tell.
        if connection.connected { fileTransfer.revoke() } else { fileTransfer.reset() }
        // Retire both posted and admitted holds before publishing the new scope.
        releaseRemoteInput(notifyPhone: true)
        invalidateTextFocus()
        inputEpoch.beginSession()
        input.invalidateQueued(); inputFreshness.expireTokens()
        input.resetNativeSequence()
        connection.media?.videoFeedback.configure(allowed: false, geometry: inputEpoch.value, scope: captureScopeEpoch)
        connection.media?.configureVideoRefinement(enabled: false, geometry: inputEpoch.value, scope: captureScopeEpoch)
        connection.setHostInputEpoch(inputEpoch.value)
    }

    private func releaseKeepAwake() {
        powerAssertions.releaseAll()
        keepAwakeActive = powerAssertions.systemHeld
    }

    private func reconcileStartResult() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishIfCoordinatorStopped()
        }
    }

    private func reconcileAvailabilityAfterCoordinatorReset() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishIfCoordinatorStopped()
        }
    }

    private func finishIfCoordinatorStopped() {
        if listeningWithoutSharing && !connection.isRunning { listeningWithoutSharing = false }
        guard active, !HostActiveAccessPolicy.isRunning(
            status: connection.status,
            hostRegistered: connection.hostRegistered,
            connected: connection.connected,
            awaitingApproval: connection.awaitingApproval
        ) else { return }
        active = false
        releaseKeepAwake()
        if wantsSharing && hasPairedPhone {
            autoStart.suspend()
            detail = connection.status
        }
    }

    private static let userInputActions: Set<String> = [
        "move", "moveTo", "click", "right", "middle", "double", "dragDown", "dragUp", "holdRenew", "scroll", "text", "key",
        "auxClick"
    ]
}

// MARK: Big Text

extension RemoteHostModel: BigTextHost {
    func bigTextQuiesce() {
        bigTextScreenSnapshot = nil
        invalidateTextFocus()
        releaseRemoteInput(notifyPhone: true)
        input.invalidateQueued(); inputFreshness.expireTokens()
        input.enabled = false
        captureHealthy = false
        pointerLocator.reset()
        pointerTelemetry.end()
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
        // The curtain windows stay excluded, so the next stream starts without ever showing them.
        guests.endAll()
        _ = capture.stop(keepingExclusions: true)
        curtain.followsScreenChanges = false
        reconcileCurtain()
    }

    func bigTextResume(display: CGDirectDisplayID) async -> Bool {
        bigTextResuming = true
        bigTextNeedsRefresh = false
        defer {
            bigTextResuming = false
            curtain.followsScreenChanges = true
        }
        guard let refreshed = await verifiedDisplays(including: display) else {
            if !terminating { bigTextForeignChange() }
            return false
        }
        guard !terminating, bigText.ownsLiveConfiguration else {
            if !terminating { bigTextForeignChange() }
            return false
        }
        rememberBigTextScreenSnapshot(refreshed)
        curtain.refitToScreens()
        guard active else {
            loadDisplays()
            return true
        }
        // loadDisplays() returns early while sharing, so the refreshed list is adopted here; the input
        // driver and geometry then come from frames that match the new mode.
        displays = refreshed
        if sessionState == .couch {
            beginCouch(restoringBigText: false)
            return true
        }
        guard bigTextSessionStreaming, refreshed.contains(where: { $0.displayID == selected }) else {
            reconcileCurtain()
            return true
        }
        beginCapture(keepingExclusions: curtain.phase == .up)
        return true
    }

    func bigTextReply(display: CGDirectDisplayID, error: BigTextError?, requestID: String?) {
        sendDisplayList(scaleError: error, scaleRequestID: requestID)
    }

    func bigTextForeignChange() {
        bigTextScreenSnapshot = nil
        bigTextNeedsRefresh = false
        curtain.followsScreenChanges = true
        handleScreenChange()
    }

    func bigTextStateChanged() {
        if bigText.isChanging {
            prepareCurtainForBigTextChange()
            bigTextScreenSnapshot = nil
            bigTextNeedsRefresh = true
        } else if bigTextNeedsRefresh {
            bigTextNeedsRefresh = false
            // A failed restore left the mode, and so the display list, as it was; refreshing would
            // stop the session and re-queue the same failing restore.
            if !bigText.restorePending { refreshAfterBigTextChange() }
        }
        reconcileCurtain()
        objectWillChange.send()
    }

    private func prepareCurtainForBigTextChange() {
        guard let target = bigText.changeTarget else { return }
        let coverage = CurtainDisplayCoverage.envelope(
            frames: NSScreen.screens.map(\.frame), currentSize: CGDisplayBounds(target.display).size,
            targetSize: CGSize(width: target.mode.width, height: target.mode.height))
        // Keep the IDs already excluded by capture. Cancel a half-raise before capture.stop().
        curtain.prepareForDisplayChange(coverage: coverage)
    }

    func bigTextDisplayBounds(_ display: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(display)
    }

    func bigTextRunningAppPIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
    }

    /// Screen changes Big Text makes are handled by its own completion, not by stopping the session.
    private var bigTextHandlingScreenChanges: Bool {
        bigText.isChanging || bigTextNeedsRefresh || bigTextResuming || bigTextRefreshTask != nil
    }

    fileprivate var bigTextOwnsScreenChanges: Bool {
        if bigTextHandlingScreenChanges {
            return bigText.screenChangeVerdict != .foreign
        }
        guard let snapshot = bigTextScreenSnapshot else { return false }
        let online = LiveDisplayModeSwitcher().onlineDisplays()
        var frames: [CGDirectDisplayID: CGRect] = [:]
        var modes: [CGDirectDisplayID: Int32] = [:]
        for id in online {
            frames[id] = CGDisplayBounds(id)
            modes[id] = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
        }
        return snapshot.matches(online: online, frames: frames, modeIDs: modes)
    }

    private func rememberBigTextScreenSnapshot(_ refreshed: [SCDisplay]) {
        let frames = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.displayID, $0.frame) })
        var modes: [CGDirectDisplayID: Int32] = [:]
        for display in refreshed { modes[display.displayID] = CGDisplayCopyDisplayMode(display.displayID)?.ioDisplayModeID }
        guard modes.count == frames.count else { bigTextScreenSnapshot = nil; return }
        bigTextScreenSnapshot = BigTextScreenSnapshot(frames: frames, modeIDs: modes)
    }

    private var bigTextSessionStreaming: Bool {
      active && sessionState == .picture && connection.connected && connection.media != nil && !phonePause.isPaused &&
        (!liveViewOnly || DeliberateSessionEnd.isEnabled()) && !terminating && !screenLocked
    }

    fileprivate func handleScreenChange() {
        away.end(.screensChanged)
        bigTextScreenSnapshot = nil
        stop()
        invalidateDisplays(status: .notChecked)
        loadDisplays()
    }

    /// SCDisplay frames can lag a mode change; only a list that agrees with CoreGraphics for every
    /// display is used, else stale frames would map clicks to the old size.
    private func verifiedDisplays(including display: CGDirectDisplayID?) async -> [SCDisplay]? {
        let generation = displaySnapshotGeneration
        for attempt in 0..<BigTextRefresh.attempts {
            if attempt > 0 { try? await Task.sleep(for: BigTextRefresh.retryDelay) }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { continue }
            guard generation == displaySnapshotGeneration, !terminating else { return nil }
            let list = content.displays
            guard !list.isEmpty,
                  display.map({ id in list.contains { $0.displayID == id } }) ?? true,
                  list.allSatisfy({ BigTextRefresh.matches(frame: $0.frame, coreGraphicsBounds: CGDisplayBounds($0.displayID)) })
            else { continue }
            return list
        }
        return nil
    }

    /// A restore that ran without pausing the stream (the session ended, or moved to another display)
    /// still resized the desktop: other displays can move, and the next session must not start from
    /// the Big Text frames.
    private func refreshAfterBigTextChange() {
        bigTextRefreshTask?.cancel()
        bigTextRefreshGeneration &+= 1
        let generation = bigTextRefreshGeneration
        bigTextRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let streamed = self.capturedDisplayID
            let before = self.displays.first { $0.displayID == streamed }?.frame
            let refreshed = await self.verifiedDisplays(including: nil)
            guard !Task.isCancelled, generation == self.bigTextRefreshGeneration else { return }
            self.bigTextRefreshTask = nil
            guard !self.terminating, !self.bigText.isChanging else { return }
            guard let refreshed, self.bigText.ownsLiveConfiguration else { return self.handleScreenChange() }
            self.rememberBigTextScreenSnapshot(refreshed)
            self.curtain.refitToScreens()
            guard self.active else { return self.loadDisplays() }
            guard refreshed.contains(where: { $0.displayID == self.selected }) else { return self.handleScreenChange() }
            self.displays = refreshed
            guard let streamed, streamed == self.capturedDisplayID, self.bigTextSessionStreaming,
                  let after = refreshed.first(where: { $0.displayID == streamed })?.frame, after != before
            else { return }
            self.beginCapture(keepingExclusions: self.curtain.phase == .up)
        }
    }
}

#if DEBUG
extension RemoteHostModel {
    /// Observable host state for the E2E harness (HostE2E writes it to host/state.json).
    func e2eSnapshot() -> [String: Any] {
        let display = displays.first { $0.displayID == selected }
        return [
            "status": "\(status)",
            "coordinatorStatus": connection.status,
            "localPairRemovalFailure": connection.pairingRemovalFailure ?? "none",
            "diagnostics": connection.diagnostics,
            "hostRegistered": connection.hostRegistered,
            "connected": connection.connected,
            "awaitingApproval": connection.awaitingApproval,
            "paired": hasPairedPhone,
            "active": active,
            "wantsSharing": wantsSharing,
            "captureHealthy": captureHealthy,
            "sessionMode": sessionState.wireMode,
            "couchHealthy": couchHealthy,
            "allowControl": allowControl,
            "inputEnabled": input.enabled,
            "held": input.held,
            "screenRecording": screenRecordingPermission.isGranted,
            "accessibility": controlPermission.isGranted,
            "displayStatus": "\(displayRefreshStatus)",
            "display": display?.frame as Any,
            "capturedDisplayID": capturedDisplayID.map { Int($0) } as Any,
            "epoch": inputEpoch.value,
            "cursorInVideo": capture.cursorInVideo,
            "appliedQuality": capture.appliedQuality?.rawValue as Any,
            "phonePaused": phonePause.isPaused,
            "displayAsleep": displayAsleep,
            "screenLocked": screenLocked,
            "autoStartSuppressed": autoStart.suppressed,
            "detail": detail as Any,
            "pairingCodeActive": !pairingCode.isEmpty && !pairingExpired,
            "recoveredLaunch": ProcessInfo.processInfo.arguments.contains(WatchdogLaunchArgument.recovered),
            "recoveredFromUnexpectedExit": watchdog?.assessment.recoveredFromUnexpectedExit ?? false,
            "crashLoopStopped": crashLoopStopped,
            "curtainPreference": curtainPreference
        ]
    }
}
#endif

extension RemoteHostModel: AwayModeHost {}
