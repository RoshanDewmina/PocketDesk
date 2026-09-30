import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement
import SystemConfiguration

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
                pointerLocator.reset()
                releaseRemoteInput(notifyPhone: true)
                inputFreshness.expireTokens()
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
    @Published private(set) var active = false
    @Published private(set) var localPairRemovalMessage: String?
    @Published private(set) var wantsSharing: Bool
    @Published private(set) var screenRecordingPermission: HostPermissionStatus = .unchecked
    /// Control's truth is the right to post events; Accessibility (AX) is read only for the focus
    /// features and the curtain. Both are cached and refreshed on timers, never per input event.
    @Published private(set) var inputAccess = HostInputAccess.unchecked
    private var inputAccessCache = HostInputAccessCache(probe: RemoteHostModel.probeInputAccess)
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
    @Published private(set) var displayAsleep = false
    @Published private(set) var openAtLogin = false
    @Published private(set) var chimeOnConnect: Bool
    @Published private(set) var allowFileTransfer: Bool
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
    private lazy var input = RemoteInputDriver(isTrusted: { [unowned self] in self.controlPermission.isGranted })
    private let capture = RemoteCapture()
    /// G12: one per capture session while the ladder switch is on.
    private var loadMonitor: HostLoadMonitor?
    private var vitalsMonitor: MacVitalsMonitor?
    private var phoneLoad: PhoneLoadFeedback?
    private var phoneLoadReceivedAt: TimeInterval?
    private var ladderState: LadderState?
    private var busyState: BusyState?
    private let keepAwake = HostKeepAwake()
    private let remoteAccessAwake = HostKeepAwake(backend: .idleSystem)
    private let displayWake = HostDisplayWake()
    private var screenLocked = false
    private var unavailabilityTeardown: Task<Void, Never>?
    private var timedPauseTask: Task<Void, Never>?
    private let clipboard = HostClipboardService()
    private let fileTransfer = HostFileTransferService()
    private var phonePause = HostPhonePause()
    private var lifecycleTimer: Timer?
    private var permissionTimer: Timer?
    private var inputLease = RemoteInputLease()
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
    private var captureHealthy = false
    private var sessionState: HostSessionState = .picture
    private var couchHealthy = false
    private var lastPhoneHeartbeatAt: TimeInterval?
    private var pendingModeReason: SessionModeRefusal?
    private let couchHUD = CouchHUD()
    private var refusalTeardown: Task<Void, Never>?
    /// Set when displays change during Couch: `displays` could not be reloaded while sharing, so Picture must not use it.
    private var displaysStaleFromCouch = false
    private var pendingPictureRefresh: CouchPictureRefreshTicket?
    private weak var pendingPictureRefreshPeer: PeerMedia?
    private var pictureRefreshTimeout: Task<Void, Never>?
    private var sessionHealthy: Bool {
        switch sessionState {
        case .picture: captureHealthy
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
    private var terminating = false

    var allowControl: Bool { controlConsent.isAllowed }
    var controlPermission: HostPermissionStatus { inputAccess.postEvents }

    nonisolated static func probeInputAccess() -> HostInputAccess {
        HostInputAccess(postEvents: CGPreflightPostEventAccess() ? .granted : .denied,
                        accessibility: AXIsProcessTrusted() ? .granted : .denied)
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
    /// Setup opens by itself at launch unless only pairing is left and the person chose to do it later.
    var presentsSetupAtLaunch: Bool { needsSetup && !(setupStep == .pairPhone && pairingDeferred) }

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
            controlEffective: allowControl && controlPermission.isGranted && sessionHealthy,
            unavailable: autoStart.suppressed,
            displayStatus: displayRefreshStatus
        ))
    }

    var pairingState: HostPairingState {
        if connection.awaitingApproval { return .awaitingApproval }
        if !pairingCode.isEmpty, connection.hostPair?.paired == false, let pairingExpires {
            return pairingExpired ? .expired : .showingCode(pairingCode, expires: pairingExpires)
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
            canBeginPairing: canPair && serviceAddress != nil && !serverRemovalPending,
            allowControl: allowControl,
            keepAwake: keepAwakeEnabled,
            openAtLogin: openAtLogin,
            chimeOnConnect: chimeOnConnect,
            allowFileTransfer: allowFileTransfer,
            pausedUntil: timedPause.resumesAt,
            session: status.isSessionLive ? HostSessionReadout.parse(connection.diagnostics) : nil,
            sessionStartedAt: status.isSessionLive ? sessionStartedAt : nil,
            phoneName: PhoneDisplayName.display(connection.peerName),
            availability: availabilityNote,
            loginItem: loginItemState,
            automaticRecovery: recoveryState,
            privacyCurtain: curtainPreference,
            curtainStatus: Self.curtainStatus(curtainState, displays: NSScreen.screens.count),
            couchMode: sessionState == .couch && connection.connected,
            agentAlerts: agentAlerts.isOn,
            agentAlertsStatus: agentAlerts.statusLine(),
            newestFrameWins: NewestFrameWinsSwitch.isOn,
            crashLoopStopped: crashLoopStopped,
            displays: displays.map { HostDisplayOption(id: $0.displayID, name: Self.displayName(for: $0.displayID)) },
            selectedDisplayID: selected,
            detail: detail,
            pairingDeferred: pairingDeferred,
            serverRemovalBusy: serverRemovalBusy,
            serverRemovalPending: serverRemovalPending,
            serverRemovalMessage: serverRemovalMessage,
            localPairRemovalMessage: localPairRemovalMessage,
            menuBarIconShown: menuBarIconShown,
            permissionsTurnedOffByUpdate: permissionsTurnedOffByUpdate
        )
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

    init() {
        controlConsent = HostControlConsentState(isAllowed: preferences.allowControl)
        keepAwakeEnabled = preferences.keepAwake
        chimeOnConnect = preferences.chimeOnConnect
        allowFileTransfer = preferences.allowFileTransfer
        wantsSharing = preferences.sharingEnabled
        accessibilitySkipped = preferences.accessibilitySkipped
        pairingDeferred = preferences.pairingDeferred
        curtainPreference = preferences.privacyCurtain
        menuBarIconShown = preferences.menuBarIconShown
        loadPendingServerRemoval()
        refreshBackgroundStates()
        background.onChange = { [weak self] in self?.refreshBackgroundStates() }
        NativeCodecCapability.warmUp()
        startWatchdog()
        browserSession.canAcquire = { [weak self] in guard let self else { return false }; return !self.active && !self.connection.connected }
        connection.restore()
        connection.startAllowed = { [weak self] in self?.serverRemovalPending == false }
        connection.shareBlocker = { [weak self] in
            MacShareBlocker.current(screenRecordingGranted: CGPreflightScreenCaptureAccess(),
                                    captureApprovalPending: self?.captureApproval.isPending == true)
        }
        connection.onAuthenticated = { [weak self] in self?.phoneConnected() }
        connection.onEnded = { [weak self] in
            self?.endCapture()
            self?.reconcileAvailabilityAfterCoordinatorReset()
        }
        connection.onControl = { [weak self] data in self?.receive(data) }
        clipboard.transport = { [weak self] frame in
            guard let self, self.connection.connected else { return false }
            return self.connection.sendControl(RemoteAction(action: "clipboard", epoch: self.inputEpoch.value, clipboard: frame))
        }
        clipboard.bufferedAmount = { [weak self] in self?.connection.media?.controlBufferedAmount }
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
        capture.onFailure = { [weak self] error in self?.captureFailed(error) }
        capture.onHealth = { [weak self] healthy in self?.captureHealthChanged(healthy) }
        capture.onExclusionLost = { [weak self] in
            guard let self, self.curtain.phase != .down else { return }
            self.curtain.lift()
            self.reconcileCurtain()
        }
        curtain.onLocalLift = { [weak self] in self?.curtainLiftedLocally() }
        curtain.onPhaseChange = { [weak self] _ in self?.reconcileCurtain() }
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
                Task { @MainActor in self?.handleAvailability(event) }
            })
        }
        for (name, event) in [(HostScreenLock.locked, HostSleepPolicy.Event.screenLocked),
                              (HostScreenLock.unlocked, HostSleepPolicy.Event.screenUnlocked)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleAvailability(event) }
            })
        }
        if HostScreenLock.isLocked() { handleAvailability(.screenLocked) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.sessionState == .couch && self.connection.connected {
                    self.displaysStaleFromCouch = true
                    self.releaseRemoteInput(notifyPhone: true)
                    let rects = HostCouchDisplays.current()
                    guard !rects.isEmpty else { self.stop(); return }
                    self.input.configure(displays: rects)
                    return
                }
                self.stop()
                self.invalidateDisplays(status: .notChecked)
                self.loadDisplays()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.captureApproval.checkSoon(at: ProcessInfo.processInfo.systemUptime)
                self.pollPermissions()
            }
        })
        screenRecordingPermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        inputAccess = inputAccessCache.current
        evaluateUpgradeRegrant()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
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

    func stopSharing() {
        cancelTimedPause()
        wantsSharing = false
        preferences.sharingEnabled = false
        events.record(.sharing, "Stop Sharing")
        stop()
        if !hasPairedPhone { clearPairingCode() }
    }

    func resumeSharing() {
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

    func setAllowFileTransfer(_ enabled: Bool) {
        allowFileTransfer = enabled
        preferences.allowFileTransfer = enabled
        if !enabled { fileTransfer.revoke() }
    }

    /// File transfer needs this Mac's setting and a current, unpaused session. It does not need control:
    /// the setting is the owner's permission, and files only land in Downloads › Farside, never opened.
    private var fileTransferRefusal: FileTransferStatus? {
        guard allowFileTransfer else { return .disabled }
        guard connection.connected, active, !phonePause.isPaused else { return .notAllowed }
        return nil
    }

    private func wireFileTransfer() {
        let engine = fileTransfer.engine
        engine.sendControl = { [weak self] frame in
            guard let self, self.connection.connected else { return false }
            return self.connection.sendControl(RemoteAction(action: "file", epoch: self.inputEpoch.value, file: frame))
        }
        engine.link = { [weak self] in self?.connection.media }
        engine.isRelayed = { [weak self] in self?.connection.media?.isRelayRoute ?? false }
        fileTransfer.refusal = { [weak self] in self?.fileTransferRefusal ?? .notAllowed }
        connection.fileTransfer = engine
    }

    func setChimeOnConnect(_ enabled: Bool) {
        chimeOnConnect = enabled
        preferences.chimeOnConnect = enabled
    }

    private func phoneConnected() {
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
        guard id != selected, displays.contains(where: { $0.displayID == id }) else { return }
        let wasActive = active
        if wasActive { stop() }
        selected = id
        if wasActive { reconcileSharing() }
    }

    func setControl(_ enabled: Bool) {
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

    func setAutomaticRecovery(_ enabled: Bool) {
        if let problem = background.setRecovery(enabled, setupComplete: setupStep == .done) {
            detail = problem
            events.record(.error, problem)
        }
        events.record(.settings, "Automatic recovery \(enabled ? "on" : "off")")
        hangWatchdog?.update(curtainUp: curtain.phase != .down, recoveryEnabled: recoveryHelperRunning)
        refreshBackgroundStates()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The Mac's "hide screen while sharing" preference; the phone changes the same preference.
    func setPrivacyCurtain(_ enabled: Bool) {
        curtainPreference = enabled
        preferences.privacyCurtain = enabled
        if enabled {
            curtainLocallyDismissed = false
            curtainRaiseFailed = false
        }
        events.record(.curtain, "Hide screen while sharing \(enabled ? "on" : "off")")
        reconcileCurtain()
    }

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
        snapshot.controlEffective = allowControl && controlPermission.isGranted && sessionHealthy
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
        openAtLogin = loginItemState.isRegistered
        hangWatchdog?.update(curtainUp: curtain.phase != .down, recoveryEnabled: recoveryHelperRunning)
    }

    /// Launch at login and automatic recovery turn on once setup is complete; later choices stick.
    private func applyBackgroundDefaults() {
        if let problem = background.applyDefaults(setupComplete: true) { events.record(.error, problem) }
        refreshBackgroundStates()
        hangWatchdog?.update(curtainUp: curtain.phase != .down, recoveryEnabled: recoveryHelperRunning)
    }

    // MARK: Watchdog and recovery

    private func startWatchdog() {
        let hang = HostHangWatchdog(onHang: watchdog.map {
            HostWatchdogReporter.hangHandler(files: $0.files, launchID: $0.record.launchID)
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

    private static let crashLoopDetail = "Farside stopped after repeated crashes. Sharing is paused until you resume it."
    /// A recovery notice is still worth telling a phone that connects within this window.
    private static let recoveryNoticeLifetime: TimeInterval = 60 * 60

    private var recoveryEventForPhone: String? {
        guard recoveryNoticePending,
              Date().timeIntervalSince(watchdog?.launchedAt ?? .distantPast) < Self.recoveryNoticeLifetime
        else { return nil }
        return HostLifecycleEvent.recovered.rawValue
    }

    // MARK: Privacy curtain

    private func reconcileCurtain() {
        let now = ProcessInfo.processInfo.systemUptime
        let inputs = PrivacyCurtainInputs(
            preference: curtainPreference,
            sessionLive: active && connection.connected && !terminating,
            captureHealthy: captureHealthy,
            unhealthyFor: captureUnhealthySince.map { now - $0 } ?? 0,
            displayAsleep: displayAsleep,
            phonePaused: phonePause.isPaused,
            screenLocked: screenLocked,
            accessibilityGranted: inputAccess.accessibility.isGranted,
            locallyDismissed: curtainLocallyDismissed,
            raiseFailed: curtainRaiseFailed,
            safeMode: crashLoopStopped
        )
        switch PrivacyCurtainPolicy.desired(inputs, currentlyUp: curtain.phase != .down) {
        case .up where curtain.phase == .down && !curtainRaising:
            raiseCurtain()
        case .down where curtain.phase != .down:
            curtain.lift()
        default:
            break
        }
        let covering = curtain.phase != .down
        watchdog?.setCurtainUp(covering)
        hangWatchdog?.update(curtainUp: covering, recoveryEnabled: recoveryHelperRunning)
        let state = PrivacyCurtainPolicy.protocolState(inputs, up: curtain.phase == .up)
        if state != curtainState {
            curtainState = state
            sendCaptureHealth(sessionHealthy)
        }
    }

    private func raiseCurtain() {
        curtainRaising = true
        let hooks = PrivacyCurtainController.CaptureHooks(
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
                self.curtainRaiseFailed = true
                self.events.record(.error, "Privacy curtain stayed down: \(result)")
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
        if curtain.phase != .down { curtain.lift() }
        watchdog?.setCurtainUp(false)
        hangWatchdog?.update(curtainUp: false, recoveryEnabled: recoveryHelperRunning)
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
    }

    func stopForTermination() {
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
        let screen: HostPermissionStatus = CGPreflightScreenCaptureAccess() ? .granted : .denied
        let screenChanged = screen != screenRecordingPermission
        if screenChanged {
            screenRecordingPermission = screen
            if screen.isGranted {
                // A fresh grant is itself the approval macOS was waiting for.
                clearCaptureApproval()
                loadDisplays()
            } else {
                if sessionState == .couch {
                    cancelPictureRefresh()
                    invalidateDisplays(status: .permissionDenied)
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
        let effective = allowControl && controlPermission.isGranted
        if !effective || !inputAccess.accessibility.isGranted { invalidateTextFocus() }
        if sessionState == .couch { refreshCouchHealth() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: controlPermission,
            session: sessionState,
            captureHealthy: captureHealthy,
            couchHealthy: couchHealthy
        )
        if !effective {
            releaseRemoteInput(notifyPhone: notifyPhone)
            clipboard.reset()
        }
        if notifyPhone, connection.connected {
            _ = connection.sendControl(RemoteAction(action: "viewing", x: effective ? 1 : 0, epoch: inputEpoch.value))
        }
        reconcileCurtain()
    }

    // MARK: Capture session

    private func beginCapture() {
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
        guard let display = displays.first(where: { $0.displayID == selected }), let peer = connection.media else { stop(); return }
        if HostScreenLock.isLocked() { handleAvailability(.screenLocked); return }
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
            sessionsThisLaunch += 1
            events.record(.session, "Phone connected")
        }
        captureUnhealthySince = nil
        peer.onSenderStatistics = { [weak self, weak peer] report in
            self?.latestSenderStatistics = report
            if let peer { self?.observeLoad(report, peer: peer) }
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
        capturedDisplayID = display.displayID
        pointerLocator.reset()
        captureTask?.cancel()
        releaseRemoteInput(notifyPhone: true)
        sessionState = .picture
        couchHealthy = false
        inputLease.changeDuration(to: RemoteInputLease.pictureDuration, at: ProcessInfo.processInfo.systemUptime)
        couchHUD.hide()
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        captureHealthy = false
        input.enabled = false
        advanceEpoch()
        pointerTelemetry.begin(displayFrame: display.frame, epoch: inputEpoch.value)

        startLifecycleTimer()

        let logicalSize = display.frame.size
        let preflight = [
            RemoteAction(action: "geometry", x: logicalSize.width, y: logicalSize.height, epoch: inputEpoch.value),
            RemoteAction(action: "viewing", x: allowControl && controlPermission.isGranted ? 1 : 0, epoch: inputEpoch.value),
            RemoteAction(action: "capture", x: 0, epoch: inputEpoch.value)
        ]
        guard CaptureStartPreflight.send(
            preflight,
            whileCurrent: { [weak self] in self?.captureStartIsCurrent(attempt, peer: peer) == true },
            using: { [weak self] action in self?.connection.sendControl(action) == true }
        ) else { return }

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.captureStartIsCurrent(attempt, peer: peer), !Task.isCancelled else { return }
                let owner = try await self.capture.start(display: display, peer: peer)
                guard self.captureStartIsCurrent(attempt, peer: peer), !Task.isCancelled else {
                    _ = self.capture.stop(ifOwnedBy: owner)
                    return
                }
                self.beginLoadMonitor(peer: peer)
            } catch is CancellationError {
                return
            } catch {
                guard self.captureAttempt == attempt else { return }
                self.events.record(.error, "Capture could not start (\(Self.captureErrorCode(error)))")
                if CaptureStopReason.classify(error) == .needsApproval {
                    self.captureNeedsApproval()
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
        let lifecycleTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phonePause.isPaused {
                    if self.phonePause.isExpired(at: ProcessInfo.processInfo.systemUptime) { self.expirePhonePause() }
                    return
                }
                self.input.expireMomentum()
                if self.inputLease.isExpired(at: ProcessInfo.processInfo.systemUptime) {
                    let releasedHold = self.input.externalHoldID
                    let releaseEpoch = self.inputEpoch.value
                    if !self.input.held || self.input.release() {
                        self.inputLease.cancel()
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
    private func beginCouch() {
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
        _ = capture.stop()
        phonePause.clear()
        capturedDisplayID = nil
        pointerLocator.reset()
        releaseRemoteInput(notifyPhone: true)
        let rects = HostCouchDisplays.current()
        guard let main = rects.first else { stop(); return }
        input.configure(displays: rects)
        inputLease.changeDuration(to: RemoteInputLease.couchDuration, at: ProcessInfo.processInfo.systemUptime)
        captureHealthy = false
        couchHealthy = false
        input.enabled = false
        sessionState = .couch
        advanceEpoch()
        pointerTelemetry.begin(displayFrame: main, epoch: inputEpoch.value)
        startLifecycleTimer()
        _ = connection.sendControl(RemoteAction(action: "geometry", x: main.width, y: main.height, epoch: inputEpoch.value))
        _ = connection.sendControl(RemoteAction(action: "viewing", x: allowControl && controlPermission.isGranted ? 1 : 0,
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
                             allowControl: allowControl, accessibility: controlPermission)
    }

    private var couchHealthInputs: CouchHealthInputs {
        let now = ProcessInfo.processInfo.systemUptime
        return CouchHealthInputs(
            routeLocal: connection.routeIsLocal, provenLinkActive: connection.provenLocalLinkActive,
            heartbeatAge: lastPhoneHeartbeatAt.map { now - $0 },
            screenLocked: screenLocked || HostScreenLock.isLocked(), consoleUserActive: Self.consoleUserActive(),
            allowControl: allowControl, accessibility: controlPermission, phonePaused: phonePause.isPaused)
    }

    /// Returns the fresh value; on a healthy → unhealthy edge input stops and tokens expire at once.
    @discardableResult
    private func refreshCouchHealth() -> Bool {
        guard sessionState == .couch else { couchHealthy = false; return false }
        // A pending sleep/lock/user-switch teardown must not be re-admitted by the next tick before it stops the session.
        let healthy = unavailabilityTeardown == nil && CouchHealth.isHealthy(couchHealthInputs)
        if couchHealthy && !healthy {
            invalidateTextFocus()
            releaseRemoteInput(notifyPhone: true)
            inputFreshness.expireTokens()
        }
        couchHealthy = healthy
        input.enabled = HostControlPolicy.isEnabled(userConsent: allowControl, accessibilityPermission: controlPermission,
                                                    session: sessionState, captureHealthy: captureHealthy, couchHealthy: healthy)
        return healthy
    }

    private static func consoleUserActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? false
    }

    private func endCapture() {
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
        clipboard.reset()
        fileTransfer.reset()
        releaseRemoteInput(notifyPhone: false)
        inputFreshness.invalidate()
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

    private func receive(_ data: Data) {
        guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else {
            countInput("rejected-parse"); stop(); return
        }
        countInput("received")
        if action.action == "release" || Self.userInputActions.contains(action.action) {
            invalidateTextFocus()
        }
        if action.action == "release" {
            if inputFreshness.acceptsRelease(
                action, epoch: inputEpoch.value, activeHold: input.externalHoldID
            ) {
                releaseRemoteInput(notifyPhone: false)
            }
            return
        }
        if action.action == "heartbeat" {
            lastPhoneHeartbeatAt = ProcessInfo.processInfo.systemUptime
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, let quality = action.streamQuality {
                capture.setQuality(quality)
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, let pixels = action.screenPixels {
                capture.setClientPixels(pixels)
            }
            if connection.connected, sessionState == .picture, action.epoch == inputEpoch.value, StreamTuning.current.viewportCapture {
                // A heartbeat without a viewport means the phone can no longer describe its
                // visible area. Return to the whole display instead of retaining an old crop.
                capture.setViewport(action.viewport)
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
            if action.pointerProbe == nil && action.textFocusProbe == nil {
                pointerTelemetry.phoneHeartbeat(action.pointerSync, epoch: action.epoch,
                                                at: ProcessInfo.processInfo.systemUptime)
            }
            receivePointerProbe(action)
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
                stop()
                autoStart.suspend()
                detail = "The phone sent input from an old session. Reconnect from the phone."
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
            stop()
            autoStart.suspend()
            detail = "The phone’s input session expired. Reconnect from the phone."
            return
        }
        if inputLease.isExpired(at: now) {
            countInput("rejected-lease-expired")
            releaseRemoteInput(notifyPhone: true)
            if action.action == "text" { sendTextResult(for: action.key, accepted: false) }
            return
        }

        if sessionState == .couch { refreshCouchHealth() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: controlPermission,
            session: sessionState,
            captureHealthy: captureHealthy,
            couchHealthy: couchHealthy
        )
        #if DEBUG
        // E2E harness interlock: injected input may only reach the Farside Test Pad.
        var fenced: RemoteAction? = action
        var fenceVerdict = "allow"
        var pointerSnapshot: CGPoint?
        if let e2e = HostE2E.active {
            pointerSnapshot = input.nextPointerBase(now: now)
            (fenced, fenceVerdict) = e2e.fence(action, held: input.held, pointer: pointerSnapshot)
        }
        if action.action == "key", action.key == "c", action.modifiers == ["command"], input.enabled, fenced != nil {
            clipboard.prepareForCopyShortcut()
        }
        let outcome = fenced.map { input.handle($0, upgraded: admission == .upgraded, now: now, pointerSnapshot: pointerSnapshot) }
            ?? RemoteInputOutcome(textRequestID: action.action == "text" ? action.key : nil)
        HostE2E.active?.recordInput(action, accepted: outcome.accepted, fence: fenceVerdict, clickPoint: outcome.clickPoint)
        #else
        if action.action == "key", action.key == "c", action.modifiers == ["command"], input.enabled {
            clipboard.prepareForCopyShortcut()
        }
        let outcome = input.handle(action, upgraded: admission == .upgraded, now: now)
        #endif
        countInput(outcome.accepted ? "posted" : (input.enabled ? "refused-by-driver" : "refused-control-disabled"))
        if outcome.accepted { activity.record(action: action.action) }
        if action.action == "move" || action.action == "moveTo", outcome.accepted {
            pointerTelemetry.moveInjected(globalPoint: input.lastPoint, at: now)
        }
        if admission == .upgraded, action.action == "dragDown", !outcome.accepted,
           let notice = inputFreshness.rejectedDragDownNotice(
                action, activeHold: input.externalHoldID
           ) {
            _ = connection.sendControl(notice)
        }
        inputLease.record(action: action.action, accepted: outcome.accepted, at: now)
        if outcome.holdEvent == .ended { inputLease.cancel() }
        if admission == .upgraded, outcome.accepted,
           (action.action == "click" || action.action == "double"),
           HostTextFocusProbe.isValidID(action.textFocusProbe),
           let probe = action.textFocusProbe, let point = outcome.clickPoint {
            scheduleTextFocusProbe(probe, point: point, geometry: action.textFocusGeometry == true, issuedAt: now)
        } else if admission == .upgraded, outcome.accepted, action.action == "text" || action.action == "key",
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
        guard let peer = connection.media else { return }
        let ticket = HostTextFocusTicket(epoch: inputEpoch.value,
                                         revision: textFocusRevision, issuedAt: issuedAt)
        let displayFrame = geometry ? input.displayBounds : nil
        textFocusTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.textFocusIsCurrent(ticket, peer: peer), !Task.isCancelled else { return }
            let focus = await HostTextFocusProbe.focus(at: point, geometry: displayFrame != nil)
            let secure = await HostSecureFocus.isSecureNow()
            guard self.textFocusIsCurrent(ticket, peer: peer), !Task.isCancelled,
                  displayFrame == nil || self.input.displayBounds == displayFrame else { return }
            let rect = focus.editable ? focus.frame.flatMap { field in
                displayFrame.flatMap { FocusGeometry.make(field: field, anchor: focus.anchor,
                                                          displayFrame: $0, geometrySize: $0.size) }
            } : nil
            _ = self.connection.sendControl(RemoteAction(
                action: "heartbeat", epoch: ticket.epoch,
                textFocusProbe: probe, textFocusEditable: focus.editable, textFocusSecure: secure, textFocusRect: rect
            ))
        }
    }

    private func textFocusIsCurrent(_ ticket: HostTextFocusTicket, peer: PeerMedia) -> Bool {
        ticket.isCurrent(epoch: inputEpoch.value, revision: textFocusRevision,
                         now: ProcessInfo.processInfo.systemUptime,
                         active: active && !terminating,
                         connected: connection.connected && connection.media === peer,
                         controlEnabled: allowControl && input.enabled && inputAccess.accessibility.isGranted,
                         captureHealthy: sessionHealthy)
    }

    private func invalidateTextFocus() {
        textFocusRevision &+= 1
        textFocusTask?.cancel()
        textFocusTask = nil
    }

    private func captureHealthChanged(_ healthy: Bool) {
        guard sessionState == .picture else { return }
        // The capture reports every 0.4 s; the 4 Hz lifecycle timer already re-checks Accessibility,
        // reconciles the curtain and sends capture status, so only a change needs handling here.
        if healthy == captureHealthy && (healthy || captureUnhealthySince != nil) { return }
        if captureHealthy && !healthy {
            invalidateTextFocus()
            releaseRemoteInput(notifyPhone: true)
            inputFreshness.expireTokens()
        }
        if healthy {
            captureUnhealthySince = nil
        } else if captureUnhealthySince == nil {
            captureUnhealthySince = ProcessInfo.processInfo.systemUptime
        }
        captureHealthy = healthy
        defer { reconcileCurtain() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: controlPermission,
            session: sessionState,
            captureHealthy: healthy,
            couchHealthy: couchHealthy
        )
        sendCaptureHealth(healthy)
    }

    private func receivePointerProbe(_ action: RemoteAction) {
        guard let probe = action.pointerProbe,
              (try? action.validate()) != nil,
              connection.connected, active, captureHealthy,
              action.epoch == inputEpoch.value,
              let display = displays.first(where: {
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
        loadMonitor = StreamTuning.current.ladder ? HostLoadMonitor(targetFPS: peer.targetFPS) : nil
        vitalsMonitor?.stop()
        let vitals = MacVitalsMonitor(sources: LiveMacVitalsSources())
        vitals.start(now: ProcessInfo.processInfo.systemUptime)
        vitalsMonitor = vitals
    }

    private func endLoadMonitor() {
        phoneLoad = nil
        phoneLoadReceivedAt = nil
        loadMonitor = nil
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
        let change = monitor.tick(sample: sampleWithPhone, at: process.systemUptime)
        loadMonitor = monitor
        if let ladder = change.ladder {
            ladderState = ladder
            capture.setLadder(ladder)
            connection.media?.applyLadder(ladder)
            events.record(.session, "Ladder rung \(ladder.rung): \(ladder.fps) fps × \(ladder.sizeFraction) (\(ladder.reason ?? "headroom"))")
        }
        if let busy = change.busy {
            busyState = busy
            connection.media?.busyState = busy
        }
        if change.ladder != nil || change.busy != nil { sendCaptureHealth(sessionHealthy) }
    }

    /// A switched-off experiment is not advertised, so the phone never sends what the host would ignore.
    private static var advertisedFeatures: [String] {
        let tuning = StreamTuning.current
        return SessionFeature.host.filter {
            ($0 != SessionFeature.viewportCapture || tuning.viewportCapture) && ($0 != SessionFeature.ladder || tuning.ladder)
        } + [SessionFeature.couch]
    }

    private func sendCaptureHealth(_ requestedHealthy: Bool, presence: HostPresence? = nil) {
        guard connection.connected else { return }
        // A caller's Couch flag can be up to one tick old; a token must reflect health at this moment.
        let healthy = sessionState == .couch ? requestedHealthy && refreshCouchHealth() : requestedHealthy
        let features = connection.peerFeatures
        let state = MacShareBlocker.sessionState(
            presence: presence ?? (displayAsleep ? .displayAsleep : nil),
            phoneUnderstands: features.contains(MacShareBlocker.feature) || features.contains(MacShareBlocker.approvalFeature),
            controlAllowed: allowControl, accessibilityGranted: controlPermission.isGranted,
            captureApprovalPending: sessionState == .picture && captureApproval.isPending,
            phoneUnderstandsApproval: features.contains(MacShareBlocker.approvalFeature))
        let capability = sessionState.issuesTokens(healthy: healthy) ? inputFreshness.capability(
            epoch: inputEpoch.value,
            now: ProcessInfo.processInfo.systemUptime,
            doubleClickInterval: min(2, max(0.1, NSEvent.doubleClickInterval))
        ) : nil
        let event = recoveryEventForPhone
        let alert = agentAlertOutbox.first
        let sent = connection.sendControl(RemoteAction(
            action: "capture", x: healthy ? 1 : 0, epoch: inputEpoch.value,
            interaction: capability, pointerLocatorSupported: true,
            pointerSync: PointerSync(videoCursor: capture.cursorInVideo), streamQuality: capture.appliedQuality,
            features: Self.advertisedFeatures, hostState: state,
            hostStream: connection.media?.takeHostSummary(),
            curtain: curtainState.rawValue, hostEvent: event,
            display: capturedDisplayID, agentAlert: alert,
            captureRegion: capture.appliedCaptureRegion, ladder: ladderState, busy: busyState,
            macVitals: vitalsMonitor?.current(now: ProcessInfo.processInfo.systemUptime),
            mode: sessionState.wireMode, modeReason: pendingModeReason?.rawValue ?? sessionState.wireReason
        ))
        if sent && event != nil { recoveryNoticeDelivered = true }
        if sent && alert != nil { agentAlertOutbox.removeFirst() }
        if sent { pendingModeReason = nil }
    }

    // MARK: Session mode

    private func receiveModeRequest(_ action: RemoteAction) {
        guard connection.connected, active, action.epoch == inputEpoch.value, !phonePause.isPaused,
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
        let current = connection.connected && active && action.epoch == inputEpoch.value && !sessionRefused
        let controlEffective = allowControl && controlPermission.isGranted
        switch action.action {
        case "wake":
            if current && controlEffective && !phonePause.isPaused { wakeDisplayForRemoteSession(force: true) }
        case "pause":
            if current { pauseForPhoneBackground() }
        case "resume":
            if current { resumeAfterPhoneBackground() }
        case "clipboard":
            guard let frame = action.clipboard else { return }
            clipboard.receive(frame, allowed: current && !phonePause.isPaused && controlEffective)
        case "file":
            if let frame = action.file { fileTransfer.receive(frame) }
        case "curtain":
            guard sessionState == .picture else {
                sendCaptureHealth(sessionHealthy)
                return
            }
            // Covering the Mac's own screen needs the same authority as controlling it.
            guard current, controlEffective, !phonePause.isPaused,
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
        guard connection.connected, active, action.epoch == inputEpoch.value, !phonePause.isPaused, !sessionRefused else { return }
        switch action.action {
        case "displays":
            sendDisplayList()
        case "display":
            guard sessionState == .picture else { sendDisplayList(); return }
            guard let requested = action.display else { return }
            let decision = HostDisplayCatalog.decide(
                requested: requested, available: displays.map(\.displayID), streaming: capturedDisplayID,
                controlEffective: allowControl && controlPermission.isGranted)
            switch decision {
            case .resendList:
                sendDisplayList()
            case .switchTo(let id):
                events.record(.sharing, "Phone switched the shared display to \(Self.displayName(for: id))")
                switchSessionDisplay(to: id)
            }
        default:
            break
        }
    }

    /// The phone chose another display: stream it in the same session. A new epoch and geometry
    /// follow, so input meant for the old display can never land on the new one.
    private func switchSessionDisplay(to id: CGDirectDisplayID) {
        liftCurtain()
        selected = id
        beginCapture()
        sendDisplayList()
    }

    private func sendDisplayList() {
        guard connection.connected else { return }
        let entries = displays.map { display in
            HostDisplayCatalog.Display(
                id: display.displayID, name: Self.displayName(for: display.displayID),
                width: Double(display.frame.width), height: Double(display.frame.height),
                pixelWidth: CGDisplayCopyDisplayMode(display.displayID).map { $0.pixelWidth },
                pixelHeight: CGDisplayCopyDisplayMode(display.displayID).map { $0.pixelHeight },
                main: display.displayID == CGMainDisplayID())
        }
        _ = connection.sendControl(RemoteAction(action: "displays", epoch: inputEpoch.value,
                                                displays: HostDisplayCatalog.descriptors(entries),
                                                display: capturedDisplayID))
    }

    /// The phone is backgrounding: stop capture and input now, but keep the peer and its
    /// session slot so a quick return resumes without renegotiation.
    private func pauseForPhoneBackground() {
        cancelPictureRefresh()
        guard !phonePause.isPaused else { return }
        liftCurtain()
        phonePause.begin(at: ProcessInfo.processInfo.systemUptime)
        clipboard.reset()
        fileTransfer.reset()
        invalidateTextFocus()
        releaseRemoteInput(notifyPhone: false)
        inputFreshness.expireTokens()
        input.enabled = false
        captureHealthy = false
        capturedDisplayID = nil
        pointerLocator.reset()
        pointerTelemetry.end()
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
        _ = capture.stop()
        couchHealthy = false
        updatePowerAssertions()
        reconcileCurtain()
    }

    /// A fresh epoch, geometry and capture follow, so no pre-background input can apply.
    private func resumeAfterPhoneBackground() {
        guard phonePause.isPaused else { return }
        phonePause.clear()
        if sessionState == .couch { beginCouch() } else { beginCapture() }
    }

    private func expirePhonePause() {
        phonePause.clear()
        connection.dropPeerSession()
    }

    // MARK: Sleep, lock and display availability

    private func handleAvailability(_ event: HostSleepPolicy.Event) {
        switch HostSleepPolicy.response(to: event) {
        case .tearDown(let presence):
            if presence == .locked {
                guard !screenLocked else { return }
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
            if event == .screenUnlocked {
                guard screenLocked else { return }
                screenLocked = false
            }
            connection.checkSignalingLiveness()
            if HostScreenLock.isLocked() { screenLocked = true; return }
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
        releaseRemoteInput(notifyPhone: true)
        inputFreshness.expireTokens()
        input.enabled = false
        captureHealthy = false
        couchHealthy = false
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        endLoadMonitor()
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
        let wanted = HostPowerPolicy.assertions(keepAwake: keepAwakeEnabled, sharing: active,
                                                phoneConnected: connection.connected && !phonePause.isPaused)
        if wanted.system {
            if !remoteAccessAwake.start() { detail = "Farside couldn’t keep this Mac awake. Normal sleep settings still apply." }
        } else {
            _ = remoteAccessAwake.stop()
        }
        if wanted.display { _ = keepAwake.start() } else { _ = keepAwake.stop() }
        keepAwakeActive = remoteAccessAwake.isActive
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
        let releasedHold = input.externalHoldID
        let releaseEpoch = inputEpoch.value
        guard let holdID = input.holdID else {
            inputLease.cancel()
            if notifyPhone { sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch) }
            return
        }
        if input.release() {
            inputLease.cancel()
            if notifyPhone { sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch) }
        } else if !terminating {
            retryRelease(
                holdID: holdID, releasedHold: releasedHold, epoch: releaseEpoch,
                notifyPhone: notifyPhone, remaining: 8
            )
        }
    }

    private func releaseRemoteInputSynchronously() {
        let releasedHold = input.externalHoldID
        let releaseEpoch = inputEpoch.value
        if input.held {
            for _ in 0..<8 {
                if input.release() { break }
            }
        }
        inputLease.cancel()
        sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch)
    }

    private func retryRelease(
        holdID: UInt64, releasedHold: String?, epoch: UInt64,
        notifyPhone: Bool, remaining: Int
    ) {
        guard remaining > 0, !terminating else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, !self.terminating, self.input.holdID == holdID else { return }
            if self.input.release() {
                self.inputLease.cancel()
                if notifyPhone { self.sendReleaseNotice(releasedHold: releasedHold, epoch: epoch) }
            } else {
                self.retryRelease(
                    holdID: holdID, releasedHold: releasedHold, epoch: epoch,
                    notifyPhone: notifyPhone, remaining: remaining - 1
                )
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
        invalidateTextFocus()
        inputEpoch.beginSession()
        inputFreshness.expireTokens()
        input.resetNativeSequence()
    }

    private func releaseKeepAwake() {
        _ = keepAwake.stop()
        _ = remoteAccessAwake.stop()
        keepAwakeActive = remoteAccessAwake.isActive
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
