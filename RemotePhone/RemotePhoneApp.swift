import SwiftUI
import WebRTC
import AVFoundation
import Combine

@main
struct RemotePhoneApp: App {
    @UIApplicationDelegateAdaptor(FarsideAppDelegate.self) private var appDelegate
    @StateObject private var model = PhoneRemoteModel()
    @Environment(\.scenePhase) private var phase

    init() {
        // Transaction.updates must be heard from launch: renewals, refunds, Ask to Buy, other devices.
        // Unit tests host this app and drive their own store against a StoreKit test session.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { AnywhereStore.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            PhoneRemoteView(model: model, connection: model.connection)
                .tint(Farside.Palette.bone)
                .preferredColorScheme(.dark)
                .onAppear {
                    FarsideSystemIntegrations.shared.attach(model)
                    AnywhereAccess.shared.attach(model.connection, store: .shared)
                    AgentPushIntegration.shared.attach(model)
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
    // E2E mode keeps its own trust (see PhoneE2E.swift); a launch that seeds a pairing keeps it in memory.
    let connection = RemoteCoordinator(isHost: false, store: PhoneE2E.active?.pairStore ?? LaunchSeeds.pairingStore(),
                                       sessionLossRetryLimit: 24,
                                       maximumRetryDelayNanoseconds: 4_000_000_000)
    #else
    let connection = RemoteCoordinator(isHost: false, sessionLossRetryLimit: 24,
                                       maximumRetryDelayNanoseconds: 4_000_000_000)
    #endif
    let pointerLocator = PointerLocator()
    let pointerOverlay = PointerOverlayModel()
    let clipboard = PhoneClipboard()
    let linkHints = PhoneLinkHintMonitor()
    @Published private(set) var hostFeatures: Set<String> = []
    @Published private(set) var resumeState: ResumeState = .none
    /// While a live session is held in the background: when Farside lets go of the Mac.
    @Published private(set) var backgroundHoldEndsAt: Date?
    /// Why the last session ended, for the Lock Screen and Dynamic Island.
    private(set) var sessionEndReason: FarsideSessionAttributes.EndReason?
    @Published private(set) var hostPresence: HostPresence?
    /// A grant the Mac reports missing during this session (only `accessibilityOff` arrives here).
    @Published private(set) var sessionBlocker: MacShareBlocker?
    /// The Mac's privacy curtain, or nil when the Mac does not support one.
    @Published private(set) var curtainState: PrivacyCurtainState?
    /// A short explanation shown over the live session, cleared after a few seconds.
    @Published private(set) var sessionNotice: String?
    private var sessionNoticeTask: Task<Void, Never>?
    private var recoveryNoticeShown = false
    /// Why the last session ended, when the Mac itself said so.
    @Published private(set) var macNotice: String?
    /// What the Mac said as the last session ended (asleep, locked, another user), until the next session.
    @Published private(set) var lastDeparture: HostPresence?
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
    /// Connection Health integration point: the AWDL once-a-second stall tip, nil when not seen.
    @Published private(set) var wifiStallTip: WiFiStallTip?
    private var wifiStall = WiFiStallDetector()
    /// G4: the part of the display the frames cover, as the Mac last reported it; nil for the whole display.
    @Published private(set) var captureRegion: CaptureRegion?
    /// G12: the Mac's own account of its load, for the pill; nil from a Mac without the ladder.
    @Published private(set) var busy: BusyState?
    private(set) var ladder: LadderState?
    private var viewportReporter = ViewportReporter()
    private var phoneLoad: PhoneLoadFeedback?
    private var phoneLoadReportedAt: TimeInterval?
    private var viewportSendTask: Task<Void, Never>?
    private var nativeScreenPixels: PixelSize?
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
    @Published var draft = "" { didSet { secureTextFocus.draftChanged(draft) } }
    @Published var secureTextFocus = SecureTextFocus()
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
    /// Set while a Hold click from Controls keeps the button down; the hold drops by itself then.
    @Published private(set) var explicitHoldDeadline: TimeInterval?
    static let explicitHoldLimit: TimeInterval = 10
    private let clickFeedback = UIImpactFeedbackGenerator(style: .heavy)
    private let secondaryClickFeedback = UIImpactFeedbackGenerator(style: .rigid)

    private var lastFrame = 0.0
    private var lastCaptureHealth = 0.0
    private var pendingText: PendingText?
    private var textFocusProbe = TextFocusProbeGate()
    private var sceneIsActive = false
    private var timer: Timer?
    /// Stream statistics: Mac ↔ phone clock offset from probes on every other heartbeat.
    private var clockSync = ClockSyncEstimator()
    private var heartbeatsSent = 0
    private var reducedPictureNoticeShown = false

    // MARK: Session resume capsule

    /// A view to put back once the new session shows the capsule's display; the session view applies it.
    @Published private(set) var viewportResume: ResumeViewport?
    private let resumeStore: SessionResumeStore
    /// The latest view of this session, or the previous session's view while it waits to be restored.
    private var resumeCapsule: SessionResumeCapsule?
    /// False from authentication until the previous view is restored or dropped; nothing is recorded meanwhile.
    private var resumeResolved = true
    private var resumeStartedAt: TimeInterval = 0

    init(background: BackgroundExecution? = nil, resumeStore: SessionResumeStore = SessionResumeStore()) {
        self.background = background ?? SystemBackgroundExecution()
        self.resumeStore = resumeStore
        resumeCapsule = resumeStore.load()
        NativeCodecCapability.warmUp()
        #if DEBUG
        contentConcealed = ProcessInfo.processInfo.arguments.contains("--ui-background-concealed-check")
        if contentConcealed { resumeState = .needsChoice }
        if let inputProbe {
            // Behave like an upgraded Mac so drags, holds and new actions take their real paths.
            nativeInteractionSupported = true
            inputToken = "probe"
            controlAllowed = true
            geometryEpoch = 1
            MacShortcutMenu.debugNote = { [weak inputProbe] in inputProbe?.note($0) }
        }
        #endif
        if let mode = LaunchOptions.viewportOverride { ViewportPreference.store(mode) }
        if let mode = LaunchOptions.touchModeOverride { UserDefaults.standard.set(mode.rawValue, forKey: TouchInputMode.key) }
        if LaunchOptions.has("--ui-minimap-reset") {
            UserDefaults.standard.removeObject(forKey: "miniMap.phoneLandscape")
            UserDefaults.standard.removeObject(forKey: "miniMap.pad")
        }
        connection.restore()
        linkHints.start()
        connection.onAuthenticated = { [weak self] in
            guard let self else { return }
            self.contentConcealed = false
            self.resumeState = .none
            self.macNotice = nil
            self.lastDeparture = nil
            self.sessionEndReason = nil
            self.backgroundHoldEndsAt = nil
            self.phoneLoad = nil
            self.phoneLoadReportedAt = nil
            self.viewportResume = nil
            self.resumeResolved = self.resumeCapsule == nil
            self.resumeStartedAt = ProcessInfo.processInfo.systemUptime
            self.wifiStall.reset()
            self.wifiStallTip = nil
            if let peer = self.connection.media {
                peer.onStreamStatistics = { [weak self, weak peer] report in
                    Task { @MainActor in
                        guard let self, let peer, self.connection.media === peer else { return }
                        let lines = report.summaryLines
                        if self.streamSummaryLines != lines { self.streamSummaryLines = lines }
                        let link = LinkSummary(report)
                        if self.link != link { self.link = link }
                        if self.wifiStall.observe(report) { self.wifiStallTip = self.wifiStall.tip }
                        self.acceptPhoneStats(report)
                        self.noticeReducedPicture()
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
        #if DEBUG
        if inputProbe != nil { return !privacyShield && !contentConcealed }
        #endif
        return !privacyShield && !contentConcealed && connection.connected && controlAllowed && fresh && captureHealthy && geometryEpoch > 0
            && (!nativeInteractionSupported || (inputToken != nil && ProcessInfo.processInfo.systemUptime - tokenReceivedAt < 1))
    }

    /// The Mac accepts `moveTo`, triple-click counts and hardware modifier flags on pointer actions.
    var absolutePointerSupported: Bool { supports(SessionFeature.absolutePointer) }
    var middleButtonSupported: Bool { supports(SessionFeature.middleButton) }
    var momentumScrollSupported: Bool { supports(SessionFeature.momentumScroll) }
    var extendedKeysSupported: Bool { supports(SessionFeature.extendedKeys) }

    /// Modifier keys held on a hardware keyboard, applied to clicks and pointer motion (⌘-click).
    var hardwareModifiers: [String] = []
    private var extendedKeyNoticeShown = false

    private static let pointerActions: Set<String> = ["move", "moveTo", "click", "right", "double", "middle", "dragDown"]

    // MARK: Display selection

    /// The Mac's displays, when it lists them (`SessionFeature.displaySelection`).
    @Published private(set) var displays: [DisplayDescriptor] = []
    /// The display the Mac is streaming now.
    @Published private(set) var currentDisplayID: UInt32?
    /// A switch the phone asked for and the Mac has not confirmed yet.
    @Published private(set) var pendingDisplayID: UInt32?
    private var displaysRequested = false
    private var rememberedDisplayApplied = false
    private let displayMemory = DisplayMemory()

    var displaySelectionSupported: Bool { supports(SessionFeature.displaySelection) }

    /// Choosing what the Mac shares needs the same authority as controlling it.
    var canChooseDisplay: Bool { displaySelectionSupported && canControl && pendingDisplayID == nil }

    func requestDisplays() {
        guard displaySelectionSupported, connection.connected || probeActive else { return }
        displaysRequested = true
        #if DEBUG
        if let inputProbe {
            _ = inputProbe.record(RemoteAction(action: "displays", epoch: geometryEpoch))
            receiveDisplays(RemoteAction(action: "displays", epoch: geometryEpoch,
                                         displays: Self.probeDisplays, display: currentDisplayID ?? Self.probeDisplays[0].id))
            return
        }
        #endif
        _ = transmit(RemoteAction(action: "displays", epoch: geometryEpoch))
    }

    private var probeActive: Bool {
        #if DEBUG
        inputProbe != nil
        #else
        false
        #endif
    }

    #if DEBUG
    /// Two displays for offline checks of the picker (`--ui-input-probe`).
    static let probeDisplays = [
        DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1440, height: 900,
                          pixelWidth: 2880, pixelHeight: 1800, main: true),
        DisplayDescriptor(id: 2, name: "Studio Display", width: 2560, height: 1440,
                          pixelWidth: 5120, pixelHeight: 2880, main: false)
    ]
    #endif

    /// Streams another display in the same session and remembers the choice for this Mac.
    @discardableResult
    func selectDisplay(_ id: UInt32) -> Bool {
        guard canChooseDisplay, id != currentDisplayID, let display = displays.first(where: { $0.id == id }) else { return false }
        if let room = connection.invitation?.room {
            displayMemory.remember(.init(id: display.id, name: display.name), forRoom: room)
        }
        guard transmit(RemoteAction(action: "display", epoch: geometryEpoch, display: id)) else { return false }
        pendingDisplayID = id
        showSessionNotice("Switching to \(display.name)…")
        #if DEBUG
        if inputProbe != nil { simulateProbeDisplaySwitch(to: display) }
        #endif
        return true
    }

    /// The Mac answers every display request with its list: after switching, or unchanged when it
    /// declined (view only, unknown display).
    private func receiveDisplays(_ action: RemoteAction) {
        displays = action.displays ?? []
        if let display = action.display { currentDisplayID = display }
        if let pending = pendingDisplayID, pending != currentDisplayID,
           let kept = displays.first(where: { $0.id == currentDisplayID }) {
            showSessionNotice("Your Mac kept showing \(kept.name).")
        }
        pendingDisplayID = nil
        applyRememberedDisplay()
    }

    #if DEBUG
    /// Offline stand-in for the Mac: a new epoch and geometry, then the list, as a real switch does.
    private func simulateProbeDisplaySwitch(to display: DisplayDescriptor) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.receive(RemoteAction(action: "geometry", x: display.width, y: display.height,
                                      epoch: self.geometryEpoch &+ 1))
            self.fresh = true
            self.captureHealthy = true
            self.receiveDisplays(RemoteAction(action: "displays", epoch: self.geometryEpoch,
                                              displays: Self.probeDisplays, display: display.id))
        }
    }
    #endif

    /// On the first list of a session, return to the display chosen last time for this Mac.
    private func applyRememberedDisplay() {
        guard !rememberedDisplayApplied, let room = connection.invitation?.room, canControl else { return }
        rememberedDisplayApplied = true
        guard let wanted = DisplayMemory.match(displayMemory.choice(forRoom: room), in: displays),
              wanted.id != currentDisplayID else { return }
        guard transmit(RemoteAction(action: "display", epoch: geometryEpoch, display: wanted.id)) else { return }
        pendingDisplayID = wanted.id
    }

    /// One physical key press from a hardware keyboard, by position, with its modifiers.
    @discardableResult
    func hardwareKey(_ key: String, modifiers: [String]) -> Bool {
        guard canControl else { return false }
        if HardwareKeyMap.needsExtendedKeys(key) && !extendedKeysSupported {
            if !extendedKeyNoticeShown {
                extendedKeyNoticeShown = true
                showSessionNotice("Some keys need the updated Farside on your Mac. Letters, arrows and Return work now.")
            }
            return false
        }
        return sendInput("key", key: key, modifiers: modifiers)
    }

    private func supports(_ feature: String) -> Bool {
        #if DEBUG
        if inputProbe != nil { return true }
        #endif
        return hostFeatures.contains(feature)
    }

    // MARK: Viewport capture (G4)

    /// The Mac crops its capture to the phone's viewport and reports the region it streams.
    var viewportCaptureSupported: Bool { hostFeatures.contains(SessionFeature.viewportCapture) }

    /// The active crop, for the dock caption and the statistics overlay.
    var cropSummary: CropSummary? { CropSummary(captureRegion, displaySize: sourceSize) }

    /// The session view reports every change of what it shows; `settled` when a gesture has ended.
    func viewportChanged(_ request: ViewportCaptureRequest?, settled: Bool = false) {
        viewportReporter.update(request)
        sendViewportChange(settled: settled, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Everything a phone heartbeat carries. The viewport rides along only after the Mac advertised
    /// viewport capture, so an older Mac receives what it always did, plus `screenPixels`, which it ignores.
    func heartbeatAction(clock: ClockProbe? = nil,
                         at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RemoteAction {
        let viewport = viewportCaptureSupported ? viewportReporter.region(forDisplay: sourceSize, at: now) : nil
        let load = hostFeatures.contains(SessionFeature.ladder) &&
            phoneLoadReportedAt.map({ now >= $0 && now - $0 <= 2.5 }) == true ? phoneLoad : nil
        return RemoteAction(action: "heartbeat", epoch: geometryEpoch, pointerSync: pointerOverlay.advertisement(),
                            streamQuality: appliedStreamQuality == nil ? nil : streamQuality, clock: clock,
                            screenPixels: screenPixels(), viewport: viewport, phoneLoad: load)
    }

    /// Statistics run on every live media connection, including when the overlay is hidden.
    func acceptPhoneStats(_ report: StreamStatsReport, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard report.role == "phone" else { return }
        phoneLoad = PhoneLoadFeedback(report: report)
        phoneLoadReportedAt = now
    }

    /// The phone's screen in device pixels, read once a window scene exists.
    func screenPixels() -> PixelSize? {
        if let nativeScreenPixels { return nativeScreenPixels }
        let screen = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
        nativeScreenPixels = screen.flatMap { Self.screenPixels(nativeBounds: $0.nativeBounds) }
        return nativeScreenPixels
    }

    static func screenPixels(nativeBounds: CGRect) -> PixelSize? {
        let width = nativeBounds.width.rounded(), height = nativeBounds.height.rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 16_384, height <= 16_384 else {
            return nil
        }
        return PixelSize(width: Int(width), height: Int(height))
    }

    /// The region the frames cover after a `capture` status: nil, the whole display, for whole-display
    /// capture, a status about another geometry or a malformed region.
    static func croppedRegion(_ region: CaptureRegion?, statusEpoch: UInt64, geometryEpoch: UInt64) -> CaptureRegion? {
        guard let region, !region.isWholeDisplay, statusEpoch == geometryEpoch,
              (try? region.validate()) != nil else { return nil }
        return region
    }

    private func sendViewportChange(settled: Bool, at now: TimeInterval) {
        guard viewportCaptureSupported, connection.connected else { return }
        switch viewportReporter.nextSend(settled: settled, at: now) {
        case .none:
            return
        case .at(let time):
            scheduleViewportChange(at: time)
        case .now:
            viewportSendTask?.cancel()
            viewportSendTask = nil
            let action = heartbeatAction(at: now)
            if action.viewport != nil { _ = connection.sendControl(action) }
        }
    }

    private func scheduleViewportChange(at time: TimeInterval) {
        guard viewportSendTask == nil else { return }
        let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
        viewportSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.viewportSendTask = nil
            self.sendViewportChange(settled: false, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    #if DEBUG
    /// Offline UI checks (`--ui-layout-check --ui-input-probe`) admit input locally and record
    /// exactly what would have been sent. Nothing leaves the phone.
    let inputProbe: InputProbe? = LaunchOptions.layoutCheck && LaunchOptions.has("--ui-input-probe") ? InputProbe() : nil
    #endif

    /// Every control message leaves through here, so the offline probe sees the same actions.
    private func transmit(_ action: RemoteAction) -> Bool {
        VideoPresentationProbe.noteUserActivity()
        #if DEBUG
        if let inputProbe { return inputProbe.record(action) }
        #endif
        SmoothMotionController.noteOutgoing(action: action.action, dragging: dragging)
        return connection.sendControl(action)
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

    /// Offline screenshots of the hold states: a finger drag, or a Hold click from Controls.
    func previewHoldForTesting(explicit: Bool) {
        dragging = true
        explicitHoldDeadline = explicit ? ProcessInfo.processInfo.systemUptime + Self.explicitHoldLimit : nil
    }
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

    /// A short notice over the live session (and to VoiceOver).
    func announce(_ text: String) {
        showSessionNotice(text)
        AccessibilityNotification.Announcement(text).post()
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

    /// Once per session, when a physical iPhone ends up below level 5.2 (the capability probe
    /// failed or timed out this launch), so the Mac is capping the picture it sends.
    private func noticeReducedPicture() {
        guard !reducedPictureNoticeShown, let link, link.reducedLevel, let size = link.pictureSize else { return }
        reducedPictureNoticeShown = true
        showSessionNotice(PhoneSessionNotice.reducedPicture(size: size))
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
        // A @Published set notifies even when unchanged, and this runs at 4 Hz while streaming.
        if !fresh { fresh = true }
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
        let isClick = ["click", "right", "double", "middle"].contains(name)
        if isClick && hapticsEnabled { (name == "click" || name == "double" ? clickFeedback : secondaryClickFeedback).prepare() }
        let clickSentMs = isClick && StreamDebug.enabled ? MachClock.nowMs() : nil
        // A Mac that places the pointer absolutely also applies held hardware modifiers to it.
        let pointerModifiers = modifiers.isEmpty && absolutePointerSupported && Self.pointerActions.contains(name)
            ? hardwareModifiers : modifiers
        let accepted = transmit(RemoteAction(action: name, x: x, y: y,
            text: text, key: key, modifiers: pointerModifiers, epoch: geometryEpoch, interaction: envelope,
            pointerSync: pointerSync, textFocusProbe: focusProbe))
        if !accepted { textFocusProbe.invalidate() }
        if accepted, let clickSentMs { connection.media?.counters.clickSent(atMs: clickSentMs) }
        if accepted && isClick {
            lastAcceptedClick = name == "click" && (count ?? 1) >= 2 ? "double" : name
            acceptedClicks &+= 1
            if hapticsEnabled { playClickHaptic(name) }
        }
        return accepted
    }

    /// A click is one heavy tap; a right-click is two lighter rigid taps 70 ms apart; a middle
    /// click is one rigid tap.
    private func playClickHaptic(_ name: String) {
        switch name {
        case "right":
            secondaryClickFeedback.impactOccurred(intensity: 0.75)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [secondaryClickFeedback] in
                secondaryClickFeedback.impactOccurred(intensity: 0.75)
            }
        case "middle":
            secondaryClickFeedback.impactOccurred(intensity: 0.9)
        default:
            clickFeedback.impactOccurred(intensity: 1.0)
        }
    }

    /// Places the Mac pointer at a display-local point (direct touch, hardware pointer). The
    /// drawn pointer jumps there at once; the Mac confirms through pointer telemetry.
    @discardableResult
    func pointTo(_ source: CGPoint, modifiers: [String] = []) -> Bool {
        guard absolutePointerSupported, source.x.isFinite, source.y.isFinite,
              source.x >= 0, source.y >= 0 else { return false }
        let ordinal = pointerOverlay.reserveMoveOrdinal()
        let accepted = sendInput("moveTo", x: Double(source.x), y: Double(source.y), modifiers: modifiers,
                                 pointerSync: ordinal.map { PointerSync(move: $0) })
        if accepted {
            pointerLocator.clear()
            pointerOverlay.localWarp(ordinal: ordinal, to: source)
        }
        return accepted
    }

    @discardableResult
    func auxiliaryClick(_ button: AuxiliaryMouseButton) -> Bool {
        guard supports(SessionFeature.auxiliaryButtons), !dragging, activeHold == nil else { return false }
        return sendInput("auxClick", count: 1, key: button.rawValue)
    }

    @discardableResult
    func middleClick(modifiers: [String] = []) -> Bool {
        guard middleButtonSupported, !dragging, activeHold == nil else { return false }
        return sendInput("middle", count: 1, modifiers: modifiers)
    }

    @discardableResult
    func gesture(_ command: NativeGestureCommand) -> Bool {
        switch command {
        case .move(let delta):
            let ordinal = pointerOverlay.reserveMoveOrdinal()
            let accepted = sendInput("move", x: delta.width, y: delta.height,
                                     pointerSync: ordinal.map { PointerSync(move: $0) })
            if accepted {
                pointerOverlay.localMove(ordinal: ordinal, delta: delta, follow: true)
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
        case .middleClick:
            return middleClick()
        case .auxiliaryClick(let button):
            return auxiliaryClick(button)
        case .pointTo:
            // Canvas points need the session's viewport; the session maps them and calls `pointTo`.
            return false
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
        explicitHoldDeadline = ProcessInfo.processInfo.systemUptime + Self.explicitHoldLimit
    }

    func release() {
        textFocusProbe.invalidate()
        if connection.connected {
            if nativeInteractionSupported {
                if let activeHold {
                    _ = transmit(RemoteAction(action: "release", epoch: geometryEpoch,
                        interaction: NativeInteraction(token: inputToken, hold: activeHold, clickCount: activeHoldCount)))
                }
            } else {
                _ = transmit(RemoteAction(action: "release", epoch: geometryEpoch))
            }
        }
        #if DEBUG
        if let inputProbe, activeHold != nil, !connection.connected {
            _ = inputProbe.record(RemoteAction(action: "release", epoch: geometryEpoch))
        }
        #endif
        dragging = false
        activeHold = nil
        explicitHoldDeadline = nil
        modifiers.removeAll()
    }

    func disconnect() {
        sessionEndReason = .user
        discardResume()
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
        // A held connection can resume before the age limit. Require a new statistics sample
        // after pause so a pre-background report cannot become new ladder evidence.
        phoneLoad = nil
        phoneLoadReportedAt = nil
        contentConcealed = true
        resumeState = .backgrounded
        persistResume()
        endSecureFocus()
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
            backgroundHoldEndsAt = Date().addingTimeInterval(seconds)
            _ = connection.sendControl(RemoteAction(action: "pause", epoch: geometryEpoch))
            holdTask?.cancel()
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.endBackgroundHold(immediately: false)
            }
        case .release:
            sessionEndReason = .timeout
            release()
            connection.stop()
            endBackgroundExecutionSoon()
        }
    }

    /// Closes a held session cleanly before iOS suspends the app, so the relay frees the
    /// phone's slot at once and the return can reconnect immediately.
    private func endBackgroundHold(immediately: Bool) {
        holdTask?.cancel(); holdTask = nil
        backgroundHoldEndsAt = nil
        if continuity.endHold() {
            sessionEndReason = .timeout
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
        backgroundHoldEndsAt = nil
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
        if sessionEndReason != .user { persistResume() }
        guard continuity.isHolding else { return }
        // Lost while backgrounded: stop the coordinator's retries until the app returns.
        if sessionEndReason == nil { sessionEndReason = .error }
        backgroundHoldEndsAt = nil
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
            if let clock = action.clock { receiveClockEcho(clock) }
            if let probe = action.textFocusProbe, probe == textFocusProbe.pending?.probe,
               action.epoch == geometryEpoch {
                receiveSecureFocus(secure: action.textFocusSecure)
            }
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
            sessionBlocker = action.hostState.flatMap(MacShareBlocker.init(rawValue:))
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
            if let alert = action.agentAlert { AgentAlertCenter.shared.receive(fromMac: alert) }
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
            if let display = action.display, display != currentDisplayID { currentDisplayID = display }
            if displaySelectionSupported && !displaysRequested { requestDisplays() }
            let region = Self.croppedRegion(action.captureRegion, statusEpoch: action.epoch,
                                            geometryEpoch: geometryEpoch)
            if region != captureRegion { captureRegion = region }
            if action.busy != busy { busy = action.busy }
            ladder = action.ladder
            sendViewportChange(settled: false, at: ProcessInfo.processInfo.systemUptime)
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
            captureRegion = nil
            busy = nil
            ladder = nil
            fresh = false
            captureHealthy = false
            lastFrame = 0
            lastCaptureHealth = 0
        case "textResult":
            receiveTextResult(action)
        case "displays":
            guard action.epoch == geometryEpoch else { return }
            receiveDisplays(action)
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

    /// The session view reports what it shows. Only a live, fresh picture of a known display counts,
    /// and never before the previous session's view has been restored or dropped.
    func recordViewport(_ viewport: ResumeViewport?) {
        guard resumeResolved, sessionEndReason != .user, connection.connected, fresh, geometryEpoch > 0,
              let viewport, let room = connection.invitation?.room else { return }
        resumeCapsule = SessionResumeCapsule(macKey: DisplayMemory.macKey(room: room), displayID: currentDisplayID,
                                             displaySize: sourceSize, viewport: viewport, savedAt: Date())
    }

    func viewportResumeApplied() {
        viewportResume = nil
    }

    private func resolveResume(at now: TimeInterval) {
        guard fresh, geometryEpoch > 0 else { return }
        guard let capsule = resumeCapsule, let room = connection.invitation?.room else {
            resumeResolved = true
            return
        }
        let switching = hostFeatures.isEmpty
            || (displaySelectionSupported && (displays.isEmpty || pendingDisplayID != nil))
        let mayStillSwitch = switching && now - resumeStartedAt < SessionResumeCapsule.displayWait
        switch capsule.decision(macKey: DisplayMemory.macKey(room: room), displayID: currentDisplayID,
                                displaySize: sourceSize, now: Date(), mayStillSwitchDisplay: mayStillSwitch) {
        case .wait:
            return
        case .discard:
            discardResume()
        case .restore(let viewport):
            // Kept as this session's view until the person moves it, so leaving again still resumes.
            resumeResolved = true
            viewportResume = viewport.isDefaultView ? nil : viewport
        }
    }

    private func discardResume() {
        resumeCapsule = nil
        resumeResolved = true
        viewportResume = nil
        resumeStore.save(nil)
    }

    /// The lifetime counts from when the session was left, not from the last time the view moved.
    private func persistResume() {
        if resumeResolved { resumeCapsule?.savedAt = Date() }
        resumeStore.save(resumeCapsule)
    }

    /// Stream statistics: a new clock probe, remembered so only its echo counts.
    func registerClockProbe(phoneMs: Double = MachClock.nowMs()) -> ClockProbe {
        clockSync.sent(phoneMs: phoneMs)
        return ClockProbe(phoneMs: phoneMs)
    }

    /// Stream statistics: the Mac's echo of a clock probe from `tick()`.
    private func receiveClockEcho(_ echo: ClockProbe) {
        guard echo.isEcho, StreamDebug.enabled else { return }
        let now = MachClock.nowMs()
        let arrived = connection.media?.controlArrivalMs ?? now
        guard clockSync.record(echo, receivedAtPhoneMs: min(now, arrived)) else { return }
        connection.media?.counters.clockUpdated(clockSync.estimate(now: now))
    }

    private func beginHeartbeat() {
        clockSync.reset()
        heartbeatsSent = 0
        pointerTimer?.invalidate()
        pointerLocator.clear()
        let pointerTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let probing = self.canControl && self.pointerLocatorSupported && !self.pointerOverlay.hostSupported
                if let probe = self.pointerLocator.poll(at: now, available: probing) {
                    _ = self.connection.sendControl(RemoteAction(action: "heartbeat", epoch: self.geometryEpoch, pointerProbe: probe))
                }
            }
        }
        self.pointerTimer = pointerTimer
        RunLoop.main.add(pointerTimer, forMode: .common)
        timer?.invalidate()
        let heartbeatTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = heartbeatTimer
        RunLoop.main.add(heartbeatTimer, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if connection.connected {
            heartbeatsSent &+= 1
            let probesClock = heartbeatsSent % 2 == 0 && StreamDebug.enabled
            let probe = probesClock ? registerClockProbe() : nil
            _ = connection.sendControl(heartbeatAction(clock: probe, at: now))
        }
        pointerOverlay.refresh()
        if !rememberedDisplayApplied && !displays.isEmpty && canControl { applyRememberedDisplay() }
        if connection.connected && !resumeResolved { resolveResume(at: now) }
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
        endSecureFocus()
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLocatorSupported = false
        appliedStreamQuality = nil
        streamSummaryLines = []
        link = nil
        wifiStall.reset()
        wifiStallTip = nil
        captureRegion = nil
        busy = nil
        ladder = nil
        viewportSendTask?.cancel()
        viewportSendTask = nil
        viewportReporter.sessionEnded()
        phoneLoad = nil
        phoneLoadReportedAt = nil
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
        hardwareModifiers = []
        extendedKeyNoticeShown = false
        displays = []
        currentDisplayID = nil
        pendingDisplayID = nil
        displaysRequested = false
        rememberedDisplayApplied = false
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
        sessionBlocker = nil
        curtainState = nil
        recoveryNoticeShown = false
        reducedPictureNoticeShown = false
        clockSync.reset()
        heartbeatsSent = 0
        if let departureReason {
            macNotice = Self.notice(for: departureReason)
            lastDeparture = departureReason
            if sessionEndReason == nil { sessionEndReason = .macStopped }
        }
        departureReason = nil
        clipboard.cancel()
        resumeWatchdog?.cancel(); resumeWatchdog = nil
    }
}

/// A cropped capture for the dock caption and the statistics overlay, e.g. "crop 1280×720 · 2.0×":
/// the stream's pixel size and how many times smaller than the display its region is per side, by area,
/// so a crop along one axis reads the same as an even one.
struct CropSummary: Equatable {
    var outputWidth: Int
    var outputHeight: Int
    var factor: Double

    init?(_ region: CaptureRegion?, displaySize: CGSize) {
        guard let region, !region.isWholeDisplay, region.width > 0, region.height > 0,
              displaySize.width > 0, displaySize.height > 0 else { return nil }
        outputWidth = region.outputWidth
        outputHeight = region.outputHeight
        factor = (Double(displaySize.width * displaySize.height) / (region.width * region.height)).squareRoot()
    }

    private var factorText: String { String(format: "%.1f", factor) }
    var caption: String { "crop \(outputWidth)×\(outputHeight) · \(factorText)×" }
    var spoken: String { "picture cropped to \(outputWidth) by \(outputHeight), \(factorText) times" }
}

/// Route, round trip and received picture for the dock caption, and the negotiated codec level
/// for the Picture settings. Network RTT, not end-to-end latency.
struct LinkSummary: Equatable {
    var route: String?
    var roundTripMs: Int?
    /// Decoded picture size, e.g. "2560×1656".
    var pictureSize: String?
    /// Negotiated codec and H.264 level, e.g. "H.264 5.2".
    var codecLevel: String?
    /// "hardware decode" or "software decode" when WebRTC reports which.
    var decoder: String?
    /// A physical iPhone negotiated an H.264 level below 5.2, which caps the picture the Mac sends.
    var reducedLevel = false

    /// H.264 level 5.2, the level the phone offers when its decoder passed the capability probe.
    static let fullLevel = 0x34

    static let runsOnDevice: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()

    init?(_ report: StreamStatsReport, physicalDevice: Bool = LinkSummary.runsOnDevice) {
        route = report.route.flatMap { $0 == "Direct" || $0 == "Relay" ? $0 : nil }
        roundTripMs = report.rttMs.map { Int($0.rounded()) }
        if let width = report.receivedWidth, let height = report.receivedHeight, width > 0, height > 0 {
            pictureSize = "\(width)×\(height)"
        }
        let codec = report.codec.map { Self.codecName(mimeType: $0) }
        let level = codec == "H.264" ? Self.levelByte(profileLevelID: report.h264ProfileLevel) : nil
        codecLevel = codec.map { name in level.map { "\(name) \(Self.levelName($0))" } ?? name }
        decoder = Self.decoderDescription(implementation: report.decoderImplementation,
                                          powerEfficient: report.powerEfficientDecoder)
        reducedLevel = physicalDevice && level.map { $0 < Self.fullLevel } == true
        guard route != nil || roundTripMs != nil || pictureSize != nil || codecLevel != nil else { return nil }
    }

    /// "video/H264" → "H.264"; other codecs keep their MIME subtype.
    static func codecName(mimeType: String) -> String {
        let name = mimeType.split(separator: "/").last.map(String.init) ?? mimeType
        return name.caseInsensitiveCompare("H264") == .orderedSame ? "H.264" : name
    }

    /// The level_idc byte: the last two hex digits of an H.264 profile-level-id ("640c34" → 0x34).
    static func levelByte(profileLevelID: String?) -> Int? {
        guard let id = profileLevelID, id.count == 6 else { return nil }
        return Int(id.suffix(2), radix: 16)
    }

    /// level_idc is ten times the level: 0x34 (52) → "5.2", 0x1f (31) → "3.1", 0x28 (40) → "4".
    static func levelName(_ levelByte: Int) -> String {
        levelByte % 10 == 0 ? "\(levelByte / 10)" : "\(levelByte / 10).\(levelByte % 10)"
    }

    static func decoderDescription(implementation: String?, powerEfficient: Bool?) -> String? {
        switch powerEfficient {
        case true?: return "hardware decode"
        case false?: return "software decode"
        case nil:
            return implementation?.localizedCaseInsensitiveContains("VideoToolbox") == true ? "hardware decode" : nil
        }
    }
}

extension PhoneSessionNotice {
    static func reducedPicture(size: String) -> String {
        "Reduced picture: this session runs at \(size) (H.264 level 3.1). Quit and reopen Farside on both devices to retry."
    }
}

struct RemoteVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack
    var counters: StreamCounters?
    /// Stream statistics: read the bench marker from each frame and score the legibility chart.
    var statistics = false
    /// The Mac display in points, which the chart layout is defined in.
    var sourceSize: CGSize = .zero
    /// Width of the picture on screen in device pixels, for the "displayed" legibility score.
    var displayedPixelWidth: CGFloat = 0
    /// G4: the frames of a cropped capture span their region exactly, whatever the stream's aspect.
    var fillsFrame = false
    var smoothMotion: SmoothMotionMode = .defaultMode
    var smoothMotionUpscale = false
    let onFrame: () -> Void

    static func contentMode(fillsFrame: Bool) -> UIView.ContentMode {
        fillsFrame ? .scaleToFill : .scaleAspectFit
    }

    func makeCoordinator() -> FrameObserver { FrameObserver(onFrame: onFrame) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = Self.contentMode(fillsFrame: fillsFrame)
        context.coordinator.track = track
        context.coordinator.view = view
        context.coordinator.presentation = VideoPresentationProbe.install(on: view)
        context.coordinator.presentation?.counters = counters
        configureStatistics(context.coordinator)
        configureSmoothMotion(context.coordinator.smoothMotion)
        context.coordinator.smoothMotion.activate()
        track.add(context.coordinator)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        let mode = Self.contentMode(fillsFrame: fillsFrame)
        if view.videoContentMode != mode { view.videoContentMode = mode }
        context.coordinator.presentation?.counters = counters
        configureStatistics(context.coordinator)
        configureSmoothMotion(context.coordinator.smoothMotion)
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(context.coordinator)
            context.coordinator.smoothMotion.resetSession()
            context.coordinator.track = track
            track.add(context.coordinator)
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: FrameObserver) {
        coordinator.track?.remove(coordinator)
        coordinator.track = nil
        coordinator.readsMarkers = false
        coordinator.legibility.configure(enabled: false, counters: nil, sourceSize: .zero, displayedPixelWidth: 0)
        coordinator.presentation?.uninstall()
        coordinator.presentation = nil
        coordinator.smoothMotion.deactivate()
    }

    private func configureSmoothMotion(_ controller: SmoothMotionController) {
        controller.setMode(smoothMotion)
        controller.setUpscale(smoothMotionUpscale)
    }

    private func configureStatistics(_ coordinator: FrameObserver) {
        coordinator.readsMarkers = statistics
        coordinator.legibility.configure(enabled: statistics, counters: counters, sourceSize: sourceSize,
                                         displayedPixelWidth: displayedPixelWidth)
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
        didSet {
            lock.lock(); tracker = presentation?.tracker; refreshProbe = presentation; lock.unlock()
            presentation?.beforeDraw = { [smoothMotion] view in smoothMotion.displayTick(view) }
            connectMarkers()
        }
    }
    /// Stream statistics: read the bench marker from every decoded frame (one strip read on the
    /// decode thread) and hand it through to presentation and the legibility probe.
    var readsMarkers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return markerReading }
        set {
            lock.lock()
            let changed = markerReading != newValue
            markerReading = newValue
            lock.unlock()
            guard changed else { return }
            if !newValue { forward.forgetMarkers() }
            connectMarkers()
        }
    }
    let legibility = LegibilityProbe()
    let onFrame: () -> Void
    let forward = RestampingRenderer()
    let smoothMotion: SmoothMotionController
    private let lock = NSLock()
    private var last = 0.0
    private var tracker: PresentationTracker?
    private weak var refreshProbe: VideoPresentationProbe?
    private var markerReading = false
    private var deliveredSize: CGSize?

    init(onFrame: @escaping () -> Void, smoothMotion: SmoothMotionController = SmoothMotionController()) {
        self.onFrame = onFrame
        self.smoothMotion = smoothMotion
        super.init()
        smoothMotion.deliver = { [weak self] output in self?.deliver(output.frame, marker: output.marker) }
    }

    func setSize(_ size: CGSize) {
        forward.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        let reading = markerReading
        let refreshProbe = refreshProbe
        lock.unlock()
        if reading {
            let decoded = (frame.buffer as? RTCCVPixelBuffer).flatMap { DecodedLuma($0) }
            let marker = decoded?.readMarker()
            smoothMotion.receive(frame, marker: marker)
            if let decoded { legibility.frameArrived(decoded.pixelBuffer, visible: decoded.visible, marker: marker) }
        } else {
            smoothMotion.receive(frame, marker: nil)
        }
        refreshProbe?.frameForwarded()
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let notify = now - last > 0.25
        if notify { last = now }
        lock.unlock()
        if notify {
            DispatchQueue.main.async { [weak self] in self?.onFrame() }
        }
    }

    /// Hands a frame to the Metal view, directly or when `smoothMotion` paces it onto a draw.
    private func deliver(_ frame: RTCVideoFrame, marker: BenchMarker?) {
        lock.lock()
        let reading = markerReading
        let tracker = tracker
        let size = frame.rotation.rawValue % 180 == 0
            ? CGSize(width: Int(frame.width), height: Int(frame.height))
            : CGSize(width: Int(frame.height), height: Int(frame.width))
        let resized = deliveredSize != nil && deliveredSize != size
        deliveredSize = size
        lock.unlock()
        // An upscaled smooth-motion frame differs from the size WebRTC announced.
        if resized { forward.setSize(size) }
        let register: (RestampingRenderer.ForwardedFrame) -> Void = { forwarded in
            tracker?.frameWillForward(stampNs: forwarded.stampNs, atMs: forwarded.arrivalMs)
        }
        if reading {
            forward.renderFrame(frame, marker: marker, beforeForward: register)
        } else {
            forward.renderFrame(frame, beforeForward: register)
        }
    }

    private func connectMarkers() {
        guard let presentation else { return }
        if readsMarkers {
            presentation.markerForStamp = { [forward] in forward.marker(forStamp: $0) }
        } else {
            presentation.markerForStamp = nil
        }
    }
}

/// The visible luma plane of a decoded 8-bit NV12 frame, where the bench marker strip is read.
struct DecodedLuma {
    let pixelBuffer: CVPixelBuffer
    /// WebRTC's crop of the buffer, in luma pixels with a top-left origin.
    let visible: CGRect

    static let formats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]

    init?(_ buffer: RTCCVPixelBuffer) {
        self.init(pixelBuffer: buffer.pixelBuffer,
                  crop: CGRect(x: Int(buffer.cropX), y: Int(buffer.cropY),
                               width: Int(buffer.cropWidth), height: Int(buffer.cropHeight)))
    }

    init?(pixelBuffer: CVPixelBuffer, crop: CGRect) {
        guard Self.formats.contains(CVPixelBufferGetPixelFormatType(pixelBuffer)) else { return nil }
        let plane = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                           height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
        let visible = crop.isEmpty ? plane : crop.intersection(plane)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        self.pixelBuffer = pixelBuffer
        self.visible = visible
    }

    func readMarker() -> BenchMarker? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let origin = base.advanced(by: Int(visible.minY) * bytesPerRow + Int(visible.minX))
        return BenchMarker.read(luma: origin.assumingMemoryBound(to: UInt8.self), width: Int(visible.width),
                                height: Int(visible.height), bytesPerRow: bytesPerRow)
    }
}

/// Every RTCMTLVideoView must get its frames through this instead of straight from the track.
/// With the tuned zero playout delay, libwebrtc stamps every decoded frame with render time 0,
/// and RTCMTLVideoView skips a frame whose timestamp equals the last one it drew, so it would
/// never draw at all. Frames are passed on with a strictly increasing timestamp.
///
/// With Stream statistics on, it also remembers which bench marker the last few forwarded frames
/// carried, so presentation can match the frame the view drew (by its stamp) to its marker.
final class RestampingRenderer: NSObject, RTCVideoRenderer {
    struct ForwardedFrame: Equatable {
        let stampNs: Int64
        let marker: BenchMarker?
        /// Phone mach ms when the frame was handed to the view.
        let arrivalMs: Double
    }

    static let rememberedFrames = 16

    weak var target: RTCMTLVideoView?
    private let handoffLock = NSLock()
    private let lock = NSLock()
    private var lastStampNs: Int64 = 0
    private var forwarded: [ForwardedFrame] = []

    init(target: RTCMTLVideoView? = nil) {
        self.target = target
        forwarded.reserveCapacity(Self.rememberedFrames)
    }

    func setSize(_ size: CGSize) {
        target?.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        forward(frame, remember: false, marker: nil)
    }

    /// Forwards the frame and remembers its marker; a frame without a readable marker is kept as nil.
    /// Returns the stamp the frame was forwarded with.
    @discardableResult
    func renderFrame(_ frame: RTCVideoFrame?, marker: BenchMarker?) -> Int64? {
        forward(frame, remember: true, marker: marker, beforeForward: nil)
    }

    /// Registers the exact identity before handing the frame to RTCMTLVideoView. The callback
    /// must remain lightweight because WebRTC invokes this method on its decode thread.
    @discardableResult
    func renderFrame(_ frame: RTCVideoFrame?, marker: BenchMarker?,
                     beforeForward: @escaping (ForwardedFrame) -> Void) -> Int64? {
        forward(frame, remember: true, marker: marker, beforeForward: beforeForward)
    }

    /// Registers an unmarked frame before handing it to RTCMTLVideoView.
    @discardableResult
    func renderFrame(_ frame: RTCVideoFrame?, beforeForward: @escaping (ForwardedFrame) -> Void) -> Int64? {
        forward(frame, remember: false, marker: nil, beforeForward: beforeForward)
    }

    func forwardedFrame(forStamp stampNs: Int64) -> ForwardedFrame? {
        lock.lock(); defer { lock.unlock() }
        return forwarded.last { $0.stampNs == stampNs }
    }

    func marker(forStamp stampNs: Int64) -> BenchMarker? {
        forwardedFrame(forStamp: stampNs)?.marker
    }

    var newestMarker: BenchMarker? {
        lock.lock(); defer { lock.unlock() }
        return forwarded.last?.marker
    }

    func forgetMarkers() {
        lock.lock(); forwarded.removeAll(keepingCapacity: true); lock.unlock()
    }

    @discardableResult
    private func forward(_ frame: RTCVideoFrame?, remember: Bool, marker: BenchMarker?) -> Int64? {
        forward(frame, remember: remember, marker: marker, beforeForward: nil)
    }

    @discardableResult
    private func forward(_ frame: RTCVideoFrame?, remember: Bool, marker: BenchMarker?,
                         beforeForward: ((ForwardedFrame) -> Void)?) -> Int64? {
        guard let frame, let target else { return nil }
        // Preserve stamp/registration/view handoff order if WebRTC changes decode threads.
        // This lock ends when renderFrame returns; it is never held through an MTK draw.
        handoffLock.lock(); defer { handoffLock.unlock() }
        guard target.isEnabled else { return nil }
        lock.lock()
        let stampNs = max(Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000), lastStampNs + 1)
        lastStampNs = stampNs
        let forwardedFrame = ForwardedFrame(stampNs: stampNs, marker: marker, arrivalMs: MachClock.nowMs())
        if remember {
            if forwarded.count == Self.rememberedFrames { forwarded.removeFirst() }
            forwarded.append(forwardedFrame)
        }
        lock.unlock()
        beforeForward?(forwardedFrame)
        target.renderFrame(RTCVideoFrame(buffer: frame.buffer, rotation: frame.rotation, timeStampNs: stampNs))
        return stampNs
    }
}
