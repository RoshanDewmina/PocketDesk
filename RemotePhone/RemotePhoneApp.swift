import SwiftUI
import WebRTC
import AVFoundation

@main
struct RemotePhoneApp: App {
    @StateObject private var model = PhoneRemoteModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRemoteView(model: model, connection: model.connection)
                .tint(PhoneTheme.tint)
                .onAppear { model.sceneChanged(phase) }
                .onChange(of: phase) { _, value in model.sceneChanged(value) }
        }
    }
}

enum PairingEntry: String, Identifiable {
    case scan, paste
    var id: String { rawValue }
}

private struct PendingText {
    let requestID: String
    let draft: String
    let sentAt: TimeInterval
}

@MainActor
final class PhoneRemoteModel: ObservableObject {
    let connection = RemoteCoordinator(isHost: false)
    let pointerLocator = PointerLocator()
    private var pointerLocatorSupported = false
    @Published private(set) var appliedStreamQuality: StreamQuality?
    @Published private(set) var streamSummaryLines: [String] = []
    @Published var streamQuality: StreamQuality = .sharp {
        didSet {
            if oldValue != streamQuality { qualityRequestedAt = ProcessInfo.processInfo.systemUptime }
        }
    }
    private var qualityRequestedAt: TimeInterval?

    var streamQualityStatus: String? {
        guard let appliedStreamQuality else { return "Picture quality needs the updated Mac companion." }
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
    @Published private(set) var contentConcealed = false

    @Published var sourceSize = CGSize(width: 1440, height: 900)
    @Published private(set) var inputRevision: UInt64 = 0
    @Published private(set) var acceptedClicks: UInt64 = 0
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
    private let clickFeedback = UIImpactFeedbackGenerator(style: .light)

    private var lastFrame = 0.0
    private var lastCaptureHealth = 0.0
    private var pendingText: PendingText?
    private var timer: Timer?

    init() {
        #if DEBUG
        contentConcealed = ProcessInfo.processInfo.arguments.contains("--ui-background-concealed-check")
        #endif
        if let mode = LaunchOptions.viewportOverride { ViewportPreference.store(mode) }
        connection.restore()
        connection.onAuthenticated = { [weak self] in
            guard let self else { return }
            self.contentConcealed = false
            if let peer = self.connection.media {
                peer.onStreamStatistics = { [weak self, weak peer] report in
                    Task { @MainActor in
                        guard let self, let peer, self.connection.media === peer else { return }
                        self.streamSummaryLines = report.summaryLines
                    }
                }
            }
            self.beginHeartbeat()
        }
        connection.onEnded = { [weak self] in
            self?.end()
        }
        connection.onControl = { [weak self] data in
            guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else { return }
            self?.receive(action)
        }
    }

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
        if draft.utf8.count > 4_096 { return "Text is limited to 4,096 UTF-8 bytes." }
        if draft.utf16.count > 1_024 { return "Text is limited to 1,024 UTF-16 units." }
        return nil
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
    }

    @discardableResult
    func action(_ name: String, x: Double = 0, y: Double = 0) -> Bool {
        sendInput(name, x: x, y: y, count: ["click", "right", "double"].contains(name) ? 1 : nil)
    }

    @discardableResult
    private func sendInput(_ name: String, x: Double = 0, y: Double = 0,
                           count: Int? = nil, hold: String? = nil,
                           phase: String? = nil, stream: String? = nil,
                           text: String = "", key: String = "", modifiers: [String] = []) -> Bool {
        guard canControl else { return false }
        let envelope = nativeInteractionSupported
            ? NativeInteraction(token: inputToken, hold: hold ?? activeHold,
                                clickCount: count ?? (activeHold == nil ? nil : activeHoldCount),
                                phase: phase, stream: stream) : nil
        let isClick = ["click", "right", "double"].contains(name)
        if isClick && hapticsEnabled { clickFeedback.prepare() }
        let accepted = connection.sendControl(RemoteAction(action: name, x: x, y: y,
            text: text, key: key, modifiers: modifiers, epoch: geometryEpoch, interaction: envelope))
        if accepted && isClick {
            acceptedClicks &+= 1
            if hapticsEnabled { clickFeedback.impactOccurred(intensity: 0.65) }
        }
        return accepted
    }

