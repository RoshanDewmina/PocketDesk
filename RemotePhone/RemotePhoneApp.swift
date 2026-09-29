import SwiftUI
import WebRTC
import AVFoundation
import Combine

@main
struct RemotePhoneApp: App {
    @StateObject private var model = PhoneRemoteModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRemoteView(model: model, connection: model.connection)
                .tint(Farside.Palette.bone)
                .preferredColorScheme(.dark)
                .onAppear {
                    FarsideSystemIntegrations.shared.attach(model)
                    model.sceneChanged(phase)
                }
                .onChange(of: phase) { _, value in model.sceneChanged(value) }
        }
    }
}

enum PairingEntry: String, Identifiable {
    case scan, paste
    var id: String { rawValue }
}

struct PendingText {
    let requestID: String
    let payload: String
    let origin: TextOrigin
    let sentAt: TimeInterval

    func draftAfterAcknowledgment(_ currentDraft: String, accepted: Bool) -> String {
        accepted && origin == .draft && currentDraft == payload ? "" : currentDraft
    }
}

enum TextOrigin { case draft, voice }

enum VoiceDeliveryStatus: Equatable {
    case idle, waiting, accepted, refused, uncertain, notQueued
}

/// A focus reply may open the local keyboard only for the most recent admitted click.
struct TextFocusProbeGate {
    private(set) var pending: (probe: String, epoch: UInt64, sentAt: TimeInterval)?

    mutating func begin(epoch: UInt64, at now: TimeInterval) -> String {
        let probe = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        pending = (probe, epoch, now)
        return probe
    }

    mutating func invalidate() { pending = nil }

    mutating func consume(probe: String?, editable: Bool?, responseEpoch: UInt64,
                          currentEpoch: UInt64, at now: TimeInterval, allowed: Bool) -> Bool {
        guard let pending else { return false }
        guard now >= pending.sentAt, now - pending.sentAt <= 1 else {
            self.pending = nil
            return false
        }
        guard probe == pending.probe else { return false }
        self.pending = nil
        return editable == true && allowed && responseEpoch == pending.epoch && currentEpoch == pending.epoch
    }
}

/// What the concealed screen explains after the app returns from the background.
enum ResumeState: Equatable {
    case none, backgrounded, reconnecting, needsChoice
}

@MainActor
final class PhoneRemoteModel: ObservableObject {
    /// A lost live session keeps retrying for about 90 seconds, long enough for the Mac's
    /// watchdog to relaunch a crashed or hung Farside with the same pairing.
    #if DEBUG
    // E2E mode keeps its own trust; see PhoneE2E.swift.
    let connection = RemoteCoordinator(isHost: false, store: PhoneE2E.active?.pairStore, sessionLossRetryLimit: 24,
                                       maximumRetryDelayNanoseconds: 4_000_000_000)
    #else
    let connection = RemoteCoordinator(isHost: false, sessionLossRetryLimit: 24,
                                       maximumRetryDelayNanoseconds: 4_000_000_000)
    #endif
    let pointerLocator = PointerLocator()
    let pointerOverlay = PointerOverlayModel()
    let clipboard = PhoneClipboard()
    @Published private(set) var hostFeatures: Set<String> = []
    @Published private(set) var resumeState: ResumeState = .none
    @Published private(set) var hostPresence: HostPresence?
    /// The Mac's privacy curtain, or nil when the Mac does not support one.
    @Published private(set) var curtainState: PrivacyCurtainState?
    /// A short explanation shown over the live session, cleared after a few seconds.
    @Published private(set) var sessionNotice: String?
    private var sessionNoticeTask: Task<Void, Never>?
    private var recoveryNoticeShown = false
    /// Why the last session ended, when the Mac itself said so.
    @Published private(set) var macNotice: String?
    private var departureReason: HostPresence?
    private var continuity = BackgroundContinuity()
    private let background: BackgroundExecution
    private var holdTask: Task<Void, Never>?
    private var resumeWatchdog: Task<Void, Never>?
    private var backgroundEndTask: Task<Void, Never>?
    private var lastHostStatusAt: TimeInterval = 0
    private var clipboardObserver: AnyCancellable?
    private var pointerLocatorSupported = false
    @Published private(set) var appliedStreamQuality: StreamQuality?
    @Published private(set) var streamSummaryLines: [String] = []
    /// Route and network round trip from the latest stream statistics, for the dock caption.
    @Published private(set) var link: LinkSummary?
    @Published var streamQuality: StreamQuality = .sharp {
        didSet {
            if oldValue != streamQuality { qualityRequestedAt = ProcessInfo.processInfo.systemUptime }
        }
    }
    private var qualityRequestedAt: TimeInterval?

