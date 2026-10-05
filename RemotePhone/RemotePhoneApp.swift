import SwiftUI
import WebRTC
import AVFoundation
import Combine
import OSLog

@main
struct RemotePhoneApp: App {
    @UIApplicationDelegateAdaptor(FarsideAppDelegate.self) private var appDelegate
    @StateObject private var model = PhoneRemoteModel()
    @Environment(\.scenePhase) private var phase

    init() {
        StillTextPreferences.retireSettingValues()
        #if !DEBUG
        // Release builds before MS17 showed these testing switches; one left on could no longer be turned off.
        for key in [StreamDebug.defaultsKey, StreamDebug.markerReadingKey, StreamTuning.legacyDefaultsKey,
                    SmoothMotionController.upscaleKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
        // Transaction.updates must be heard from launch: renewals, refunds, Ask to Buy, other devices.
        // Unit tests host this app and drive their own store against a StoreKit test session.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            AnywhereStore.shared.start()
            Task { await RegulatoryFeatureCheck.run() }
        }
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
    var usefulContext: UsefulSessionContext? = nil

    func draftAfterAcknowledgment(_ currentDraft: String, accepted: Bool) -> String {
        accepted && origin == .draft && currentDraft == payload ? "" : currentDraft
    }
}

enum TextOrigin { case draft, voice }

enum VoiceDeliveryStatus: Equatable {
    case idle, waiting, accepted, refused, uncertain, notQueued
}

/// A focus reply may open the local keyboard only for the most recent admitted click.
/// A refresh probe re-measures the focused field after typing; it never opens the keyboard.
struct TextFocusProbeGate {
    private(set) var pending: (probe: String, epoch: UInt64, sentAt: TimeInterval, refresh: Bool)?

    mutating func begin(epoch: UInt64, at now: TimeInterval, refresh: Bool = false) -> String {
        let probe = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        pending = (probe, epoch, now, refresh)
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

struct BigTextState: Equatable {
    var steps: [ScaleStep] = []
    var baselineWidth: Double?
    var currentWidth: Double?
    var savedWidth: Double?
    var pendingTarget: Double?
    var pendingSince: TimeInterval?
    var pendingPillExpired = false
    var sessionOff = false
    var autoApplied = false
}

/// Presentation timing only. This never supplies video admission or an input grant.
struct FirstPictureSettlement {
    static let maximumHold: TimeInterval = 1
    private(set) var deadline: TimeInterval?
    private(set) var ready = false

    mutating func begin(at now: TimeInterval, hold: Bool) {
        ready = !hold
        deadline = hold ? now + Self.maximumHold : nil
    }
    @discardableResult
    mutating func refresh(at now: TimeInterval, settled: Bool) -> Bool {
        guard let deadline else { return ready }
        if settled || now >= deadline { ready = true; self.deadline = nil }
        return ready
    }
    mutating func cancel() { deadline = nil }
}

enum First60HintStage: Int {
    case move, click, finished
    var text: String? {
        switch self {
        case .move: "Slide to move"
        case .click: "Tap to click"
        case .finished: nil
        }
    }
}

@MainActor
final class PhoneRemoteModel: ObservableObject {
    /// A lost live session keeps retrying for about 90 seconds, long enough for the Mac's
    /// watchdog to relaunch a crashed or hung Farside with the same pairing.
    let connection: RemoteCoordinator
    let pointerLocator = PointerLocator()
    let pointerOverlay = PointerOverlayModel()
    let clipboard = PhoneClipboard()
    let linkHints = PhoneLinkHintMonitor()
    private var lowDataState = LowDataPolicyState()
    @Published private(set) var linkHint: NetworkLinkHint?
    let diagnostics = PhoneDiagnostics()
    @Published private(set) var dataWarningShown = false
    private let dataWarningGate: DataWarningGate
    private let preferences: UserDefaults
    private var linkConsentObserver: AnyCancellable?
    private var first60SetupObserver: AnyCancellable?
    static let firstPictureShownKey = "PocketDeskFirstPictureShown"
    static let first60HintStageKey = "PocketDeskFirst60HintStage"
    @Published private(set) var firstPictureReady = false
    @Published private(set) var firstPictureSettling = false
    @Published private(set) var first60HintStage = First60HintStage.move
    let first60Enabled: Bool
    static let sessionPolishKey = "FarsideSessionPolish"
    let sessionPolishEnabled: Bool
    private var lastDepartureInvitation: PairInvitation?
    private var macNoticeInvitation: PairInvitation?
    var recoveryHostPresence: HostPresence? {
        hostPresence ?? (sessionPolishEnabled && !connection.connected && lastDepartureInvitation == connection.invitation ? lastDeparture : nil)
    }
    var recoveryMacNotice: String? {
        !sessionPolishEnabled || macNoticeInvitation == connection.invitation ? macNotice : nil
    }
    var sessionRecoveryHint: String? {
        guard sessionPolishEnabled else { return nil }
        if recoveryHostPresence == .locked {
            return connection.connected
                ? "Your Mac reported that it is locked. Unlock your Mac in person to connect."
                : "Your Mac last reported that it was locked. Unlock it in person if needed, then try again."
        }
        return "Check that your Mac is awake and unlocked, with Farside in its menu bar."
    }
    private var firstPictureSettlement = FirstPictureSettlement()
    private var firstPictureTask: Task<Void, Never>?
    private var firstPictureCaptureObserved = false
    private var firstPictureSession = false
    private var initialScaleOpportunity = false
    private var initialScaleDeferredForSetup = false
    private var firstPictureVeilDeadline: TimeInterval?
    private var firstPictureVeilTask: Task<Void, Never>?
    private var initialBigTextRequestID: String?
    var first60InlineHint: String? {
        guard first60Enabled, firstPictureReady, fresh, canControl, sessionMode == .picture,
              sceneIsActive, !privacyShield, !contentConcealed else { return nil }
        // Older Macs cannot confirm a posted click. Never invent a completion on send.
        if first60HintStage == .click && !hostFeatures.contains(SessionFeature.inputReceipt) { return nil }
        return first60HintStage.text
    }

    private func beginFirstPicture() {
        firstPictureTask?.cancel()
        stopFirstPictureSettling()
        firstPictureCaptureObserved = false
        firstPictureSession = first60Enabled && !preferences.bool(forKey: Self.firstPictureShownKey) && requestedMode == .picture
        initialScaleOpportunity = firstPictureSession
        initialScaleDeferredForSetup = firstPictureSession && connection.setupInProgress == true
        firstPictureSettlement.begin(at: ProcessInfo.processInfo.systemUptime, hold: firstPictureSession)
        firstPictureReady = firstPictureSettlement.ready
        guard !firstPictureReady else { return }
        firstPictureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(FirstPictureSettlement.maximumHold))
            guard let self, !Task.isCancelled else { return }
            self.refreshFirstPicture()
        }
    }

    private func refreshFirstPicture(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let deadline = firstPictureVeilDeadline, now >= deadline { stopFirstPictureSettling() }
        let scaleSettled = !bigTextSupported || connection.setupInProgress == true
            || (bigText.autoApplied && bigText.pendingTarget == nil && bigTextSendTask == nil)
        let settled = firstPictureCaptureObserved && captureHealthy && geometryEpoch > 0
            && (!curtainSupported || curtainState != .pending) && scaleSettled
        if firstPictureSettlement.refresh(at: now, settled: settled), !firstPictureReady {
            firstPictureReady = true
            firstPictureTask?.cancel(); firstPictureTask = nil
        }
    }

