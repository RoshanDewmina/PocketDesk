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
        WindowGroup("PocketDesk Host") { HostRemoteView(model: model, connection: model.connection) }.defaultSize(width: 560, height: 650)
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
            if selected != oldValue { releaseRemoteInput(notifyPhone: true); browserSession.stop() }
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
    private var captureHealthy = false
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
                    if !self.input.held || self.input.release() {
                        self.inputLease.cancel()
                        _ = self.connection.sendControl(RemoteAction(action: "release", epoch: self.inputEpoch.value))
                        self.notice = "A held drag was released because its two-second input lease expired."
                    }
                }
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
        lifecycleTimer?.invalidate(); lifecycleTimer = nil
        captureHealthy = false
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
            releaseRemoteInput(notifyPhone: false)
            return
        }
        if action.action == "heartbeat" { return }

        guard Self.userInputActions.contains(action.action), inputEpoch.accepts(action) else {
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
        let outcome = input.handle(action)
        let now = ProcessInfo.processInfo.systemUptime
        inputLease.record(action: action.action, accepted: outcome.accepted, at: now)
        if outcome.holdEvent == .ended { inputLease.cancel() }
        if action.action == "text" {
            sendTextResult(for: action.key, accepted: outcome.accepted)
        }
    }

    private func captureHealthChanged(_ healthy: Bool) {
        if captureHealthy && !healthy { releaseRemoteInput(notifyPhone: true) }
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

    private func sendCaptureHealth(_ healthy: Bool) {
        guard connection.connected else { return }
        _ = connection.sendControl(RemoteAction(action: "capture", x: healthy ? 1 : 0, epoch: inputEpoch.value))
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
        guard let holdID = input.holdID else {
            inputLease.cancel()
            if notifyPhone, connection.connected {
                _ = connection.sendControl(RemoteAction(action: "release", epoch: inputEpoch.value))
            }
            return
        }
        if input.release() {
            inputLease.cancel()
            if notifyPhone, connection.connected {
                _ = connection.sendControl(RemoteAction(action: "release", epoch: inputEpoch.value))
            }
        } else if !terminating {
            retryRelease(holdID: holdID, notifyPhone: notifyPhone, remaining: 8)
        }
    }

    private func releaseRemoteInputSynchronously() {
        if input.held {
            for _ in 0..<8 {
                if input.release() { break }
            }
        }
        inputLease.cancel()
        if connection.connected {
            _ = connection.sendControl(RemoteAction(action: "release", epoch: inputEpoch.value))
        }
    }

    private func retryRelease(holdID: UInt64, notifyPhone: Bool, remaining: Int) {
        guard remaining > 0, !terminating else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, !self.terminating, self.input.holdID == holdID else { return }
            if self.input.release() {
                self.inputLease.cancel()
                if notifyPhone, self.connection.connected {
                    _ = self.connection.sendControl(RemoteAction(
                        action: "release",
                        epoch: self.inputEpoch.value
                    ))
                }
            } else {
                self.retryRelease(holdID: holdID, notifyPhone: notifyPhone, remaining: remaining - 1)
            }
        }
    }

    private func captureStartIsCurrent(_ attempt: UInt64, peer: PeerMedia) -> Bool {
        captureAttempt == attempt && connection.connected && connection.media === peer
    }

    private func advanceEpoch() {
        inputEpoch.beginSession()
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
        "move", "click", "right", "double", "dragDown", "dragUp", "scroll", "text", "key"
    ]
}

