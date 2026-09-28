import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreImage.CIFilterBuiltins

@main
struct RemoteHostApp: App {
    @NSApplicationDelegateAdaptor(RemoteHostAppDelegate.self) private var appDelegate
    @StateObject private var model: RemoteHostModel

    init() {
        let model = RemoteHostModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.configure { model.stopForTermination() }
    }

    var body: some Scene {
        WindowGroup("PocketDesk Host") {
            HostRemoteView(model: model, connection: model.connection, browserController: model.browserSession.controller)
        }.defaultSize(width: 680, height: 720)
        MenuBarExtra("PocketDesk", systemImage: "desktopcomputer") {
            Text(model.connection.status)
            Button("Stop remote access") { model.stop() }
            Button("Quit") { model.stop(); NSApplication.shared.terminate(nil) }
        }
    }
}

@MainActor
final class RemoteHostModel: ObservableObject {
    let connection = RemoteCoordinator(isHost: true)
    let browserSession = BrowserMediaSession()
    @Published var server = ""
    @Published var displays: [SCDisplay] = []
    @Published var selected: CGDirectDisplayID = 0 {
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
    @Published var pairingCode = ""
    @Published private var controlConsent = HostControlConsentState()
    @Published var notice = "Choose your display, then enable remote access."
    @Published var active = false
    @Published private(set) var screenRecordingPermission: HostPermissionStatus = .unchecked
    @Published private(set) var accessibilityPermission: HostPermissionStatus = .unchecked
    @Published private(set) var displayRefreshStatus: HostDisplayRefreshStatus = .notChecked
    @Published var keepAwakeEnabled = false
    @Published private(set) var keepAwakeActive = false
    private let input = RemoteInputDriver()
    private let capture = RemoteCapture()
    private let keepAwake = HostKeepAwake()
    private var lifecycleTimer: Timer?
    private var inputLease = RemoteInputLease()
    private var observers: [NSObjectProtocol] = []
    private var captureTask: Task<Void, Never>?
    private var captureAttempt: UInt64 = 0
    private var inputEpoch = RemoteInputEpoch()
    private var inputFreshness = NativeInputFreshness()
    private var captureHealthy = false
    private var capturedDisplayID: CGDirectDisplayID?
    private var pointerLocator = HostPointerLocator()
    private var displayRefreshTask: Task<Void, Never>?
    private var displayRefreshGeneration = HostPermissionRefreshGeneration()
    private var terminating = false

    var canPair: Bool {
        displayRefreshStatus == .ready && screenRecordingPermission.isGranted && HostPairingPreflight.isEligible(
            selectedDisplayID: selected,
            availableDisplayIDs: displays.map(\.displayID)
        )
    }

    var currentAppPath: String { Bundle.main.bundleURL.path }
    var allowControl: Bool { controlConsent.isAllowed }

    init() {
        browserSession.canAcquire = { [weak self] in guard let self else { return false }; return !self.active && !self.connection.connected }
        connection.restore(); server = connection.invitation?.server ?? ""
        connection.onAuthenticated = { [weak self] in self?.beginCapture() }
        connection.onEnded = { [weak self] in
            self?.endCapture()
            self?.reconcileAvailabilityAfterCoordinatorReset()
        }
        connection.onControl = { [weak self] data in self?.receive(data) }
        capture.onFailure = { [weak self] in self?.captureFailed() }
        capture.onHealth = { [weak self] healthy in self?.captureHealthChanged(healthy) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(); self?.notice = "Mac became unavailable. Enable remote access again when ready." }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                self?.invalidateDisplays(status: .notChecked)
                self?.notice = "The display arrangement changed. Check Screen Recording and choose the display again."
            }
        })
        observePermissions()
    }

    func loadDisplays() {
        guard !active && !browserSession.controller.running else {
            notice = "Stop remote access before checking or changing displays."
            return
        }
        releaseRemoteInput(notifyPhone: true)
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        let previousSelection = selected
        let generation = displayRefreshGeneration.begin()
        displays = []
        selected = 0
        displayRefreshStatus = .checking
        observePermissions()

        guard screenRecordingPermission.isGranted else {
            displayRefreshStatus = .permissionDenied
            notice = screenRecordingRecoveryGuidance
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
        }
    }

    func requestScreenRecordingPermission() {
        guard !active else {
            notice = "Stop remote access before changing Screen Recording access."
            return
        }
        invalidateDisplays(status: .notChecked)
        _ = CGRequestScreenCaptureAccess()
        observePermissions()
        notice = screenRecordingPermission.isGranted
            ? "Screen Recording is granted. Quit and reopen PocketDesk Host if displays still do not appear, then check again."
            : screenRecordingRecoveryGuidance
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        accessibilityPermission = trusted ? .granted : .denied
        if !trusted { disableControlForPermissionLoss(notifyPhone: true) }
        notice = trusted
            ? "Accessibility is granted. Remote control stays off until you explicitly allow it below."
            : accessibilityRecoveryGuidance
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        checkAccessibilityPermission()
    }

    func setKeepAwake(_ enabled: Bool) {
        guard enabled else {
            keepAwakeEnabled = false
            releaseKeepAwake()
            return
        }
        keepAwakeEnabled = true
        guard active else {
            notice = "Keep awake is selected for the next remote-access session."
            return
        }
        guard keepAwake.start() else {
            keepAwakeEnabled = false
            keepAwakeActive = false
            notice = "PocketDesk could not keep this Mac awake. Remote access can continue, but normal sleep settings still apply."
            return
        }
        keepAwakeActive = true
    }

    func pair() {
        guard !browserSession.controller.running else { notice = "Stop browser access before pairing a native phone."; return }
        resetControlConsent(notifyPhone: true)
        do {
            guard let display = validatedSelectedDisplay() else { return }
            guard let invitation = try HostPairingPreflight.createInvitation(
                selectedDisplayID: selected,
                availableDisplayIDs: displays.map(\.displayID),
                create: {
                    try connection.createPair(
                        server: server.trimmingCharacters(in: .whitespacesAndNewlines),
                        name: Host.current().localizedName ?? "My Mac"
                    )
                }
            ) else {
                notice = "Choose an available display first."
                return
            }
            pairingCode = try invitation.code(); start(display: display)
        } catch { notice = error.localizedDescription }
    }
    func start() {
        guard !browserSession.controller.running else { notice = "Browser access is enabled. Stop it before enabling the native phone."; return }
        guard let display = validatedSelectedDisplay() else { return }
        start(display: display)
    }

    private func start(display: SCDisplay) {
        releaseRemoteInput(notifyPhone: true)
        input.configure(SCContentFilter(display: display, excludingWindows: []))
        input.enabled = false
        active = true
        if keepAwakeEnabled {
            guard keepAwake.start() else {
                keepAwakeEnabled = false
                keepAwakeActive = false
                notice = "PocketDesk could not keep this Mac awake. Remote access can continue, but normal sleep settings still apply."
                connection.start()
                reconcileStartResult()
                return
            }
            keepAwakeActive = true
        }
        connection.start()
        reconcileStartResult()
    }
    func stop() {
        browserSession.stop()
        releaseRemoteInput(notifyPhone: true)
        sendCaptureHealth(false)
        active = false
        keepAwakeEnabled = false
        releaseKeepAwake()
        connection.stop()
    }
    func stopForTermination() {
        browserSession.stop()
        terminating = true
        input.enabled = false
        releaseRemoteInputSynchronously()
        sendCaptureHealth(false)
        active = false
        keepAwakeEnabled = false
        releaseKeepAwake()
        connection.stop()
    }
    func revoke() {
        if browserSession.controller.running { connection.revoke(); pairingCode = ""; return }
        resetControlConsent(notifyPhone: true)
        stop()
        connection.revoke()
        pairingCode = ""
    }
    func setControl(_ enabled: Bool) {
        let trusted = AXIsProcessTrusted()
        accessibilityPermission = trusted ? .granted : .denied
        if enabled && !trusted {
            controlConsent.setAllowed(false)
            notice = "Accessibility is not granted. Use Show setup prompt, finish the OS step, check again, then turn on PocketDesk control."
        } else {
            controlConsent.setAllowed(enabled)
        }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: accessibilityPermission,
            captureHealthy: captureHealthy
        )
        if !allowControl { releaseRemoteInput(notifyPhone: true) }
        if connection.connected {
            _ = connection.sendControl(RemoteAction(
                action: "viewing",
                x: allowControl ? 1 : 0,
                epoch: inputEpoch.value
            ))
        }
    }
    private func beginCapture() {
        guard CGPreflightScreenCaptureAccess() else {
            screenRecordingPermission = .denied
            stop()
            invalidateDisplays(status: .permissionDenied)
            notice = screenRecordingRecoveryGuidance
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
                        self.notice = "A held drag was released because its two-second input lease expired."
                    }
                }
                self.sendCaptureHealth(self.captureHealthy)
                if self.allowControl && !AXIsProcessTrusted() {
                    self.accessibilityPermission = .denied
                    self.disableControlForPermissionLoss(notifyPhone: true)
                    self.notice = "Accessibility ended. Viewing remains available; check the OS permission before allowing control again."
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
                self.notice = "Sharing \(Int(logicalSize.width)) × \(Int(logicalSize.height)) logical display"
            } catch is CancellationError {
                return
            } catch {
                guard self.captureAttempt == attempt else { return }
                self.stop()
                self.notice = "Could not start screen sharing. Check permission and retry."
            }
        }
    }
    private func endCapture() {
        releaseRemoteInput(notifyPhone: false)
        inputFreshness.invalidate()
        input.resetNativeSequence()
        lifecycleTimer?.invalidate(); lifecycleTimer = nil
        captureHealthy = false
        capturedDisplayID = nil
        pointerLocator.reset()
        input.enabled = false
        captureAttempt &+= 1
        captureTask?.cancel(); captureTask = nil
        _ = capture.stop()
    }

    private func captureFailed() {
        stop()
        observePermissions()
        if !screenRecordingPermission.isGranted {
            invalidateDisplays(status: .permissionDenied)
            notice = screenRecordingRecoveryGuidance
        } else {
            notice = "Screen sharing stopped. Screen Recording is granted, but capture failed. Check the display and retry."
        }
    }
    private func receive(_ data: Data) {
        guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else { stop(); return }
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
            receivePointerProbe(action)
            return
        }

        guard Self.userInputActions.contains(action.action), inputEpoch.accepts(action) else {
            if inputFreshness.upgraded || action.interaction != nil {
                stop()
                notice = "Native input belonged to an old session. Reconnect to control this Mac."
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
            notice = "Native input expired or lost its session token. Reconnect to control this Mac."
            return
        }
        if inputLease.isExpired(at: now) {
            releaseRemoteInput(notifyPhone: true)
            if action.action == "text" { sendTextResult(for: action.key, accepted: false) }
            return
        }

        let trusted = AXIsProcessTrusted()
        accessibilityPermission = trusted ? .granted : .denied
        if !trusted && allowControl { disableControlForPermissionLoss(notifyPhone: true) }
        input.enabled = HostControlPolicy.isEnabled(
            userConsent: allowControl,
            accessibilityPermission: accessibilityPermission,
            captureHealthy: captureHealthy
        )
        let outcome = input.handle(action, upgraded: admission == .upgraded, now: now)
        if admission == .upgraded, action.action == "dragDown", !outcome.accepted,
           let notice = inputFreshness.rejectedDragDownNotice(
                action, activeHold: input.externalHoldID
           ) {
            _ = connection.sendControl(notice)
        }
        inputLease.record(action: action.action, accepted: outcome.accepted, at: now)
        if outcome.holdEvent == .ended { inputLease.cancel() }
        if action.action == "text" {
            sendTextResult(for: action.key, accepted: outcome.accepted)
        }
    }

    private func captureHealthChanged(_ healthy: Bool) {
        if captureHealthy && !healthy {
            releaseRemoteInput(notifyPhone: true)
            inputFreshness.expireTokens()
        }
        captureHealthy = healthy
        let trusted = AXIsProcessTrusted()
        accessibilityPermission = trusted ? .granted : .denied
        if !trusted && allowControl { disableControlForPermissionLoss(notifyPhone: true) }
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
            interaction: capability, pointerLocatorSupported: true, streamQuality: capture.appliedQuality
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
        inputEpoch.beginSession()
        inputFreshness.expireTokens()
        input.resetNativeSequence()
    }

    private func observePermissions() {
        screenRecordingPermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        let trusted = AXIsProcessTrusted()
        accessibilityPermission = trusted ? .granted : .denied
        if !trusted && allowControl { disableControlForPermissionLoss(notifyPhone: true) }
    }

    private func applyPermissionRefresh(
        _ result: HostPermissionRefreshResult<SCDisplay>,
        previousSelection: CGDirectDisplayID
    ) {
        screenRecordingPermission = result.screenRecording
        accessibilityPermission = result.accessibility
        if !result.accessibility.isGranted && allowControl {
            disableControlForPermissionLoss(notifyPhone: true)
        }
        displays = result.displays
        displayRefreshStatus = result.displayStatus
        if displays.contains(where: { $0.displayID == previousSelection }) {
            selected = previousSelection
        } else {
            selected = displays.first?.displayID ?? 0
        }

        switch result.displayStatus {
        case .ready:
            notice = "Screen Recording is granted. Choose the display your phone may view."
        case .unavailable:
            notice = "Screen Recording is granted, but macOS reported no available display. Try again after checking the display connection."
        case .permissionDenied:
            notice = screenRecordingRecoveryGuidance
        case .failed:
            notice = "Display discovery failed, so no previous display can be used. Try again. If this repeats, quit and reopen the exact app shown below."
        case .notChecked, .checking:
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
        observePermissions()
        guard screenRecordingPermission.isGranted else {
            invalidateDisplays(status: .permissionDenied)
            notice = screenRecordingRecoveryGuidance
            return nil
        }
        guard displayRefreshStatus == .ready,
              let display = displays.first(where: { $0.displayID == selected }) else {
            invalidateDisplays(status: .notChecked)
            notice = "Check Screen Recording and choose an available display first."
            return nil
        }
        return display
    }

    private func disableControlForPermissionLoss(notifyPhone: Bool) {
        controlConsent.setAllowed(false)
        input.enabled = false
        releaseRemoteInput(notifyPhone: notifyPhone)
        if notifyPhone, connection.connected {
            _ = connection.sendControl(RemoteAction(action: "viewing", x: 0, epoch: inputEpoch.value))
        }
    }

    private func resetControlConsent(notifyPhone: Bool) {
        controlConsent.pairingIdentityWillChange()
        input.enabled = false
        releaseRemoteInput(notifyPhone: notifyPhone)
        if notifyPhone, connection.connected {
            _ = connection.sendControl(RemoteAction(action: "viewing", x: 0, epoch: inputEpoch.value))
        }
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
        keepAwakeEnabled = false
        releaseKeepAwake()
    }

    private var screenRecordingRecoveryGuidance: String {
        "Screen Recording is not granted to this running copy. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording. If PocketDesk is already enabled, remove the older PocketDesk Host entry, add this exact app, then quit and reopen it."
    }

    private var accessibilityRecoveryGuidance: String {
        "Accessibility is not granted to this running copy. Use Show setup prompt, enable this exact PocketDesk Host in System Settings, then check again. If an enabled row still fails, remove the older entry, add this exact app, and quit and reopen it."
    }

    private static let userInputActions: Set<String> = [
        "move", "click", "right", "double", "dragDown", "dragUp", "holdRenew", "scroll", "text", "key"
    ]
}