    private func startFirstPictureSettling() {
        firstPictureVeilTask?.cancel()
        firstPictureSettling = true
        firstPictureVeilDeadline = ProcessInfo.processInfo.systemUptime + FirstPictureSettlement.maximumHold
        firstPictureVeilTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(FirstPictureSettlement.maximumHold))
            guard !Task.isCancelled else { return }
            self?.stopFirstPictureSettling()
        }
    }
    private func stopFirstPictureSettling() {
        firstPictureVeilTask?.cancel(); firstPictureVeilTask = nil
        firstPictureVeilDeadline = nil
        if firstPictureSettling { firstPictureSettling = false }
    }

    private func advanceFirst60Hint(_ stage: First60HintStage) {
        guard first60Enabled, stage.rawValue == first60HintStage.rawValue + 1 else { return }
        first60HintStage = stage
        preferences.set(stage.rawValue, forKey: Self.first60HintStageKey)
    }
    let files = PhoneFileTransfer()
    let sendToMac = SendToMacInbox()
    private var shareLiveSessionID: String?
    private var shareDestination: SendToMacDestination?
    private var sendToMacBeaconAt: TimeInterval = 0
    private let sendToMacBeaconIO = SendToMacFileIO()
    private var fileTransferWasAvailable = false
    @Published private(set) var awayState: AwayModeState?
    @Published private(set) var lockMacStatus: String?
    private let awayMemory = AwayMemory()
    private var pendingLockMac: PhoneAwayLockRequest?
    private var awayStatusEpoch: UInt64?
    private var lockMacTimeout: Task<Void, Never>?
    var awaySupported: Bool { hostFeatures.contains(SessionFeature.away) }
    var canLockMac: Bool {
        awaySupported && awayStatusEpoch == geometryEpoch && pendingLockMac == nil && canControl && sceneIsActive && !captureScopeViewOnly &&
            !viewOnlyConfirmed && !pendingViewOnlyStart && !awaitingViewOnlyExit && !pipBackground &&
            connection.presentationDeadline() != nil && connection.presentationHostTrust != nil
    }
    @discardableResult
    func endAndLockMac() -> Bool {
        guard canLockMac, let host = connection.presentationHostTrust else { return false }
        let request = PhoneAwayLockRequest(hostKey: AwayMemory.macKey(host: host),
            session: connection.presentationSessionID, epoch: geometryEpoch, sentAt: ProcessInfo.processInfo.systemUptime)
        cancelInput(); setMacAudioMuted(true)
        guard connection.sendControl(RemoteAction(action: "lockMac", epoch: geometryEpoch)) else { return false }
        acceptedLockMacRequest(request)
        return true
    }
    private func acceptedLockMacRequest(_ request: PhoneAwayLockRequest) {
        // End is already the explicit local intent; waiting for a status must never seed resume.
        sessionEndReason = .user
        resumeTiming.cancel(.userEnded)
        discardResume(); clearContinuity()
        pendingLockMac = request
        lockMacStatus = "Lock requested. Waiting for this Mac’s status…"
        invalidatePresentation()
        lockMacTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PhoneAwayLockRequest.timeout))
            guard !Task.isCancelled, let self, self.pendingLockMac == request else { return }
            self.lockMacStatus = "Lock wasn’t confirmed. Unlock or check your Mac in person."
            let notice = self.lockMacStatus
            self.disconnect()
            self.macNotice = notice
        }
    }
    private func receiveAwayStatus(_ action: RemoteAction) {
        guard action.epoch == geometryEpoch, let host = connection.presentationHostTrust else { return }
        awayStatusEpoch = action.epoch
        let next = awaySupported ? AwayModeState(reported: action.away) : nil
        if next != awayState {
            awayState = next
            if next == .covered { showSessionNotice("Mac covered · requests a lock if touched") }
        }
        if let next, !(next == .off && hostPresence == .locked) { awayMemory.remember(next, host: host) }
        if let request = pendingLockMac, hostPresence == .locked,
           request.matches(hostKey: AwayMemory.macKey(host: host), session: connection.presentationSessionID,
                           epoch: action.epoch, at: ProcessInfo.processInfo.systemUptime) {
            lockMacStatus = "This Mac reports that it is locked. Unlock it in person."
            departureReason = .locked
            disconnect()
        }
    }
    private func cancelLockMacRequest() {
        lockMacTimeout?.cancel(); lockMacTimeout = nil; pendingLockMac = nil
    }
    @Published private(set) var wakeStatus: String?
    private var pendingWake: (request: WakeRequest, host: PhoneHostTrust, session: UUID, epoch: UInt64, sentAt: TimeInterval)?
    private var wakeTimeout: Task<Void, Never>?
    var canRequestLANWake: Bool {
        !contentConcealed && !privacyShield && !captureScopeViewOnly && !viewOnlyConfirmed && !pipBackground &&
            !pendingViewOnlyStart && !awaitingViewOnlyExit && hostFeatures.contains(SessionFeature.lanWake) &&
            connection.presentationDeadline() != nil && connection.presentationHostTrust?.ownerPairID != nil && pendingWake == nil
    }
    func requestLANWake(targetID: UUID) {
        guard canRequestLANWake, let host = connection.presentationHostTrust,
              host.durableHostID != nil, host.ownerPairID != nil else { wakeStatus = "Connect to your paired powered helper with a registered wake target first."; return }
        let request = WakeRequest(targetID: targetID, requestID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        pendingWake = (request, host, connection.presentationSessionID, geometryEpoch, ProcessInfo.processInfo.systemUptime)
        wakeStatus = "Requesting one wake packet…"
        guard connection.sendControl(RemoteAction(action: "wakeRequest", epoch: geometryEpoch, wakeRequest: request)) else {
            pendingWake = nil; wakeStatus = "Couldn’t send the request. No wake result was confirmed."; return
        }
        wakeTimeout?.cancel()
        wakeTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.pendingWake?.request == request else { return }
            self.pendingWake = nil; self.wakeStatus = "No helper reply was confirmed. The target’s wake state is unknown."
        }
    }
    private func receiveWakeReply(_ action: RemoteAction) {
        guard (try? action.validate()) != nil, let reply = action.wakeReply, let pending = pendingWake,
              reply.targetID == pending.request.targetID, reply.requestID == pending.request.requestID,
              action.epoch == pending.epoch, action.epoch == geometryEpoch,
              connection.presentationSessionID == pending.session, connection.presentationHostTrust == pending.host,
              connection.presentationDeadline() != nil, ProcessInfo.processInfo.systemUptime - pending.sentAt <= 5 else { return }
        pendingWake = nil; wakeTimeout?.cancel(); wakeTimeout = nil
        switch reply.status {
        case .sent: wakeStatus = "One wake packet was sent. The target is not yet confirmed awake or unlocked."
        case .unsupported: wakeStatus = "This helper couldn’t send a supported LAN wake packet. Check its local interface and target configuration."
        case .denied: wakeStatus = "The helper denied this request. Check owner registration, pairing, current connection or the one-minute cooldown."
        }
    }

    @Published private(set) var hostFeatures: Set<String> = []
    @Published private(set) var sessionMode: SessionMode = .picture { willSet { if newValue != sessionMode { retireContentPresentation() } } }
    @Published private(set) var requestedMode: SessionMode = .picture
    /// What the Mac last confirmed on screen, or the switch it was asked for; survives `end()` so a
    /// reconnect comes back as the person last saw it. Home's next Connect clears it.
    @Published private(set) var lastOnScreenMode: SessionMode?
    @Published private(set) var pendingModeSwitch: SessionMode?
    @Published private(set) var couchRefusal: SessionModeRefusal?
    @Published private(set) var couchStalled = false
    private var couchAck = CouchAckWatchdog()
    private var lastModeReason: String?
    private var modeSwitchTimeout: Task<Void, Never>?
    @Published private(set) var resumeState: ResumeState = .none
    /// While a live session is held in the background: when Farside lets go of the Mac.
    @Published private(set) var backgroundHoldEndsAt: Date?
    /// Why the last session ended, for the Lock Screen and Dynamic Island.
    private(set) var sessionEndReason: FarsideSessionAttributes.EndReason?
    @Published private(set) var hostPresence: HostPresence? { willSet { if newValue == .locked || newValue == .switchedUser { invalidatePresentation() } } }
    /// A grant the Mac reports missing during this session (only `accessibilityOff` arrives here).
    @Published private(set) var sessionBlocker: MacShareBlocker?
    /// The Mac's privacy curtain, or nil when the Mac does not support one.
    @Published private(set) var curtainState: PrivacyCurtainState?
    /// A short explanation shown over the live session, cleared after a few seconds.
    @Published private(set) var sessionNotice: String?
    private var sessionNoticeTask: Task<Void, Never>?
    private var recoveryNoticeShown = false
    private var curtainNoticedStates: Set<PrivacyCurtainState> = []
    /// Why the last session ended, when the Mac itself said so.
    @Published private(set) var macNotice: String? { didSet { macNoticeInvitation = connection.invitation } }
    /// What the Mac said as the last session ended (asleep, locked, another user), until the next session.
    @Published private(set) var lastDeparture: HostPresence? { didSet { lastDepartureInvitation = connection.invitation } }
    private var departureReason: HostPresence?
    private var continuity = BackgroundContinuity()
    /// Correlation for foreground recovery, never permission to reuse an expired media route.
    private var backgroundResumeHost: PhoneHostTrust?
    private var backgroundRecoveryBlocked: Bool {
        (hostPresence != nil && hostPresence != .displayAsleep) || sessionBlocker != nil || pendingLockMac != nil
    }
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
    private var qualityMonitor = ConnectionQualityMonitor()
    @Published private(set) var qualityVerdict: ConnectionQualityVerdict?
    @Published private(set) var slowRoundTripMs: Int?
    @Published private(set) var roundTripSpreadMs: Double?
    @Published private(set) var frameHealthPercent: Double?
    @Published private(set) var dismissedQualityBanners: Set<QualityBannerContent.Key> = []
    private var qualityRouteDetail: String?
    private var resumeTiming = ResumeTiming()
    @Published private(set) var lastResume: ResumeTiming.Measurement?
    private var resumeCount = 0
    private var sceneWasBackground = false

    func dismissQualityBanner(_ key: QualityBannerContent.Key) { dismissedQualityBanners.insert(key) }

    private func resetQuality() {
        qualityMonitor.reset()
        qualityVerdict = nil
        slowRoundTripMs = nil
        roundTripSpreadMs = nil
        frameHealthPercent = nil
        wifiStall.reset()
        wifiStallTip = nil
    }

    private func observeQuality(_ report: StreamStatsReport) {
        guard sceneIsActive, sessionMode == .picture else { return }
        if qualityRouteDetail != report.routeDetail {
            resetQuality()
            qualityRouteDetail = report.routeDetail
        }
        let changed = qualityMonitor.observe(ConnectionQualitySample(report, at: ProcessInfo.processInfo.systemUptime))
        slowRoundTripMs = qualityMonitor.slowRoundTripMs
        roundTripSpreadMs = qualityMonitor.roundTripSpreadMs
        frameHealthPercent = qualityMonitor.lastLossPercent
        if qualityMonitor.isPoor {
            let cause = qualityVerdict?.cause ?? ConnectionQualityCause.pick(routeDetail: report.routeDetail,
                phoneLink: linkHint, macLink: report.host?.macLink)
            qualityVerdict = ConnectionQualityVerdict(cause: cause, lossPercent: Int((frameHealthPercent ?? 0).rounded()))
        } else { qualityVerdict = nil }
        if changed {
            SessionLog.log.info("picture quality \(self.qualityMonitor.level.rawValue, privacy: .public) · slow RTT \(self.slowRoundTripMs ?? 0, privacy: .public) ms")
        }
        _ = wifiStall.observe(report)
        wifiStallTip = wifiStall.showing ? WiFiStallTip.observed(report) : nil
    }

    private func acceptResumeMeasurement(_ measurement: ResumeTiming.Measurement?) {
        guard let measurement else { return }
        lastResume = measurement
        resumeCount += 1
        SessionLog.log.info("resume \(measurement.kind.rawValue, privacy: .public) \(measurement.totalMs, privacy: .public) ms · after active \(measurement.afterActiveMs, privacy: .public) ms · settled \(measurement.settledMs ?? -1, privacy: .public) ms · fallback \(measurement.fellBack, privacy: .public) · count \(self.resumeCount, privacy: .public)")
    }

    /// G4: the part of the display the frames cover, as the Mac last reported it; nil for the whole display.
    // Not a presentation boundary: every viewport echo and ladder step changes it while the display,
    // geometry epoch and owner stay the same. Retiring here blanked the picture several times a second.
    @Published private(set) var captureRegion: CaptureRegion?
    /// The region the picture is placed by (b7-scroll, 2 Oct). Frames carry their own capture region in
    /// the access unit (`VideoFrameTag.region`), so the placement switches with the first frame of a new
    /// crop instead of with the `capture` status, which used to arrive 1-10 frames apart from the video
    /// and showed old-crop frames stretched into the new rect. Fallbacks, for frames without a region:
    /// the last echoed region of the frame's pixel size, then the echo itself.
    @Published private(set) var placementRegion: CaptureRegion?
    private var regionHistory: [CaptureRegion] = []
    static let regionHistoryLimit = 16
    /// While frames carry regions, a frame without one (a Smooth Motion midpoint, or one encoded before
    /// the Mac learned its region) keeps the placement; after `untaggedRunLimit` such frames in a row
    /// the Mac has stopped tagging and the fallbacks apply again.
    private var taggedRegionFrames = 0
    private var untaggedRun = 0
    private var placedOutput: PixelSize?
    static let untaggedRunLimit = 30
    var regionByFrame = RegionByFrameSwitch.isOn
    /// G12: the Mac's own account of its load, for the pill; nil from a Mac without the ladder.
    @Published private(set) var busy: BusyState?
    /// The Mac's battery, temperature and load as last received; read through `currentMacVitals(now:)`.
    @Published private(set) var macVitals: MacVitals?
    private var macVitalsReceivedAt: TimeInterval = 0
    /// The session's last real reading for Home: the Mac's own sleep or lock status carries no vitals.
    private var sessionVitals: (vitals: MacVitals, receivedAt: Date, room: String?)?
    private var vitalsNotices = MacVitalsNoticePolicy()
    var vitalsMemory = MacVitalsMemory()
    static let macVitalsMaxAge: TimeInterval = 3
    #if DEBUG
    private var vitalsPreview: (supported: Bool, active: Bool) = (false, false)
    #endif
    private(set) var ladder: LadderState?
    private var viewportReporter = ViewportReporter()
    private var phoneLoadCache = PhoneLoadFeedbackCache()
    private var hostPhoneLoadWindows = false
    private var viewportSendTask: Task<Void, Never>?
    private var viewportSendAt: TimeInterval?
    private var nativeScreenPixels: PixelSize?
    @Published var streamQuality: StreamQuality = .sharp {
        didSet {
            guard oldValue != streamQuality else { return }
            qualityRequestedAt = ProcessInfo.processInfo.systemUptime
            StreamQualityPreference.store(streamQuality, in: preferences)
        }
    }
    private var qualityRequestedAt: TimeInterval?

    var pictureMode: PictureMode {
        get { PictureMode(quality: streamQuality) }
        set { streamQuality = newValue.streamQuality }
    }
    var pictureSmoothMotion: SmoothMotionMode {
        PictureModePreference.motion(for: pictureMode, defaults: preferences)
    }

    var streamQualityStatus: String? {
        guard let appliedStreamQuality else { return "Update Farside on your Mac to change picture quality." }
        guard appliedStreamQuality != streamQuality else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - (qualityRequestedAt ?? ProcessInfo.processInfo.systemUptime)
        return elapsed < 3
            ? CommerceLocalization.text("PICTURE_MODE_SWITCHING", "Switching to %@…", pictureMode.localizedTitle())
            : CommerceLocalization.text("PICTURE_MODE_PENDING", "Mac is still using %@. Switch modes to retry.",
                                        PictureMode(quality: appliedStreamQuality).localizedTitle())
    }
    private var pointerTimer: Timer?

    struct PendingPairReplacement: Identifiable {
        var id: String { approval.request.scannedInvitationFingerprint }
        let code: String
        let oldName: String
        let approval: PhoneTrustReplacementApproval
    }
    @Published private(set) var pendingPairReplacement: PendingPairReplacement?
    @Published var pairingCode = ""
    @Published var error = ""
    @Published var pairingEntry: PairingEntry?
    @Published private(set) var sharedCaptureScope: CaptureScopeFrame? { willSet { if newValue != sharedCaptureScope { retireContentPresentation() } } }
    var captureScopeViewOnly: Bool { sharedCaptureScope?.viewOnly == true }
    var captureScopeDescription: String? {
        guard let scope = sharedCaptureScope, scope.viewOnly else { return nil }
        return "\(scope.label) · view only · audio off"
    }
    @Published private(set) var macAudioMuted = true
    private let macAudioPlayback: PhoneSystemAudioPlayback
    private struct MacAudioConsent {
        let peer: PeerMedia
        let session: UUID
        let contentEpoch: UInt64
        let geometry: UInt64
    }
    private var macAudioConsent: MacAudioConsent?
    private var macAudioSuspended = false
    private func currentMacAudioConsent() -> Bool {
        guard !macAudioMuted, let consent = macAudioConsent else { return false }
        return connection.media === consent.peer && connection.presentationSessionID == consent.session &&
            presentationContentEpoch == consent.contentEpoch && geometryEpoch == consent.geometry &&
            connection.connected && !captureScopeViewOnly && !viewOnlyConfirmed && !pendingViewOnlyStart &&
            !awaitingViewOnlyExit && !pipBackground && pendingLockMac == nil
    }
    private func suspendMacAudio() {
        guard !macAudioMuted else { return }
        macAudioSuspended = true
        connection.media?.setRemoteAudioMuted(true)
        sendMacAudioRequest()
    }
    private func resumeMacAudioIfAllowed() {
        guard macAudioSuspended else { return }
        guard currentMacAudioConsent() else { setMacAudioMuted(true); return }
        guard sceneIsActive, !privacyShield, !contentConcealed, macAudioPlayback.isAdmitted,
              connection.presentationDeadline(at: ProcessInfo.processInfo.systemUptime) != nil else { return }
        macAudioSuspended = false
        connection.media?.setRemoteAudioMuted(false)
        sendMacAudioRequest()
    }
    var phoneAudioRequestSupported: Bool { hostFeatures.contains(SessionFeature.phoneAudio) }
    private func sendMacAudioRequest() {
        guard connection.connected, phoneAudioRequestSupported else { return }
        _ = connection.sendControl(heartbeatAction())
    }
    func setMacAudioMuted(_ muted: Bool) {
        if !muted {
            guard !captureScopeViewOnly, !viewOnlyConfirmed, !pendingViewOnlyStart, !awaitingViewOnlyExit, !pipBackground,
                  pendingLockMac == nil, connection.connected, !contentConcealed, sceneIsActive,
                  let peer = connection.media, connection.presentationDeadline(at: ProcessInfo.processInfo.systemUptime) != nil else { return }
            let session = connection.presentationSessionID, content = presentationContentEpoch, geometry = geometryEpoch
            guard macAudioPlayback.begin() else { return }
            guard connection.media === peer, connection.presentationSessionID == session,
                  presentationContentEpoch == content, geometryEpoch == geometry, sceneIsActive, !privacyShield,
                  !contentConcealed, !captureScopeViewOnly, !viewOnlyConfirmed, !pendingViewOnlyStart,
                  !awaitingViewOnlyExit, !pipBackground, pendingLockMac == nil,
                  connection.presentationDeadline(at: ProcessInfo.processInfo.systemUptime) != nil else {
                macAudioPlayback.end(); return
            }
            macAudioConsent = MacAudioConsent(peer: peer, session: session, contentEpoch: content, geometry: geometry)
        }
        macAudioMuted = muted
        connection.media?.setRemoteAudioMuted(muted)
        if muted {
            macAudioConsent = nil; macAudioSuspended = false
            macAudioPlayback.end()
        }
        sendMacAudioRequest()
    }
    @Published private(set) var privacyShield = false { willSet { if newValue { invalidatePresentation(keepingPiP: mayKeepLivePiP || autoPiPMayStart || pipBackground && mayHoldBackgroundPiP) } } }
    private var hasBeenActive = false
    @Published var draft = "" { didSet { secureTextFocus.draftChanged(draft) } }
    @Published private(set) var frontmostApp: FrontmostApp?
    @Published var secureTextFocus = SecureTextFocus()
    @Published var isComposingText = false
    @Published var dragging = false
    @Published var modifiers: Set<String> = []
    @Published var controlAllowed = false
    @Published var fresh = false
    @Published var captureHealthy = false { willSet { if !newValue { invalidatePresentation() } } }
    @Published var geometryEpoch: UInt64 = 0 { willSet { if newValue != geometryEpoch { retireContentPresentation() } } }
    @Published var textStatus = ""
    @Published private(set) var voiceDeliveryStatus: VoiceDeliveryStatus = .idle
    @Published private(set) var voiceRetryTranscript = ""
    @Published private(set) var contentConcealed = false { willSet { if newValue { invalidatePresentation(keepingPiP: pipBackground && mayHoldBackgroundPiP) } } }

    @Published var sourceSize = CGSize(width: 1440, height: 900)
    @Published private(set) var inputRevision: UInt64 = 0
    @Published private(set) var acceptedClicks: UInt64 = 0
    /// Which click the last accepted one was ("click", "right" or "double"), for the contact ripple.
    private(set) var lastAcceptedClick = "click"
    @Published private(set) var autoKeyboardRevision: UInt64 = 0
    /// The focused field's rect from the newest click (or, while following typing, the newest text).
    @Published private(set) var focusTarget: FocusTarget?
    private var focusTargetRevision: UInt64 = 0
    /// Set by the session while the keyboard is open in Follow typing.
    var followTyping = false
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

    let livePiP: LivePiPController
    @Published private(set) var pipState: LivePiPPolicy.State = .ineligible
    @Published private(set) var inlinePresentationAdmission: VideoPresentationAdmission?
    @Published private(set) var pipAdmission: VideoPresentationAdmission?
    let usefulSession = UsefulSessionProgress()
    private var appliedReceiptTracker = AppliedInputReceiptTracker()
    private var presentationHost: PhoneHostTrust?
    private var presentationContentEpoch: UInt64 = 1
    private var pipBackground = false
    private var pipTransitional = false
    /// The OS started PiP as the user left a live session; the Mac's live-view-only confirmation may still be pending.
    private var autoPiPStarted = false
    /// iOS can deliver `.background` before AVKit's automatic start; a prepared PiP gets this one bounded wait.
    private var autoPiPBackgroundGrace: Task<Void, Never>?
    private var autoPiPGraceSpent = false
    static let autoPiPBackgroundGraceSeconds: Double = 1
    /// Internal kill switch, no UI: `defaults write <bundle id> farsideAutoPiPDisabled -bool YES`.
    static let autoPiPDisabledKey = "farsideAutoPiPDisabled"
    private(set) var autoPiPEnabled = true
    private struct PiPRestoreRequest {
        let session: UUID
        let contentEpoch: UInt64
        let geometry: UInt64
        let deadline: TimeInterval
        let complete: (Bool) -> Void
    }
    private var pipRestoreRequest: PiPRestoreRequest?
    #if DEBUG
    // Model lifecycle boundary only: never presented as native producer or route admission evidence.
    private var presentationProofForTesting: VideoPresentationAdmission?
    #endif
    private func finishPiPRestore(_ restored: Bool) {
        guard let request = pipRestoreRequest else { return }
        pipRestoreRequest = nil // Completion may synchronously reenter.
        request.complete(restored)
    }
    private func requestPiPRestore(_ completion: @escaping (Bool) -> Void) {
        guard connection.connected, pipAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true else {
            completion(false); return
        }
        let session = connection.presentationSessionID, content = presentationContentEpoch, geometry = geometryEpoch
        finishPiPRestore(false)
        guard pipRestoreRequest == nil, connection.connected, connection.presentationSessionID == session,
              presentationContentEpoch == content, geometryEpoch == geometry,
              pipAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true else { completion(false); return }
        pipRestoreRequest = PiPRestoreRequest(session: connection.presentationSessionID,
            contentEpoch: presentationContentEpoch, geometry: geometryEpoch,
            deadline: ProcessInfo.processInfo.systemUptime + 2, complete: completion)
        if sceneIsActive { completePiPRestoreIfCurrent() }
    }
    private func completePiPRestoreIfCurrent() {
        guard let request = pipRestoreRequest else { return }
        guard request.session == connection.presentationSessionID, request.contentEpoch == presentationContentEpoch,
              request.geometry == geometryEpoch, connection.connected,
              ProcessInfo.processInfo.systemUptime < request.deadline else { finishPiPRestore(false); return }
        guard sceneIsActive, !privacyShield, !contentConcealed else { return }
        finishPiPRestore(true) // UI restored; control still waits for the matching host exit ACK.
    }
    private var invalidatingPiP = false
    private var viewOnlyConfirmed = false
    private var pendingViewOnlyStart = false
    private var viewOnlyStartDeadline: TimeInterval?
    private var viewOnlyRequest = LiveViewOnlyRequest()
    private var awaitingViewOnlyExit = false
    // Independent of content retirement: a changed geometry cannot erase the safety timeout.
    private var viewOnlyExitDeadline: TimeInterval?

    private var mayKeepLivePiP: Bool {
        PresentationLeasePolicy.mayContinueBackground(state: pipState, admission: pipAdmission,
            viewOnlyConfirmed: viewOnlyConfirmed, now: ProcessInfo.processInfo.systemUptime) || autoPiPAwaitingConfirmation
    }
    private var mayHoldBackgroundPiP: Bool {
        PresentationLeasePolicy.mayHoldBackground(state: pipState, admission: pipAdmission,
            viewOnlyConfirmed: viewOnlyConfirmed, now: ProcessInfo.processInfo.systemUptime) || autoPiPAwaitingConfirmation
    }
    /// An OS-started PiP is held while the Mac confirms live view only (at most the 2 s `viewOnlyStartDeadline`)
    /// and after it confirms, including while AVKit is still finishing the start (`.starting`).
    private var autoPiPAwaitingConfirmation: Bool {
        autoPiPStarted && (pendingViewOnlyStart || viewOnlyConfirmed) && [.starting, .active, .paused].contains(pipState)
            && pipAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true
    }
    /// Armed while a live picture session is in the foreground: leaving the app may then start PiP.
    private var autoPiPArmed: Bool {
        autoPiPEnabled && sceneIsActive && connection.connected && sessionMode == .picture
            && hostFeatures.contains(SessionFeature.liveViewOnly) && pipState == .ready
            && pipAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true
            && !privacyShield && !contentConcealed && !viewOnlyConfirmed && !pendingViewOnlyStart
            && !awaitingViewOnlyExit && pendingLockMac == nil && pipRestoreRequest == nil
    }
    /// Through `.inactive` an armed, not-yet-started PiP stays prepared so the OS can still auto-start it.
    private var autoPiPMayStart: Bool {
        livePiP.automaticStartAllowed && pipState == .ready && connection.connected && sessionMode == .picture
            && pipAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true && pendingLockMac == nil
    }
    /// The inline PiP source layer sits behind the picture whenever an automatic start could be armed.
    var showsInlinePiPSource: Bool { autoPiPEnabled && pipAdmission != nil && sessionMode == .picture }
    private func cachePresentationHost() {
        presentationHost = nil
        guard let invitation = connection.invitation,
              let host = connection.presentationHostTrust,
              host.invitation == invitation else { return }
        presentationHost = host
    }
    private func retireContentPresentation() {
        diagnostics.cancel()
        pipTransitional = false
        invalidatePresentation()
        presentationContentEpoch &+= 1
        setMacAudioMuted(true)
        finishPiPRestore(false)
    }
    private func invalidatePresentation(keepingPiP: Bool = false, requestHostExit: Bool = true) {
        phoneLoadCache.invalidate()
        PhoneIdleTimer.shared.endSession()
        if pendingWake != nil { wakeStatus = "The helper session changed. No new wake result can be confirmed." }
        pendingWake = nil; wakeTimeout?.cancel(); wakeTimeout = nil
        appliedReceiptTracker.clear()
        pendingText?.usefulContext = nil
        usefulSession.invalidate()
        usefulPicture.invalidate()
        inlinePresentationAdmission?.lifetime.retire()
        if !keepingPiP { pipAdmission?.lifetime.retire() }
        VideoPresentationSession.invalidateActive()
        if !keepingPiP { connection.media?.videoFeedback.configure(allowed: false, geometry: geometryEpoch, scope: sharedCaptureScope?.epoch ?? 1) }
        inlinePresentationAdmission = nil
        if !keepingPiP {
            // A queued enter may already have suspended the host. Retiring its content
            // correlation cannot retire the independent cleanup obligation.
            let needsExit = requestHostExit && connection.connected &&
                (pendingViewOnlyStart || viewOnlyConfirmed) && !awaitingViewOnlyExit
            pipAdmission = nil
            pendingViewOnlyStart = false
            viewOnlyStartDeadline = nil
            autoPiPStarted = false
            livePiP.automaticStartAllowed = false
            // Presentation retirement can repeat while the host applies our exit.
            // Preserve that exact cleanup request until its ACK or timeout; terminal
            // session teardown still retires its correlation synchronously.
            if !awaitingViewOnlyExit || !requestHostExit { viewOnlyRequest.reset() }
            invalidatingPiP = true
            livePiP.stop()
            invalidatingPiP = false
            // A deadline alone cannot return the Mac to interactive mode. Send a correlated exit.
            if needsExit { requestViewOnlyExit() }
        }
    }
    private func refreshPresentation(at now: TimeInterval) {
        refreshIdleTimer(at: now)
        let host = presentationHost
        let identity: VideoPresentationIdentity? = host.map {
            VideoPresentationIdentity(hostRecordID: $0.id,
                ownerPairID: $0.ownerPairID ?? "legacy-session:" + connection.presentationSessionID.uuidString,
                sessionID: connection.presentationSessionID, trackID: connection.presentationTrackID,
                contentEpoch: presentationContentEpoch, geometryEpoch: geometryEpoch)
        }
        let blocked = pendingLockMac != nil || host?.invitation != connection.invitation || hostPresence == .locked || hostPresence == .switchedUser
        var proof = PresentationLeasePolicy.admission(identity: identity, routeDeadline: connection.presentationDeadline(at: now),
            captureHealthAt: lastCaptureHealth, healthy: captureHealthy, picture: sessionMode == .picture,
            trackPresent: connection.remoteVideo != nil, blocked: blocked, now: now)
        #if DEBUG
        if let fixture = presentationProofForTesting, connection.connected,
           fixture.identity.sessionID == connection.presentationSessionID,
           fixture.identity.trackID == connection.presentationTrackID,
           fixture.identity.contentEpoch == presentationContentEpoch, fixture.identity.geometryEpoch == geometryEpoch,
           pendingLockMac == nil, fixture.permits(at: now) {
            proof = VideoPresentationAdmission(identity: fixture.identity, validUntil: fixture.validUntil)
        }
        #endif
        resumeMacAudioIfAllowed()
        let inline = VideoPresentationAdmission.renewed(sceneIsActive && !privacyShield && !contentConcealed ? proof : nil,
            from: inlinePresentationAdmission)
        if let peer = connection.media {
            let supportsLTR = hostFeatures.contains(SessionFeature.videoLTR)
            // Only a refinement this phone asked for at session start, whatever the Mac advertises.
            let refines = !lowDataState.active && hostFeatures.contains(SessionFeature.videoRefinement) && connection.requestedFeatures.contains(SessionFeature.videoRefinement)
            peer.videoFeedback.configure(allowed: proof != nil && (supportsLTR || refines || hostFeatures.contains(SessionFeature.exactVideoTiming)),
                ltr: supportsLTR, refinement: refines, timing: hostFeatures.contains(SessionFeature.exactVideoTiming), geometry: geometryEpoch, scope: sharedCaptureScope?.epoch ?? 1)
            peer.configureVideoRefinement(enabled: proof != nil && refines, geometry: geometryEpoch, scope: sharedCaptureScope?.epoch ?? 1)
            peer.videoFeedback.setFeedback { [weak self, weak peer] packet, epoch in
                DispatchQueue.main.async {
                    guard let self, let peer, self.connection.media === peer, self.geometryEpoch == epoch,
                          self.captureHealthy, self.hostFeatures.contains(SessionFeature.videoLTR),
                          self.connection.presentationDeadline(at: ProcessInfo.processInfo.systemUptime) != nil else { return }
                    _ = self.connection.sendControl(RemoteAction(action: "heartbeat", epoch: epoch, videoFeedback: packet))
                }
            }
        }
        if inlinePresentationAdmission?.identity != inline?.identity { VideoPresentationSession.invalidateActive() }
        inlinePresentationAdmission = inline
        let mayPreroll = sceneIsActive && !privacyShield && !contentConcealed
        // PiP and inline have separate terminal lifetimes: background retirement of inline cannot kill an approved PiP.
        let pipProposal = proof.map { VideoPresentationAdmission(identity: $0.identity, validUntil: $0.validUntil) }
        let nextPiP = VideoPresentationAdmission.renewed(hostFeatures.contains(SessionFeature.liveViewOnly) &&
            (mayPreroll || pipTransitional && (mayKeepLivePiP || autoPiPMayStart) || pipBackground && mayHoldBackgroundPiP) ? pipProposal : nil, from: pipAdmission)
        pipAdmission = nextPiP
        livePiP.updateAdmission(nextPiP)
        if nextPiP != nil, let track = connection.remoteVideo { livePiP.attachSourceTrack(track) }
        // Re-armed only in the foreground; through `.inactive` the last foreground decision stands.
        if sceneIsActive { livePiP.automaticStartAllowed = autoPiPArmed }
    }
    private var usefulPicture = UsefulPictureEvidence()
    private var lastUsefulPresentationUpdate: TimeInterval = 0
    func originalSourcePresented(_ identity: VideoPresentationIdentity, receipt: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let admission = inlinePresentationAdmission, identity == admission.identity,
              admission.permits(at: now), let context = usefulSessionContext,
              identity.hostRecordID == context.hostRecordID, identity.sessionID == context.sessionID,
              identity.contentEpoch == context.contentEpoch, identity.geometryEpoch == context.geometryEpoch,
              identity.trackID == connection.presentationTrackID, sceneIsActive, !privacyShield, !contentConcealed,
              let deadline = usefulPictureDeadline(at: now) else { return }
        usefulPicture.presented(receipt, context: context, deadline: deadline, now: now)
        if now - lastUsefulPresentationUpdate >= 0.25 || !usefulSession.evidence.ready(at: now) {
            lastUsefulPresentationUpdate = now; refreshUsefulSession(at: now)
        }
    }
    private func usefulPictureDeadline(at now: TimeInterval) -> TimeInterval? {
        guard sessionMode == .picture, fresh, lastFrame > 0,
              inlinePresentationAdmission?.permits(at: now) == true,
              let route = connection.presentationDeadline(at: now), captureHealthy,
              lastCaptureHealth > 0, sourceSize.width > 0, sourceSize.height > 0,
              hostPresence != .locked, hostPresence != .switchedUser,
              sceneIsActive, !privacyShield, !contentConcealed else { return nil }
        let deadline = min(route, lastCaptureHealth + 2, lastFrame + 2)
        return now < deadline ? deadline : nil
    }
    private func confirmVisibleUsefulPicture() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let context = usefulSessionContext, let deadline = usefulPictureDeadline(at: now) else { return }
        usefulPicture.confirmVisible(context: context, deadline: deadline, now: now)
        refreshUsefulSession(at: now)
    }

    private var usefulSessionContext: UsefulSessionContext? {
        guard let host = presentationHost, host.invitation == connection.invitation, geometryEpoch > 0 else { return nil }
        return UsefulSessionContext(hostRecordID: host.id, sessionID: connection.presentationSessionID,
            contentEpoch: presentationContentEpoch, geometryEpoch: geometryEpoch)
    }
    private func refreshUsefulSession(at now: TimeInterval) {
        guard sceneIsActive, !privacyShield, !contentConcealed, hostPresence != .locked,
              hostPresence != .switchedUser, captureHealthy, sourceSize.width > 0, sourceSize.height > 0,
              let context = usefulSessionContext, let route = connection.presentationDeadline(at: now),
              lastCaptureHealth > 0 else { usefulSession.invalidate(); return }
        let deadline = min(route, lastCaptureHealth + 2)
        let pictureEligible = usefulPictureDeadline(at: now) != nil
        if pictureEligible, let visibleUntil = usefulPicture.visibleUntil(context: context, now: now) {
            usefulSession.setPictureConfirmationAvailable(false)
            usefulSession.admit(.picture, context: context, deadline: min(deadline, lastFrame + 2, visibleUntil), now: now)
        } else if sessionMode == .couch, connection.provenLocalLinkActive,
                  hostFeatures.contains(SessionFeature.couch), canControl {
            usefulSession.setPictureConfirmationAvailable(false)
            usefulSession.admit(.couch, context: context, deadline: deadline, now: now)
        } else {
            usefulSession.invalidate(pictureConfirmationAvailable: pictureEligible)
        }
    }
    private func receiveAppliedInput(_ action: RemoteAction) {
        let now = ProcessInfo.processInfo.systemUptime
        refreshUsefulSession(at: now)
        guard hostFeatures.contains(SessionFeature.inputReceipt), let context = usefulSessionContext,
              let receipt = action.inputAppliedReceipt,
              appliedReceiptTracker.consume(receipt, epoch: action.epoch, context: context, at: now) else { return }
        usefulSession.applied(context: context, now: now)
        // Setup Done can start Big Text before this ACK arrives and hide the hint.
        // The consumed receipt remains authoritative within its exact original context.
        if first60Enabled, receipt.kind == "click", first60HintStage == .click {
            advanceFirst60Hint(.finished)
        }
    }
    func startPictureInPicture() {
        guard sceneIsActive, !privacyShield, !contentConcealed, !awaitingViewOnlyExit, pipState == .ready,
              hostFeatures.contains(SessionFeature.liveViewOnly), pipAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true else { return }
        livePiP.automaticStartAllowed = false; autoPiPStarted = false // The button owns this start.
        requestViewOnlyEntry()
    }
    private func requestViewOnlyEntry() {
        releasePiPControl()
        let id = viewOnlyRequest.begin(epoch: geometryEpoch, at: ProcessInfo.processInfo.systemUptime)
        pendingViewOnlyStart = connection.sendControl(RemoteAction(action: "viewOnly", liveViewOnly: true, liveViewOnlyRequestID: id, epoch: geometryEpoch))
        viewOnlyStartDeadline = pendingViewOnlyStart ? ProcessInfo.processInfo.systemUptime + 2 : nil
        if !pendingViewOnlyStart { invalidatePresentation() }
    }
    func stopPictureInPicture() {
        invalidatePresentation()
        if pipBackground && pipRestoreRequest == nil { disconnect(explicitEnd: false) }
    }
    private func requestViewOnlyExit() {
        awaitingViewOnlyExit = true
        let now = ProcessInfo.processInfo.systemUptime
        viewOnlyExitDeadline = min(viewOnlyExitDeadline ?? (now + 2), now + 2)
        let id = viewOnlyRequest.begin(epoch: geometryEpoch, at: ProcessInfo.processInfo.systemUptime)
        viewOnlyStartDeadline = nil
        if !connection.sendControl(RemoteAction(action: "viewOnly", liveViewOnly: false, liveViewOnlyRequestID: id, epoch: geometryEpoch)) { disconnect(explicitEnd: false) }
    }
    private func releasePiPControl() {
        setMacAudioMuted(true); endSecureFocus(); cancelInput(); inputToken = nil
        clipboard.cancel(); clipboard.clearNotice(); files.stopForBackground()
    }

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

    init(background: BackgroundExecution? = nil, resumeStore: SessionResumeStore = SessionResumeStore(),
         macAudioPlayback: PhoneSystemAudioPlayback? = nil, livePiP: LivePiPController? = nil,
         preferences: UserDefaults = .standard, coordinator: RemoteCoordinator? = nil) {
        #if DEBUG
        // E2E keeps its own trust; launch-seeded and injected test pairings stay isolated.
        connection = coordinator ?? RemoteCoordinator(isHost: false,
            store: PhoneE2E.active?.pairStore ?? LaunchSeeds.pairingStore(),
            sessionLossRetryLimit: 24, maximumRetryDelayNanoseconds: 4_000_000_000)
        #else
        connection = coordinator ?? RemoteCoordinator(isHost: false,
            sessionLossRetryLimit: 24, maximumRetryDelayNanoseconds: 4_000_000_000)
        #endif
        diagnostics.bind(to: connection)
        self.preferences = preferences
        first60Enabled = First60.isEnabled(preferences)
        sessionPolishEnabled = preferences.object(forKey: Self.sessionPolishKey) == nil || preferences.bool(forKey: Self.sessionPolishKey)
        firstPictureReady = !first60Enabled || preferences.bool(forKey: Self.firstPictureShownKey)
        first60HintStage = First60HintStage(rawValue: preferences.integer(forKey: Self.first60HintStageKey)) ?? .move
        dataWarningGate = DataWarningGate(defaults: preferences)
        streamQuality = StreamQualityPreference.stored(in: preferences)
        self.macAudioPlayback = macAudioPlayback ?? PhoneSystemAudioPlayback()
        self.livePiP = livePiP ?? LivePiPController()
        autoPiPEnabled = !preferences.bool(forKey: Self.autoPiPDisabledKey)
        self.background = background ?? SystemBackgroundExecution()
        self.resumeStore = resumeStore
        resumeCapsule = resumeStore.load()
        if let host = connection.presentationHostTrust { bigTextMemory.migrate(host: host) }
        NativeCodecCapability.warmUp()
        NativeHEVCCapability.warmUp()
        NativeHEVC444Capability.warmUp()
        // Shown by the Mac as who is connected (D39). Without the user-assigned-device-name
        // entitlement iOS reports the model ("iPhone"), which the Mac shows as "Your iPhone".
        connection.localDisplayName = UIDevice.current.name
        #if DEBUG
        contentConcealed = ProcessInfo.processInfo.arguments.contains("--ui-background-concealed-check")
        dataWarningShown = LaunchOptions.has("--ui-data-warning")
        if LaunchOptions.demoMacName != nil || LaunchOptions.value("--ui-last-battery=") != nil {
            // UI tests get their own last-seen battery so they never read or overwrite the real one.
            let suite = "farside.ui-tests.vitals"
            if let defaults = UserDefaults(suiteName: suite) {
                defaults.removePersistentDomain(forName: suite)
                vitalsMemory = MacVitalsMemory(defaults: defaults)
            }
            if let raw = LaunchOptions.value("--ui-last-battery="), let percent = Int(raw) {
                vitalsMemory.record(MacVitals(power: "battery", batteryPercent: percent, charging: false), at: Date(), room: connection.invitation?.room)
            }
        }
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
        HiddenSettingsMigration.run()
        if let mode = LaunchOptions.touchModeOverride { UserDefaults.standard.set(mode.rawValue, forKey: TouchInputMode.key) }
        if LaunchOptions.has("--ui-minimap-reset") {
            UserDefaults.standard.removeObject(forKey: "miniMap.phoneLandscape")
            UserDefaults.standard.removeObject(forKey: "miniMap.pad")
        }
        usefulSession.onConfirmVisiblePicture = { [weak self] in self?.confirmVisibleUsefulPicture() }
        self.macAudioPlayback.onMustMute = { [weak self] in self?.setMacAudioMuted(true) }
        self.macAudioPlayback.onSuspended = { [weak self] in self?.suspendMacAudio() }
        self.macAudioPlayback.onResumed = { [weak self] in
            guard let self, self.currentMacAudioConsent(),
                  self.connection.presentationDeadline(at: ProcessInfo.processInfo.systemUptime) != nil else { return false }
            self.resumeMacAudioIfAllowed()
            return true
        }
        self.livePiP.didChangeState = { [weak self] state in
            guard let self else { return }
            self.pipState = state
            if (state == .ineligible || state == .stopping) && self.autoPiPStarted {
                // An OS-started PiP ended on its own: drop its pending entry so no later answer can restart it.
                self.autoPiPStarted = false
                if self.pendingViewOnlyStart && !self.invalidatingPiP {
                    self.pendingViewOnlyStart = false; self.viewOnlyStartDeadline = nil
                    if self.connection.connected && !self.awaitingViewOnlyExit { self.requestViewOnlyExit() }
                }
            }
            if self.pipBackground && state != .active && state != .paused && !(state == .starting && self.autoPiPStarted)
                && self.pipRestoreRequest == nil { self.disconnect(explicitEnd: false) }
            else if state == .ineligible && !self.invalidatingPiP && self.viewOnlyConfirmed && !self.awaitingViewOnlyExit && self.pipRestoreRequest == nil {
                self.requestViewOnlyExit()
            }
        }
        self.livePiP.mayStartAutomatically = { [weak self] in
            guard let self else { return false }
            return self.autoPiPMayStart && !self.viewOnlyConfirmed && !self.pendingViewOnlyStart && !self.awaitingViewOnlyExit
        }
        self.livePiP.didStartAutomatically = { [weak self] in
            guard let self else { return }
            self.autoPiPStarted = true
            self.requestViewOnlyEntry() // The Mac must confirm live view only within 2 s, as for the button.
            // Started inside the background grace: take the PiP background path now.
            if self.autoPiPBackgroundGrace != nil, self.sceneWasBackground, !self.sceneIsActive, !self.pipBackground { self.enterBackground() }
        }
        self.livePiP.restoreForeground = { [weak self] completion in
            guard let self else { completion(false); return }
            self.requestPiPRestore(completion)
        }
        connection.onPresentationInvalidated = { [weak self] in self?.retireContentPresentation() }
        if preferences.bool(forKey: Self.localOnlyKey) { connection.setLocalOnly(true) }
        connection.restore()
        linkHints.start()
        linkConsentObserver = linkHints.$hint.removeDuplicates().sink { [weak self] hint in self?.observeLinkHint(hint) }
        first60SetupObserver = connection.$setupInProgress.removeDuplicates().sink { [weak self] open in
            if open == true {
                if self?.firstPictureSession == true { self?.initialScaleDeferredForSetup = true }
                return
            }
            // Published values emit before assignment. Read the accepted status next turn.
            DispatchQueue.main.async { [weak self] in
                if let self, self.connection.setupInProgress != true, let deferred = self.deferredSetupBigText {
                    self.deferredSetupBigText = nil
                    self.sendBigText(display: deferred.display, width: deferred.width, initialPresentation: deferred.initial)
                }
                self?.applySavedBigText()
                self?.refreshFirstPicture()
            }
        }
        connection.onAuthenticated = { [weak self] in
            guard let self else { return }
            if self.sessionPolishEnabled {
                self.retireBigTextRequest()
                self.bigTextDisplayID = nil
                self.displaysRequested = false
                self.bigText.autoApplied = false
            }
            self.beginFirstPicture()
            self.invalidatePresentation()
            self.cachePresentationHost()
            self.cancelLockMacRequest()
            self.awayState = nil
            self.awayStatusEpoch = nil
            self.lockMacStatus = nil
            self.contentConcealed = false
            self.resumeState = .none
            self.macNotice = nil
            self.lastDeparture = nil
            self.sessionEndReason = nil
            self.backgroundHoldEndsAt = nil
            self.phoneLoadCache = PhoneLoadFeedbackCache()
            self.phoneLoadCache.invalidate()
            self.hostPhoneLoadWindows = false
            self.viewportResume = nil
            self.resumeResolved = self.resumeCapsule == nil
            self.resumeStartedAt = ProcessInfo.processInfo.systemUptime
            self.qualityMonitor = ConnectionQualityMonitor()
            self.resetQuality()
            self.link = nil
            self.qualityRouteDetail = nil
            self.dismissedQualityBanners = []
            self.resumeCount = 0
            if let peer = self.connection.media {
                peer.onAudioPlaybackFailure = { [weak self, weak peer] in
                    guard let self, let peer, self.connection.media === peer else { return }
                    self.setMacAudioMuted(true)
                    self.showSessionNotice("Mac audio couldn’t start. Try Listen again.")
                }
                peer.onStreamStatistics = { [weak self, weak peer] report in
                    Task { @MainActor in
                        guard let self, let peer, self.connection.media === peer else { return }
                        self.observeQuality(report)
                        var report = report
                        report.frameHealthPercent = self.frameHealthPercent
                        report.connectionQuality = self.frameHealthPercent == nil ? "unmeasured" : self.qualityMonitor.level.rawValue
                        report.qualityMeasuredWindows = self.qualityMonitor.measuredWindows
                        report.qualityPoorEntries = self.qualityMonitor.poorEntries
                        report.rttStdDevMs = self.roundTripSpreadMs
                        self.diagnostics.observe(report, estimate: self.appliedStreamQuality.map(self.dataUseEstimate(for:)))
                        if StreamDebug.enabled { StreamDebug.record(report) }
                        let lines = report.summaryLines
                        if self.streamSummaryLines != lines { self.streamSummaryLines = lines }
                        var link = LinkSummary(report)
                        if link?.frameRate == nil { link?.frameRate = self.link?.frameRate }
                        if self.link != link { self.link = link }
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
        connection.onCausalContext = { [weak self] context in
            guard let self else { return }
            // The host has already retired this hold. Cancel unsent display-tick
            // motion before any later geometry callback or semantic flush.
            self.displayTickInput.cancel()
            self.cancelInput()
            if context.epoch != self.geometryEpoch {
                self.captureHealthy = false; self.fresh = false; self.inputToken = nil
            }
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
        wireFileTransfer()
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
        guard pendingLockMac == nil else { return false }
        guard !captureScopeViewOnly, bigText.pendingTarget == nil, !viewOnlyConfirmed, !pendingViewOnlyStart, !awaitingViewOnlyExit, !pipBackground else { return false }
        #if DEBUG
        if inputProbe != nil { return !privacyShield && !contentConcealed }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        return PhoneControlGate.canControl(.init(
            mode: sessionMode, privacyShield: privacyShield, contentConcealed: contentConcealed,
            connected: connection.connected, controlAllowed: controlAllowed, fresh: fresh, captureHealthy: captureHealthy,
            hostModeIsCouch: sessionMode == .couch, statusAge: lastCaptureHealth > 0 ? now - lastCaptureHealth : .infinity,
            geometryEpoch: geometryEpoch, nativeInteractionSupported: nativeInteractionSupported,
            hasToken: inputToken != nil, tokenAge: now - tokenReceivedAt))
    }

    // MARK: Couch mode

    var couchSwitchAvailable: Bool {
        connection.connected && hostFeatures.contains(SessionFeature.couch) && connection.provenLocalLinkActive
            && sessionMode == .picture
    }

    /// The mode the current or most recent attempt is in: what was on screen, else what Home asked for.
    var attemptMode: SessionMode { lastOnScreenMode ?? requestedMode }

    /// A retry the coordinator already has under way continues what was on screen; once it has
    /// stopped, a start that did not choose a mode (a Shortcut, a URL) gets the picture.
    static func modeRequestAfterSessionEnd(coordinatorRunning: Bool, attemptMode: SessionMode) -> SessionMode {
        coordinatorRunning ? attemptMode : .picture
    }

    func prepareConnection(mode: SessionMode) {
        clearContinuity()
        requestedMode = mode
        lastOnScreenMode = nil
        connection.sessionModeRequest = mode
        couchRefusal = nil
    }

    func clearCouchRefusal() { couchRefusal = nil }

    /// Asks the Mac to switch this session's mode; the Mac's next `capture` status confirms it.
    @discardableResult
    func requestMode(_ mode: SessionMode) -> Bool {
        guard connection.connected, hostFeatures.contains(SessionFeature.couch), mode != sessionMode,
              pendingModeSwitch == nil, mode != .couch || couchSwitchAvailable else { return false }
        cancelInput()
        guard connection.sendControl(RemoteAction(action: RemoteAction.modeAction, epoch: geometryEpoch,
                                                  mode: mode.rawValue)) else { return false }
        pendingModeSwitch = mode
        if mode == .picture { showSessionNotice(CouchCopy.showingPicture) }
        modeSwitchTimeout?.cancel()
        modeSwitchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.pendingModeSwitch == mode else { return }
            self.pendingModeSwitch = nil
        }
        return true
    }

    private func setSessionMode(_ mode: SessionMode) {
        if mode != sessionMode {
            couchAck.reset()
            couchStalled = false
            cancelInput()
            sessionMode = mode
            // Couch restores the Mac's normal mode. Wait for a new streamed display list
            // when picture returns rather than treating cached scale metadata as confirmation.
            bigTextDisplayID = nil
            if mode == .picture { displaysRequested = false }
            bigText.autoApplied = false
            if mode == .couch {
                bigTextSendTask?.cancel()
                bigTextSendTask = nil
                bigTextPendingRequest = nil
                bigTextTimedOut = nil
                bigText.pendingTarget = nil
                bigText.pendingSince = nil
            }
        }
        lastOnScreenMode = mode
        connection.sessionModeRequest = mode
        if pendingModeSwitch == mode { clearPendingModeSwitch() }
    }

    private func clearPendingModeSwitch() {
        pendingModeSwitch = nil
        modeSwitchTimeout?.cancel()
        modeSwitchTimeout = nil
    }

    /// The Mac accepts `moveTo`, triple-click counts and hardware modifier flags on pointer actions.
    @Published var pencilEnabled = true { didSet { if !pencilEnabled { cancelInput() } } }
    var pencilSupported: Bool { sessionMode == .picture && supports(SessionFeature.pencilInput) && absolutePointerSupported && connection.causalInputNegotiated }
    @discardableResult
    func pencil(at point: CGPoint, frame: PencilFrame) -> Bool {
        if frame.phase == .ended || frame.phase == .cancelled {
            guard activeHold == frame.stream else { return false }
            if frame.phase == .ended, canControl {
                var moved = frame; moved.phase = .moved
                _ = sendPencilPoint(point, frame: moved)
            }
            let accepted = sendInput("dragUp", count: 1, hold: frame.stream, pencil: frame)
            release(); return accepted
        }
        guard pencilEnabled, pencilSupported, canControl, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0 else { return false }
        if frame.phase == .began {
            // End any prior hold without changing the canvas revision of this new contact.
            displayTickInput.cancel(); release()
            let hover = frame.zeroed(.hover)
            guard sendPencilPoint(point, frame: hover),
                  sendInput("dragDown", count: 1, hold: frame.stream, pencil: frame) else { return false }
            activeHold = frame.stream; activeHoldCount = 1; dragging = true
            return true
        }
        if frame.phase == .moved { guard activeHold == frame.stream else { return false } }
        return sendPencilPoint(point, frame: frame)
    }
    private func sendPencilPoint(_ point: CGPoint, frame: PencilFrame) -> Bool {
        let ordinal = pointerOverlay.reserveMoveOrdinal()
        let accepted = sendInput("moveTo", x: point.x, y: point.y, count: frame.phase == .moved ? 1 : nil,
            hold: frame.phase == .moved ? frame.stream : nil, pointerSync: ordinal.map { PointerSync(move: $0) }, pencil: frame)
        if accepted { pointerLocator.clear(); pointerOverlay.localWarp(ordinal: ordinal, to: point) }
        return accepted
    }
    var absolutePointerSupported: Bool { supports(SessionFeature.absolutePointer) }
    var middleButtonSupported: Bool { supports(SessionFeature.middleButton) }
    var momentumScrollSupported: Bool { supports(SessionFeature.momentumScroll) }
    var hostMomentumSupported: Bool { nativeInteractionSupported && momentumScrollSupported && supports(SessionFeature.hostMomentum) }
    var focusGeometrySupported: Bool { supports(SessionFeature.focusGeometry) }
    var extendedKeysSupported: Bool { supports(SessionFeature.extendedKeys) }

    /// Modifier keys held on a hardware keyboard, applied to clicks, pointer motion and scrolling.
    var hardwareModifiers: [String] = []
    /// Process-start rollback snapshot; injectable per model for offline both-state checks.
    var scrollModifiers = ScrollModifierPolicy.phoneProcessEnabled
    private var extendedKeyNoticeShown = false

    private static let pointerActions: Set<String> = ["move", "moveTo", "click", "right", "double", "middle", "dragDown", "scroll"]
    private static let couchPressActions: Set<String> = ["click", "double", "right", "middle", "dragDown"]

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
            watchProbeBigText()
            receiveDisplays(RemoteAction(action: "displays", epoch: geometryEpoch,
                                         displays: probeDisplayList, display: currentDisplayID ?? Self.probeDisplays[0].id))
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
    /// Two displays for offline checks of the picker (`--ui-input-probe`); the built-in one offers
    /// two Big Text steps.
    static let probeDisplays = [
        DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1440, height: 900,
                          pixelWidth: 2880, pixelHeight: 1800, main: true,
                          scaleSteps: [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1024, height: 665)],
                          scaleBaselineWidth: 1470, scaleCurrentWidth: 1470),
        DisplayDescriptor(id: 2, name: "Studio Display", width: 2560, height: 1440,
                          pixelWidth: 5120, pixelHeight: 2880, main: false)
    ]
    private var probeScaleWidth: Double = 1470
    private var probeScaleWatch: AnyCancellable?

    private var probeDisplayList: [DisplayDescriptor] {
        var list = Self.probeDisplays
        list[0].scaleCurrentWidth = probeScaleWidth
        return list
    }

    /// Offline stand-in for the Mac's answer to `displayScale`: each request the phone starts
    /// waiting on is answered with the list at the new size, a second later so a UI test can see
    /// the progress pill.
    private func watchProbeBigText() {
        guard probeScaleWatch == nil else { return }
        probeScaleWatch = $bigText.map(\.pendingSince).removeDuplicates().compactMap { $0 }
            .delay(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.answerProbeBigText() }
    }

    private func answerProbeBigText() {
        guard let target = bigText.pendingTarget else { return }
        probeScaleWidth = target == 0 ? 1470 : target
        receiveDisplays(RemoteAction(action: "displays", epoch: geometryEpoch,
                                     displays: probeDisplayList, display: currentDisplayID, scaleRequestID: bigTextPendingRequest?.id))
    }
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
        if pendingDisplayID != nil { resetQuality() }
        pendingDisplayID = nil
        applyRememberedDisplay()
        updateBigText(from: action)
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
                                              displays: self.probeDisplayList, display: display.id))
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
        guard canControl, pendingLockMac == nil else { return false }
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

    // MARK: Mac vitals

    var macVitalsSupported: Bool {
        #if DEBUG
        if vitalsPreview.active { return vitalsPreview.supported }
        #endif
        return hostFeatures.contains(SessionFeature.macVitals)
    }

    var previewingVitals: Bool {
        #if DEBUG
        return vitalsPreview.active
        #else
        return false
        #endif
    }

    func currentMacVitals(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MacVitals? {
        if previewingVitals { return macVitals }
        guard macVitalsSupported, let macVitals, now - macVitalsReceivedAt <= Self.macVitalsMaxAge else { return nil }
        return macVitals
    }

    #if DEBUG
    func previewVitalsForTesting(_ vitals: MacVitals?, supported: Bool) {
        vitalsPreview = (supported, true)
        macVitals = vitals
    }
    #endif
    // MARK: Big Text

    @Published private(set) var bigText = BigTextState()
    var lastBigTextRequest: (display: UInt32, width: Double, requestID: String)?
    private(set) var bigTextRequestsSent = 0
    var bigTextMemory = BigTextMemory() {
        didSet { bigTextStatusSnapshot = nil }
    }
    private var bigTextStatusSnapshot: Bool?
    var bigTextRoomOverride: String?
    var bigTextClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var bigTextSendTask: Task<Void, Never>?
    private var bigTextDisplayID: UInt32?
    private var deferredSetupBigText: (display: UInt32, width: Double, initial: Bool)?
    private struct BigTextRequest {
        let id: String
        let display: UInt32
        let acceptedWidth: Double?
    }
    private var bigTextPendingRequest: BigTextRequest?
    /// Capture restart can send the scale receipt before its new geometry preflight.
    private var deferredBigTextReply: RemoteAction?
    private var bigTextTimedOut: (request: BigTextRequest, noticeGeneration: UInt64)?
    /// Advances on every notice shown; tests use it to prove a message produced no new notice.
    private(set) var sessionNoticeGeneration: UInt64 = 0
    static let bigTextDebounce: Duration = .milliseconds(600)
    static let bigTextTimeout: TimeInterval = 8
    static let bigTextPillDuration: TimeInterval = 2
    static let bigTextStatusDisabledKey = "disableBigTextStatusReliability"

    private var bigTextStatusReliabilityEnabled: Bool {
        if let bigTextStatusSnapshot { return bigTextStatusSnapshot }
        let enabled = !bigTextMemory.defaults.bool(forKey: Self.bigTextStatusDisabledKey)
        bigTextStatusSnapshot = enabled
        return enabled
    }

    private func retireBigTextRequest() {
        bigTextSendTask?.cancel()
        bigTextSendTask = nil
        deferredSetupBigText = nil
        deferredBigTextReply = nil
        bigTextPendingRequest = nil
        bigTextTimedOut = nil
        bigText.pendingTarget = nil
        bigText.pendingSince = nil
        bigText.pendingPillExpired = false
        initialBigTextRequestID = nil
        stopFirstPictureSettling()
    }

    private func confirmDeferredBigTextReply(_ reply: RemoteAction) {
        guard bigTextStatusReliabilityEnabled || reply.scaleError == nil,
              let request = bigTextPendingRequest ?? bigTextTimedOut?.request,
              reply.scaleRequestID == request.id, let accepted = request.acceptedWidth,
              reply.displays?.first(where: { $0.id == request.display })?.scaleCurrentWidth == accepted else { return }
        if let timedOut = bigTextTimedOut {
            if sessionNoticeGeneration == timedOut.noticeGeneration {
                sessionNoticeTask?.cancel()
                sessionNotice = nil
            }
            bigTextTimedOut = nil
        }
        if request.id == initialBigTextRequestID { stopFirstPictureSettling() }
        bigTextPendingRequest = nil
        bigText.pendingTarget = nil
        bigText.pendingSince = nil
        refreshFirstPicture()
    }
    var bigTextPillTarget: Double? {
        if first60Enabled, initialBigTextRequestID != nil,
           initialBigTextRequestID == bigTextPendingRequest?.id { return nil }
        return bigTextStatusReliabilityEnabled && bigText.pendingPillExpired ? nil : bigText.pendingTarget
    }

    var bigTextSupported: Bool { sessionMode == .picture && !captureScopeViewOnly && supports(SessionFeature.displayScale) }
    var showsSharingStoppedCard: Bool { fresh && !captureHealthy && bigText.pendingTarget == nil }
    private var bigTextRoom: String? { bigTextRoomOverride ?? connection.invitation?.room }
    private var currentDescriptor: DisplayDescriptor? { displays.first { $0.id == currentDisplayID } }

    /// Saves the level for this Mac and display now; the Mac is asked after a short pause, so
    /// several quick choices cost one mode change.
    func chooseBigText(_ width: Double?) {
        guard bigTextSupported, pendingModeSwitch == nil, let id = currentDisplayID, let descriptor = currentDescriptor else { return }
        initialBigTextRequestID = nil
        initialScaleOpportunity = false
        rememberBigText(width, display: descriptor)
        bigText.savedWidth = width
        bigText.sessionOff = false
        bigText.autoApplied = true
        scheduleBigText(display: id, width: width ?? 0)
    }

    func setBigTextOffForSession(_ off: Bool) {
        guard bigTextSupported, pendingModeSwitch == nil, let id = currentDisplayID else { return }
        initialBigTextRequestID = nil
        initialScaleOpportunity = false
        bigText.sessionOff = off
        bigText.autoApplied = true
        scheduleBigText(display: id, width: off ? 0 : (bigText.savedWidth ?? 0))
    }

    func chooseBigTextNow(_ width: Double) {
        guard bigTextSupported, let id = currentDisplayID else { return }
        initialBigTextRequestID = nil
        initialScaleOpportunity = false
        bigTextSendTask?.cancel()
        bigTextSendTask = nil
        sendBigText(display: id, width: width)
    }

    func checkBigTextTimeout() {
        guard let since = bigText.pendingSince else { return }
        let elapsed = bigTextClock() - since
        if bigTextStatusReliabilityEnabled, elapsed >= Self.bigTextPillDuration, !bigText.pendingPillExpired {
            bigText.pendingPillExpired = true
        }
        guard elapsed > Self.bigTextTimeout else { return }
        let timedOut = bigTextPendingRequest
        bigTextPendingRequest = nil
        bigText.pendingTarget = nil
        bigText.pendingSince = nil
        if first60Enabled, timedOut?.id == initialBigTextRequestID, initialBigTextRequestID != nil {
            showSessionNotice("Using your Mac’s current text size.")
        } else {
            showSessionNotice(bigTextStatusReliabilityEnabled ? "Couldn't confirm text size" : "Couldn't change text size")
        }
        if let timedOut { bigTextTimedOut = (timedOut, sessionNoticeGeneration) }
        refreshFirstPicture()
    }

    static func bigTextMessage(_ error: BigTextError) -> String? {
        switch error {
        case .noAccessibility: "Big Text needs Accessibility permission on your Mac."
        case .unsupported: "This display doesn't offer larger sizes."
        case .disabled: "Big Text is turned off on this Mac."
        case .failed: "Couldn't change text size. If an app is full screen on your Mac, exit full screen and try again."
        case .busy: nil
        }
    }

    private func scheduleBigText(display: UInt32, width: Double) {
        bigTextSendTask?.cancel()
        bigTextSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.bigTextDebounce)
            guard let self, !Task.isCancelled, self.currentDisplayID == display else { return }
            self.bigTextSendTask = nil
            self.sendBigText(display: display, width: width)
        }
    }

    private func sendBigText(display: UInt32, width: Double, initialPresentation: Bool = false) {
        guard bigTextSupported, pendingModeSwitch == nil, currentDisplayID == display,
              !sessionPolishEnabled || !sceneWasBackground,
              !viewOnlyConfirmed, !pendingViewOnlyStart, !awaitingViewOnlyExit, !pipBackground else { return }
        if first60Enabled, connection.setupInProgress == true {
            deferredSetupBigText = (display, width, initialPresentation)
            return
        }
        if let timedOut = bigTextTimedOut, sessionNoticeGeneration == timedOut.noticeGeneration {
            sessionNoticeTask?.cancel()
            sessionNotice = nil
        }
        bigTextTimedOut = nil
        deferredBigTextReply = nil
        cancelInput()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let descriptor = displays.first { $0.id == display }
        let nearest = descriptor?.scaleSteps?.min { abs($0.width - width) < abs($1.width - width) }?.width
        let boundedNearest = nearest.flatMap { abs($0 - width) <= width * 0.10 ? $0 : nil }
        let noOp = descriptor?.scaleBaselineWidth.flatMap { width >= $0 ? descriptor?.scaleCurrentWidth : nil }
        let accepted = width == 0 ? descriptor?.scaleBaselineWidth : (boundedNearest ?? noOp)
        bigTextPendingRequest = BigTextRequest(id: id, display: display, acceptedWidth: accepted)
        initialBigTextRequestID = initialPresentation && first60Enabled ? id : nil
        if initialPresentation, initialScaleDeferredForSetup, firstPictureReady { startFirstPictureSettling() }
        lastBigTextRequest = (display, width, id)
        bigTextRequestsSent += 1
        // Pending even if the send failed: the 8 s timeout then tells the person, instead of silence.
        _ = transmit(RemoteAction(action: "displayScale", epoch: geometryEpoch, display: display, looksLikeWidth: width, scaleRequestID: id))
        bigText.pendingTarget = width
        bigText.pendingSince = bigTextClock()
        bigText.pendingPillExpired = false
    }

    private func updateBigText(from action: RemoteAction) {
        guard let descriptor = currentDescriptor else { return }
        if bigTextDisplayID != descriptor.id {
            // A delayed request belongs to the old display and must not block the new one.
            bigTextSendTask?.cancel()
            bigTextSendTask = nil
            // A saved level belongs to one display, so a switch gets that display's level once.
            bigTextDisplayID = descriptor.id
            bigText.autoApplied = false
        }
        bigText.steps = descriptor.scaleSteps ?? []
        bigText.baselineWidth = descriptor.scaleBaselineWidth
        bigText.currentWidth = descriptor.scaleCurrentWidth
        if let host = connection.presentationHostTrust {
            bigText.savedWidth = bigTextMemory.width(forHost: host, display: descriptor, among: displays)
        } else if let room = bigTextRoom {
            bigText.savedWidth = bigTextMemory.width(forRoom: room, display: descriptor, among: displays)
        }
        let error = action.scaleError.flatMap(BigTextError.init(rawValue:))
        if (bigTextStatusReliabilityEnabled || action.scaleError == nil), let timedOut = bigTextTimedOut,
           action.scaleRequestID == timedOut.request.id, timedOut.request.display == descriptor.id,
           let accepted = timedOut.request.acceptedWidth, descriptor.scaleCurrentWidth == accepted {
            bigTextTimedOut = nil
            if sessionNoticeGeneration == timedOut.noticeGeneration {
                sessionNoticeTask?.cancel()
                sessionNotice = nil
            }
        }
        // A display list is also sent on capture restart, display selection and other
        // requests. Only the completion of the latest scale request owns its pending UI.
        let pendingSucceeded = bigTextPendingRequest.map { pending in
            guard let accepted = pending.acceptedWidth else { return false }
            return displays.first(where: { $0.id == pending.display })?.scaleCurrentWidth == accepted
        } ?? false
        if let pending = bigTextPendingRequest, action.scaleRequestID == pending.id,
           (bigTextStatusReliabilityEnabled && pendingSucceeded) || (error != .busy && (action.scaleError != nil || pendingSucceeded)) {
            if pending.id == initialBigTextRequestID { stopFirstPictureSettling() }
            bigTextPendingRequest = nil
            bigText.pendingTarget = nil
            bigText.pendingSince = nil
            if !(bigTextStatusReliabilityEnabled && pendingSucceeded), let error, let message = Self.bigTextMessage(error) {
                showSessionNotice(first60Enabled && pending.id == initialBigTextRequestID
                    ? "Using your Mac’s current text size." : message)
            }
        }
        applySavedBigText()
        refreshFirstPicture()
    }

    private func applySavedBigText() {
        guard bigTextSupported, !bigText.autoApplied, bigText.pendingTarget == nil, bigTextSendTask == nil,
              !sessionPolishEnabled || !sceneWasBackground,
              !first60Enabled || connection.setupInProgress != true,
              captureHealthy, pendingModeSwitch == nil, pendingDisplayID == nil,
              !viewOnlyConfirmed, !pendingViewOnlyStart, !awaitingViewOnlyExit, !pipBackground,
              let baseline = bigText.baselineWidth, let current = bigText.currentWidth,
              let id = currentDisplayID, id == bigTextDisplayID else { return }
        // The healthy status can precede the first video frame/token needed to select a
        // remembered monitor. Do not resize/save a temporary initial display on that path.
        if !rememberedDisplayApplied, controlAllowed, displaySelectionSupported,
           let room = connection.invitation?.room,
           let wanted = DisplayMemory.match(displayMemory.choice(forRoom: room), in: displays), wanted.id != id { return }
        if !bigText.sessionOff, bigText.savedWidth == nil,
           !bigTextMemory.defaults.bool(forKey: BigTextAutoLevel.disabledKey),
           let descriptor = currentDescriptor, bigTextRoom != nil || connection.presentationHostTrust != nil,
           !hasSavedBigText(display: descriptor) {
            // The scene may not exist when the first host status arrives; the normal tick retries.
            guard let phonePixels = screenPixels() else { return }
            if let width = BigTextAutoLevel.choose(phonePixels: phonePixels, baselineWidth: baseline, steps: bigText.steps) {
                rememberBigText(width, display: descriptor)
                bigText.savedWidth = width
            }
        }
        let initialPresentation = initialScaleOpportunity
        initialScaleOpportunity = false
        bigText.autoApplied = true
        // A different phone may have left its level during the host's disconnect grace.
        guard !bigText.sessionOff, let saved = bigText.savedWidth else {
            if current != baseline { sendBigText(display: id, width: 0, initialPresentation: initialPresentation) }
            return
        }
        guard saved < baseline, saved != current else { return }
        sendBigText(display: id, width: saved, initialPresentation: initialPresentation)
    }

    private func rememberBigText(_ width: Double?, display: DisplayDescriptor) {
        if let host = connection.presentationHostTrust {
            bigTextMemory.remember(width, forHost: host, display: display, among: displays)
        } else if let room = bigTextRoom {
            bigTextMemory.remember(width, forRoom: room, display: display, among: displays)
        }
    }

    private func hasSavedBigText(display: DisplayDescriptor) -> Bool {
        if let host = connection.presentationHostTrust {
            return bigTextMemory.hasSavedChoice(forHost: host, display: display, among: displays)
        }
        guard let room = bigTextRoom else { return false }
        return bigTextMemory.hasSavedChoice(forRoom: room, display: display, among: displays)
    }

    func observeLinkHint(_ hint: NetworkLinkHint?) {
        linkHint = hint
        guard !dataWarningShown, dataWarningGate.shouldOffer(metered: hint?.metered == true) else { return }
        dataWarningShown = true
    }
    var dataWarning: DataWarningContent? {
        guard dataWarningShown else { return nil }
        return DataWarningContent.make(quality: streamQuality, tuning: StreamTuning.current, audio: !macAudioMuted,
                                       canLower: appliedStreamQuality != nil)
    }
    func useLessData() {
        if appliedStreamQuality != nil, let lower = streamQuality.lowerDataPreset { streamQuality = lower }
        dismissDataWarning()
    }
    func keepDataQuality() { dismissDataWarning() }
    private func dismissDataWarning() { dataWarningGate.markSeen(); dataWarningShown = false }
    func dataUseEstimate(for quality: StreamQuality) -> DataUseEstimate {
        DataUseEstimate(quality, tuning: StreamTuning.current, audio: !macAudioMuted, packetRepair: false)
    }
    private var diagnosticAuthority: Bool {
        sceneIsActive && connection.connected && !privacyShield && !contentConcealed &&
        connection.presentationDeadline() != nil && geometryEpoch > 0 && hostPresence != .locked && hostPresence != .switchedUser
    }
    func testMyMac(full: Bool) {
        let epoch = geometryEpoch, session = connection.presentationSessionID
        diagnostics.start(full: full, session: session, epoch: epoch,
            authorized: { [weak self] in self?.diagnosticAuthority == true && self?.geometryEpoch == epoch && self?.connection.presentationSessionID == session },
            send: { [weak self] probe in guard let self else { return false }; return self.connection.sendControl(self.heartbeatAction(clock: probe)) },
            facts: { [weak self] in guard let self else { return [] }; return [
                .init(.captureHealthy, self.captureHealthy ? 1 : 0), .init(.controlAvailable, self.canControl ? 1 : 0),
                .init(.geometryAvailable, self.sourceSize.width > 0 && self.sourceSize.height > 0 ? 1 : 0),
                .init(.wifiBurstPossible, self.wifiStallTip != nil ? 1 : nil, source: .inferred)] })
    }

    // MARK: Viewport capture (G4)

    /// The Mac crops its capture to the phone's viewport and reports the region it streams.
    var viewportCaptureSupported: Bool { hostFeatures.contains(SessionFeature.viewportCapture) }

    /// The active crop, for the dock caption and the statistics overlay.
    var cropSummary: CropSummary? { CropSummary(captureRegion, displaySize: sourceSize) }

    /// The session view reports every change of what it shows; `settled` when a gesture has ended.
    func viewportChanged(_ request: ViewportCaptureRequest?, settled: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        viewportReporter.update(request, at: now)
        sendViewportChange(settled: settled, at: now)
    }

    /// Everything a phone heartbeat carries. The viewport rides along only after the Mac advertised
    /// viewport capture, so an older Mac receives what it always did, plus `screenPixels`, which it ignores.
    func heartbeatAction(clock: ClockProbe? = nil,
                         at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RemoteAction {
        let constrained = lowDataState.observe(constrained: linkHints.hint?.constrained == true,
            supported: hostFeatures.contains(SessionFeature.lowDataPolicy), enabled: LowDataPolicy.isEnabled(preferences), at: now)
        connection.media?.applyLowDataPolicy(constrained == true)
        let viewport = viewportCaptureSupported ? viewportReporter.region(forDisplay: sourceSize) : nil
        let load = hostFeatures.contains(SessionFeature.ladder)
            ? phoneLoadCache.current(epoch: geometryEpoch,
                identified: hostPhoneLoadWindows && connection.phoneLoadWindowsRequested, at: now) : nil
        return RemoteAction(action: "heartbeat", macAudioRequested: phoneAudioRequestSupported ? currentMacAudioConsent() && !macAudioSuspended : nil, lowDataMode: constrained, epoch: geometryEpoch, pointerSync: pointerOverlay.advertisement(),
                            streamQuality: appliedStreamQuality == nil ? nil : streamQuality, clock: clock,
                            screenPixels: screenPixels(), viewport: viewport, phoneLoad: load)
    }

    /// Statistics run on every live media connection, including when the overlay is hidden.
    func acceptPhoneStats(_ report: StreamStatsReport, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard report.role == "phone" else { return }
        phoneLoadCache.accept(report, epoch: geometryEpoch, at: now)
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

    /// Called on the main thread for every frame the Metal view draws.
    func frameDrawn(_ envelope: VideoFrameEnvelope) {
        framePlacement(tag: envelope.videoTag, width: Int(envelope.frame.width), height: Int(envelope.frame.height))
    }

    func framePlacement(tag: VideoFrameTag?, width: Int, height: Int) {
        guard regionByFrame else { return }
        if let region = tag?.region, tag?.geometryEpoch == geometryEpoch {
            taggedRegionFrames += 1
            untaggedRun = 0
            placedOutput = PixelSize(width: region.outputWidth, height: region.outputHeight)
        } else {
            untaggedRun += 1
            // A midpoint of the same size keeps its sources' placement; another size is another stream.
            if taggedRegionFrames > 0, untaggedRun < Self.untaggedRunLimit,
               placedOutput == PixelSize(width: width, height: height) { return }
        }
        let placed = FramePlacementPolicy.region(tag: tag, geometryEpoch: geometryEpoch, frameWidth: width,
                                                 frameHeight: height, history: regionHistory, echo: captureRegion)
        if Self.regionCoverageChanged(placementRegion, placed) { placementRegion = placed }
    }

    private func observeEchoedRegion(_ region: CaptureRegion?, statusEpoch: UInt64) {
        guard let region, statusEpoch == geometryEpoch, (try? region.validate()) != nil else { return }
        if let last = regionHistory.last, !Self.regionCoverageChanged(last, region) { return }
        regionHistory.append(region)
        if regionHistory.count > Self.regionHistoryLimit { regionHistory.removeFirst(regionHistory.count - Self.regionHistoryLimit) }
    }

    private func resetRegions() {
        captureRegion = nil
        regionHistory.removeAll()
        taggedRegionFrames = 0
        untaggedRun = 0
        placedOutput = nil
        if placementRegion != nil { placementRegion = nil }
    }

    /// The region the frames cover after a `capture` status: nil, the whole display, for whole-display
    /// capture, a status about another geometry or a malformed region.
    static func croppedRegion(_ region: CaptureRegion?, statusEpoch: UInt64, geometryEpoch: UInt64) -> CaptureRegion? {
        guard let region, !region.isWholeDisplay, statusEpoch == geometryEpoch,
              (try? region.validate()) != nil else { return nil }
        return region
    }

    /// Echoes renew only the epoch, up to 10 times a second; nothing on the phone reads it, so they
    /// must not republish the region and re-render the session view.
    static func regionCoverageChanged(_ old: CaptureRegion?, _ new: CaptureRegion?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        return old.rect != new.rect || old.outputWidth != new.outputWidth || old.outputHeight != new.outputHeight
    }

    private func sendViewportChange(settled: Bool, at now: TimeInterval) {
        guard viewportCaptureSupported, connection.connected else { return }
        let coverage = captureRegion?.rect ?? ViewportTransform.wholeDisplayRect(for: sourceSize)
        switch viewportReporter.nextSend(settled: settled, coverage: coverage, at: now) {
        case .none:
            return
        case .at(let time):
            scheduleViewportChange(at: time)
        case .now:
            viewportSendTask?.cancel()
            viewportSendTask = nil
            viewportSendAt = nil
            guard viewportReporter.commit(settled: settled, coverage: coverage, forDisplay: sourceSize, at: now) else { return }
            let action = heartbeatAction(at: now)
            if action.viewport != nil { _ = connection.sendControl(action) }
        }
    }

    private func scheduleViewportChange(at time: TimeInterval) {
        if viewportSendTask != nil, let scheduled = viewportSendAt, scheduled <= time { return }
        viewportSendTask?.cancel()
        viewportSendAt = time
        let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
        viewportSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.viewportSendTask = nil
            self.viewportSendAt = nil
            self.sendViewportChange(settled: false, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    #if DEBUG
    /// Offline UI checks (`--ui-layout-check --ui-input-probe`) admit input locally and record
    /// exactly what would have been sent. Nothing leaves the phone.
    let inputProbe: InputProbe? = LaunchOptions.layoutCheck && LaunchOptions.has("--ui-input-probe") ? InputProbe() : nil
    #endif

    private lazy var displayTickInput = PhoneDisplayTickInputPump()

    #if DEBUG
    /// Keep model cancellation tests on the real transmission path with a deterministic display clock.
    func setDisplayTickInputForTesting(_ pump: PhoneDisplayTickInputPump) {
        displayTickInput.cancel()
        displayTickInput = pump
    }
    #endif

    /// Every control message leaves through here, so the offline probe sees the same actions.
    private func transmit(_ action: RemoteAction) -> Bool {
        VideoPresentationProbe.noteUserActivity()
        #if DEBUG
        if let inputProbe { return inputProbe.record(action) }
        #endif
        SmoothMotionController.noteOutgoing(action: action.action, dragging: dragging)
        displayTickInput.send = { [weak self] actions in self?.connection.sendInputMoves(actions) ?? false }
        displayTickInput.onDisplayInterval = { [weak self] milliseconds in
            self?.connection.media?.counters.phoneRenderTiming(.displayLinkInterval, milliseconds: milliseconds)
        }
        displayTickInput.onLeadingMotionLatency = { [weak self] milliseconds in
            self?.connection.media?.counters.phoneRenderTiming(.leadingMotionLatency, milliseconds: milliseconds)
        }
        displayTickInput.onFailure = { [weak self] in self?.displayTickInput.cancel() }
        if action.action == "release" { displayTickInput.cancel() }
        else if ["move", "moveTo"].contains(action.action) {
            return displayTickInput.offer(action, preferDisplayMaximum: sessionMode == .couch)
        }
        else if !displayTickInput.flush() { return false }
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
    func previewEditableFocusForTesting() {
        if LaunchOptions.has("--ui-focus-preview") {
            let geometry = FocusGeometry(displayWidth: sourceSize.width, displayHeight: sourceSize.height,
                                         x: sourceSize.width * 0.3, y: sourceSize.height * 0.84,
                                         width: sourceSize.width * 0.4, height: 40,
                                         anchorX: sourceSize.width * 0.32, anchorY: sourceSize.height * 0.84 + 20)
            focusTargetRevision &+= 1
            focusTarget = FocusTarget(geometry, sourceSize: sourceSize, epoch: geometryEpoch, refresh: false,
                                      revision: focusTargetRevision)
        }
        autoKeyboardRevision &+= 1
    }

    /// Offline screenshots of the hold states: a finger drag, or a Hold click from Controls.
    func setLowDataCapabilityForTesting(_ supported: Bool) {
        if supported { hostFeatures.insert(SessionFeature.lowDataPolicy) }
        else { hostFeatures.remove(SessionFeature.lowDataPolicy) }
    }
    func previewHoldForTesting(explicit: Bool) {
        dragging = true
        explicitHoldDeadline = explicit ? ProcessInfo.processInfo.systemUptime + Self.explicitHoldLimit : nil
    }

    /// The token stays valid so a test isolates the Mac status age.
    func ageCouchStatusForTesting(by seconds: TimeInterval) {
        lastCaptureHealth -= seconds
        tokenReceivedAt -= min(seconds, 0.5)
    }
    #endif

    var automaticClipboardSupported: Bool {
        hostFeatures.contains(SessionFeature.clipboardSync)
            && connection.requestedFeatures.contains(SessionFeature.clipboardSync)
            && !UserDefaults.standard.bool(forKey: PhoneClipboard.automaticDisabledKey)
    }

    var clipboardSupported: Bool { hostFeatures.contains(SessionFeature.clipboardText) }

    /// Clipboard transfer needs a live session with control allowed on the Mac, but not a
    /// fresh picture: it changes pasteboards, not the screen.
    var clipboardAvailable: Bool {
        sceneIsActive && (sessionMode != .couch || canControl) && !captureScopeViewOnly && !viewOnlyConfirmed && !pendingViewOnlyStart && !awaitingViewOnlyExit && !pipBackground && clipboardSupported && connection.connected && controlAllowed && !privacyShield && !contentConcealed
    }

    func pasteToMac(_ strings: [String], sourceChangeCount: Int? = nil) {
        guard clipboardAvailable else { clipboard.postUnavailable(clipboardUnavailableMessage); return }
        guard let text = strings.first(where: { !$0.isEmpty }) else {
            clipboard.postUnavailable("Your \(DeviceWord.current) clipboard has no text to send.")
            return
        }
        clipboard.send(text, pasteAfter: automaticClipboardSupported ? true : nil, sourceChangeCount: sourceChangeCount)
    }

    /// Presses ⌘C on the Mac through the admitted key path, then brings the copied text here.
    func copySelectionFromMac() {
        guard clipboardAvailable else { clipboard.postUnavailable(clipboardUnavailableMessage); return }
        guard !clipboard.isBusy else { clipboard.postUnavailable("Wait for the current clipboard transfer to finish."); return }
        guard commandShortcut("c") else {
            clipboard.postUnavailable("Copy needs control of your Mac and a fresh picture.")
            return
        }
        if !automaticClipboardSupported || lowDataState.active { clipboard.requestFromMac(afterCopy: true) }
    }

    func fetchMacClipboard() {
        guard clipboardAvailable else { clipboard.postUnavailable(clipboardUnavailableMessage); return }
        clipboard.requestFromMac()
    }

    // MARK: File transfer

    var fileTransferSupported: Bool { hostFeatures.contains(SessionFeature.fileTransfer) }

    /// Files need a live foreground session and the Mac's `file` channel. Control is not required:
    /// the Mac answers with a clear refusal when its sharing scope does not allow files.
    var fileTransferAvailable: Bool {
        !captureScopeViewOnly && !viewOnlyConfirmed && !pendingViewOnlyStart && !awaitingViewOnlyExit && !pipBackground && fileTransferSupported && connection.connected && connection.media?.fileChannelOpen == true
            && !privacyShield && !contentConcealed
    }

    var fileTransferUnavailableMessage: String {
        if !connection.connected { return "Connect to your Mac to send files." }
        if !fileTransferSupported { return "Files need the updated Farside on your Mac." }
        return "File transfer is unavailable right now."
    }

    @discardableResult
    func sendFileToMac(_ url: URL, securityScoped: Bool, release: @escaping () -> Void = {}) -> Bool {
        guard fileTransferAvailable else {
            release()
            files.postUnavailable(fileTransferUnavailableMessage)
            return false
        }
        let scoped = securityScoped && url.startAccessingSecurityScopedResource()
        return files.send(fileAt: url) {
            if scoped { url.stopAccessingSecurityScopedResource() }
            release()
        } == nil
    }

    /// A drop is an explicit send, with the same peer, scope and file-channel admission as
    /// the picker. Never retain a refused imported copy or silently send one of many items.
    func sendDroppedFiles(_ items: [PickedMediaFile], regularWidth: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        guard regularWidth, items.count == 1, sceneIsActive, fileTransferAvailable, !files.isBusy else {
            items.forEach { $0.discard() }
            files.postUnavailable(items.count > 1 ? "Send one file at a time."
                                  : files.isBusy ? "Wait for the current file transfer to finish." : fileTransferUnavailableMessage)
            return false
        }
        let picked = items[0]
        return sendFileToMac(picked.url, securityScoped: false) { picked.discard() }
    }

    func requestFileFromMac() {
        guard fileTransferAvailable else { files.postUnavailable(fileTransferUnavailableMessage); return }
        files.requestFromMac()
    }

    private func wireFileTransfer() {
        let engine = files.engine
        engine.sendControl = { [weak self] frame in
            guard let self, self.connection.connected else { return false }
            return self.connection.sendControl(RemoteAction(action: "file", epoch: self.geometryEpoch, file: frame))
        }
        engine.link = { [weak self] in self?.connection.media }
        engine.isRelayed = { [weak self] in self?.connection.media?.isRelayRoute ?? false }
        connection.fileTransfer = engine
        files.receipts = { [weak self] transfer, snapshot, finish in self?.sendToMac.transferChanged(transfer, snapshot, finish) }
        files.onLinkResult = { [weak self] status in self?.sendToMac.linkFinished(status) }
        sendToMac.canSend = { [weak self] in
            guard let self else { return false }
            return self.fileTransferAvailable && !self.files.isBusy
        }
        sendToMac.canSendText = { [weak self] in
            guard let self else { return false }
            return self.clipboardAvailable && !self.clipboard.isBusy
        }
        sendToMac.sendFile = { [weak self] url, name, release in
            guard let self else { release(); return .connectionLost }
            return self.files.send(fileAt: url, name: name, release: release)
        }
        sendToMac.sendPreparedFile = { [weak self] source, url, name, release in
            guard let self else { source.close(); release(); return .connectionLost }
            return self.files.send(prepared: source, url: url, name: name, release: release)
        }
        sendToMac.preparationFailed = { [weak self] status in
            self?.files.postUnavailable(PhoneFileTransfer.message(sending: status))
        }
        sendToMac.pendingTransfer = { [weak self] in self?.files.engine.outgoing?.transfer }
        sendToMac.sendText = { [weak self] text in
            guard let self, self.clipboardAvailable else { return false }
            self.clipboard.send(text, pasteAfter: false, usesPhonePasteboard: false)
            return true
        }
        sendToMac.sendLink = { [weak self] url in self?.files.sendLink(url) ?? false }
        sendToMac.destinationNow = { [weak self] in self?.currentShareDestination }
        sendToMac.liveSessionNow = { [weak self] in
            guard let self, self.currentShareDestination == self.shareDestination,
                  self.fileTransferAvailable || self.clipboardAvailable else { return nil }
            return self.shareLiveSessionID
        }
        sendToMac.start()
        refreshSendToMac(force: true)
    }

    /// Keeps the share extension's view of the paired Mac current (name and whether a session is live),
    /// and offers anything it staged once a session can send.
    private var currentShareDestination: SendToMacDestination? {
        guard let invitation = connection.invitation,
              let canonical = PairedMacs.id(for: invitation), canonical.hasPrefix("m_"),
              let ownerPairID = invitation.ownerPairID else { return nil }
        let value = SendToMacDestination(hostRecordID: String(canonical.dropFirst(2)), ownerPairID: ownerPairID)
        return value.isValid ? value : nil
    }

    static let localOnlyKey = "localNetworkOnly"
    func setLocalOnly(_ enabled: Bool) {
        disconnect()
        connection.setLocalOnly(enabled)
        preferences.set(enabled, forKey: Self.localOnlyKey)
        refreshSendToMac(force: true)
    }

    func refreshSendToMac(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let invitation = connection.invitation
        let destination = currentShareDestination
        let available = fileTransferAvailable || clipboardAvailable
        let changed = available != fileTransferWasAvailable || destination != shareDestination
        if !available || destination != shareDestination { shareLiveSessionID = nil }
        if available, destination != nil, shareLiveSessionID == nil { shareLiveSessionID = SendToMacOutbox.makeID() }
        shareDestination = destination
        fileTransferWasAvailable = available
        sendToMac.updateDestination(destination, name: invitation?.name, liveSessionID: shareLiveSessionID)
        guard force || changed || now - sendToMacBeaconAt >= 5 else { return }
        sendToMacBeaconAt = now
        guard let name = invitation?.name, let destination else { sendToMacBeaconIO.updateBeacon(nil); return }
        let date = Date()
        let beacon = SendToMacBeacon(macName: name, liveUntil: available ? date.addingTimeInterval(15) : nil,
                                    lastConnected: connection.connected ? date : nil,
                                    filesSupported: connection.connected && fileTransferSupported,
                                    destination: destination, liveSessionID: shareLiveSessionID)
        sendToMacBeaconIO.updateBeacon(beacon)
        if available { sendToMac.check() }
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
        sessionNoticeGeneration &+= 1
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
        guard canControl, pendingLockMac == nil else { return false }
        return sendInput("key", key: key, modifiers: ["command"])
    }

    private var localAccessApprovedPairingCode: String?

    /// Approval is scoped to this exact, still-valid QR; it is never persisted across attempts.
    func approvePairingLocalAccess(_ code: String) {
        guard let normalized = try? PairInvitation.normalizedCode(code),
              (try? PairInvitation.parse(normalized)) != nil else { return }
        localAccessApprovedPairingCode = normalized
    }

    func cancelPairingLocalAccess() { localAccessApprovedPairingCode = nil }

    /// External URLs are untrusted navigation. Show the same in-app review as a camera scan.
    func stagePairingLink(_ url: URL) {
        guard First60.isEnabled(preferences), !connection.isRunning, pairingEntry == nil,
              let normalized = try? PairInvitation.normalizedCode(url.absoluteString),
              (try? PairInvitation.parse(normalized)) != nil else { return }
        cancelPairingLocalAccess()
        pairingCode = normalized
        pairingEntry = .paste
    }

    @discardableResult
    func enroll(_ code: String) -> Bool {
        guard pendingPairReplacement == nil else { return false }
        do {
            let code = try PairInvitation.normalizedCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
            let invitation = try PairInvitation.parse(code)
            guard !First60.isEnabled(preferences) || localAccessApprovedPairingCode == code else {
                self.error = "Allow Wi-Fi access in the pairing sheet before pairing this Mac."
                return false
            }
            if let request = try PhoneTrustStore.shared.replacementRequest(for: invitation) {
                let oldName = try PhoneTrustStore.shared.snapshot().hosts
                    .first { $0.id == request.existingHostRecordID }?.invitation.name ?? "this Mac"
                pendingPairReplacement = PendingPairReplacement(code: code, oldName: oldName,
                    approval: PhoneTrustReplacementApproval(request: request, enrollment: invitation))
                error = ""
                return false
            }
            disconnect()
            try connection.enroll(code)
            cancelPairingLocalAccess()
            pairingCode = ""
            error = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func cancelPairReplacement() { pendingPairReplacement = nil; cancelPairingLocalAccess() }

    @discardableResult
    func confirmPairReplacement(_ pending: PendingPairReplacement) -> Bool {
        guard let current = pendingPairReplacement, current.code == pending.code,
              current.approval.request == pending.approval.request else { return false }
        guard !First60.isEnabled(preferences) || localAccessApprovedPairingCode == pending.code else { return false }
        pendingPairReplacement = nil
        do {
            let invitation = try PairInvitation.parse(pending.code) // rechecks QR expiry on confirmation
            guard invitation == pending.approval.enrollment,
                  try PhoneTrustStore.shared.replacementRequest(for: invitation) == pending.approval.request else {
                throw RemoteError.invalidPairing
            }
            if let host = try PhoneTrustStore.shared.snapshot().hosts.first(where: { $0.id == pending.approval.request.existingHostRecordID }) {
                bigTextMemory.migrate(host: host)
            }
            disconnect()
            try connection.enroll(pending.code, replacementApproval: pending.approval)
            cancelPairingLocalAccess()
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
        acceptResumeMeasurement(resumeTiming.frame(at: lastFrame))
        // A @Published set notifies even when unchanged, and this runs at 4 Hz while streaming.
        if !fresh { fresh = true }
        refreshFirstPicture()
        if first60Enabled, firstPictureSession, firstPictureReady, sessionMode == .picture,
           !preferences.bool(forKey: Self.firstPictureShownKey) {
            preferences.set(true, forKey: Self.firstPictureShownKey)
        }
        refreshUsefulSession(at: lastFrame)
        #if DEBUG
        PhoneE2E.active?.frameReceived()
        #endif
    }

    @discardableResult
    func action(_ name: String, x: Double = 0, y: Double = 0) -> Bool {
        sendInput(name, x: x, y: y, count: ["click", "right", "double"].contains(name) ? 1 : nil,
                  probeTextFocus: name == "double")
    }

    @discardableResult
    private func sendInput(_ name: String, x: Double = 0, y: Double = 0,
                           count: Int? = nil, hold: String? = nil,
                           phase: String? = nil, stream: String? = nil,
                           text: String = "", key: String = "", modifiers: [String] = [],
                           probeTextFocus: Bool = false, pointerSync: PointerSync? = nil, pencil: PencilFrame? = nil) -> Bool {
        textFocusProbe.invalidate()
        guard canControl, pendingLockMac == nil else { return false }
        // Moves still go while the Mac is behind, so it can catch up; presses wait.
        if sessionMode == .couch, Self.couchPressActions.contains(name),
           couchAck.stalled(at: ProcessInfo.processInfo.systemUptime) { return false }
        let clickProbe = probeTextFocus && nativeInteractionSupported && !dragging && activeHold == nil
        let refreshProbe = !clickProbe && followTyping && focusTarget != nil && focusGeometrySupported
            && nativeInteractionSupported && (name == "text" || name == "key")
        if clickProbe { focusTarget = nil }
        let focusProbe = clickProbe || refreshProbe
            ? textFocusProbe.begin(epoch: geometryEpoch, at: ProcessInfo.processInfo.systemUptime,
                                   refresh: refreshProbe) : nil
        let envelope = nativeInteractionSupported
            ? NativeInteraction(token: inputToken, hold: hold ?? activeHold,
                                clickCount: count ?? (activeHold == nil ? nil : activeHoldCount),
                                phase: phase, stream: stream) : nil
        let isClick = ["click", "right", "double", "middle"].contains(name)
        if isClick && hapticsEnabled { (name == "click" || name == "double" ? clickFeedback : secondaryClickFeedback).prepare() }
        let clickSentMs = isClick && StreamDebug.enabled ? MachClock.nowMs() : nil
        // Scroll already supports validated modifiers on legacy peers; pointer extensions retain
        // their existing capability gate. The rollback snapshot is never read from defaults here.
        let inheritsHardwareModifiers = name == "scroll" ? scrollModifiers : absolutePointerSupported
        let pointerModifiers = modifiers.isEmpty && inheritsHardwareModifiers && Self.pointerActions.contains(name)
            ? hardwareModifiers : modifiers
let now = ProcessInfo.processInfo.systemUptime
        let receiptID = hostFeatures.contains(SessionFeature.inputReceipt)
            ? usefulSessionContext.flatMap { appliedReceiptTracker.reserve(kind: name, context: $0, at: now) } : nil
        var outbound = RemoteAction(action: name, x: x, y: y,
            text: text, key: key, modifiers: pointerModifiers, epoch: geometryEpoch, interaction: envelope, pencil: pencil,
            pointerSync: pointerSync, textFocusProbe: focusProbe,
            textFocusGeometry: focusProbe != nil && focusGeometrySupported ? true : nil)
        outbound.inputRequestID = receiptID
        let accepted = transmit(outbound)
        if !accepted { appliedReceiptTracker.cancel(receiptID) }
        if !accepted { textFocusProbe.invalidate() }
        if accepted, let clickSentMs { connection.media?.counters.clickSent(atMs: clickSentMs) }
        if accepted && isClick {
            lastAcceptedClick = name == "click" && (count ?? 1) >= 2 ? "double" : name
            acceptedClicks &+= 1
            #if DEBUG
            // Offline Mac text-field fixture: produce the same focus revision after a tap.
            if inputProbe != nil, name == "click", LaunchOptions.has("--ui-manual-keyboard-check") {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self else { return }
                    self.previewEditableFocusForTesting()
                    self.inputProbe?.note("editable focus")
                }
            }
            #endif
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
                if first60HintStage == .move, first60InlineHint != nil,
                   delta.width.isFinite, delta.height.isFinite, delta != .zero {
                    advanceFirst60Hint(.click)
                }
                if sessionMode == .couch, let ordinal {
                    couchAck.sent(ordinal: ordinal, at: ProcessInfo.processInfo.systemUptime)
                }
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
        case .clipboardCopy:
            guard !UserDefaults.standard.bool(forKey: "clipboardGesturesDisabled"),
                  !dragging, activeHold == nil, clipboardAvailable else { return false }
            guard automaticClipboardSupported || !clipboard.isBusy, commandShortcut("c") else { return false }
            if !automaticClipboardSupported || lowDataState.active { clipboard.requestFromMac(afterCopy: true) }
            return true
        case .clipboardPaste:
            guard !UserDefaults.standard.bool(forKey: "clipboardGesturesDisabled"),
                  !dragging, activeHold == nil, clipboardAvailable else { return false }
            return commandShortcut("v")
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
        case .zoom, .zoomEnded, .zoomToggle, .navigate, .pan, .precision:
            return false
        }
    }

    func cancelInput() {
        textFocusProbe.invalidate()
        pointerLocator.clear()
        // Unsent motion belongs to the cancelled gesture even when no button is held.
        // Native release() only sends cleanup for a hold, so it cannot retire this queue alone.
        displayTickInput.cancel()
        release()
        inputRevision &+= 1
    }

    var shortcutChips: [ShortcutChip] {
        guard ShortcutChips.negotiated(enabled: ShortcutChips.isEnabled(preferences), peerFeatures: hostFeatures),
              !passwordFieldFocused, canControl else { return [] }
        return ShortcutCatalog.chips(for: frontmostApp?.bundleID)
    }

    @discardableResult
    func tapShortcut(_ chip: ShortcutChip) -> Bool {
        guard shortcutChips.contains(chip) else { return false }
        // A complete one-shot chord; the toolbar's latched modifiers never affect it.
        modifiers.removeAll()
        return sendInput("key", key: chip.key, modifiers: chip.modifiers)
    }

    #if DEBUG
    func previewShortcutChipsForTesting(bundleID: String) {
        hostFeatures.insert(SessionFeature.shortcutChips)
        frontmostApp = FrontmostApp(bundleID: bundleID, displayName: "Chrome")
    }
    #endif

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
            sentAt: ProcessInfo.processInfo.systemUptime, usefulContext: usefulSessionContext
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

    func disconnect() { disconnect(explicitEnd: true) }
    func disconnect(explicitEnd: Bool) {
        let preserveBackgroundIntent = !explicitEnd && sceneWasBackground && !sceneIsActive &&
            backgroundResumeHost != nil && backgroundResumeHost == connection.presentationHostTrust &&
            sessionEndReason != .user && !backgroundRecoveryBlocked
        autoPiPBackgroundGrace?.cancel(); autoPiPBackgroundGrace = nil
        PhoneIdleTimer.shared.endSession()
        cancelLockMacRequest()
        usefulSession.invalidate(explicitEnd: explicitEnd)
        pipTransitional = false; pipBackground = false
        invalidatePresentation(requestHostExit: false)
        setMacAudioMuted(true)
        finishPiPRestore(false)
        viewOnlyConfirmed = false
        awaitingViewOnlyExit = false
        viewOnlyExitDeadline = nil
        sessionEndReason = explicitEnd ? .user : (sessionEndReason ?? .error)
        resumeTiming.cancel(explicitEnd ? .userEnded : .timedOut)
        discardResume()
        clearContinuity(preservingBackgroundIntent: preserveBackgroundIntent)
        release()
        if explicitEnd { connection.stopDeliberately(epoch: geometryEpoch, hostFeatures: hostFeatures) }
        else { connection.stop() }
        end()
    }

    /// `.inactive` covers Control Center, Notification Center, call banners and the start of a
    /// screen recording: the session survives and the picture is only shielded until the scene
    /// is active again. `.background` conceals the screen, releases input and pauses video; a
    /// live session is held briefly for a quick return, then closed and resumed on return.
    func sceneChanged(_ phase: ScenePhase) {
        #if DEBUG
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Measurement only. Do not relax shielding/audio/PiP based on simulator focus.
            Logger(subsystem: "com.roshan.PocketDesk", category: "iPadFocus")
                .info("iPad scenePhase=\(String(describing: phase), privacy: .public)")
        }
        #endif
        PhoneIdleTimer.shared.setForeground(phase == .active)
        if phase == .active { files.refreshIdleTimer() }
        defer { refreshIdleTimer(at: ProcessInfo.processInfo.systemUptime) }
        switch phase {
        case .active:
            sceneIsActive = true
            hasBeenActive = true
            privacyShield = false
            acceptResumeMeasurement(resumeTiming.sceneActive(at: ProcessInfo.processInfo.systemUptime))
            sceneWasBackground = false
            autoPiPBackgroundGrace?.cancel(); autoPiPBackgroundGrace = nil; autoPiPGraceSpent = false
            returnToForeground()
            pipTransitional = false
            // An OS start during `.inactive` (app switcher) that never reached the background was not asked for.
            if autoPiPStarted && !pipBackground && pipRestoreRequest == nil { invalidatePresentation() }
            resumeMacAudioIfAllowed()
            completePiPRestoreIfCurrent()
        case .inactive:
            diagnostics.cancel()
            pipTransitional = mayKeepLivePiP || autoPiPMayStart
            if autoPiPMayStart { livePiP.prepareForLeaving() }
            suspendMacAudio()
            sceneIsActive = false
            if hasBeenActive {
                cancelInput()
                privacyShield = true
                if !sceneWasBackground, UserDefaults.standard.bool(forKey: "disableDuoInactiveContinuity"),
                          connection.connected && pendingLockMac == nil && !mayKeepLivePiP {
                    background.begin { [weak self] in self?.endBackgroundHold(immediately: true) }
                }
                // Split View focus loss and folding transitions can stay inactive indefinitely.
                // Release input and shield the snapshot, but only .background starts a hold timer.
            }
        case .background:
            sceneWasBackground = true
            sceneIsActive = false
            privacyShield = false
            if hasBeenActive { enterBackground() }
        @unknown default:
            break
        }
    }

    func enterBackground() {
        if backgroundResumeHost == nil, connection.connected, sessionEndReason != .user,
           !backgroundRecoveryBlocked,
           let host = presentationHost, host == connection.presentationHostTrust {
            backgroundResumeHost = host
        }
        if sessionPolishEnabled { retireBigTextRequest() }
        PhoneIdleTimer.shared.setForeground(false)
        if pendingLockMac != nil {
            let notice = "Lock wasn’t confirmed. Unlock or check your Mac in person."
            disconnect()
            macNotice = notice
            return
        }
        displayTickInput.cancel()
        setMacAudioMuted(true) // Background is a terminal boundary for Mac-audio consent.
        if !mayKeepLivePiP, autoPiPMayStart, !autoPiPGraceSpent, autoPiPBackgroundGrace == nil {
            LivePiPController.log.notice("pip background grace: waiting for the automatic start")
            // Background is terminal for clipboard replies and file I/O whether or not PiP then starts.
            clipboard.cancel(); clipboard.clearNotice(); files.stopForBackground()
            privacyShield = true // The app-switcher snapshot stays shielded while the prepared PiP waits.
            pipTransitional = true
            autoPiPBackgroundGrace = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.autoPiPBackgroundGraceSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.autoPiPBackgroundGrace = nil
                self.autoPiPGraceSpent = true
                LivePiPController.log.notice("pip background grace expired without an automatic start")
                if self.sceneWasBackground && !self.sceneIsActive && !self.pipBackground { self.enterBackground() }
            }
            return
        }
        autoPiPBackgroundGrace?.cancel(); autoPiPBackgroundGrace = nil
        pipTransitional = false
        if mayKeepLivePiP {
            continuity.enterLiveBackground(at: ProcessInfo.processInfo.systemUptime, sessionOpen: connection.connected)
            pipBackground = true
            if DeliberateSessionEnd.isEnabled() { bigText.autoApplied = false }
            invalidatePresentation(keepingPiP: true)
            releasePiPControl()
            contentConcealed = true
            resumeState = .backgrounded
            persistResume()
            holdTask?.cancel(); holdTask = nil
            resumeWatchdog?.cancel(); resumeWatchdog = nil
            background.end() // PiP is legitimate platform continuation; no background-task keepalive.
            return
        }
        invalidatePresentation()
        resumeTiming.cancel(.leftAgain)
        resetQuality()
        setMacAudioMuted(true)
        // A pause restores the host's scaling lease. Reapply the saved choice after fresh foreground geometry.
        if DeliberateSessionEnd.isEnabled() { bigText.autoApplied = false }
        let now = ProcessInfo.processInfo.systemUptime
        // A held connection can resume before the age limit. Require a new statistics sample
        // after pause so a pre-background report cannot become new ladder evidence.
        phoneLoadCache.invalidate()
        hostPhoneLoadWindows = false
        contentConcealed = true
        resumeState = .backgrounded
        persistResume()
        endSecureFocus()
        cancelInput()
        suspendInputReadiness()
        clipboard.cancel()
        clipboard.clearNotice()
        files.stopForBackground()
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
            connection.stopDeliberately(epoch: geometryEpoch, hostFeatures: hostFeatures)
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
            connection.stopDeliberately(epoch: geometryEpoch, hostFeatures: hostFeatures)
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
        // Background/PiP restoration retires scaling without retiring the authenticated peer.
        if DeliberateSessionEnd.isEnabled() { bigText.autoApplied = false }
        if pipBackground {
            pipBackground = false
            invalidatePresentation()
            contentConcealed = false; resumeState = .none
            suspendInputReadiness() // Fresh foreground status and token are required.
        }
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
            resetQuality()
            resumeTiming.begin(.held, at: now, sceneActive: sceneIsActive)
            resumeHeldSession(at: now)
        case .reconnect:
            if LaunchOptions.layoutCheck || backgroundResumeHost == nil || backgroundResumeHost != connection.presentationHostTrust {
                backgroundResumeHost = nil
                resumeState = .needsChoice
            } else {
                resetQuality()
                resumeTiming.begin(.reconnect, at: now, sceneActive: sceneIsActive)
                beginAutomaticReconnect()
            }
        case .offerReconnect:
            backgroundResumeHost = nil
            resumeState = .needsChoice
        }
        if resumeState != .backgrounded { backgroundResumeHost = nil }
    }

    private func resumeHeldSession(at now: TimeInterval) {
        let supported = hostFeatures.contains(SessionFeature.backgroundPause)
        guard !supported || connection.sendControl(RemoteAction(action: "resume", epoch: geometryEpoch)) else {
            resumeTiming.fellBack(at: now)
            // A failed send already started the coordinator's bounded reconnect.
            resumeState = .reconnecting
            if !connection.isRunning { restartConnection() }
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
            self.resumeTiming.fellBack(at: ProcessInfo.processInfo.systemUptime)
            self.beginAutomaticReconnect(restart: true)
        }
    }

    private func beginAutomaticReconnect(restart: Bool = false) {
        resumeState = .reconnecting
        if restart { connection.stop() }
        if !connection.isRunning { restartConnection() }
    }

    /// The model's own reconnects come back as the session was on screen; `end()` has already
    /// reset the coordinator to the picture for every other start.
    private func restartConnection() {
        connection.sessionModeRequest = attemptMode
        connection.start()
    }

    private func suspendInputReadiness() {
        fresh = false
        captureHealthy = false
        inputToken = nil
        lastFrame = 0
        lastCaptureHealth = 0
    }

    private func clearContinuity(preservingBackgroundIntent: Bool = false) {
        if preservingBackgroundIntent { continuity.endHold() }
        else { continuity.reset(); backgroundResumeHost = nil }
        holdTask?.cancel(); holdTask = nil
        resumeWatchdog?.cancel(); resumeWatchdog = nil
        backgroundEndTask?.cancel(); backgroundEndTask = nil
        background.end()
        resumeState = preservingBackgroundIntent ? .backgrounded : .none
    }

    private func sessionEnded() {
        let waitingForLock = pendingLockMac != nil
        if backgroundRecoveryBlocked { clearContinuity() }
        diagnostics.ended()
        pipTransitional = false; pipBackground = false
        invalidatePresentation(requestHostExit: false)
        finishPiPRestore(false)
        presentationHost = nil
        viewOnlyConfirmed = false
        awaitingViewOnlyExit = false
        viewOnlyExitDeadline = nil
        setMacAudioMuted(true)
        end()
        if waitingForLock {
            let notice = "The session ended before a lock status arrived. Check your Mac in person."
            lockMacStatus = notice; macNotice = notice
            Task { @MainActor [weak self] in self?.connection.stop() }
            return
        }
        if sessionEndReason != .user { persistResume() }
        guard continuity.isHolding || continuity.isViewing else { return }
        // Lost while backgrounded: stop the coordinator's retries until the app returns.
        if sessionEndReason == nil { sessionEndReason = .error }
        backgroundHoldEndsAt = nil
        continuity.endHold()
        holdTask?.cancel(); holdTask = nil
        Task { @MainActor [weak self] in
            guard let self, self.sceneWasBackground, !self.sceneIsActive else { return }
            self.connection.stop()
        }
        endBackgroundExecutionSoon()
    }

    func dismissConcealment() {
        guard !connection.connected else { return }
        resumeTiming.cancel(.userEnded)
        if resumeState == .reconnecting { connection.stop() }
        clearContinuity()
        contentConcealed = false
    }

    func reconnect() {
        guard connection.invitation != nil else { dismissConcealment(); return }
        contentConcealed = true
        resetQuality()
        resumeTiming.begin(.manual, at: ProcessInfo.processInfo.systemUptime, sceneActive: sceneIsActive)
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
        setMacAudioMuted(true)
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
        case "wakeReply": receiveWakeReply(action)
        case "viewing":
            controlAllowed = !captureScopeViewOnly && action.x == 1
            if !controlAllowed { pointerLocator.clear(); release() }
        case "heartbeat":
            if let app = action.frontmostApp, action.epoch == geometryEpoch,
               ShortcutChips.negotiated(enabled: ShortcutChips.isEnabled(preferences), peerFeatures: hostFeatures),
               connection.connected, (try? app.validate()) != nil {
                frontmostApp = app
            }
            if let clock = action.clock {
                diagnostics.receive(clock, session: connection.presentationSessionID, epoch: action.epoch,
                    authorized: diagnosticAuthority)
                receiveClockEcho(clock)
            }
            if let probe = action.textFocusProbe, probe == textFocusProbe.pending?.probe,
               action.epoch == geometryEpoch {
                receiveSecureFocus(secure: action.textFocusSecure)
            }
            let refresh = textFocusProbe.pending?.refresh == true
            if textFocusProbe.consume(probe: action.textFocusProbe, editable: action.textFocusEditable,
                                      responseEpoch: action.epoch, currentEpoch: geometryEpoch,
                                      at: ProcessInfo.processInfo.systemUptime,
                                      allowed: sceneIsActive && canControl && !dragging
                                        && (refresh ? followTyping : textEditable && !isComposingText)) {
                if !refresh { autoKeyboardRevision &+= 1 }
                focusTargetRevision &+= 1
                let target = action.textFocusRect.flatMap {
                    FocusTarget($0, sourceSize: sourceSize, epoch: action.epoch, refresh: refresh,
                                revision: focusTargetRevision)
                }
                if target != nil || !refresh { focusTarget = target }
            }
            if action.epoch == geometryEpoch, canControl, pointerLocatorSupported {
                pointerLocator.receive(action, at: ProcessInfo.processInfo.systemUptime, sourceSize: sourceSize)
            }
        case "pointer":
            if action.epoch == geometryEpoch, let sync = action.pointerSync {
                pointerOverlay.receive(sync)
                if let applied = sync.applied { couchAck.acknowledged(through: applied) }
            }
        case "capture":
            if let scope = action.captureScope {
                guard (try? scope.validate()) != nil,
                      sharedCaptureScope.map({ scope.epoch >= $0.epoch }) ?? true else { return }
                if sharedCaptureScope != scope { phoneLoadCache.invalidate() }
                sharedCaptureScope = scope
                if scope.viewOnly {
                    controlAllowed = false
                    inputToken = nil
                    pointerLocator.clear()
                    release()
                    setMacAudioMuted(true)
                }
            }
            // Only the host's reliable, current-scope applied status can confirm view-only.
            if action.epoch == geometryEpoch, action.features?.contains(SessionFeature.liveViewOnly) == true, let value = action.liveViewOnly,
               let confirmed = viewOnlyRequest.receive(value, id: action.liveViewOnlyRequestID, epoch: action.epoch, at: ProcessInfo.processInfo.systemUptime) {
                viewOnlyConfirmed = confirmed
                if !confirmed, action.liveViewOnlyRequestID != nil {
                    awaitingViewOnlyExit = false; viewOnlyExitDeadline = nil
                }
                if !confirmed && (pipState == .active || pipState == .starting || pipState == .paused) {
                    invalidatePresentation()
                }
                if pendingViewOnlyStart && autoPiPStarted {
                    pendingViewOnlyStart = false
                    viewOnlyStartDeadline = nil
                    if !confirmed || ![.starting, .active, .paused].contains(pipState) { stopPictureInPicture() }
                    else { livePiP.automaticStartConfirmed() }
                } else if pendingViewOnlyStart {
                    pendingViewOnlyStart = false
                    viewOnlyStartDeadline = nil
                    if !confirmed || !sceneIsActive || !livePiP.startFromUserAction(foreground: true) {
                        stopPictureInPicture()
                        showSessionNotice("Picture in Picture isn’t available for this stream yet.")
                    }
                }
            }
            lastHostStatusAt = ProcessInfo.processInfo.systemUptime
            hostPhoneLoadWindows = action.epoch == geometryEpoch && action.phoneLoadWindows == true
            hostFeatures = Set(SharedCaptureScopePolicy.features(action.features ?? [], kind: sharedCaptureScope?.kind ?? .display))
            if !hostFeatures.contains(SessionFeature.shortcutChips) { frontmostApp = nil }
            if action.features != nil { firstPictureCaptureObserved = true }
            if hostFeatures.contains(SessionFeature.causalInput) { connection.requestCausalInput(epoch: geometryEpoch) }
            hostPresence = action.hostState.flatMap(HostPresence.init(rawValue:))
            sessionBlocker = action.hostState.flatMap(MacShareBlocker.init(rawValue:))
            if backgroundRecoveryBlocked { clearContinuity() }
            receiveAwayStatus(action)
            if !connection.connected { return }
            let previousCurtain = curtainState
            curtainState = curtainSupported
                ? action.curtain.flatMap(PrivacyCurtainState.init(rawValue:)) ?? .off : nil
            // Every capture start's preflight status carries no features, which reads as "no
            // curtain" for a moment; the unavailable/failed explanations are still once per session.
            if let notice = PhoneSessionNotice.curtainChange(from: previousCurtain, to: curtainState),
               let state = curtainState, !curtainNoticedStates.contains(state) {
                if state == .unavailable || state == .failed { curtainNoticedStates.insert(state) }
                showSessionNotice(notice)
            }
            if action.hostEvent == HostLifecycleEvent.recovered.rawValue, !recoveryNoticeShown {
                recoveryNoticeShown = true
                showSessionNotice(PhoneSessionNotice.hostRecovered)
            }
            if let alert = action.agentAlert { AgentAlertCenter.shared.receive(fromMac: alert) }
            if let hostPresence, hostPresence != .displayAsleep { departureReason = hostPresence }
            if let hostStream = action.hostStream {
                connection.media?.acceptHostSummary(hostStream, arrivedFrames: connection.controlArrivedFrames,
                                                    arrivedAt: connection.controlArrivedAt)
            }
            appliedStreamQuality = action.streamQuality
            if action.streamQuality != nil, action.streamQuality != streamQuality, qualityRequestedAt == nil {
                qualityRequestedAt = ProcessInfo.processInfo.systemUptime
            }
            pointerLocatorSupported = !captureScopeViewOnly && action.pointerLocatorSupported == true
            pointerOverlay.hostCapability(action.pointerSync)
            if !captureScopeViewOnly, let interaction = action.interaction, interaction.version == 1 {
                nativeInteractionSupported = true
                inputToken = interaction.token
                tokenReceivedAt = ProcessInfo.processInfo.systemUptime
                if let interval = interaction.doubleClickInterval { doubleClickInterval = interval }
            }
            captureHealthy = action.x == 1
            lastCaptureHealth = captureHealthy ? ProcessInfo.processInfo.systemUptime : 0
            if !captureHealthy { pointerLocator.clear(); release() }
            // A status without a feature list (the host's capture-start preflight) says nothing about the mode.
            if action.features != nil {
                switch PhoneModeResolver.resolve(requested: requestedMode, features: hostFeatures,
                                                 statusMode: action.mode, reason: action.modeReason) {
                case .couch: setSessionMode(.couch)
                case .picture: setSessionMode(.picture)
                case .couchUnsupported:
                    if requestedMode == .couch { requestedMode = .picture; showSessionNotice(CouchCopy.updateMac) }
                    setSessionMode(.picture)
                case .refused(let reason):
                    couchRefusal = reason
                    sessionEndReason = .error
                    release()
                    connection.stop()
                    return
                }
                if let reason = action.modeReason.flatMap(SessionModeRefusal.init(rawValue:)),
                   action.mode != SessionModeStatus.refused {
                    clearPendingModeSwitch()
                    if action.modeReason != lastModeReason { showSessionNotice(CouchCopy.refusal(reason)) }
                }
                lastModeReason = action.modeReason
            }
            if let display = action.display, display != currentDisplayID { currentDisplayID = display }
            if displaySelectionSupported && !displaysRequested { requestDisplays() }
            let region = Self.croppedRegion(action.captureRegion, statusEpoch: action.epoch,
                                            geometryEpoch: geometryEpoch)
            observeEchoedRegion(action.captureRegion, statusEpoch: action.epoch)
            if Self.regionCoverageChanged(captureRegion, region) { captureRegion = region }
            if !regionByFrame, Self.regionCoverageChanged(placementRegion, region) { placementRegion = region }
            if action.busy != busy { busy = action.busy }
            let now = ProcessInfo.processInfo.systemUptime
            let vitals = hostFeatures.contains(SessionFeature.macVitals) ? action.macVitals : nil
            if vitals != macVitals { macVitals = vitals }
            if let vitals {
                macVitalsReceivedAt = now
                sessionVitals = (vitals, Date(), connection.invitation?.room)
            }
            if let notice = vitalsNotices.observe(vitals, pill: busy, now: now) { announce(notice) }
            if ladder != action.ladder { phoneLoadCache.invalidate() }
            ladder = action.ladder
            connection.media?.observeLadder(action.ladder)
            sendViewportChange(settled: false, at: ProcessInfo.processInfo.systemUptime)
            refreshFirstPicture()
        case "geometry":
            lastHostStatusAt = ProcessInfo.processInfo.systemUptime
            guard action.epoch != geometryEpoch else { return }
            cancelInput()
            inputToken = nil
            files.stopForMacChange()
            if action.x.isFinite, action.y.isFinite, action.x > 0, action.y > 0 {
                sourceSize = CGSize(width: action.x, height: action.y)
            }
            pointerOverlay.reset(sourceSize: sourceSize)
            displayTickInput.cancel()
            phoneLoadCache.invalidate()
            hostPhoneLoadWindows = false
            geometryEpoch = action.epoch
            couchAck.reset()
            couchStalled = false
            resetRegions()
            busy = nil
            ladder = nil
            connection.media?.observeLadder(nil)
            fresh = false
            captureHealthy = false
            lastFrame = 0
            lastCaptureHealth = 0
            if let reply = deferredBigTextReply {
                if reply.epoch == geometryEpoch {
                    deferredBigTextReply = nil
                    receiveDisplays(reply)
                } else if reply.epoch < geometryEpoch {
                    deferredBigTextReply = nil
                }
            }
        case "inputApplied":
            receiveAppliedInput(action)
        case "textResult":
            receiveTextResult(action)
        case "displays":
            guard action.epoch == geometryEpoch else {
                if sessionPolishEnabled, action.epoch > geometryEpoch,
                   let id = action.scaleRequestID,
                   id == bigTextPendingRequest?.id || id == bigTextTimedOut?.request.id {
                    deferredBigTextReply = action
                    suspendInputReadiness()
                    confirmDeferredBigTextReply(action)
                }
                return
            }
            receiveDisplays(action)
        case "clipboard":
            if let frame = action.clipboard {
                if frame.automatic == true {
                    guard action.epoch == geometryEpoch, clipboardAvailable, hostPresence == nil, automaticClipboardSupported, !lowDataState.active else {
                        clipboard.cancelAutomaticReceive()
                        return
                    }
                }
                clipboard.receive(frame)
            }
        case "file":
            if let frame = action.file { files.engine.receive(frame) }
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
        let now = ProcessInfo.processInfo.systemUptime
        refreshUsefulSession(at: now)
        // Older hosts have a correlated text result only. Modern hosts use the posting receipt.
        if !hostFeatures.contains(SessionFeature.inputReceipt), action.x == 1,
           let context = pending.usefulContext, context == usefulSessionContext,
           action.epoch == context.geometryEpoch, now >= pending.sentAt,
           now - pending.sentAt <= AppliedInputReceiptTracker.lifetime {
            usefulSession.applied(context: context, now: now)
        }
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
        acceptResumeMeasurement(resumeTiming.settled(at: ProcessInfo.processInfo.systemUptime))
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
        guard echo.isEcho, StreamDebug.enabled || hostFeatures.contains(SessionFeature.exactVideoTiming) else { return }
        let now = MachClock.nowMs()
        let arrived = connection.media?.controlArrivalMs ?? now
        guard clockSync.record(echo, receivedAtPhoneMs: min(now, arrived)) else { return }
        let observation = clockSync.observation(now: now)
        connection.media?.counters.clockUpdated(observation?.estimate, observedAtMs: observation?.atMs ?? now)
    }

    private func beginHeartbeat() {
        clockSync.reset()
        connection.media?.counters.clockUpdated(nil)
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

    #if DEBUG
    /// Injects the already-authorized transport boundary only; production admission remains unchanged.
    func sendAdmittedLockMacForTesting(_ request: PhoneAwayLockRequest) -> Bool {
        guard connection.sendControl(RemoteAction(action: "lockMac", epoch: request.epoch)) else { return false }
        acceptedLockMacRequest(request)
        return true
    }
    var presentationContentEpochForTesting: UInt64 { presentationContentEpoch }
    /// Inject a finite, terminal presentation lease at the downstream model boundary, not network authority.
    func admitPiPProofForTesting(validUntil: TimeInterval) -> VideoPresentationAdmission {
        let proof = VideoPresentationAdmission(identity: .init(hostRecordID: "fixture-host", ownerPairID: "fixture-owner",
            sessionID: connection.presentationSessionID, trackID: connection.presentationTrackID,
            contentEpoch: presentationContentEpoch, geometryEpoch: geometryEpoch), validUntil: validUntil)
        presentationProofForTesting = proof
        hostFeatures.insert(SessionFeature.liveViewOnly)
        refreshPresentation(at: ProcessInfo.processInfo.systemUptime)
        return proof
    }
    var pipBackgroundForTesting: Bool { pipBackground }
    var awaitingViewOnlyExitForTesting: Bool { awaitingViewOnlyExit }
    var viewOnlyConfirmedForTesting: Bool { viewOnlyConfirmed }
    var lockMacPendingForTesting: Bool { pendingLockMac != nil }
    func expireViewOnlyExitForTesting(at now: TimeInterval) { tick(at: now) }
    func sendViewOnlyEntryForTesting() { requestViewOnlyEntry() }
    var viewOnlyExitDeadlineForTesting: TimeInterval? { viewOnlyExitDeadline }
    var viewOnlyStartDeadlineForTesting: TimeInterval? { viewOnlyStartDeadline }
    #endif
    private func refreshIdleTimer(at now: TimeInterval) {
        PhoneIdleTimer.shared.updateSession(authenticated: connection.connected && connection.presentationDeadline(at: now) != nil,
            paused: pendingLockMac != nil || resumeState == .backgrounded,
            concealed: contentConcealed || privacyShield)
    }
    private func tick(at suppliedNow: TimeInterval? = nil) {
        let now = suppliedNow ?? ProcessInfo.processInfo.systemUptime
        refreshFirstPicture(at: now)
        if let request = pipRestoreRequest, now >= request.deadline {
            finishPiPRestore(false)
            if pipBackground { disconnect(explicitEnd: false); return }
        }
        if awaitingViewOnlyExit, let deadline = viewOnlyExitDeadline, now >= deadline {
            disconnect(explicitEnd: false)
            showSessionNotice("Your Mac didn’t confirm foreground control. Reconnect to continue.")
            return
        }
        if let deadline = viewOnlyStartDeadline, now >= deadline {
            stopPictureInPicture()
            showSessionNotice("Your Mac didn’t confirm live view only. Picture in Picture stopped.")
        }
        refreshPresentation(at: now)
        refreshUsefulSession(at: now)
        if connection.connected {
            heartbeatsSent &+= 1
            let probesClock = heartbeatsSent % 2 == 0 && (StreamDebug.enabled || hostFeatures.contains(SessionFeature.exactVideoTiming))
            let probe = probesClock ? registerClockProbe() : nil
            _ = connection.sendControl(heartbeatAction(clock: probe, at: now))
        }
        pointerOverlay.refresh()
        refreshSendToMac()
        if !rememberedDisplayApplied && !displays.isEmpty && canControl { applyRememberedDisplay() }
        if connection.connected && !resumeResolved { resolveResume(at: now) }
        if resumeResolved && viewportResume == nil && pendingDisplayID == nil && rememberedDisplayApplied && fresh {
            acceptResumeMeasurement(resumeTiming.settled(at: now))
        }
        _ = resumeTiming.expire(at: now)
        if !bigText.autoApplied { applySavedBigText() }
        checkBigTextTimeout()
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
        if sessionMode == .couch {
            if captureHealthy && now - lastCaptureHealth > PhoneControlGate.couchStatusLimit {
                captureHealthy = false
                pointerLocator.clear()
                release()
            }
            let stalled = couchAck.stalled(at: now)
            if stalled && !couchStalled {
                cancelInput()
                showSessionNotice(CouchCopy.notAnswering)
            }
            if couchStalled != stalled { couchStalled = stalled }
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
        firstPictureTask?.cancel(); firstPictureTask = nil
        firstPictureSettlement.cancel()
        firstPictureSession = false
        initialScaleOpportunity = false
        initialScaleDeferredForSetup = false
        stopFirstPictureSettling()
        firstPictureCaptureObserved = false
        initialBigTextRequestID = nil
        deferredSetupBigText = nil
        PhoneIdleTimer.shared.endSession()
        let awayWasOn = (presentationHost ?? connection.presentationHostTrust).map { awayMemory.wasOn(host: $0) } ?? false
        cancelLockMacRequest()
        awayState = nil
        awayStatusEpoch = nil
        pipTransitional = false; pipBackground = false
        invalidatePresentation(requestHostExit: false)
        setMacAudioMuted(true)
        finishPiPRestore(false)
        shareLiveSessionID = nil
        displayTickInput.cancel()
        // Only a session that received vitals knows the battery, so a failed reconnect or an older Mac keeps
        // what Home shows; the reading's own time stops a long background hold from renewing an old one.
        if let sessionVitals { vitalsMemory.record(sessionVitals.vitals, at: sessionVitals.receivedAt, room: sessionVitals.room) }
        sessionVitals = nil
        textFocusProbe.invalidate()
        endSecureFocus()
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLocatorSupported = false
        appliedStreamQuality = nil
        streamSummaryLines = []
        resetQuality()
        link = nil
        resetRegions()
        busy = nil
        macVitals = nil
        macVitalsReceivedAt = 0
        vitalsNotices = MacVitalsNoticePolicy()
        ladder = nil
        viewportSendTask?.cancel()
        viewportSendTask = nil
        viewportSendAt = nil
        viewportReporter.sessionEnded()
        phoneLoadCache.invalidate()
        hostPhoneLoadWindows = false
        qualityRequestedAt = nil
        pointerLocator.clear()
        pointerOverlay.reset(sourceSize: sourceSize)
        timer?.invalidate()
        timer = nil
        fresh = false
        captureHealthy = false
        sharedCaptureScope = nil
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
        bigTextSendTask?.cancel()
        bigTextSendTask = nil
        bigTextDisplayID = nil
        deferredBigTextReply = nil
        bigTextTimedOut = nil
        bigTextPendingRequest = nil
        bigText = BigTextState()
        lastBigTextRequest = nil
        bigTextRequestsSent = 0
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
        lowDataState = LowDataPolicyState()
        frontmostApp = nil
        hostPresence = nil
        sessionBlocker = nil
        curtainState = nil
        curtainNoticedStates = []
        recoveryNoticeShown = false
        reducedPictureNoticeShown = false
        clockSync.reset()
        heartbeatsSent = 0
        if let departureReason {
            macNotice = Self.notice(for: departureReason)
            if departureReason == .locked, awayWasOn { macNotice = (macNotice ?? "") + " Away mode can’t unlock it." }
            lastDeparture = departureReason
            if sessionEndReason == nil { sessionEndReason = .macStopped }
        }
        departureReason = nil
        clipboard.cancel()
        files.reset()
        refreshSendToMac(force: true)
        resumeWatchdog?.cancel(); resumeWatchdog = nil
        // couchRefusal, requestedMode and lastOnScreenMode outlive the session: Home explains and
        // retries from them. A switch still in flight (a host restart mid-switch) counts as on screen.
        if let pendingModeSwitch { lastOnScreenMode = pendingModeSwitch }
        connection.sessionModeRequest = Self.modeRequestAfterSessionEnd(coordinatorRunning: connection.isRunning,
                                                                       attemptMode: attemptMode)
        sessionMode = .picture
        clearPendingModeSwitch()
        couchStalled = false
        couchAck.reset()
        lastModeReason = nil
    }
}

/// Which region a drawn frame is placed by (see `PhoneRemoteModel.placementRegion`).
enum FramePlacementPolicy {
    static func region(tag: VideoFrameTag?, geometryEpoch: UInt64, frameWidth: Int, frameHeight: Int,
                       history: [CaptureRegion], echo: CaptureRegion?) -> CaptureRegion? {
        if let tag, let region = tag.region, tag.geometryEpoch == geometryEpoch, (try? region.validate()) != nil {
            return region.isWholeDisplay ? nil : region
        }
        if let match = history.last(where: { $0.outputWidth == frameWidth && $0.outputHeight == frameHeight }) {
            return match.isWholeDisplay ? nil : match
        }
        return echo
    }
}

/// Kill switch for placing frames by their own region (`defaults write <phone bundle id>
/// PocketDeskRegionByFrame -bool NO`, then relaunch the app). Off places the picture by the `capture`
/// status echo, as build 20261002.2 did.
enum RegionByFrameSwitch {
    static let defaultsKey = "PocketDeskRegionByFrame"
    static let isOn = ScrollFixesSwitch.isOn && (UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true)
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
    /// Nil while no fresh Mac report is at hand; the model then keeps this session's last known value.
    var frameRate: String?

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
        if (report.hostSummaryAgeMs ?? .infinity) <= 5_000, let host = report.host {
            frameRate = CaptureRatePolicy.pictureRateDescription(hostDisplayRefreshHz: host.displayRefreshHz,
                                                                 hostTargetFPS: host.targetFPS, phoneDisplayFPS: report.displayMaxFPS)
        }
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
    var statistics = false
    var sourceSize: CGSize = .zero
    var displayedPixelWidth: CGFloat = 0
    var fillsFrame = false
    var smoothMotion: SmoothMotionMode = .defaultMode
    var smoothMotionUpscale = false
    var primary = true
    /// Root supplies authenticated current host/grant/session/content/route admission. Nil displays no pixels.
    var admission: VideoPresentationAdmission?
    /// Raw decoded source callback; must be thread-safe (LivePiPController.offer is thread-safe).
    var onSourceFrame: ((VideoFrameEnvelope) -> Void)?
    var onOriginalSourcePresented: ((VideoPresentationIdentity, UUID) -> Void)?
    /// Main thread, once per drawn frame, outside the presentation fence.
    var onFrameDrawn: ((VideoFrameEnvelope) -> Void)?
    var videoFeedback: VideoFeedbackContext?
    var frameTiming: PhoneFrameTimingLog?
    var sourceCrop: CGRect?
    var glassLens = false
    let onFrame: () -> Void

    static func contentMode(fillsFrame: Bool) -> UIView.ContentMode { fillsFrame ? .scaleToFill : .scaleAspectFit }
    final class Coordinator {
        var session: VideoPresentationSession?
        func invalidate() { session?.invalidate(); session = nil }
        func ensureSession(track: RTCVideoTrack, admission: VideoPresentationAdmission, onFrame: @escaping () -> Void, primary: Bool) -> Bool {
            guard admission.permits(at: ProcessInfo.processInfo.systemUptime) else { invalidate(); return false }
            guard session?.isTerminal != false || session?.track !== track || session?.admissionIdentity != admission.identity ||
                  session?.admissionLifetime !== admission.lifetime else { return false }
            invalidate()
            session = VideoPresentationSession(track: track, admission: admission, onFrame: onFrame, primary: primary)
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let container = UIView(); container.backgroundColor = .black; container.clipsToBounds = true
        updateUIView(container, context: context); return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        guard let admission, admission.permits(at: ProcessInfo.processInfo.systemUptime) else {
            context.coordinator.invalidate(); container.subviews.forEach { $0.removeFromSuperview() }; return
        }
        if context.coordinator.ensureSession(track: track, admission: admission, onFrame: onFrame, primary: primary), let session = context.coordinator.session {
            container.subviews.forEach { $0.removeFromSuperview() }
            let view = session.view; view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: container.leadingAnchor), view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        }
        context.coordinator.session?.onOriginalSourcePresented = onOriginalSourcePresented
        context.coordinator.session?.onFrameDrawn = onFrameDrawn
        context.coordinator.session?.configure(admission: admission, counters: counters, statistics: statistics,
            sourceSize: sourceSize, displayedPixelWidth: displayedPixelWidth, fillsFrame: fillsFrame,
            mode: smoothMotion, upscale: smoothMotionUpscale, onSourceFrame: onSourceFrame, videoFeedback: videoFeedback, sourceCrop: sourceCrop, frameTiming: frameTiming, glassLens: glassLens)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.invalidate(); view.subviews.forEach { $0.removeFromSuperview() } }
}

/// Legacy stock-renderer compatibility helper retained for regression fixtures.
/// RemoteVideoSurface uses VideoPresentationSession; this helper is not owned-presentation evidence.
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

    static let formats: Set<OSType> = [kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
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