struct HostRemoteView: View {
    @ObservedObject var model: RemoteHostModel
    @ObservedObject var connection: RemoteCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Your Mac, wherever you are", systemImage: "desktopcomputer").font(.title2.bold())
                Text(connection.status).foregroundStyle(.secondary)
                HostSettingsSection("Next step") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(nextStep).font(.headline)
                        Text(model.notice).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                if connection.awaitingApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A phone has your pairing code. Allow it to connect?")
                        HStack {
                            Button("Approve", action: connection.approve).buttonStyle(.borderedProminent)
                            Button("Decline", action: connection.reject)
                        }
                    }
                }
                HostSettingsSection("Remote connection service") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("wss://your-service.example/signal", text: $model.server)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Connection service address")
                            .disabled(model.active)
                        Text("Use the service address supplied for your private PocketDesk test.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HostSettingsSection("Screen viewing") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow("Screen Recording", status: model.screenRecordingPermission)
                        HStack {
                            Button("Check displays", action: model.loadDisplays)
                                .disabled(model.active || model.displayRefreshStatus == .checking)
                            if model.screenRecordingPermission == .denied {
                                Button("Allow Screen Recording", action: model.requestScreenRecordingPermission)
                                    .disabled(model.active)
                            }
                            if model.displayRefreshStatus == .checking { ProgressView().controlSize(.small) }
                        }
                        if !model.displays.isEmpty {
                            Picker("Shared display", selection: $model.selected) {
                                ForEach(model.displays, id: \.displayID) { display in
                                    Text("Display \(display.displayID) · \(display.width) × \(display.height)").tag(display.displayID)
                                }
                            }.disabled(model.active)
                        }
                        if model.screenRecordingPermission == .denied || model.accessibilityPermission == .denied || model.displayRefreshStatus == .failed {
                            Text("Running app: \(model.currentAppPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }.padding(8)
                }
                HostSettingsSection("Remote control") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow("macOS Accessibility", status: model.accessibilityPermission)
                        HStack {
                            Button("Check Accessibility", action: model.checkAccessibilityPermission)
                            if model.accessibilityPermission == .denied {
                                Button("Show setup prompt", action: model.requestAccessibilityPermission)
                            }
                        }
                        Toggle("Allow this phone to control the mouse and keyboard", isOn: Binding(get: { model.allowControl }, set: model.setControl))
                            .disabled(!model.accessibilityPermission.isGranted)
                        Text("Accessibility is the macOS grant. This separate PocketDesk consent stays off until you turn it on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }.padding(8)
                }
                HostSettingsSection("Availability") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Keep this Mac and display awake during remote access", isOn: Binding(get: { model.keepAwakeEnabled }, set: model.setKeepAwake))
                        Text(model.keepAwakeActive ? "Keep awake is active for this session." : "Off by default; any assertion is released when remote access stops.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("This prevents idle sleep only. Closing the lid, locking or sleeping the Mac manually, low battery, or a system sleep event still ends access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }.padding(8)
                }
                BrowserHostSettingsView(browser: model.browserSession, controller: model.browserSession.controller,
                                        selected: model.displays.first(where: { $0.displayID == model.selected }), nativeActive: model.active)
                HStack {
                    Button("Pair a phone", action: model.pair).disabled(model.active || !model.canPair)
                    Button("Enable remote access", action: model.start).buttonStyle(.borderedProminent).disabled(model.active || connection.invitation == nil || !model.canPair)
                    Button("Stop", role: .destructive, action: model.stop).disabled(!model.active)
                }
                if connection.hostRegistered && !model.pairingCode.isEmpty && connection.hostPair?.paired == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan on your iPhone within two minutes").font(.headline)
                        if let image = qr(model.pairingCode) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220).accessibilityLabel("Private pairing QR code") }
                        Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairingCode, forType: .string) }
                        Text("Keep this code private. Approve the phone here after scanning.").font(.caption)
                    }
                }
                Text("Early prototype: Mac must remain unlocked. Audio stays on the Mac.").font(.caption).foregroundStyle(.secondary)
                if !connection.hasRelay { Text("Relay is not configured. Outside-network connectivity is not yet verified.").font(.caption).foregroundStyle(.orange) }
                Button("Remove paired phone", role: .destructive, action: model.revoke).disabled(connection.invitation == nil)
            }.padding(24)
        }.frame(minWidth: 520, minHeight: 580)
    }
    private var nextStep: String {
        if connection.awaitingApproval { return "Approve only the phone you’re pairing." }
        if connection.connected { return "Your phone is connected. Keep PocketDesk open on your phone." }
        if model.active { return "Remote access is enabled. Follow the connection status above." }
        if !model.screenRecordingPermission.isGranted { return "Allow Screen Recording in the Screen viewing section." }
        if model.displayRefreshStatus == .checking { return "Checking the displays available to share…" }
        if !model.canPair { return "Check access, then choose the display to share." }
        if model.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter your connection service address below." }
        if connection.invitation == nil { return "Pair your phone, then approve it on this Mac." }
        return "Enable remote access when you’re ready to connect."
    }
    private func permissionRow(_ title: String, status: HostPermissionStatus) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(permissionLabel(status), systemImage: permissionIcon(status))
                .foregroundStyle(status == .granted ? Color.green : Color.gray)
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
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let image = filter.outputImage, let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
    }
}
