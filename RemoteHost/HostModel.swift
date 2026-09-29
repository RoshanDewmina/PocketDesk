import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement

@MainActor
final class RemoteHostModel: ObservableObject {
    let connection = RemoteCoordinator(isHost: true)
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
    @Published private(set) var openAtLogin = false
    @Published private var autoStart = HostAutoStartGate()
    private let preferences = HostPreferences()
    private let input = RemoteInputDriver()
    private let capture = RemoteCapture()
    private let keepAwake = HostKeepAwake()
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
        HostViewState(
            macName: Host.current().localizedName ?? "this Mac",
            screenRecording: screenRecordingPermission,
            accessibility: accessibilityPermission,
            screenRecordingSettingsOpened: screenRecordingSettingsOpened,
            accessibilitySettingsOpened: accessibilitySettingsOpened,
            status: status,
            setupStep: setupStep,
            hasPairedPhone: hasPairedPhone,
            pairingRequested: pairingRequested,
            pairing: pairingState,
            canBeginPairing: canPair && serviceAddress != nil,
            allowControl: allowControl,
            keepAwake: keepAwakeEnabled,
            openAtLogin: openAtLogin,
            displays: displays.map { HostDisplayOption(id: $0.displayID, name: Self.displayName(for: $0.displayID)) },
            selectedDisplayID: selected,
            detail: detail
        )
    }

    init() {
        controlConsent = HostControlConsentState(isAllowed: preferences.allowControl)
        keepAwakeEnabled = preferences.keepAwake
        wantsSharing = preferences.sharingEnabled
        accessibilitySkipped = preferences.accessibilitySkipped
        openAtLogin = SMAppService.mainApp.status == .enabled
        browserSession.canAcquire = { [weak self] in guard let self else { return false }; return !self.active && !self.connection.connected }
        connection.restore()
        connection.onAuthenticated = { [weak self] in self?.beginCapture() }
        connection.onEnded = { [weak self] in
            self?.endCapture()
            self?.reconcileAvailabilityAfterCoordinatorReset()
        }
        connection.onControl = { [weak self] data in self?.receive(data) }
        connectionObserver = connection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.connectionDidChange() }
        }
        capture.onFailure = { [weak self] in self?.captureFailed() }
        capture.onHealth = { [weak self] healthy in self?.captureHealthChanged(healthy) }
        pointerTelemetry.send = { [weak self] action in self?.connection.sendControl(action) ?? false }
        pointerTelemetry.setCaptureShowsCursor = { [weak self] shows in self?.capture.setShowsCursor(shows) }
        pointerTelemetry.captureShowsCursor = { [weak self] in self?.capture.cursorInVideo ?? true }
        capture.onCursorVisibility = { [weak self] shows in
            guard let self else { return }
            self.pointerTelemetry.captureCursorChanged(showsCursor: shows)
            self.sendCaptureHealth(self.captureHealthy)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.autoStart.suspend()
                    self.stop()
                    self.detail = "This Mac went to sleep or was locked. Sharing resumes when it wakes."
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.autoStart.clear()
                    self.detail = nil
                    self.reconcileSharing()
                }
            })
        }
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
            detail = "Couldn’t reopen automatically. Quit PocketDesk from the menu bar and open it again."
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
            detail = "PocketDesk needs Screen Recording and an available display before pairing."
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
        wantsSharing = false
        preferences.sharingEnabled = false
        stop()
        if !hasPairedPhone { clearPairingCode() }
    }

    func resumeSharing() {
        wantsSharing = true
        preferences.sharingEnabled = true
        autoStart.clear()
        detail = nil
        if displayRefreshStatus != .ready { loadDisplays() } else { reconcileSharing() }
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
        guard enabled else { releaseKeepAwake(); return }
        guard active else { return }
        keepAwakeActive = keepAwake.start()
        if !keepAwakeActive { detail = "PocketDesk couldn’t keep this Mac awake. Normal sleep settings still apply." }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            detail = "Couldn’t change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func start(display: SCDisplay) {
        releaseRemoteInput(notifyPhone: true)
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        input.enabled = false
        active = true
        detail = nil
        if keepAwakeEnabled {
            keepAwakeActive = keepAwake.start()
            if !keepAwakeActive { detail = "PocketDesk couldn’t keep this Mac awake. Normal sleep settings still apply." }
        }
        connection.start()
        reconcileStartResult()
    }

    func stop() {
        invalidateTextFocus()
        browserSession.stop()
        releaseRemoteInput(notifyPhone: true)
        sendCaptureHealth(false)
        active = false
        releaseKeepAwake()
        connection.stop()
    }

    func stopForTermination() {
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
            detail = "PocketDesk couldn’t list this Mac’s displays. Try again."
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
        if !effective { releaseRemoteInput(notifyPhone: notifyPhone) }
        if notifyPhone, connection.connected {
            _ = connection.sendControl(RemoteAction(action: "viewing", x: effective ? 1 : 0, epoch: inputEpoch.value))
        }
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
        captureAttempt &+= 1
        if captureAttempt == 0 { captureAttempt = 1 }
        let attempt = captureAttempt
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
            }
        }
    }

    private func endCapture() {
        invalidateTextFocus()
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
    }

    private func captureFailed() {
        stop()
        pollPermissions()
        if screenRecordingPermission.isGranted {
            autoStart.suspend()
            detail = "Screen sharing stopped unexpectedly. Try again."
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
        let outcome = input.handle(action, upgraded: admission == .upgraded, now: now)
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
        captureHealthy = healthy
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

    private func sendCaptureHealth(_ healthy: Bool) {
        guard connection.connected else { return }
        let capability = inputFreshness.capability(
            epoch: inputEpoch.value,
            now: ProcessInfo.processInfo.systemUptime,
            doubleClickInterval: min(2, max(0.1, NSEvent.doubleClickInterval))
        )
        _ = connection.sendControl(RemoteAction(
            action: "capture", x: healthy ? 1 : 0, epoch: inputEpoch.value,
            interaction: capability, pointerLocatorSupported: true,
            pointerSync: PointerSync(videoCursor: capture.cursorInVideo), streamQuality: capture.appliedQuality
        ))
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
        keepAwakeActive = keepAwake.isActive
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
