import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement

@MainActor
final class RemoteHostModel: ObservableObject {
    #if DEBUG
    // E2E mode swaps in isolated trust and preferences; see HostE2E.swift.
    let connection = RemoteCoordinator(isHost: true, store: HostE2E.active?.pairStore)
    #else
    let connection = RemoteCoordinator(isHost: true)
    #endif
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
    @Published private(set) var active = false
    @Published private(set) var wantsSharing: Bool
    @Published private(set) var screenRecordingPermission: HostPermissionStatus = .unchecked
    @Published private(set) var accessibilityPermission: HostPermissionStatus = .unchecked
    @Published private(set) var screenRecordingSettingsOpened = false
    @Published private(set) var accessibilitySettingsOpened = false
    @Published private(set) var accessibilitySkipped: Bool
    @Published private(set) var displayRefreshStatus: HostDisplayRefreshStatus = .notChecked
    @Published private(set) var keepAwakeEnabled: Bool
    @Published private(set) var keepAwakeActive = false
    @Published private(set) var displayAsleep = false
    @Published private(set) var openAtLogin = false
    @Published private(set) var chimeOnConnect: Bool
    @Published private(set) var timedPause = HostTimedPause()
    @Published private(set) var unavailableReason: HostAvailabilityNote?
    @Published private(set) var loginItemState: HostBackgroundItemState = .off
    @Published private(set) var recoveryState: HostBackgroundItemState = .off
    @Published private(set) var curtainPreference: Bool
    @Published private(set) var curtainState: PrivacyCurtainState = .off
    @Published private(set) var crashLoopStopped = false
    @Published private var autoStart = HostAutoStartGate()
    let events = HostEventLog()
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
    /// Set when this launch followed an unexpected exit; told to the first phone that connects.
    private var recoveryNoticePending = false
    private var recoveryNoticeDelivered = false
    private var setupWasComplete = false
    private var sessionsThisLaunch = 0
    private var sessionStartedAt: Date?
    private var lastSessionDuration: TimeInterval?
    #if DEBUG
    private let preferences = HostPreferences(defaults: HostE2E.active?.defaults ?? .standard)
    #else
    private let preferences = HostPreferences()
    #endif
    private let input = RemoteInputDriver()
    private let capture = RemoteCapture()
    private let keepAwake = HostKeepAwake()
    private let remoteAccessAwake = HostKeepAwake(backend: .idleSystem)
    private let displayWake = HostDisplayWake()
    private var screenLocked = false
    private var unavailabilityTeardown: Task<Void, Never>?
    private var timedPauseTask: Task<Void, Never>?
    private let clipboard = HostClipboardService()
    private var phonePause = HostPhonePause()
    private var lifecycleTimer: Timer?
    private var permissionTimer: Timer?
    private var inputLease = RemoteInputLease()
    private var observers: [NSObjectProtocol] = []
    private var connectionObserver: AnyCancellable?
    private var captureTask: Task<Void, Never>?
    private var captureAttempt: UInt64 = 0
    private var inputEpoch = RemoteInputEpoch()
    private var inputFreshness = NativeInputFreshness()
    private var textFocusRevision: UInt64 = 0
    private var textFocusTask: Task<Void, Never>?
    private var captureHealthy = false
    private var capturedDisplayID: CGDirectDisplayID?
    private var pointerLocator = HostPointerLocator()
    private let pointerTelemetry = HostPointerTelemetry()
    private var displayRefreshTask: Task<Void, Never>?
    private var displayRefreshGeneration = HostPermissionRefreshGeneration()
    private var terminating = false

    var allowControl: Bool { controlConsent.isAllowed }
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