    var streamQualityStatus: String? {
        guard let appliedStreamQuality else { return "Update Farside on your Mac to change picture quality." }
        guard appliedStreamQuality != streamQuality else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - (qualityRequestedAt ?? ProcessInfo.processInfo.systemUptime)
        return elapsed < 3 ? "Switching to \(streamQuality.title)…"
            : "Mac is still using \(appliedStreamQuality.title). Switch modes to retry."
    }
    private var pointerTimer: Timer?

    @Published var pairingCode = ""
    @Published var error = ""
    @Published var pairingEntry: PairingEntry?
    @Published private(set) var privacyShield = false
    private var hasBeenActive = false
    @Published var draft = ""
    @Published var isComposingText = false
    @Published var dragging = false
    @Published var modifiers: Set<String> = []
    @Published var controlAllowed = false
    @Published var fresh = false
    @Published var captureHealthy = false
    @Published var geometryEpoch: UInt64 = 0
    @Published var textStatus = ""
    @Published private(set) var voiceDeliveryStatus: VoiceDeliveryStatus = .idle
    @Published private(set) var voiceRetryTranscript = ""
    @Published private(set) var contentConcealed = false

    @Published var sourceSize = CGSize(width: 1440, height: 900)
    @Published private(set) var inputRevision: UInt64 = 0
    @Published private(set) var acceptedClicks: UInt64 = 0
    /// Which click the last accepted one was ("click", "right" or "double"), for the contact ripple.
    private(set) var lastAcceptedClick = "click"
    @Published private(set) var autoKeyboardRevision: UInt64 = 0
    @Published private(set) var nativeInteractionSupported = false
    @Published private(set) var doubleClickInterval: TimeInterval = 0.5
    @Published var hapticsEnabled = UserDefaults.standard.object(forKey: "clickHaptics") == nil ? true : UserDefaults.standard.bool(forKey: "clickHaptics") {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "clickHaptics") }
    }
    private var inputToken: String?
    private var tokenReceivedAt: TimeInterval = 0
    private var activeHold: String?
    private var activeHoldCount = 1
    private var explicitHoldDeadline: TimeInterval?
    private let clickFeedback = UIImpactFeedbackGenerator(style: .heavy)
    private let secondaryClickFeedback = UIImpactFeedbackGenerator(style: .rigid)

    private var lastFrame = 0.0
    private var lastCaptureHealth = 0.0
    private var pendingText: PendingText?
    private var textFocusProbe = TextFocusProbeGate()
    private var sceneIsActive = false
    private var timer: Timer?

    init(background: BackgroundExecution? = nil) {
        self.background = background ?? SystemBackgroundExecution()
        #if DEBUG
        contentConcealed = ProcessInfo.processInfo.arguments.contains("--ui-background-concealed-check")
        if contentConcealed { resumeState = .needsChoice }
        #endif
        if let mode = LaunchOptions.viewportOverride { ViewportPreference.store(mode) }
        connection.restore()
        connection.onAuthenticated = { [weak self] in
            guard let self else { return }
            self.contentConcealed = false
            self.resumeState = .none
            self.macNotice = nil
            if let peer = self.connection.media {
                peer.onStreamStatistics = { [weak self, weak peer] report in
                    Task { @MainActor in
                        guard let self, let peer, self.connection.media === peer else { return }
                        self.streamSummaryLines = report.summaryLines
                        self.link = LinkSummary(report)
                        #if DEBUG
                        PhoneE2E.active?.record(report)
                        #endif
                    }
                }
            }
            self.beginHeartbeat()
        }
        connection.onEnded = { [weak self] in
            self?.sessionEnded()
        }
        connection.onControl = { [weak self] data in
            guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else { return }
            self?.receive(action)
        }
        clipboard.transport = { [weak self] frame in
            guard let self, self.connection.connected else { return false }
            return self.connection.sendControl(RemoteAction(action: "clipboard", epoch: self.geometryEpoch, clipboard: frame))
        }
        clipboard.bufferedAmount = { [weak self] in self?.connection.media?.controlBufferedAmount }
        clipboard.pressPaste = { [weak self] in self?.commandShortcut("v") ?? false }
        clipboardObserver = clipboard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        #if DEBUG
        PhoneE2E.active?.attach(self)
        #endif
    }

    #if DEBUG
    /// E2E harness: a shortcut the phone UI has no button for, sent through the same admitted
    /// path (fresh picture, host token, epoch) as every other key.
    func e2eSendKey(_ key: String, modifiers: [String]) -> Bool {
        guard canControl, !key.isEmpty, key.utf8.count <= 32, modifiers.count <= 4 else { return false }
        return sendInput("key", key: key, modifiers: modifiers)
    }
    #endif

    var canControl: Bool {
        !privacyShield && !contentConcealed && connection.connected && controlAllowed && fresh && captureHealthy && geometryEpoch > 0
            && (!nativeInteractionSupported || (inputToken != nil && ProcessInfo.processInfo.systemUptime - tokenReceivedAt < 1))
    }

    var textEditable: Bool { pendingText == nil }

    var textCanSend: Bool {
        !isComposingText && !draft.isEmpty && draft.utf8.count <= 4_096 && draft.utf16.count <= 1_024 && pendingText == nil
    }

    var textLimitMessage: String? {
        guard !draft.isEmpty else { return nil }
        if draft.utf8.count > 4_096 || draft.utf16.count > 1_024 { return "That’s too long to send at once. Send it in two parts." }
        return nil
    }

    #if DEBUG
    func previewEditableFocusForTesting() { autoKeyboardRevision &+= 1 }
    #endif

    var clipboardSupported: Bool { hostFeatures.contains(SessionFeature.clipboardText) }

    /// Clipboard transfer needs a live session with control allowed on the Mac, but not a
    /// fresh picture: it changes pasteboards, not the screen.
    var clipboardAvailable: Bool {
        clipboardSupported && connection.connected && controlAllowed && !privacyShield && !contentConcealed
    }

    func pasteToMac(_ strings: [String]) {
        guard clipboardAvailable else { clipboard.postUnavailable(clipboardUnavailableMessage); return }
        guard let text = strings.first(where: { !$0.isEmpty }) else {
            clipboard.postUnavailable("Your iPhone clipboard has no text to send.")
            return
        }
        clipboard.send(text)
    }

    /// Presses ⌘C on the Mac through the admitted key path, then brings the copied text here.
    func copySelectionFromMac() {
        guard clipboardAvailable else { clipboard.postUnavailable(clipboardUnavailableMessage); return }
        guard !clipboard.isBusy else { clipboard.postUnavailable("Wait for the current clipboard transfer to finish."); return }
        guard commandShortcut("c") else {
            clipboard.postUnavailable("Copy needs control of your Mac and a fresh picture.")
            return
        }
        clipboard.requestFromMac(afterCopy: true)
    }

    func fetchMacClipboard() {
        guard clipboardAvailable else { clipboard.postUnavailable(clipboardUnavailableMessage); return }
        clipboard.requestFromMac()
    }

    private var clipboardUnavailableMessage: String {
        if !connection.connected { return "Connect to your Mac to use the clipboard." }
        if !clipboardSupported { return "Clipboard needs the updated Farside on your Mac." }
        if !controlAllowed { return "Your Mac is view-only, so the clipboard is off." }
        return "The clipboard is unavailable right now."
    }

    var canWakeDisplay: Bool {
        hostFeatures.contains(SessionFeature.displayWake) && connection.connected && controlAllowed
            && !privacyShield && !contentConcealed
    }

    func wakeMacDisplay() {
        guard canWakeDisplay else { return }
        _ = connection.sendControl(RemoteAction(action: "wake", epoch: geometryEpoch))
    }

    var curtainSupported: Bool { hostFeatures.contains(SessionFeature.privacyCurtain) }

    /// Changing the curtain affects the Mac's own screen, so it needs control, like waking it.
    var canChangeCurtain: Bool {
        curtainSupported && connection.connected && controlAllowed && !privacyShield && !contentConcealed
    }

    /// Turns the Mac's "hide screen while sharing" preference on or off. The Mac confirms the new
    /// state on its next status message; nothing changes locally until then.
    @discardableResult
    func setMacCurtain(_ on: Bool) -> Bool {
        guard canChangeCurtain else { return false }
        let request: PrivacyCurtainRequest = on ? .up : .down
        return connection.sendControl(RemoteAction(action: "curtain", epoch: geometryEpoch, curtain: request.rawValue))
    }

    private func showSessionNotice(_ text: String) {
        sessionNotice = text
        sessionNoticeTask?.cancel()
        sessionNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sessionNotice = nil
        }
    }

    @discardableResult
    func commandShortcut(_ key: String) -> Bool {
        guard canControl else { return false }
        return sendInput("key", key: key, modifiers: ["command"])
    }

    @discardableResult
    func enroll(_ code: String) -> Bool {
        do {
            try connection.enroll(code.trimmingCharacters(in: .whitespacesAndNewlines))
            pairingCode = ""
            error = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func frameReceived() {
        lastFrame = ProcessInfo.processInfo.systemUptime
        fresh = true
        #if DEBUG
        PhoneE2E.active?.frameReceived()
        #endif
    }

    @discardableResult
    func action(_ name: String, x: Double = 0, y: Double = 0) -> Bool {
        sendInput(name, x: x, y: y, count: ["click", "right", "double"].contains(name) ? 1 : nil)
    }

    @discardableResult
    private func sendInput(_ name: String, x: Double = 0, y: Double = 0,
                           count: Int? = nil, hold: String? = nil,
                           phase: String? = nil, stream: String? = nil,
                           text: String = "", key: String = "", modifiers: [String] = [],
                           probeTextFocus: Bool = false, pointerSync: PointerSync? = nil) -> Bool {
        textFocusProbe.invalidate()
        guard canControl else { return false }
        let focusProbe = probeTextFocus && nativeInteractionSupported && !dragging && activeHold == nil
            ? textFocusProbe.begin(epoch: geometryEpoch, at: ProcessInfo.processInfo.systemUptime) : nil
        let envelope = nativeInteractionSupported
            ? NativeInteraction(token: inputToken, hold: hold ?? activeHold,
                                clickCount: count ?? (activeHold == nil ? nil : activeHoldCount),
                                phase: phase, stream: stream) : nil
        let isClick = ["click", "right", "double"].contains(name)
        if isClick && hapticsEnabled { (name == "right" ? secondaryClickFeedback : clickFeedback).prepare() }
        let accepted = connection.sendControl(RemoteAction(action: name, x: x, y: y,
            text: text, key: key, modifiers: modifiers, epoch: geometryEpoch, interaction: envelope,
            pointerSync: pointerSync, textFocusProbe: focusProbe))
        if !accepted { textFocusProbe.invalidate() }
        if accepted && isClick {
            lastAcceptedClick = name == "click" && (count ?? 1) >= 2 ? "double" : name
            acceptedClicks &+= 1
            if hapticsEnabled { playClickHaptic(secondary: name == "right") }
        }
        return accepted
    }

    /// A click is one heavy tap; a right-click is two lighter rigid taps 70 ms apart.
    private func playClickHaptic(secondary: Bool) {
        guard secondary else { clickFeedback.impactOccurred(intensity: 1.0); return }
        secondaryClickFeedback.impactOccurred(intensity: 0.75)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [secondaryClickFeedback] in
            secondaryClickFeedback.impactOccurred(intensity: 0.75)
        }
    }

    @discardableResult
    func gesture(_ command: NativeGestureCommand) -> Bool {
        switch command {
        case .move(let delta):
            let ordinal = pointerOverlay.reserveMoveOrdinal()
            let accepted = sendInput("move", x: delta.width, y: delta.height,
                                     pointerSync: ordinal.map { PointerSync(move: $0) })
            if accepted {
                pointerOverlay.localMove(ordinal: ordinal, delta: delta, follow: !dragging)
                if !dragging && !pointerOverlay.hostSupported {
                    pointerLocator.moved(at: ProcessInfo.processInfo.systemUptime)
                }
            }
            return accepted
        case .scroll(let delta, let phase, let stream):
            pointerLocator.clear()
            return sendInput("scroll", x: delta.width, y: delta.height, phase: phase, stream: stream)
        case .click(let count):
            // Legacy hosts have no semantic count contract. First tap is still prompt.
            return sendInput("click", count: count, probeTextFocus: count == 1 || count == 2)
        case .secondaryClick:
            return sendInput("right", count: 1)
        case .workspaceSwipe(let direction):
            guard !dragging, activeHold == nil else { return false }
            let key: String
            switch direction {
            case .left: key = "right"
            case .right: key = "left"
            case .up: key = "up"
            case .down: key = "down"
            }
            return sendInput("key", key: key, modifiers: ["control"])
        case .dragBegan(let id, let count):
            pointerLocator.clear()
            guard nativeInteractionSupported, activeHold == nil,
                  sendInput("dragDown", count: count, hold: id) else { return false }
            activeHold = id; activeHoldCount = count
            explicitHoldDeadline = nil; dragging = true
            return true
        case .dragEnded(let id):
            guard id == activeHold else { return false }
            let accepted = sendInput("dragUp", count: activeHoldCount, hold: id)
            release()
            return accepted
        case .zoom, .zoomEnded, .zoomToggle, .navigate, .pan:
            return false
        }
    }

    func cancelInput() {
        textFocusProbe.invalidate()
        pointerLocator.clear()
        release()
        inputRevision &+= 1
    }

    func key(_ key: String) {
        guard canControl else { return }
        _ = sendInput("key", key: key, modifiers: Array(modifiers))
        modifiers.removeAll()
    }

    func sendText() {
        guard canControl, textCanSend else { return }
        _ = queueText(draft, origin: .draft)
    }

    @discardableResult
    func sendVoiceText(_ transcript: String) -> Bool {
        guard pendingText == nil else { return false }
        stageVoiceRetry(transcript)
        guard canControl, !isComposingText,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transcript.utf8.count <= 4_096, transcript.utf16.count <= 1_024 else {
            voiceDeliveryStatus = .notQueued
            return false
        }
        return queueText(transcript, origin: .voice)
    }

    private func queueText(_ payload: String, origin: TextOrigin) -> Bool {
        let pending = PendingText(
            requestID: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            payload: payload,
            origin: origin,
            sentAt: ProcessInfo.processInfo.systemUptime
        )
        guard sendInput("text", text: payload, key: pending.requestID) else {
            if origin == .voice { voiceDeliveryStatus = .notQueued }
            else { textStatus = "Text was not queued. Your draft is still here." }
            return false
        }
        pendingText = pending
        if origin == .voice { voiceDeliveryStatus = .waiting }
        else { textStatus = "Waiting for your Mac to confirm text delivery…" }
        return true
    }

    func drag() {
        if dragging { cancelInput(); return }
        // The explicitly labeled command mode is bounded, unlike a hidden drag lock.
        guard nativeInteractionSupported, canControl else { return }
        let id = UUID().uuidString
        guard sendInput("dragDown", count: 1, hold: id) else { return }
        activeHold = id; activeHoldCount = 1; dragging = true
        explicitHoldDeadline = ProcessInfo.processInfo.systemUptime + 10
    }

    func release() {
        textFocusProbe.invalidate()
        if connection.connected {
            if nativeInteractionSupported {
                if let activeHold {
                    _ = connection.sendControl(RemoteAction(action: "release", epoch: geometryEpoch,
                        interaction: NativeInteraction(token: inputToken, hold: activeHold, clickCount: activeHoldCount)))
                }
            } else {
                _ = connection.sendControl(RemoteAction(action: "release", epoch: geometryEpoch))
            }
        }
        dragging = false
        activeHold = nil
        explicitHoldDeadline = nil
        modifiers.removeAll()
    }

    func disconnect() {
        clearContinuity()
        release()
        connection.stop()
        end()
    }

    /// `.inactive` covers Control Center, Notification Center, call banners and the start of a
    /// screen recording: the session survives and the picture is only shielded until the scene
    /// is active again. `.background` conceals the screen, releases input and pauses video; a
    /// live session is held briefly for a quick return, then closed and resumed on return.
    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneIsActive = true
            hasBeenActive = true
            privacyShield = false
            returnToForeground()
        case .inactive:
            sceneIsActive = false
            if hasBeenActive {
                cancelInput()
                privacyShield = true
                if connection.connected {
                    background.begin { [weak self] in self?.endBackgroundHold(immediately: true) }
                }
            }
        case .background:
            sceneIsActive = false
            privacyShield = false
            if hasBeenActive { enterBackground() }
        @unknown default:
            break
        }
    }

    func enterBackground() {
        let now = ProcessInfo.processInfo.systemUptime
        contentConcealed = true
        resumeState = .backgrounded
        cancelInput()
        suspendInputReadiness()
        clipboard.cancel()
        clipboard.clearNotice()
        resumeWatchdog?.cancel(); resumeWatchdog = nil
        var canHold = connection.connected && hostFeatures.contains(SessionFeature.backgroundPause)
        if canHold {
            canHold = background.begin { [weak self] in self?.endBackgroundHold(immediately: true) }
        }
        let sessionOpen = connection.connected || connection.isRunning || LaunchOptions.layoutCheck
        switch continuity.enterBackground(at: now, sessionOpen: sessionOpen, canHold: canHold,
                                          budget: background.remainingTime) {
        case .none:
            background.end()
        case .hold(let seconds):
            _ = connection.sendControl(RemoteAction(action: "pause", epoch: geometryEpoch))
            holdTask?.cancel()
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.endBackgroundHold(immediately: false)
            }
        case .release:
            release()
            connection.stop()
            endBackgroundExecutionSoon()
        }
    }

    /// Closes a held session cleanly before iOS suspends the app, so the relay frees the
    /// phone's slot at once and the return can reconnect immediately.
    private func endBackgroundHold(immediately: Bool) {
        holdTask?.cancel(); holdTask = nil
        if continuity.endHold() {
            release()
            connection.stop()
        }
        if immediately { background.end() } else { endBackgroundExecutionSoon() }
    }

    private func endBackgroundExecutionSoon() {
        backgroundEndTask?.cancel()
        backgroundEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.background.end()
        }
    }

    private func returnToForeground() {
        holdTask?.cancel(); holdTask = nil
        backgroundEndTask?.cancel(); backgroundEndTask = nil
        background.end()
        let now = ProcessInfo.processInfo.systemUptime
        switch continuity.returnToForeground(at: now, sessionConnected: connection.connected) {
        case .none:
            if resumeState == .backgrounded {
                resumeState = .none
                contentConcealed = false
            }
        case .resumeHeldSession:
            resumeHeldSession(at: now)
        case .reconnect:
            if LaunchOptions.layoutCheck || connection.invitation == nil {
                resumeState = .needsChoice
            } else {
                beginAutomaticReconnect()
            }
        case .offerReconnect:
            resumeState = .needsChoice
        }
    }

    private func resumeHeldSession(at now: TimeInterval) {
        let supported = hostFeatures.contains(SessionFeature.backgroundPause)
        guard !supported || connection.sendControl(RemoteAction(action: "resume", epoch: geometryEpoch)) else {
            // A failed send already started the coordinator's bounded reconnect.
            resumeState = .reconnecting
            if !connection.isRunning { connection.start() }
            return
        }
        resumeState = .none
        contentConcealed = false
        resumeWatchdog?.cancel()
        resumeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.connection.connected,
                  self.lastHostStatusAt < now else { return }
            self.contentConcealed = true
            self.beginAutomaticReconnect(restart: true)
        }
    }

    private func beginAutomaticReconnect(restart: Bool = false) {
        resumeState = .reconnecting
        if restart { connection.stop() }
        if !connection.isRunning { connection.start() }
    }

    private func suspendInputReadiness() {
        fresh = false
        captureHealthy = false
        inputToken = nil
        lastFrame = 0
        lastCaptureHealth = 0
    }

    private func clearContinuity() {
        continuity.reset()
        holdTask?.cancel(); holdTask = nil
        resumeWatchdog?.cancel(); resumeWatchdog = nil
        backgroundEndTask?.cancel(); backgroundEndTask = nil
        background.end()
        resumeState = .none
    }

    private func sessionEnded() {
        end()
        guard continuity.isHolding else { return }
        // Lost while backgrounded: stop the coordinator's retries until the app returns.
        continuity.endHold()
        holdTask?.cancel(); holdTask = nil
        Task { @MainActor [weak self] in self?.connection.stop() }
        endBackgroundExecutionSoon()
    }

    func dismissConcealment() {
        guard !connection.connected else { return }
        if resumeState == .reconnecting { connection.stop() }
        clearContinuity()
        contentConcealed = false
    }

    func reconnect() {
        guard connection.invitation != nil else { dismissConcealment(); return }
        contentConcealed = true
        beginAutomaticReconnect(restart: connection.isRunning && !connection.connected)
    }

    func clearUncertainText() {
        guard pendingText?.origin == .draft else { return }
        pendingText = nil
        textStatus = ""
    }

    func clearUncertainVoiceText() {
        guard pendingText?.origin == .voice, voiceDeliveryStatus == .uncertain else { return }
        pendingText = nil
        voiceDeliveryStatus = .idle
    }

    func prepareVoiceInput() {
        if pendingText?.origin != .voice && voiceRetryTranscript.isEmpty { voiceDeliveryStatus = .idle }
    }

    func stageVoiceRetry(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        voiceRetryTranscript = transcript
        voiceDeliveryStatus = .notQueued
    }

    func discardVoiceRetry() {
        if pendingText?.origin == .voice { pendingText = nil }
        voiceRetryTranscript = ""
        voiceDeliveryStatus = .idle
    }

    private func receive(_ action: RemoteAction) {
        switch action.action {
        case "viewing":
            controlAllowed = action.x == 1
            if !controlAllowed { pointerLocator.clear(); release() }
        case "heartbeat":
            if textFocusProbe.consume(probe: action.textFocusProbe, editable: action.textFocusEditable,
                                      responseEpoch: action.epoch, currentEpoch: geometryEpoch,
                                      at: ProcessInfo.processInfo.systemUptime,
                                      allowed: sceneIsActive && canControl && !dragging && textEditable && !isComposingText) {
                autoKeyboardRevision &+= 1
            }
            if action.epoch == geometryEpoch, canControl, pointerLocatorSupported {
                pointerLocator.receive(action, at: ProcessInfo.processInfo.systemUptime, sourceSize: sourceSize)
            }
        case "pointer":
            if action.epoch == geometryEpoch, let sync = action.pointerSync { pointerOverlay.receive(sync) }
        case "capture":
            lastHostStatusAt = ProcessInfo.processInfo.systemUptime
            hostFeatures = Set(action.features ?? [])
            hostPresence = action.hostState.flatMap(HostPresence.init(rawValue:))
            let previousCurtain = curtainState
            curtainState = curtainSupported
                ? action.curtain.flatMap(PrivacyCurtainState.init(rawValue:)) ?? .off : nil
            if let notice = PhoneSessionNotice.curtainChange(from: previousCurtain, to: curtainState) {
                showSessionNotice(notice)
            }
            if action.hostEvent == HostLifecycleEvent.recovered.rawValue, !recoveryNoticeShown {
                recoveryNoticeShown = true
                showSessionNotice(PhoneSessionNotice.hostRecovered)
            }
            if let hostPresence, hostPresence != .displayAsleep { departureReason = hostPresence }
            if let hostStream = action.hostStream { connection.media?.remoteHostSummary = hostStream }
            appliedStreamQuality = action.streamQuality
            if action.streamQuality != nil, action.streamQuality != streamQuality, qualityRequestedAt == nil {
                qualityRequestedAt = ProcessInfo.processInfo.systemUptime
            }
            pointerLocatorSupported = action.pointerLocatorSupported == true
            pointerOverlay.hostCapability(action.pointerSync)
            if let interaction = action.interaction, interaction.version == 1 {
                nativeInteractionSupported = true
                inputToken = interaction.token
                tokenReceivedAt = ProcessInfo.processInfo.systemUptime
                if let interval = interaction.doubleClickInterval { doubleClickInterval = interval }
            }
            captureHealthy = action.x == 1
            lastCaptureHealth = captureHealthy ? ProcessInfo.processInfo.systemUptime : 0
            if !captureHealthy { pointerLocator.clear(); release() }
        case "geometry":
            lastHostStatusAt = ProcessInfo.processInfo.systemUptime
            guard action.epoch != geometryEpoch else { return }
            cancelInput()
            inputToken = nil
            if action.x.isFinite, action.y.isFinite, action.x > 0, action.y > 0 {
                sourceSize = CGSize(width: action.x, height: action.y)
            }
            pointerOverlay.reset(sourceSize: sourceSize)
            geometryEpoch = action.epoch
            fresh = false
            captureHealthy = false
            lastFrame = 0
            lastCaptureHealth = 0
        case "textResult":
            receiveTextResult(action)
        case "clipboard":
            if let frame = action.clipboard { clipboard.receive(frame) }
        case "release":
            if nativeInteractionSupported {
                guard let activeHold, action.epoch == geometryEpoch,
                      action.interaction?.hold == activeHold else { return }
            }
            activeHold = nil
            explicitHoldDeadline = nil
            dragging = false
            inputRevision &+= 1
            modifiers.removeAll()
            textStatus = "Drag ended on your Mac."
        default:
            break
        }
    }

    static func notice(for presence: HostPresence, at date: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch presence {
        case .sleeping: return "Your Mac went to sleep at \(time). Wake it to reconnect."
        case .locked: return "Your Mac was locked at \(time). Farside can’t unlock it; unlock it in person to reconnect."
        case .switchedUser: return "Another user started using your Mac at \(time)."
        case .displayAsleep: return "Your Mac’s display is asleep."
        }
    }

    private func receiveTextResult(_ action: RemoteAction) {
        guard let pending = pendingText, action.key == pending.requestID else { return }
        pendingText = nil
        if pending.origin == .voice {
            voiceDeliveryStatus = action.x == 1 ? .accepted : .refused
            if action.x == 1 { voiceRetryTranscript = "" }
            return
        }
        if action.x == 1 {
            draft = pending.draftAfterAcknowledgment(draft, accepted: true)
            textStatus = draft.isEmpty ? "Sent to your Mac." : "Mac accepted input; your edited draft was kept."
        } else {
            textStatus = "Your Mac refused the text. Your draft is still here."
        }
    }

    private func beginHeartbeat() {
        pointerTimer?.invalidate()
        pointerLocator.clear()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let probing = self.canControl && self.pointerLocatorSupported && !self.pointerOverlay.hostSupported
                if let probe = self.pointerLocator.poll(at: now, available: probing) {
                    _ = self.connection.sendControl(RemoteAction(action: "heartbeat", epoch: self.geometryEpoch, pointerProbe: probe))
                }
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if connection.connected {
            _ = connection.sendControl(RemoteAction(action: "heartbeat", epoch: geometryEpoch,
                pointerSync: pointerOverlay.advertisement(),
                streamQuality: appliedStreamQuality == nil ? nil : streamQuality))
        }
        pointerOverlay.refresh()
        if fresh && now - lastFrame > 2 {
            fresh = false
            pointerLocator.clear()
            release()
        }
        if captureHealthy && now - lastCaptureHealth > 2 {
            captureHealthy = false
            pointerLocator.clear()
            release()
        }
        if activeHold != nil {
            if !canControl || explicitHoldDeadline.map({ now >= $0 }) == true {
                cancelInput()
            } else {
                _ = sendInput("holdRenew", hold: activeHold)
            }
        }
        if let pending = pendingText, now - pending.sentAt > 4 {
            if pending.origin == .voice, voiceDeliveryStatus == .waiting {
                voiceDeliveryStatus = .uncertain
            } else if pending.origin == .draft, textStatus.hasPrefix("Waiting") {
                textStatus = "Delivery is uncertain. Your draft is still here; it was not sent again."
            }
        }
    }

    private func end() {
        textFocusProbe.invalidate()
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLocatorSupported = false
        appliedStreamQuality = nil
        streamSummaryLines = []
        link = nil
        qualityRequestedAt = nil
        pointerLocator.clear()
        pointerOverlay.reset(sourceSize: sourceSize)
        timer?.invalidate()
        timer = nil
        fresh = false
        captureHealthy = false
        controlAllowed = false
        dragging = false
        activeHold = nil
        explicitHoldDeadline = nil
        modifiers.removeAll()
        geometryEpoch = 0
        nativeInteractionSupported = false
        inputToken = nil
        tokenReceivedAt = 0
        inputRevision &+= 1
        lastFrame = 0
        lastCaptureHealth = 0
        if pendingText?.origin == .voice { voiceDeliveryStatus = .uncertain }
        pendingText = nil
        textStatus = ""
        hostFeatures = []
        hostPresence = nil
        curtainState = nil
        recoveryNoticeShown = false
        if let departureReason { macNotice = Self.notice(for: departureReason) }
        departureReason = nil
        clipboard.cancel()
        resumeWatchdog?.cancel(); resumeWatchdog = nil
    }
}