struct HostRemoteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: RemoteHostModel
    @ObservedObject var connection: RemoteCoordinator
    @ObservedObject var browserController: BrowserPeerController
    @State private var showServiceSetup = false
    @State private var showBrowserSettings = false

    private var palette: PocketDeskPalette { PocketDeskPalette.resolve(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                masthead
                overview
                primaryActions

                if connection.awaitingApproval { approvalRequest }
                if connection.hostRegistered && !model.pairingCode.isEmpty && connection.hostPair?.paired == false {
                    pairingInvitation
                }

                HostSettingsSection("Prepare this Mac") {
                    VStack(alignment: .leading, spacing: 16) {
                        screenViewing
                        Rectangle().fill(palette.line).frame(height: 1)
                        controlPermission
                    }
                }

                HostSettingsSection("Remote control") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Allow this phone to control the mouse and keyboard",
                               isOn: Binding(get: { model.allowControl }, set: model.setControl))
                            .disabled(!model.accessibilityPermission.isGranted)
                        Text("The macOS Accessibility grant and your PocketDesk consent are separate. Control stays off until you allow it here.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }

                serviceSetup

                HostSettingsSection("During a session") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Keep this Mac and display awake during remote access",
                               isOn: Binding(get: { model.keepAwakeEnabled }, set: model.setKeepAwake))
                        Text(model.keepAwakeActive
                             ? "Keep awake is active for this session."
                             : "Off by default. PocketDesk releases it when remote access stops.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                        Text("Closing the lid, locking or sleeping the Mac manually, low battery, or a system sleep event still ends access.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }

                browserPreview
                footer
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
        .background(palette.paper)
        .tint(palette.accent)
        .frame(minWidth: 520, minHeight: 580)
        .onAppear {
            showServiceSetup = model.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            showBrowserSettings = browserController.running || browserController.pendingApproval
        }
        .onChange(of: browserController.pendingApproval) { _, pending in
            if pending { showBrowserSettings = true }
        }
        .onChange(of: browserController.running) { _, running in
            if running { showBrowserSettings = true }
        }
    }

    private var masthead: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 42, height: 42)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("PocketDesk")
                    .font(.system(size: 21, weight: .regular, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("Mac companion")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            Spacer()
            Label(statusTitle, systemImage: statusIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.10), in: Capsule())
                .accessibilityLabel(statusTitle)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Mac, within reach.")
                .font(.system(size: 32, weight: .regular, design: .serif))
                .foregroundStyle(palette.ink)
            Text(browserController.running ? browserController.status : connection.status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.ink)
            Text(nextStep)
                .font(.callout)
                .foregroundStyle(palette.muted)
            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    private var primaryActions: some View {
        HStack(spacing: 9) {
            if connection.invitation == nil {
                Button("Pair a phone", action: model.pair)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.active || browserController.running || !model.canPair)
                Button("Enable remote access", action: model.start)
                    .disabled(true)
            } else {
                Button("Pair a phone", action: model.pair)
                    .disabled(model.active || browserController.running || !model.canPair)
                Button("Enable remote access", action: model.start)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.active || browserController.running || !model.canPair)
            }
            Spacer(minLength: 4)
            Button("Stop", role: .destructive, action: model.stop)
                .buttonStyle(.borderedProminent)
                .disabled(!model.active && !browserController.running)
        }
        .controlSize(.large)
    }

    private var approvalRequest: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Approve this phone?", systemImage: "iphone.gen3")
                .font(.headline)
                .foregroundStyle(palette.ink)
            Text("A phone has your pairing code. Approve only the phone you are pairing beside this Mac.")
                .font(.callout)
                .foregroundStyle(palette.muted)
            HStack {
                Button("Approve", action: connection.approve)
                    .buttonStyle(.borderedProminent)
                Button("Decline", action: connection.reject)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(palette.warning.opacity(0.65), lineWidth: 1))
    }

    private var pairingInvitation: some View {
        HostSettingsSection("Pair your phone") {
            VStack(alignment: .leading, spacing: 11) {
                Text("Scan on your iPhone within two minutes.")
                    .font(.callout)
                    .foregroundStyle(palette.muted)
                if let image = qr(model.pairingCode) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 196, height: 196)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Private pairing QR code")
                }
                Button("Copy pairing code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.pairingCode, forType: .string)
                }
                Text("Keep this code private. Approve the phone here after scanning.")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
        }
    }

    private var screenViewing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screen viewing")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            permissionRow("Screen Recording", status: model.screenRecordingPermission)
            HStack(spacing: 9) {
                Button("Check displays", action: model.loadDisplays)
                    .disabled(model.active || model.displayRefreshStatus == .checking)
                if model.screenRecordingPermission == .denied {
                    Button("Allow Screen Recording", action: model.requestScreenRecordingPermission)
                        .disabled(model.active)
                }
                if model.displayRefreshStatus == .checking {
                    ProgressView().controlSize(.small)
                }
            }
            if !model.displays.isEmpty {
                Picker("Shared display", selection: $model.selected) {
                    ForEach(model.displays, id: \.displayID) { display in
                        Text("Display \(display.displayID) · \(display.width) × \(display.height)")
                            .tag(display.displayID)
                    }
                }
                .disabled(model.active)
            }
            if model.screenRecordingPermission == .denied ||
                model.accessibilityPermission == .denied ||
                model.displayRefreshStatus == .failed {
                Text("Running app: \(model.currentAppPath)")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .textSelection(.enabled)
            }
        }
    }

    private var controlPermission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Control permission")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            permissionRow("macOS Accessibility", status: model.accessibilityPermission)
            HStack(spacing: 9) {
                Button("Check Accessibility", action: model.checkAccessibilityPermission)
                if model.accessibilityPermission == .denied {
                    Button("Show setup prompt", action: model.requestAccessibilityPermission)
                }
            }
        }
    }

    private var serviceSetup: some View {
        HostSettingsSection("Connection service") {
            DisclosureGroup("Private service setup", isExpanded: $showServiceSetup) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("wss://your-service.example/signal", text: $model.server)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Connection service address")
                        .disabled(model.active)
                    Text("Use the service address supplied for your private PocketDesk test.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                .padding(.top, 9)
            }
        }
    }

    private var browserPreview: some View {
        HostSettingsSection("Browser preview") {
            DisclosureGroup("Private browser access", isExpanded: $showBrowserSettings) {
                BrowserHostSettingsView(
                    browser: model.browserSession,
                    controller: browserController,
                    selected: model.displays.first(where: { $0.displayID == model.selected }),
                    nativeActive: model.active
                )
                .padding(.top, 9)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Early prototype: Mac must remain unlocked. Audio stays on the Mac.")
                .font(.caption)
                .foregroundStyle(palette.muted)
            if !connection.hasRelay {
                Label("Relay is not configured. Outside-network connectivity is not yet verified.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(palette.warning)
            }
            Divider()
            Button("Remove paired phone", role: .destructive, action: model.revoke)
                .disabled(connection.invitation == nil)
                .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private var statusTitle: String {
        if connection.connected { return "Phone connected" }
        if connection.awaitingApproval { return "Approval requested" }
        if model.active { return "Remote access on" }
        if browserController.connected { return "Browser connected" }
        if browserController.pendingApproval { return "Browser approval requested" }
        if browserController.running { return "Browser access on" }
        if model.canPair && connection.invitation != nil { return "Ready to enable" }
        if readyForPairing { return "Ready to pair" }
        return "Setup needed"
    }

    private var statusIcon: String {
        if connection.connected { return "checkmark.circle.fill" }
        if connection.awaitingApproval { return "person.crop.circle.badge.questionmark" }
        if model.active { return "dot.radiowaves.left.and.right" }
        if browserController.connected { return "checkmark.circle.fill" }
        if browserController.pendingApproval { return "person.crop.circle.badge.questionmark" }
        if browserController.running { return "dot.radiowaves.left.and.right" }
        if readyForPairing || (model.canPair && connection.invitation != nil) { return "checkmark.circle" }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if connection.connected { return palette.sage }
        if connection.awaitingApproval { return palette.warning }
        if model.active { return palette.accent }
        if browserController.connected { return palette.sage }
        if browserController.pendingApproval { return palette.warning }
        if browserController.running { return palette.accent }
        if readyForPairing || (model.canPair && connection.invitation != nil) { return palette.sage }
        return palette.muted
    }

    private var readyForPairing: Bool {
        model.canPair && !model.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nextStep: String {
        if connection.awaitingApproval { return "Approve only the phone you’re pairing." }
        if connection.connected { return "Your phone is connected. Keep PocketDesk open on your phone." }
        if model.active { return "Remote access is enabled. Follow the connection status above." }
        if browserController.pendingApproval { return "Review the browser request in Browser preview below." }
        if browserController.running { return "Browser preview is active. Stop it before enabling the native phone." }
        if !model.screenRecordingPermission.isGranted { return "Allow Screen Recording in Prepare this Mac." }
        if model.displayRefreshStatus == .checking { return "Checking the displays available to share…" }
        if !model.canPair { return "Check access, then choose the display to share." }
        if model.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter your connection service address in Connection service."
        }
        if connection.invitation == nil { return "Pair your phone, then approve it on this Mac." }
        return "Enable remote access when you’re ready to connect."
    }

    private func permissionRow(_ title: String, status: HostPermissionStatus) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(palette.ink)
            Spacer()
            Label(permissionLabel(status), systemImage: permissionIcon(status))
                .font(.caption.weight(.medium))
                .foregroundStyle(status == .granted ? palette.sage : status == .denied ? palette.warning : palette.muted)
        }
    }

    private func permissionLabel(_ status: HostPermissionStatus) -> String {
        switch status {
        case .unchecked: "Not checked"
        case .granted: "Granted"
        case .denied: "Not granted"
        }
    }

    private func permissionIcon(_ status: HostPermissionStatus) -> String {
        switch status {
        case .unchecked: "questionmark.circle"
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.circle"
        }
    }

    private func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
    }
}