    @discardableResult
    func gesture(_ command: NativeGestureCommand) -> Bool {
        switch command {
        case .move(let delta):
            let accepted = sendInput("move", x: delta.width, y: delta.height)
            if accepted && !dragging { pointerLocator.moved(at: ProcessInfo.processInfo.systemUptime) }
            return accepted
        case .scroll(let delta, let phase, let stream):
            pointerLocator.clear()
            return sendInput("scroll", x: delta.width, y: delta.height, phase: phase, stream: stream)
        case .click(let count):
            // Legacy hosts have no semantic count contract. First tap is still prompt.
            return sendInput("click", count: count)
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
        let pending = PendingText(
            requestID: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            draft: draft,
            sentAt: ProcessInfo.processInfo.systemUptime
        )
        guard sendInput("text", text: pending.draft, key: pending.requestID) else {
            textStatus = "Text was not queued. Your draft is still here."
            return
        }
        pendingText = pending
        textStatus = "Waiting for your Mac to confirm text delivery…"
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
        release()
        connection.stop()
        end()
    }

    /// `.inactive` covers Control Center, Notification Center, call banners and the start of a
    /// screen recording: the session survives and the picture is only shielded until the scene
    /// is active again. A real `.background` ends the session and keeps the screen hidden.
    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            hasBeenActive = true
            privacyShield = false
        case .inactive:
            if hasBeenActive {
                cancelInput()
                privacyShield = true
            }
        case .background:
            privacyShield = false
            if hasBeenActive { concealForBackground() }
        @unknown default:
            break
        }
    }

    func concealForBackground() {
        contentConcealed = true
        disconnect()
    }

    func dismissConcealment() {
        guard !connection.connected else { return }
        contentConcealed = false
    }

    func reconnect() {
        dismissConcealment()
        guard !contentConcealed, connection.invitation != nil else { return }
        connection.start()
    }

    func clearUncertainText() {
        pendingText = nil
        textStatus = ""
    }

    private func receive(_ action: RemoteAction) {
        switch action.action {
        case "viewing":
            controlAllowed = action.x == 1
            if !controlAllowed { pointerLocator.clear(); release() }
        case "heartbeat":
            if action.epoch == geometryEpoch, canControl, pointerLocatorSupported {
                pointerLocator.receive(action, at: ProcessInfo.processInfo.systemUptime, sourceSize: sourceSize)
            }
        case "capture":
            appliedStreamQuality = action.streamQuality
            if action.streamQuality != nil, action.streamQuality != streamQuality, qualityRequestedAt == nil {
                qualityRequestedAt = ProcessInfo.processInfo.systemUptime
            }
            pointerLocatorSupported = action.pointerLocatorSupported == true
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
            guard action.epoch != geometryEpoch else { return }
            cancelInput()
            inputToken = nil
            if action.x.isFinite, action.y.isFinite, action.x > 0, action.y > 0 {
                sourceSize = CGSize(width: action.x, height: action.y)
            }
            geometryEpoch = action.epoch
            fresh = false
            captureHealthy = false
            lastFrame = 0
            lastCaptureHealth = 0
        case "textResult":
            receiveTextResult(action)
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

    private func receiveTextResult(_ action: RemoteAction) {
        guard let pending = pendingText, action.key == pending.requestID else { return }
        pendingText = nil
        if action.x == 1 {
            if draft == pending.draft { draft = "" }
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
                if let probe = self.pointerLocator.poll(at: now, available: self.canControl && self.pointerLocatorSupported) {
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
                streamQuality: appliedStreamQuality == nil ? nil : streamQuality))
        }
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
        if let pending = pendingText, now - pending.sentAt > 4, textStatus.hasPrefix("Waiting") {
            textStatus = "Delivery is uncertain. Your draft is still here; it was not sent again."
        }
    }

    private func end() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLocatorSupported = false
        appliedStreamQuality = nil
        streamSummaryLines = []
        qualityRequestedAt = nil
        pointerLocator.clear()
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
        pendingText = nil
        textStatus = ""
    }
}

struct RemoteVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack
    let onFrame: () -> Void

    func makeCoordinator() -> FrameObserver { FrameObserver(onFrame: onFrame) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        context.coordinator.track = track
        context.coordinator.view = view
        track.add(view)
        track.add(context.coordinator)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            context.coordinator.track?.remove(context.coordinator)
            context.coordinator.track = track
            track.add(view)
            track.add(context.coordinator)
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: FrameObserver) {
        coordinator.track?.remove(view)
        coordinator.track?.remove(coordinator)
        coordinator.track = nil
    }
}

final class FrameObserver: NSObject, RTCVideoRenderer {
    var track: RTCVideoTrack?
    weak var view: RTCMTLVideoView?
    let onFrame: () -> Void
    private let lock = NSLock()
    private var last = 0.0

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let notify = now - last > 0.25
        if notify { last = now }
        lock.unlock()
        if notify {
            DispatchQueue.main.async { [weak self] in self?.onFrame() }
        }
    }
}