/// Route and round trip for the dock caption. Network RTT, not end-to-end latency.
struct LinkSummary: Equatable {
    var route: String?
    var roundTripMs: Int?

    init?(_ report: StreamStatsReport) {
        route = report.route.flatMap { $0 == "Direct" || $0 == "Relay" ? $0 : nil }
        roundTripMs = report.rttMs.map { Int($0.rounded()) }
        guard route != nil || roundTripMs != nil else { return nil }
    }
}

struct RemoteVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack
    var counters: StreamCounters?
    let onFrame: () -> Void

    func makeCoordinator() -> FrameObserver { FrameObserver(onFrame: onFrame) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        context.coordinator.track = track
        context.coordinator.view = view
        context.coordinator.presentation = VideoPresentationProbe.install(on: view)
        context.coordinator.presentation?.counters = counters
        track.add(context.coordinator)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.presentation?.counters = counters
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(context.coordinator)
            context.coordinator.track = track
            track.add(context.coordinator)
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: FrameObserver) {
        coordinator.track?.remove(coordinator)
        coordinator.track = nil
        coordinator.presentation?.uninstall()
        coordinator.presentation = nil
    }
}

/// The track's only renderer for the main picture: it reports arrivals and passes frames on to
/// the Metal view through `RestampingRenderer`.
final class FrameObserver: NSObject, RTCVideoRenderer {
    var track: RTCVideoTrack?
    weak var view: RTCMTLVideoView? {
        didSet { forward.target = view }
    }
    var presentation: VideoPresentationProbe? {
        didSet { lock.lock(); tracker = presentation?.tracker; lock.unlock() }
    }
    let onFrame: () -> Void
    private let forward = RestampingRenderer()
    private let lock = NSLock()
    private var last = 0.0
    private var tracker: PresentationTracker?

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {
        forward.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        forward.renderFrame(frame)
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let notify = now - last > 0.25
        if notify { last = now }
        let tracker = tracker
        lock.unlock()
        tracker?.frameArrived(at: now)
        if notify {
            DispatchQueue.main.async { [weak self] in self?.onFrame() }
        }
    }
}

/// Every RTCMTLVideoView must get its frames through this instead of straight from the track.
/// With the tuned zero playout delay, libwebrtc stamps every decoded frame with render time 0,
/// and RTCMTLVideoView skips a frame whose timestamp equals the last one it drew, so it would
/// never draw at all. Frames are passed on with a strictly increasing timestamp.
final class RestampingRenderer: NSObject, RTCVideoRenderer {
    weak var target: RTCMTLVideoView?
    private let lock = NSLock()
    private var lastStampNs: Int64 = 0

    init(target: RTCMTLVideoView? = nil) {
        self.target = target
    }

    func setSize(_ size: CGSize) {
        target?.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let target else { return }
        lock.lock()
        let stampNs = max(Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000), lastStampNs + 1)
        lastStampNs = stampNs
        lock.unlock()
        target.renderFrame(RTCVideoFrame(buffer: frame.buffer, rotation: frame.rotation, timeStampNs: stampNs))
    }
}