    var setupStep: HostSetupStep {
        .current(
            screenRecording: screenRecordingPermission,
            accessibility: accessibilityPermission,
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
            connected: connection.connected,
            awaitingApproval: connection.awaitingApproval,
            controlEffective: allowControl && accessibilityPermission.isGranted && captureHealthy,
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

    var viewState: HostViewState {
        let status = status
        return HostViewState(
            macName: Host.current().localizedName ?? "this Mac",
            appListName: Self.appListName,
            screenRecording: screenRecordingPermission,
            accessibility: accessibilityPermission,
            screenRecordingSettingsOpened: screenRecordingSettingsOpened,
            accessibilitySettingsOpened: accessibilitySettingsOpened,
            accessibilitySkipped: accessibilitySkipped,
            status: status,
            setupStep: setupStep,
            hasPairedPhone: hasPairedPhone,
            pairingRequested: pairingRequested,
            pairing: pairingState,
            canBeginPairing: canPair && serviceAddress != nil,
            allowControl: allowControl,
            keepAwake: keepAwakeEnabled,
            openAtLogin: openAtLogin,
            chimeOnConnect: chimeOnConnect,
            pausedUntil: timedPause.resumesAt,
            session: status.isSessionLive ? HostSessionReadout.parse(connection.diagnostics) : nil,
            availability: availabilityNote,
            loginItem: loginItemState,
            automaticRecovery: recoveryState,
            privacyCurtain: curtainPreference,
            curtainStatus: Self.curtainStatus(curtainState, displays: NSScreen.screens.count),
            crashLoopStopped: crashLoopStopped,
            displays: displays.map { HostDisplayOption(id: $0.displayID, name: Self.displayName(for: $0.displayID)) },
            selectedDisplayID: selected,
            detail: detail
        )
    }

    private var availabilityNote: HostAvailabilityNote? {
        if screenLocked { return .locked }
        if let unavailableReason { return unavailableReason }
        return displayAsleep && active ? .displayAsleep : nil
    }

    /// The installed bundle keeps its original file name so macOS permission grants survive the
    /// rename; setup mentions it because System Settings may list the app under that name.
    private static let appListName: String = {
        let name = FileManager.default.displayName(atPath: Bundle.main.bundlePath)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }()

    init() {
        controlConsent = HostControlConsentState(isAllowed: preferences.allowControl)
        keepAwakeEnabled = preferences.keepAwake
        chimeOnConnect = preferences.chimeOnConnect
        wantsSharing = preferences.sharingEnabled
        accessibilitySkipped = preferences.accessibilitySkipped
        curtainPreference = preferences.privacyCurtain
        refreshBackgroundStates()
        background.onChange = { [weak self] in self?.refreshBackgroundStates() }
        startWatchdog()
        browserSession.canAcquire = { [weak self] in guard let self else { return false }; return !self.active && !self.connection.connected }
        connection.restore()
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
        connectionObserver = connection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.connectionDidChange() }
        }
        capture.onFailure = { [weak self] in self?.captureFailed() }
        capture.onHealth = { [weak self] healthy in self?.captureHealthChanged(healthy) }
        capture.onExclusionLost = { [weak self] in
            guard let self, self.curtain.phase != .down else { return }
            self.curtain.lift()
            self.reconcileCurtain()
        }
        curtain.onLocalLift = { [weak self] in self?.curtainLiftedLocally() }
        curtain.onPhaseChange = { [weak self] _ in self?.reconcileCurtain() }
        pointerTelemetry.send = { [weak self] action in self?.connection.sendControl(action) ?? false }
        pointerTelemetry.setCaptureShowsCursor = { [weak self] shows in self?.capture.setShowsCursor(shows) }
        pointerTelemetry.captureShowsCursor = { [weak self] in self?.capture.cursorInVideo ?? true }
        capture.onCursorVisibility = { [weak self] shows in
            guard let self else { return }
            self.pointerTelemetry.captureCursorChanged(showsCursor: shows)
            self.sendCaptureHealth(self.captureHealthy)
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
                self.stop()
                self.invalidateDisplays(status: .notChecked)
                self.loadDisplays()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
        })
        screenRecordingPermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        accessibilityPermission = AXIsProcessTrusted() ? .granted : .denied
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
        }
        if screenRecordingPermission.isGranted { loadDisplays() }
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
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        NSWorkspace.shared.open(pane.url)
    }

    func skipAccessibility() {
        accessibilitySkipped = true
        preferences.accessibilitySkipped = true
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
        pairingRequested = true
    }

    func cancelPairing() {
        pairingRequested = false
    }

    func setServiceAddress(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PairInvitation.validServer(trimmed) else { return }
        preferences.serviceAddress = trimmed
        objectWillChange.send()
        beginPairing()
    }

    func beginPairing() {
        guard let serviceAddress else { objectWillChange.send(); return }
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
                    try connection.createPair(server: serviceAddress, name: Host.current().localizedName ?? "My Mac")
                }
            ) else { return }
            preferences.serviceAddress = serviceAddress
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

    func revoke() {
        if browserSession.controller.running { connection.revoke(); clearPairingCode(); return }
        stop()
        connection.revoke()
        clearPairingCode()
        pairingRequested = false
    }

    private func clearPairingCode() {
        pairingCode = ""
        pairingExpires = nil
        pairingExpired = false
    }

    private func connectionDidChange() {
        guard !pairingCode.isEmpty, hasPairedPhone else { return }
        clearPairingCode()
        pairingRequested = false
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

    func setChimeOnConnect(_ enabled: Bool) {
        chimeOnConnect = enabled
        preferences.chimeOnConnect = enabled
    }

    private func phoneConnected() {
        beginCapture()
        guard chimeOnConnect, connection.connected, !terminating else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    private func reconcileSharing() {
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
        snapshot.accessibility = accessibilityPermission.isGranted ? "allowed"
            : (accessibilitySkipped ? "not allowed (skipped in setup)" : "not allowed")
        snapshot.loginItem = loginItemState.diagnosticsText
        snapshot.automaticRecovery = background.recoveryWanted ? recoveryState.diagnosticsText : "off"
        snapshot.status = status.title
        snapshot.sharingWanted = wantsSharing
        snapshot.sharingActive = active
        snapshot.phonePaired = hasPairedPhone
        snapshot.phoneConnected = connection.connected
        snapshot.controlEffective = allowControl && accessibilityPermission.isGranted && captureHealthy
        snapshot.keepAwake = keepAwakeEnabled
        snapshot.displayCount = displays.count
        snapshot.detail = detail
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
        snapshot.streamQuality = capture.appliedQuality?.title
        snapshot.events = events.entries
        return HostDiagnosticsReport.render(snapshot)
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
            accessibilityGranted: accessibilityPermission.isGranted,
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
            sendCaptureHealth(captureHealthy)
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
        releaseRemoteInput(notifyPhone: true)
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        input.enabled = false
        active = true
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

    private func pollPermissions() {
        let screen: HostPermissionStatus = CGPreflightScreenCaptureAccess() ? .granted : .denied
        let trusted: HostPermissionStatus = AXIsProcessTrusted() ? .granted : .denied
        if screen != screenRecordingPermission {
            screenRecordingPermission = screen
            if screen.isGranted {
                loadDisplays()
            } else {
                stop()
                invalidateDisplays(status: .permissionDenied)
            }
        }
        if trusted != accessibilityPermission {
            accessibilityPermission = trusted
            applyControlState(notifyPhone: true)
        }
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
        guard !active && !browserSession.controller.running else { return }
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        let previousSelection = selected
        let generation = displayRefreshGeneration.begin()
        displayRefreshStatus = .checking

        guard CGPreflightScreenCaptureAccess() else {
            screenRecordingPermission = .denied
            invalidateDisplays(status: .permissionDenied)
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
                accessibilityGranted: AXIsProcessTrusted(),
                displayEnumeration: enumeration
            )
            self.applyPermissionRefresh(result, previousSelection: previousSelection)
            self.displayRefreshTask = nil
            self.reconcileSharing()
        }
    }

    private func applyPermissionRefresh(
        _ result: HostPermissionRefreshResult<SCDisplay>,
        previousSelection: CGDirectDisplayID
    ) {
        screenRecordingPermission = result.screenRecording
        if accessibilityPermission != result.accessibility {
            accessibilityPermission = result.accessibility
            applyControlState(notifyPhone: true)
        }
        displays = result.displays
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
        let effective = allowControl && accessibilityPermission.isGranted
        if !effective { invalidateTextFocus() }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: accessibilityPermission,
            captureHealthy: captureHealthy
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
        guard let display = displays.first(where: { $0.displayID == selected }), let peer = connection.media else { stop(); return }
        if HostScreenLock.isLocked() { handleAvailability(.screenLocked); return }
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
            sessionsThisLaunch += 1
            events.record(.session, "Phone connected")
        }
        captureUnhealthySince = nil
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
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        captureHealthy = false
        input.enabled = false
        advanceEpoch()
        pointerTelemetry.begin(displayFrame: display.frame, epoch: inputEpoch.value)

        lifecycleTimer?.invalidate()
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phonePause.isPaused {
                    if self.phonePause.isExpired(at: ProcessInfo.processInfo.systemUptime) { self.expirePhonePause() }
                    return
                }
                if self.inputLease.isExpired(at: ProcessInfo.processInfo.systemUptime) {
                    let releasedHold = self.input.externalHoldID
                    let releaseEpoch = self.inputEpoch.value
                    if !self.input.held || self.input.release() {
                        self.inputLease.cancel()
                        self.sendReleaseNotice(releasedHold: releasedHold, epoch: releaseEpoch)
                    }
                }
                self.sendCaptureHealth(self.captureHealthy)
                if self.accessibilityPermission.isGranted && !AXIsProcessTrusted() {
                    self.accessibilityPermission = .denied
                    self.applyControlState(notifyPhone: true)
                }
                self.reconcileCurtain()
            }
        }

        let logicalSize = display.frame.size
        let preflight = [
            RemoteAction(action: "geometry", x: logicalSize.width, y: logicalSize.height, epoch: inputEpoch.value),
            RemoteAction(action: "viewing", x: allowControl && accessibilityPermission.isGranted ? 1 : 0, epoch: inputEpoch.value),
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
            } catch is CancellationError {
                return
            } catch {
                guard self.captureAttempt == attempt else { return }
                self.stop()
                self.autoStart.suspend()
                self.detail = "Screen sharing couldn’t start. Try again."
                self.events.record(.error, "Capture could not start")
            }
        }
    }

    private func endCapture() {
        liftCurtain()
        curtainLocallyDismissed = false
        curtainRaiseFailed = false
        captureUnhealthySince = nil
        if let sessionStartedAt {
            lastSessionDuration = Date().timeIntervalSince(sessionStartedAt)
            events.record(.session, "Phone disconnected after \(HostDiagnosticsReport.duration(lastSessionDuration ?? 0))")
            self.sessionStartedAt = nil
        }
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
        _ = capture.stop()
        updatePowerAssertions()
        reconcileCurtain()
    }

    private func captureFailed() {
        #if DEBUG
        HostE2E.active?.event("capture.failed", ["screenRecording": CGPreflightScreenCaptureAccess()])
        #endif
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

    private func receive(_ data: Data) {
        guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else { stop(); return }
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
            if connection.connected, action.epoch == inputEpoch.value, let quality = action.streamQuality {
                capture.setQuality(quality)
            }
            if action.pointerProbe == nil && action.textFocusProbe == nil {
                pointerTelemetry.phoneHeartbeat(action.pointerSync, epoch: action.epoch,
                                                at: ProcessInfo.processInfo.systemUptime)
            }
            receivePointerProbe(action)
            return
        }
        if RemoteAction.sessionExtensionActions.contains(action.action) {
            receiveSessionExtension(action)
            return
        }

        pointerTelemetry.moveProcessed(action)
        guard Self.userInputActions.contains(action.action), inputEpoch.accepts(action) else {
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

        let now = ProcessInfo.processInfo.systemUptime
        let admission = inputFreshness.admit(action, epoch: inputEpoch.value, now: now)
        if admission == .terminate {
            stop()
            autoStart.suspend()
            detail = "The phone’s input session expired. Reconnect from the phone."
            return
        }
        if inputLease.isExpired(at: now) {
            releaseRemoteInput(notifyPhone: true)
            if action.action == "text" { sendTextResult(for: action.key, accepted: false) }
            return
        }

        let trusted: HostPermissionStatus = AXIsProcessTrusted() ? .granted : .denied
        if trusted != accessibilityPermission {
            accessibilityPermission = trusted
            applyControlState(notifyPhone: true)
        }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: accessibilityPermission,
            captureHealthy: captureHealthy
        )
        #if DEBUG
        // E2E harness interlock: injected input may only reach the Farside Test Pad.
        var fenced: RemoteAction? = action
        var fenceVerdict = "allow"
        if let e2e = HostE2E.active { (fenced, fenceVerdict) = e2e.fence(action, held: input.held) }
        if action.action == "key", action.key == "c", action.modifiers == ["command"], input.enabled, fenced != nil {
            clipboard.prepareForCopyShortcut()
        }
        let outcome = fenced.map { input.handle($0, upgraded: admission == .upgraded, now: now) }
            ?? RemoteInputOutcome(textRequestID: action.action == "text" ? action.key : nil)
        HostE2E.active?.recordInput(action, accepted: outcome.accepted, fence: fenceVerdict, clickPoint: outcome.clickPoint)
        #else
        if action.action == "key", action.key == "c", action.modifiers == ["command"], input.enabled {
            clipboard.prepareForCopyShortcut()
        }
        let outcome = input.handle(action, upgraded: admission == .upgraded, now: now)
        #endif
        if action.action == "move", outcome.accepted {
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
            scheduleTextFocusProbe(probe, point: point, issuedAt: now)
        }
        if action.action == "text" {
            sendTextResult(for: action.key, accepted: outcome.accepted)
        }
    }

    private func scheduleTextFocusProbe(_ probe: String, point: CGPoint, issuedAt: TimeInterval) {
        guard let peer = connection.media else { return }
        let ticket = HostTextFocusTicket(epoch: inputEpoch.value,
                                         revision: textFocusRevision, issuedAt: issuedAt)
        textFocusTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.textFocusIsCurrent(ticket, peer: peer), !Task.isCancelled else { return }
            let editable = await HostTextFocusProbe.editableAtClick(point)
            guard self.textFocusIsCurrent(ticket, peer: peer), !Task.isCancelled else { return }
            _ = self.connection.sendControl(RemoteAction(
                action: "heartbeat", epoch: ticket.epoch,
                textFocusProbe: probe, textFocusEditable: editable
            ))
        }
    }

    private func textFocusIsCurrent(_ ticket: HostTextFocusTicket, peer: PeerMedia) -> Bool {
        ticket.isCurrent(epoch: inputEpoch.value, revision: textFocusRevision,
                         now: ProcessInfo.processInfo.systemUptime,
                         active: active && !terminating,
                         connected: connection.connected && connection.media === peer,
                         controlEnabled: allowControl && input.enabled && AXIsProcessTrusted(),
                         captureHealthy: captureHealthy)
    }

    private func invalidateTextFocus() {
        textFocusRevision &+= 1
        textFocusTask?.cancel()
        textFocusTask = nil
    }

    private func captureHealthChanged(_ healthy: Bool) {
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
        let trusted: HostPermissionStatus = AXIsProcessTrusted() ? .granted : .denied
        if trusted != accessibilityPermission {
            accessibilityPermission = trusted
            applyControlState(notifyPhone: true)
        }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: accessibilityPermission,
            captureHealthy: healthy
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

    private func sendCaptureHealth(_ healthy: Bool, presence: HostPresence? = nil) {
        guard connection.connected else { return }
        let state = presence ?? (displayAsleep ? .displayAsleep : nil)
        let capability = inputFreshness.capability(
            epoch: inputEpoch.value,
            now: ProcessInfo.processInfo.systemUptime,
            doubleClickInterval: min(2, max(0.1, NSEvent.doubleClickInterval))
        )
        let event = recoveryEventForPhone
        let sent = connection.sendControl(RemoteAction(
            action: "capture", x: healthy ? 1 : 0, epoch: inputEpoch.value,
            interaction: capability, pointerLocatorSupported: true,
            pointerSync: PointerSync(videoCursor: capture.cursorInVideo), streamQuality: capture.appliedQuality,
            features: SessionFeature.host, hostState: state?.rawValue,
            hostStream: connection.media?.takeHostSummary(),
            curtain: curtainState.rawValue, hostEvent: event
        ))
        if sent && event != nil { recoveryNoticeDelivered = true }
    }

    // MARK: Session extensions

    private func receiveSessionExtension(_ action: RemoteAction) {
        let current = connection.connected && active && action.epoch == inputEpoch.value
        let controlEffective = allowControl && accessibilityPermission.isGranted
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
        case "curtain":
            // Covering the Mac's own screen needs the same authority as controlling it.
            guard current, controlEffective, !phonePause.isPaused,
                  let request = action.curtain.flatMap(PrivacyCurtainRequest.init(rawValue:)) else {
                sendCaptureHealth(captureHealthy)
                return
            }
            events.record(.curtain, "Phone asked to \(request == .up ? "hide" : "show") the screen")
            setPrivacyCurtain(request == .up)
        default:
            break
        }
    }

    /// The phone is backgrounding: stop capture and input now, but keep the peer and its
    /// session slot so a quick return resumes without renegotiation.
    private func pauseForPhoneBackground() {
        guard !phonePause.isPaused else { return }
        liftCurtain()
        phonePause.begin(at: ProcessInfo.processInfo.systemUptime)
        clipboard.reset()
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
        _ = capture.stop()
        updatePowerAssertions()
        reconcileCurtain()
    }

    /// A fresh epoch, geometry and capture follow, so no pre-background input can apply.
    private func resumeAfterPhoneBackground() {
        guard phonePause.isPaused else { return }
        phonePause.clear()
        beginCapture()
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
            if HostScreenLock.isLocked() { screenLocked = true; return }
            autoStart.clear()
            detail = nil
            unavailableReason = nil
            reconcileSharing()
        case .displayAsleep:
            displayAsleep = true
            guard active, connection.connected else { return }
            releaseRemoteInput(notifyPhone: true)
            sendCaptureHealth(captureHealthy)
        case .displayAwake:
            displayAsleep = false
            if connection.connected { sendCaptureHealth(captureHealthy) }
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
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
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
        "move", "click", "right", "double", "dragDown", "dragUp", "holdRenew", "scroll", "text", "key"
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
            "diagnostics": connection.diagnostics,
            "hostRegistered": connection.hostRegistered,
            "connected": connection.connected,
            "awaitingApproval": connection.awaitingApproval,
            "paired": hasPairedPhone,
            "active": active,
            "wantsSharing": wantsSharing,
            "captureHealthy": captureHealthy,
            "allowControl": allowControl,
            "inputEnabled": input.enabled,
            "held": input.held,
            "screenRecording": screenRecordingPermission.isGranted,
            "accessibility": accessibilityPermission.isGranted,
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
