import SwiftUI

/// Full-bleed remote desktop. The Mac picture stays crisp in its Metal renderer; the only
/// resting chrome is the dock handle. This view owns low-frequency chrome and viewport state.
struct NativeSessionView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    let offlineLayoutCheck: Bool
    let replayCoach: @MainActor () -> Void

    @State private var viewport = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                                    canvasSize: .zero, mode: ViewportPreference.stored())
    @State private var focusReturn = ViewportFocusReturn()
    @State private var smartZoomTask: Task<Void, Never>?
    @State private var smartZoomToken: UInt64?
    @State private var virtualDisplayPreviousMode: ViewportMode?
    @State private var canvasFrame: CGRect = .zero
    @State private var stackedPicture = false
    @State private var padTouched = false
    @State private var deckKeysHeight: CGFloat = 0
    @State private var dataWarningTop: CGFloat = 0
    @State private var safeFrame: CGRect = .zero
    @State private var dockFrame: CGRect = .zero
    @State private var topChromeFrame: CGRect = .zero
    @State private var workspaceDraftGeometry = IPadWorkspaceGeometry.DraftGeometry()
    @State private var geometryPending = false
    @State private var duoLayout = DuoSessionLayout()
    @State private var controlsCollapsed = true
    @State private var keyboardOpen = false
    /// Internal opt-in: Mac text focus leaves the keyboard closed unless explicitly enabled.
    @AppStorage("FarsideAutoKeyboard") private var autoKeyboardEnabled = false
    /// Accepted simplified session controls; NO restores the older arrangement for diagnosis.
    @AppStorage("FarsideBottomControls") private var bottomControls = true
    @State private var dismissedAutoKeyboardRevision: UInt64 = 0
    @State private var autoKeyboardPreviewEmitted = false
    @State private var showControls = false
    @State private var showOverlaySettings = false
    @State private var controlsPath: [ControlsPage] = []
    @State private var controlsDetent: PresentationDetent = .large
    @State private var panelFrame: CGRect = .zero
    #if DEBUG
    @State private var controlsProbeContentFrame: CGRect = .zero
    #endif
    @State private var curtainPreview = false
    @State private var showVoiceInput = false
    @State private var showClipboardRow = false
    @State private var primingMicrophone = false
    @State private var dockHintVisible = false
    @State private var sessionPillCollapsed = false
    @State private var sessionPillActivity = SessionPillActivityClock()
    /// Internal rollback only; compact windows always retain their original chrome.
    @AppStorage("ipadSessionLayoutEnabled") private var ipadSessionLayoutEnabled = true
    @State private var lockVisible = false
    /// A live session that dropped just came back: "Back" shows for a moment (D38).
    @State private var reconnectBack = false
    @StateObject private var voiceInput = VoiceInputController()
    @State private var panMode = false
    @State private var clickAcknowledged = false
    @State private var couchTouched = false
    @State private var couchClickBaseline: UInt64 = 0
    @State private var zoomBadge: String?
    @State private var zoomBadgeToken = 0
    @State private var pinchRevision: UInt64 = 0
    @State private var revision: UInt64 = 0
    @State private var keyboardBarFrame: CGRect = .zero
    @State private var manualViewportRevision: UInt64 = 0
    @StateObject private var precisionTap = PrecisionTapController()
    @AppStorage(PrecisionTapTrigger.key) private var precisionTrigger: PrecisionTapTrigger = .off
    @AppStorage("pointerSensitivity") private var sensitivity = 1.0
    @AppStorage(TouchInputMode.key) private var touchMode: TouchInputMode = .trackpad
    @AppStorage("remapReservedShortcuts") private var remapShortcuts = true
    @AppStorage("miniMap.pad") private var miniMapPad = true
    @AppStorage("miniMap.phoneLandscape") private var miniMapPhone = false
    @State private var miniMap = MiniMapVisibility()
    @State private var miniMapToken = 0
    @ObservedObject private var peripherals = HardwarePeripherals.shared
    @State private var lockedMouseRequested = false
    @State private var lockedMouseNotice = ""
    /// Internal keys, no UI: `pointerSize` (small … extraLarge) and `pointerFollow` (smooth, rigid, off).
    @AppStorage(PointerSizePreference.key) private var storedPointerSize: PointerSizePreference?
    @AppStorage(PointerFollowStyle.key) private var followStyle: PointerFollowStyle = .smooth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var accessibleCommands: Bool {
        PhoneCommandAccessibility.usesKeyList(typeSize: dynamicTypeSize, enabled: PhoneCommandAccessibility.keyListEnabled)
    }
    private var commandTypeLimit: DynamicTypeSize { accessibleCommands ? dynamicTypeSize : .xxxLarge }
    private var commandTargetHeight: CGFloat { PhoneCommandAccessibility.target(40, enabled: PhoneCommandAccessibility.targetsEnabled) }
    private var adaptiveLayout: Bool { dynamicTypeSize.isAccessibilitySize && FarsideAccessibilityLayout.enabled }
    private var pointerSize: PointerSizePreference {
        PointerSizePreference.resolved(stored: storedPointerSize, largerText: dynamicTypeSize.isAccessibilitySize)
    }
    @AppStorage(StreamDebug.defaultsKey) private var streamStatsEnabled = false
    @AppStorage(StreamDebug.markerReadingKey) private var markerReadingEnabled = true
    @AppStorage(StreamTuning.legacyDefaultsKey) private var legacyStreamTuning = false
    @AppStorage(SmoothMotionMode.key) private var smoothMotion: SmoothMotionMode = .defaultMode
    @AppStorage(PictureModePreference.legacyKey) private var legacyPictureSettings = false
    @AppStorage(SmoothMotionController.upscaleKey) private var smoothMotionUpscale = false
    @AppStorage("dockHintSessions") private var dockHintSessions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    // Keep the session's large SwiftUI type behind stable erasure boundaries. On a physical
    // iPhone the combined chrome + presentation + lifecycle modifier type exhausted the main
    // thread stack while Swift instantiated its metadata (Connect, build 20260929.6).
    // State stays on this view and modifier order is unchanged.
    private var sessionChrome: AnyView {
        AnyView(ZStack {
            stage.ignoresSafeArea()
                .overlay {
                    if FarsideBeta.isEnabled && (model.workspaceBetaRequested || model.workspaceBetaExitPending) {
                        ZStack {
                            Farside.Palette.void.ignoresSafeArea()
                            VStack(spacing: 12) {
                                if model.workspaceBetaPhase != .blocked { ProgressView().tint(Farside.Palette.bone) }
                                Text(betaWorkspaceStatus).font(.callout).multilineTextAlignment(.center)
                                Text("BETA · Workspace").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(Farside.Palette.bone).padding(24)
                        }
                        // Sharpen In is a truthful reveal of a matching fitted original picture.
                        // Pixels are never blurred/dithered, and no timer can declare readiness.
                        .opacity(model.workspaceBetaReady ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.workspaceBetaReady)
                        .allowsHitTesting(false)
                        .accessibilityHidden(model.workspaceBetaReady)
                        .accessibilityIdentifier("remote.beta.workspace.waiting")
                    }
                }
                .overlay {
                    if model.firstPictureSettling {
                        ZStack {
                            Farside.Palette.void.ignoresSafeArea()
                            ProgressView("Settling your Mac’s picture…")
                                .font(.footnote).tint(Farside.Palette.bone)
                                .foregroundStyle(Farside.Palette.bone)
                        }
                        .accessibilityIdentifier("remote.first60.settling")
                    }
                }
            LockedMousePresenter(requested: $lockedMouseRequested,
                eligible: model.canControl && scenePhase == .active && !showControls && !showVoiceInput && !keyboardOpen && !panMode,
                revision: model.inputRevision &+ revision, gain: Double(sensitivity), remapShortcuts: remapShortcuts,
                send: { command in noteSessionPillActivity(); return model.gesture(command) },
                key: { key, modifiers in noteSessionPillActivity(); return model.hardwareKey(key, modifiers: modifiers) },
                modifiers: { noteSessionPillActivity(); model.hardwareModifiers = $0 }, cleanup: { model.cancelInput() }, ended: { message in
                    lockedMouseNotice = message
                }).frame(width: 0, height: 0)

            if !couch { PrecisionLoupeOverlay(controller: precisionTap, model: model, viewport: viewport,
                                  track: connection.remoteVideo, offline: offlineLayoutCheck)
                .ignoresSafeArea() }
            ReconnectVeil(active: (!offlineLayoutCheck && !connection.connected && !lockVisible) || LaunchOptions.has("--ui-reconnecting"))
            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    safeFrame = frame
                    scheduleGeometry()
                }
            centerNotices
            if showsSessionRecoveryHint,
               let hint = model.recoveryMacNotice ?? model.sessionRecoveryHint {
                Text(hint)
                    .font(.callout).foregroundStyle(Farside.Palette.bone)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16).frame(maxWidth: 300)
                    .farsidePlate(Farside.Radius.control, fill: Farside.Palette.panel, stroke: Farside.Palette.line2)
                    .padding(20).allowsHitTesting(false)
                    .accessibilityIdentifier("remote.recoveryHint")
            }
        }
        .overlay {
            if !regularSessionLayout && !couch && !controlsCollapsed && !keyboardOpen && !showControls {
                // Light enough that the Mac stays readable while the dock is open.
                FarsideDotScreen(dotOpacity: 0.32, wash: 0.0...0.5)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                topPills
                if FarsideBeta.isEnabled { betaWorkspaceBar }
                if FarsideBeta.isEnabled && panMode && !couch { smartZoomControls }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if model.workspaceDeviceEligible {
                    topChromeFrame = frame
                    scheduleGeometry()
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if let probe = model.inputProbe {
                if LaunchOptions.has("--ui-probe-quiet") {
                    // Quiet screenshot checks still need the probe value to verify that a tap
                    // crossed transparent chrome and reached the real input surface.
                    QuietInputProbe(probe: probe)
                } else {
                    InputProbeOverlay(probe: probe).padding(.top, 60).padding(.leading, 12)
                }
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            if !regularSessionLayout && !keyboardOpen && !(showControls && controlsAsOverlay) {
                dock.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dockFrame = $0 }
                    .padding(.trailing, couchSideTiles ? Self.couchColumnWidth : 0)
                if couchSideTiles { couchTileColumn }
            }
        }
        .overlay(alignment: .bottom) {
            if !regularSessionLayout && showControls && controlsAsOverlay {
                overlayControls
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if regularSessionLayout && couchSideTiles && !keyboardOpen && !showControls { couchTileColumn }
        }
        .overlay(alignment: .trailing) {
            if !bottomControls && keyboardButtonEligible {
                keyboardButton.padding(.trailing, 8)
            }
        }
        .overlay(alignment: miniMap.shown && miniMapEligible ? .bottomLeading : .bottomTrailing) {
            // Level with the controls handle, in the thumb's corner; the open dock has its own Keyboard tile.
            if bottomControls && keyboardButtonEligible && (controlsCollapsed || regularSessionLayout) {
                keyboardButton
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if miniMap.shown && miniMapEligible {
                sessionMiniMap
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
            }
        }
        .overlay {
            if keyboardOpen {
                KeyboardLayoutDock(containerOnlySafeArea: keyboardContainerAreaProbe,
                                   onFrame: { keyboardBarFrame = $0; scheduleGeometry() }) { keyboardDockContent }
                    .onDisappear { keyboardBarFrame = .zero; scheduleGeometry() }
                    // SwiftUI must not also move the dock for the keyboard. UIKit's keyboard
                    // layout guide owns that one offset and updates it on first presentation,
                    // interactive dismissal and rotation.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .overlay {
            if model.privacyShield { privacyShield }
        }
        .overlay { DuoReservedRegionShield(layout: duoLayout).ignoresSafeArea() }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if offlineLayoutCheck {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("remote.layout.state")
                    .accessibilityLabel("Session layout state")
                    .accessibilityValue("{\"orientation\":\"\(duoLayout.orientation)\",\"ready\":\(layoutProbeReady)}")
            }
        }
        #endif
        .background(Farside.Palette.void.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .vertical))
    }

    private var sessionPresentation: AnyView {
        AnyView(sessionChrome
        .sheet(isPresented: controlsSheetPresented) { controlsSheet }
        .onChange(of: controlsAsOverlay) { _, _ in if showControls { closeControls() } }
        .onChange(of: controlsBlockInput) { _, blocked in
            // A Hold click starts in the key panel, outside NativeTrackpadSurface. Settings and
            // the expanded sheet hide Drop, so release that hold before covering the canvas.
            if blocked { cancelGesture() }
        }
        .fullScreenCover(isPresented: $primingMicrophone) {
            PermissionPrimingView(kind: .microphone) {
                primingMicrophone = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openVoiceInput() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelGesture() }
            if phase == .background { cancelVoiceInput() }
            else if phase == .inactive && voiceInput.phase != .requestingPermission {
                voiceInput.pauseForInterruption()
            }
        }
        .onChange(of: connection.connected) { _, connected in
            if !connected { cancelGesture(); cancelVoiceInput() }
            if connected { scheduleGeometry() }
            if !offlineLayoutCheck && !model.fresh { lockVisible = true }
        }
        .onChange(of: model.contentConcealed) { _, concealed in
            if concealed { cancelGesture(); cancelVoiceInput() }
        }
        .onChange(of: connection.inputRecovering) { _, recovering in
            if recovering { UIAccessibility.post(notification: .announcement, argument: "Input catching up") }
        }
        .onChange(of: model.privacyShield) { _, shielded in
            if shielded { cancelGesture() }
            if shielded && voiceInput.phase != .requestingPermission { voiceInput.pauseForInterruption() }
        }
        .onChange(of: model.canControl) { _, allowed in
            if !allowed { cancelGesture() }
            if !allowed && voiceInput.phase == .listening { voiceInput.pauseForInterruption() }
        }
        .onChange(of: model.autoKeyboardRevision) { _, value in
            guard autoKeyboardEnabled, value > dismissedAutoKeyboardRevision, !keyboardOpen, !panMode,
                  IPadWorkspaceGeometry.mayOpenAutomaticDraft(isPad: model.workspaceDeviceIsPad,
                                                             hardwareKeyboard: sessionHardwareKeyboard),
                  !showControls, !showVoiceInput, scenePhase == .active,
                  (model.canControl || autoKeyboardPreview), model.textEditable, !model.isComposingText,
                  !model.dragging, !model.privacyShield, !model.contentConcealed else { return }
            openKeyboard()
        }
        .task(id: scenePhase) {
            #if DEBUG
            guard autoKeyboardPreview, scenePhase == .active, !autoKeyboardPreviewEmitted else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, scenePhase == .active, !autoKeyboardPreviewEmitted else { return }
            autoKeyboardPreviewEmitted = true
            model.previewEditableFocusForTesting()
            #endif
        }
        .onChange(of: model.voiceDeliveryStatus) { _, status in
            if status == .accepted { showVoiceInput = false }
        }
        .onChange(of: couch, initial: true) { wasCouch, isCouch in
            scheduleGeometry()
            if isCouch {
                couchTouched = false
                couchClickBaseline = model.acceptedClicks
                setInteractionMode(false)
                controlsCollapsed = !regularSessionLayout ? false : true
            } else if wasCouch {
                collapseControls()
            }
        }
        )
    }

    private var sessionInteraction: AnyView {
        AnyView(sessionPresentation
        .sensoryFeedback(.selection, trigger: viewport.mode)
        .sensoryFeedback(.selection, trigger: touchMode)
        .sensoryFeedback(.selection, trigger: model.currentDisplayID) { old, new in old != nil && new != nil }
        .onChange(of: peripherals.keyboardConnected) { _, connected in
            if connected && model.canControl { model.announce("Keyboard connected · keys go to your Mac") }
            scheduleGeometry()
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: controlsCollapsed)
        .sensoryFeedback(trigger: model.dragging) { _, holding in
            holding ? .impact(weight: .medium) : .impact(weight: .light)
        }
        .sensoryFeedback(trigger: voiceInput.phase) { old, new in
            if new == .listening { return .start }
            return old == .listening && new != .listening ? .stop : nil
        }
        .modifier(E2EViewportReporter(report: E2EViewportReport(
            contentRect: viewport.contentRect, scale: viewport.scale, zoom: viewport.zoom,
            mode: viewport.mode.rawValue, safeRect: viewport.safeRect, canvasFrame: canvasFrame,
            dockFrame: dockFrame, keyboardOpen: keyboardOpen, panMode: panMode,
            showControls: showControls, controlsCollapsed: controlsCollapsed)))
        .onChange(of: viewport.mode) { _, mode in
            if !model.virtualDisplayActive { ViewportPreference.store(mode) }
        }
        .onChange(of: viewport.captureRequest(displayScale: displayScale), initial: true) { _, request in
            if smartZoomToken == nil { model.viewportChanged(request) }
        }
        .onChange(of: model.virtualDisplayActive, initial: true) { _, enabled in
            cancelSmartZoom(clearBookmark: true)
            if enabled {
                virtualDisplayPreviousMode = viewport.mode
                viewport.setMode(.fit)
                viewport.setZoom(1, anchoredAt: CGPoint(x: viewport.canvasSize.width / 2, y: viewport.canvasSize.height / 2))
            } else if let previous = virtualDisplayPreviousMode {
                virtualDisplayPreviousMode = nil
                viewport.setMode(previous)
            }
            scheduleGeometry()
        }
        .onChange(of: viewport.offset) { _, _ in pokeMiniMap(); VideoPresentationProbe.noteUserActivity() }
        .onChange(of: viewport.zoom) { _, _ in pokeMiniMap(); VideoPresentationProbe.noteUserActivity() }
        .onChange(of: viewport.canvasSize) { _, _ in pokeMiniMap() }
        .onChange(of: miniMapEligible) { _, eligible in
            // Closing the dock or a sheet after zooming shows where you are, briefly.
            if eligible { pokeMiniMap() } else { withAnimation(miniMapMotion) { miniMap.eligibilityChanged(false) } }
        }
        .task(id: miniMapToken) {
            guard miniMapToken > 0, !LaunchOptions.has("--ui-minimap-pinned") else { return }
            let linger = LaunchOptions.value("--ui-minimap-linger=").flatMap(Double.init) ?? MiniMapVisibility.linger
            do { try await Task.sleep(for: .seconds(linger)) } catch { return }
            withAnimation(miniMapMotion) { miniMap.lingerExpired() }
        }
        )
    }

    /// Session Resume Capsule: report what is shown, and put back the previous session's view.
    private var sessionResume: AnyView {
        AnyView(sessionInteraction
        .onChange(of: recordableViewport) { _, resume in model.recordViewport(resume) }
        .onChange(of: model.viewportResume) { _, resume in
            if let resume { applyResume(resume) }
        }
        .onChange(of: viewport.visibleSourceRect) { _, _ in
            // Read CURRENT framing: a delayed sample callback after completion must preserve
            // the retained endpoint, while every other camera path retires it on a real change.
            model.synchronizeSmartZoomPresentation(visible: viewport.visibleSourceRect)
        })
    }

    private var keyboardRevealViewport: Binding<ViewportTransform> {
        Binding(get: { viewport }, set: { next in
            if next.visibleSourceRect != viewport.visibleSourceRect || next.scale != viewport.scale || next.offset != viewport.offset {
                cancelSmartZoom(clearBookmark: false)
            }
            viewport = next
        })
    }

    private var sessionGeometryObservation: AnyView {
        AnyView(sessionResume
        .modifier(KeyboardFocusRevealModifier(model: model, viewport: keyboardRevealViewport, keyboardOpen: keyboardOpen,
                                              barFrame: keyboardBarFrame, canvasFrame: canvasFrame,
                                              manualViewportRevision: manualViewportRevision,
                                              preview: offlineLayoutCheck))
        .onChange(of: model.sourceSize) { _, _ in cancelSmartZoom(clearBookmark: true); scheduleGeometry() }
        .onChange(of: model.geometryEpoch) { _, _ in cancelSmartZoom(clearBookmark: true) }
        .onChange(of: model.inlinePresentationAdmission?.identity) { _, _ in cancelSmartZoom(clearBookmark: true) }
        .onChange(of: model.currentDisplayID) { _, _ in cancelSmartZoom(clearBookmark: true) }
        .onChange(of: model.sharedCaptureScope?.epoch) { _, _ in
            cancelSmartZoom(clearBookmark: true)
            model.clearSmartZoomPresentationConstraint()
        }
        .onChange(of: model.workspaceLayoutSourceSize) { _, _ in scheduleGeometry() }
        .onChange(of: model.workspaceMeasurementGeneration) { _, _ in
            cancelSmartZoom(clearBookmark: true)
            workspaceDraftGeometry = .init()
            scheduleGeometry()
        }
        .onChange(of: model.hostFeatures.contains(SessionFeature.virtualDisplay)) { _, supported in
            if supported { scheduleGeometry() }
        }
        .onChange(of: displayScale) { _, _ in scheduleGeometry() }
        )
    }

    private var sessionLayoutLifecycle: AnyView {
        AnyView(sessionGeometryObservation
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            guard sizeClass != nil else { return }
            let mode = ViewportPreference.initialize(regularWidth: regularSessionLayout)
            if !model.virtualDisplayActive, LaunchOptions.viewportOverride == nil && mode != viewport.mode { viewport.setMode(mode) }
            noteSessionPillActivity()
            scheduleGeometry()
        }
        .onChange(of: regularSessionLayout) { _, _ in noteSessionPillActivity(); scheduleGeometry() }
        .onChange(of: keyboardOpen) { _, _ in noteSessionPillActivity(); scheduleGeometry() }
        .onChange(of: controlsCollapsed) { _, _ in noteSessionPillActivity() }
        .onChange(of: showControls) { _, _ in noteSessionPillActivity() }
        .task(id: sessionPillIdleKey) {
            guard SessionChromePolicy.mayCollapse(regular: regularSessionLayout, controlsCollapsed: controlsCollapsed,
                                                 showControls: showControls, keyboardOpen: keyboardOpen, persistent: sessionPillPersistent),
                  !sessionPillCollapsed else { return }
            while !Task.isCancelled {
                let remaining = sessionPillActivity.remaining()
                if remaining <= 0 { break }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Farside.Motion.easeOut()) { sessionPillCollapsed = true }
        }
        )
    }

    private var sessionAppearanceLifecycle: AnyView {
        AnyView(sessionLayoutLifecycle
        .onAppear {
            if !offlineLayoutCheck && !model.fresh { lockVisible = true }
            #if DEBUG
            if offlineLayoutCheck && LaunchOptions.value("--ui-lock-stage=") != nil { lockVisible = true }
            if offlineLayoutCheck && LaunchOptions.has("--ui-pointer-preview") {
                model.pointerOverlay.showPreview(.init(point: CGPoint(x: model.sourceSize.width * 0.42,
                                                                      y: model.sourceSize.height * 0.38),
                                                       shape: .arrow))
            }
            if offlineLayoutCheck && LaunchOptions.has("--ui-voice-preview-check") {
                voiceInput.loadNonRecordingPreview(String(repeating: "A long spoken note stays readable while the insert action remains in reach. ", count: 12))
                controlsCollapsed = false
                showVoiceInput = true
            }
            if offlineLayoutCheck, let app = LaunchOptions.value("--ui-shortcut-app=") {
                model.previewShortcutChipsForTesting(bundleID: app)
            }
            if offlineLayoutCheck && LaunchOptions.has("--ui-keyboard-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { keyboardOpen = true }
            }
            if offlineLayoutCheck && LaunchOptions.has("--ui-curtain-preview") { curtainPreview = true }
            if offlineLayoutCheck, let name = LaunchOptions.value("--ui-vitals=") {
                model.previewVitalsForTesting(name == "old" ? nil : MacVitalsPresentation.preview(name), supported: name != "old")
            }
            if offlineLayoutCheck && LaunchOptions.has("--ui-controls-check") { openControls() }
            if offlineLayoutCheck && LaunchOptions.has("--ui-controls-settings") {
                openControls()
                let page = LaunchOptions.value("--ui-controls-page=").flatMap(ControlsPage.named)
                if controlsAsOverlay {
                    showOverlaySettings = true
                    controlsPath = page.map { [$0] } ?? []
                } else {
                    controlsPath = [.settings] + (page.map { [$0] } ?? [])
                }
            }
            if offlineLayoutCheck, let hold = LaunchOptions.value("--ui-hold-preview=") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    model.previewHoldForTesting(explicit: hold == "explicit")
                }
            }
            if offlineLayoutCheck && LaunchOptions.has("--ui-dock-open") { controlsCollapsed = false }
            if offlineLayoutCheck && LaunchOptions.has("--ui-clipboard-row") {
                controlsCollapsed = false
                showClipboardRow = true
            }
            #endif
        }
        .task(id: model.clipboardAvailable && unifiedClipboard) {
            if model.clipboardAvailable && unifiedClipboard {
                model.clipboard.startPasteboardMonitoring()
            } else {
                model.clipboard.stopPasteboardMonitoring()
            }
        }
        .onDisappear { cancelGesture(); cancelVoiceInput(); model.clipboard.stopPasteboardMonitoring() }
        .sensoryFeedback(.success, trigger: model.clipboard.automaticCopyRevision)
        )
    }

    var body: some View {
        sessionAppearanceLifecycle
        .task(id: model.acceptedClicks) {
            guard model.acceptedClicks > 0 else { return }
            clickAcknowledged = true
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            clickAcknowledged = false
        }
        .task(id: connection.connected) {
            guard connection.connected, !offlineLayoutCheck, dockHintSessions < 3 else { return }
            dockHintSessions += 1
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            withAnimation(reduceMotion ? nil : Farside.Motion.easeOut()) { dockHintVisible = true }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation(reduceMotion ? nil : Farside.Motion.easeOut()) { dockHintVisible = false }
        }
        .task(id: model.clipboard.notice?.id) {
            guard model.clipboard.notice != nil else { return }
            do { try await Task.sleep(for: .seconds(3.2)) } catch { return }
            withAnimation(.easeOut(duration: 0.25)) { model.clipboard.clearNotice() }
        }
        .onChange(of: model.clipboard.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.message).post() }
        }
        .sensoryFeedback(trigger: model.clipboard.notice?.id) { _, _ in
            guard let notice = model.clipboard.notice else { return nil }
            return notice.tone == .success ? .success : .warning
        }
        .task(id: zoomBadgeToken) {
            guard zoomBadge != nil else { return }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            withAnimation(.easeOut(duration: 0.25)) { zoomBadge = nil }
        }
    }

    // MARK: - Stage

    #if DEBUG
    private var layoutProbeReady: Bool {
        !geometryPending && canvasFrame.width > 0 && canvasFrame.height > 0 &&
        safeFrame.width > 0 && safeFrame.height > 0 &&
        duoLayout.bounds.size == canvasFrame.size && viewport.canvasSize == canvasFrame.size &&
        viewport.sourceSize == model.sourceSize
    }
    #endif

    /// Layers, bottom to top: the Mac picture, the pre-first-frame lock, then the input surface.
    /// Alternative input modes replace `inputSurface`; chrome lives in the overlays above `stage`.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            if couch {
                couchRestCard
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        videoLayer
                        if lockVisible {
                            ResolutionLockView(connected: connection.connected || offlineLayoutCheck, videoTrack: connection.remoteVideo != nil, pictureReady: model.fresh,
                                               fixedStage: LaunchOptions.value("--ui-lock-stage=").flatMap(Int.init)) {
                                lockVisible = false
                            }
                            .transition(.opacity)
                        }
                    }
                    .frame(height: stackedPicture ? pictureSize.height : nil)
                    .clipped()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Mac picture")
                    .accessibilityIdentifier("remote.picture")
                    if stackedPicture {
                        GeometryReader { pad in
                            stackedRestCard
                                .padding(.top, showsDeckKeys ? deckKeysHeight + 12 : 0)
                                .padding(.bottom, keyboardOpen && keyboardBarFrame.height > 0
                                         ? min(pad.size.height, max(0, canvasFrame.maxY - keyboardBarFrame.minY)) : 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            // One native input view survives resizing; gestures work on picture and pad.
            inputSurface
            if showsDeckKeys {
                deckKeys
                    .padding(.top, pictureSize.height + 12)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            canvasFrame = frame
            scheduleGeometry()
        }
        .background {
            DuoSessionProbe { state in
                if duoLayout.posture != state.posture || duoLayout.reservedFrames != state.reservedFrames {
                    cancelGesture()
                }
                duoLayout = state
                scheduleGeometry()
            }
        }
        .onReceive(model.pointerLocator.followUpdates, perform: follow)
        .onReceive(model.pointerOverlay.followUpdates, perform: follow)
        .task(id: model.dragging) { await runDragAutoPan() }
        .modifier(SessionFileDrop(model: model, regularWidth: regularSessionLayout))
        .privacySensitive()
    }

    private var inputSurface: some View {
            NativeTrackpadSurface(enabled: model.canControl && !panMode && !controlsBlockInput && !showVoiceInput,
                                  panMode: panMode && !couch,
                                  direct: directTouch && !couch && !regularSessionLayout,
                                  coalescedFingerMotion: couch,
                                  precision: couch || stackedPicture ? .off : precisionTrigger,
                                  revision: model.inputRevision &+ revision,
                                  sensitivity: CGFloat(couch ? sensitivity * CouchTuning.speed : sensitivity),
                                  pointerScale: couch ? 1 : viewport.scale, doubleClickInterval: model.doubleClickInterval,
                                  middleClickAvailable: model.middleButtonSupported,
                                  momentumScroll: model.momentumScrollSupported,
                                  hostMomentum: model.hostMomentumSupported,
                                  hardwareKeys: model.canControl && !showControls && !showVoiceInput && !keyboardOpen,
                                  // Couch has no picture to place an absolute pointer on: relative motion only.
                                  hardwarePointer: !couch && model.canControl && model.absolutePointerSupported
                                    && !controlsBlockInput && !showVoiceInput && !model.coordinateInputFenced,
                                  pencilEnabled: !couch && model.pencilEnabled && model.pencilSupported,
                                  onPencil: { point, frame in
                                      noteSessionPillActivity()
                                      guard let source = DirectTouchMapping.sourcePoint(for: point, in: viewport) else {
                                          guard frame.phase == .ended || frame.phase == .cancelled else { return false }
                                          // A lift outside the picture still releases its exact contact; never warp there.
                                          return model.pencil(at: .zero, frame: frame.zeroed())
                                      }
                                      return model.pencil(at: source, frame: frame)
                                  },
                                  keyboardFocus: !keyboardOpen && !showControls && !showVoiceInput
                                    && !primingMicrophone && scenePhase == .active,
                                  remapShortcuts: remapShortcuts,
                                  onCommand: handle,
                                  onPointerMotionEnded: { model.pointerLocator.stopFollowing() },
                                  onHardwareKey: { key, modifiers in noteSessionPillActivity(); return model.hardwareKey(key, modifiers: modifiers) },
                                  onHardwareModifiers: { noteSessionPillActivity(); model.hardwareModifiers = $0 },
                                  onKeyDiagnostic: keyDiagnostic)
                .accessibilityIdentifier("remote.canvas")
                .allowsHitTesting(!controlsBlockInput && !showVoiceInput && !model.privacyShield && !model.contentConcealed)
    }

    private var keyDiagnostic: ((String) -> Void)? {
        #if DEBUG
        if let probe = model.inputProbe { return { probe.note($0) } }
        #endif
        return nil
    }

    /// Direct touch needs a Mac that places the pointer absolutely; otherwise touches stay a trackpad.
    private var directTouch: Bool { touchMode == .direct && model.absolutePointerSupported }

    private var pictureSize: CGSize {
        SessionWindowLayout.pictureSize(window: canvasFrame.size, source: workspaceLayoutSource, stacked: stackedPicture)
    }

    private var workspaceLayoutSource: CGSize {
        IPadWorkspaceGeometry.layoutSource(current: model.sourceSize, reference: model.workspaceLayoutSourceSize,
                                           active: model.workspaceLayoutSourceSize != nil)
    }

    /// Stacked iPad (and the Duo laptop pose): a row of keys above the trackpad, like a laptop deck.
    private var showsDeckKeys: Bool {
        stackedPicture && !keyboardOpen && controlsCollapsed && !showControls
            && UserDefaults.standard.object(forKey: "ipad.deckKeys") as? Bool ?? true
    }

    private var deckKeys: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { openKeyboard() } label: { Label("Keyboard", systemImage: "keyboard") }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Keyboard")
            if showsMicOrReleaseTile { micOrReleaseTile.frame(maxWidth: .infinity) }
            Button {
                revealControls()
                if !showClipboardRow { toggleClipboardRow() }
            } label: {
                Label(unifiedClipboard ? "Files" : "Clipboard", systemImage: unifiedClipboard ? "folder" : "list.clipboard")
            }
            .frame(maxWidth: .infinity)
            .disabled(!(unifiedClipboard ? model.fileTransferSupported : showsClipboard))
            .accessibilityLabel(unifiedClipboard ? "Files" : "Clipboard")
            Button { openControls() } label: { Label(moreTileTitle, systemImage: moreTileSymbol) }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(moreTileTitle)
        }
        .buttonStyle(FarsideTileButtonStyle())
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: 520)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { deckKeysHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.stacked.keys")
    }

    private var stackedRestCard: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Farside.Palette.void2)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Farside.Palette.line2, lineWidth: 1))
            .overlay {
                VStack(spacing: 8) {
                    Text("Look up. This is your Mac’s trackpad.")
                        .font(.title3.weight(.semibold)).foregroundStyle(Farside.Palette.bone)
                    Text(CouchCopy.restDeadpan)
                        .font(.footnote).foregroundStyle(Farside.Palette.ash)
                }
                .multilineTextAlignment(.center).padding(.horizontal, 24)
                .opacity(padTouched ? 0 : 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.stacked.pad")
    }

    // MARK: - Couch

    private var couch: Bool {
        model.sessionMode == .couch || (offlineLayoutCheck && LaunchOptions.has("--ui-couch"))
    }

    /// Landscape and iPad: the Couch keys stand on the trailing edge, beside the trackpad.
    private var couchSideTiles: Bool { couch && controlsAsOverlay }

    private static let couchColumnWidth: CGFloat = 96

    /// The whole stage is the trackpad; the card only says so. Insets keep it clear of the top line and the dock.
    private var couchRestCard: some View {
        let insets = viewport.safeInsets
        let dockCover = !regularSessionLayout && dockFrame.height > 0 && !keyboardOpen ? max(0, canvasFrame.maxY - dockFrame.minY) : 0
        return RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Farside.Palette.line, lineWidth: 1)
            .overlay {
                VStack(spacing: 8) {
                    Text(CouchCopy.restHeadline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Farside.Palette.bone)
                    Text(CouchCopy.restDeadpan)
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.ash)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .opacity(couchTouched ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: couchTouched)
            }
            .overlay {
                // The click count lives as long as the app, so only clicks since Couch began ripple here.
                if couchTouched && model.acceptedClicks > couchClickBaseline {
                    ContactRipple(serial: Int(truncatingIfNeeded: model.acceptedClicks),
                                  kind: ContactRipple.Kind(action: model.lastAcceptedClick))
                }
            }
            .padding(EdgeInsets(top: insets.top + (regularSessionLayout ? 48 : 40), leading: insets.left + 12,
                                bottom: max(insets.bottom, dockCover) + 12,
                                trailing: insets.right + 12 + (couchSideTiles ? Self.couchColumnWidth : 0)))
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.couch.rest")
    }

    private var couchCaption: String {
        var parts = [macName, "Couch"]
        if !offlineLayoutCheck, let rtt = model.link?.roundTripMs { parts.append("\(rtt) ms") }
        return parts.joined(separator: " · ")
    }

    private var couchTopLine: some View {
        HStack(spacing: 7) {
            LiveDot(state: liveState, size: 7)
            Text(couchCaption)
                .farsideCaption(Farside.Palette.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(linkAccessibility)
    }

    /// Keyboard · Files · Picture · More, plus held Drop or active voice cancellation when needed.
    @ViewBuilder private func couchTiles(wide: Bool) -> some View {
        Button { openKeyboard() } label: { Label("Keyboard", systemImage: "keyboard") }
            .buttonStyle(FarsideTileButtonStyle())
            .frame(maxWidth: wide ? CGFloat.infinity : nil)
            .accessibilityLabel("Keyboard")
            .accessibilityIdentifier("remote.couch.keys")
        if showsMicOrReleaseTile {
            micOrReleaseTile
                .frame(maxWidth: wide ? CGFloat.infinity : nil)
                .accessibilityIdentifier("remote.couch.mic")
        }
        Button(action: toggleClipboardRow) { Label(unifiedClipboard ? "Files" : "Clipboard", systemImage: unifiedClipboard ? "folder" : "list.clipboard") }
            .buttonStyle(FarsideTileButtonStyle(selected: showClipboardRow))
            .frame(maxWidth: wide ? CGFloat.infinity : nil)
            .disabled(!(unifiedClipboard ? model.fileTransferSupported : showsClipboard) || showVoiceInput)
            .accessibilityLabel(unifiedClipboard ? "Files" : "Clipboard")
            .accessibilityHint(unifiedClipboard ? "Send a file or photo, or get a file from your Mac" : "Paste to or copy from your Mac")
            .accessibilityIdentifier("remote.couch.clip")
        Button { _ = model.requestMode(.picture) } label: { Label("Picture", systemImage: "photo") }
            .buttonStyle(FarsideTileButtonStyle())
            .frame(maxWidth: wide ? CGFloat.infinity : nil)
            .disabled(model.pendingModeSwitch != nil)
            .accessibilityHint(DeviceWord.copy("Shows your Mac’s screen on this device"))
            .accessibilityIdentifier("remote.couch.picture")
        Button { openControls() } label: { Label(moreTileTitle, systemImage: moreTileSymbol) }
            .buttonStyle(FarsideTileButtonStyle())
            .frame(maxWidth: wide ? CGFloat.infinity : nil)
            .accessibilityHint(bottomControls ? "Right-click, Mission Control, Spaces and more" : "")
            .accessibilityIdentifier("remote.couch.controls")
    }

    private var couchTileColumn: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 10) { couchTiles(wide: false) }
                .padding(.vertical, 12)
            ScrollView {
                VStack(spacing: 10) { couchTiles(wide: false) }
                    .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: Self.couchColumnWidth - 12)
        .farsidePlate(30, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    private var videoLayer: some View {
        ZStack(alignment: .topLeading) {
            Farside.Palette.void
            let rect = viewport.contentRect
            // The picture and the pointer share one placement, so an eased camera pan can never
            // separate them: the pointer is positioned in picture points inside this container.
            ZStack(alignment: .topLeading) {
                if model.showsInlinePiPSource {
                    // Auto-start PiP needs its source inline: the same live picture, behind the visible one.
                    // Kept while concealed so a started PiP keeps its layer; the shield and concealment overlays cover it.
                    let picture = viewport.picturePlacement(for: model.picturePlacementRegion)
                    LivePiPPreview(layer: model.livePiP.displayLayer, inline: true)
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                        .accessibilityHidden(true)
                }
                if let track = connection.remoteVideo, !model.contentConcealed {
                    let picture = viewport.picturePlacement(for: model.picturePlacementRegion)
                    RemoteVideoSurface(track: track, counters: connection.media?.counters,
                                       statistics: streamStatsEnabled && markerReadingEnabled,
                                       sourceSize: streamStatsEnabled && model.picturePlacementRegion == nil
                                        ? model.sourceSize : .zero,
                                       displayedPixelWidth: streamStatsEnabled ? rect.width * displayScale : 0,
                                       fillsFrame: model.picturePlacementRegion != nil,
                                       smoothMotion: legacyPictureSettings ? smoothMotion : model.pictureMode.smoothMotion,
                                       smoothMotionUpscale: smoothMotionUpscale,
                                       admission: model.inlinePresentationAdmission,
                                       onOriginalSourcePresented: { [weak model] identity, receipt in
                                           Task { @MainActor in model?.originalSourcePresented(identity, receipt: receipt) }
                                       },
                                       onSourcePresented: FarsideBeta.isEnabled || model.hostFeatures.contains(SessionFeature.virtualDisplay) && model.virtualDisplayActive ? { [weak model] source in
                                           Task { @MainActor in model?.rotationSourcePresented(source) }
                                       } : nil,
                                       onFrameDrawn: { [weak model] envelope in
                                           MainActor.assumeIsolated { model?.frameDrawn(envelope) }
                                       },
                                       videoFeedback: connection.media?.videoFeedback,
                                       frameTiming: connection.media?.frameTimingReceiver?.log,
                                       onFrame: model.frameReceived)
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                } else if offlineLayoutCheck {
                    DesktopPreview(size: model.sourceSize)
                        .scaleEffect(viewport.scale, anchor: .topLeading)
                        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                }
                if model.hostFeatures.contains(SessionFeature.virtualDisplay) {
                    VirtualDisplayRotationOverlay(owner: model.virtualDisplayRotationHold)
                        .frame(width: rect.width, height: rect.height)
                        .accessibilityHidden(true)
                }
                PointerOverlayView(model: model.pointerOverlay, viewport: viewport, size: pointerSize)
                    .opacity(model.virtualDisplayRotationHold.isHolding ? 0 : 1)
                PointerAccentView(model: model.pointerOverlay, viewport: viewport, size: pointerSize,
                                  acceptedClicks: model.acceptedClicks,
                                  clickKind: ContactRipple.Kind(action: model.lastAcceptedClick), holding: model.dragging,
                                  preview: offlineLayoutCheck && LaunchOptions.has("--ui-pointer-accent-preview"))
                    .opacity(model.virtualDisplayRotationHold.isHolding ? 0 : 1)
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .position(x: rect.midX, y: rect.midY)
            #if DEBUG
            if offlineLayoutCheck && LaunchOptions.has("--ui-pointer-gallery") {
                PointerGlyphGallery(size: pointerSize)
            }
            if model.inputProbe != nil && !LaunchOptions.has("--ui-probe-quiet") {
                InputProbeTargets(viewport: viewport)
            }
            #endif
        }
        .allowsHitTesting(false)
    }

    private enum BetaWorkspaceCaption: String, CaseIterable {
        case restorationAttention = "Restoration needs attention on Mac"
        case restoring = "Restoring normal desktop…"
        case ready = "Workspace ready"
        case blocked = "Workspace unavailable · check Mac"
        case waiting = "Waiting for fitted picture…"
        case preparing = "Preparing Workspace…"
        case offered = "Try Workspace"
        case unavailable = "Workspace unavailable on this Mac"

        var compactTitle: String {
            switch self {
            case .restorationAttention, .blocked: "Check Mac"
            case .restoring: "Restoring"
            case .ready: "Ready"
            case .waiting: "Waiting"
            case .preparing: "Preparing"
            case .offered: "Available"
            case .unavailable: "Unavailable"
            }
        }
    }

    private var betaWorkspaceStatus: String {
        if model.workspaceBetaExitPending {
            return (model.workspaceBetaPhase == .blocked ? BetaWorkspaceCaption.restorationAttention : .restoring).rawValue
        }
        if model.workspaceBetaRequested {
            if model.workspaceBetaReady { return BetaWorkspaceCaption.ready.rawValue }
            if model.workspaceBetaPhase == .blocked { return BetaWorkspaceCaption.blocked.rawValue }
            return (model.workspaceBetaPhase == .active ? BetaWorkspaceCaption.waiting : .preparing).rawValue
        }
        return (model.phoneWorkspaceOffered ? BetaWorkspaceCaption.offered : .unavailable).rawValue
    }

    private var betaWorkspaceCaption: some View {
        ZStack(alignment: .leading) {
            // Every phase reserves the same measured extent at this width/text size.
            // A Ready/Waiting label change must not change the requested Workspace raster.
            ForEach(BetaWorkspaceCaption.allCases, id: \.self) { caption in
                Text(betaWorkspaceTitle(caption)).fixedSize(horizontal: false, vertical: true)
                    .hidden().accessibilityHidden(true)
            }
            Text(betaWorkspaceTitle(BetaWorkspaceCaption(rawValue: betaWorkspaceStatus) ?? .unavailable))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(betaWorkspaceStatus)
        }
        .font(.caption2)
    }

    private func betaWorkspaceTitle(_ caption: BetaWorkspaceCaption) -> String {
        dynamicTypeSize.isAccessibilitySize ? caption.compactTitle : caption.rawValue
    }

    private var betaWorkspaceOptions: some View {
        Menu {
            Text(betaWorkspaceStatus)
            if !model.workspaceBetaRequested && !model.workspaceBetaExitPending {
                Button("Try experimental Workspace") { _ = model.enterBetaWorkspace() }
                    .disabled(!model.phoneWorkspaceOffered || couch)
            } else {
                Button("Use normal desktop") { model.exitBetaWorkspace() }
            }
            Button("End session", role: .destructive) { model.disconnect() }
            Text("Supported Mac windows move to a temporary display. Restoration can need attention on your Mac.")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Beta Workspace options")
        .accessibilityValue(betaWorkspaceStatus)
        .accessibilityHint("Workspace details, normal desktop and session options")
    }

    private var betaWorkspaceBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("BETA").font(.caption2.weight(.bold)).fixedSize()
                betaWorkspaceCaption.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 0)
                betaWorkspaceOptions
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("BETA").font(.caption2.weight(.bold))
                    Spacer(minLength: 0)
                    betaWorkspaceOptions
                }
                betaWorkspaceCaption
            }
        }
        .foregroundStyle(Farside.Palette.bone)
        .padding(.horizontal, 12)
        .farsidePlate(16, fill: Farside.Palette.panel, stroke: Farside.Palette.line2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.beta.workspace")
    }

    private var compactBetaViewChrome: Bool {
        FarsideBeta.isEnabled && bottomControls && !regularSessionLayout && !couch
    }

    private var smartZoomControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if compactBetaViewChrome { smartZoomModeControls }
                smartZoomNavigationControls
            }
            VStack(spacing: 6) {
                if compactBetaViewChrome { smartZoomModeControls }
                smartZoomNavigationControls
            }
        }
        .font(.caption2.weight(.medium)).foregroundStyle(Farside.Palette.bone)
        .buttonStyle(.plain)
        .padding(6).farsidePlate(16, fill: Farside.Palette.panel, stroke: Farside.Palette.line2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.beta.smartZoom")
    }

    private var smartZoomModeControls: some View {
        HStack(spacing: 8) {
            Text("View").fixedSize()
                .accessibilityLabel("View mode. Drag or pinch to look around.")
            Button { setInteractionMode(false) } label: {
                Text("Control").fixedSize()
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Farside.Palette.bone.opacity(0.16), in: .capsule)
                    .contentShape(.capsule)
            }
            .accessibilityLabel("Control desktop")
            .accessibilityHint("Returns to controlling your Mac")
        }
    }

    private var smartZoomNavigationControls: some View {
        HStack(spacing: 8) {
            Button {
                if focusReturn.canRestore {
                    restoreSmartZoom()
                } else {
                    _ = toggleSmartZoom(at: CGPoint(x: viewport.safeRect.midX, y: viewport.safeRect.midY))
                }
            } label: {
                // Bookmark changes must not resize the measured Workspace chrome:
                // a new safe inset would cancel focus and discard its return point.
                ZStack {
                    Text(betaZoomTitle(returning: false)).hidden().accessibilityHidden(true)
                    Text(betaZoomTitle(returning: true)).hidden().accessibilityHidden(true)
                    Text(betaZoomTitle(returning: focusReturn.canRestore))
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background(Farside.Palette.bone.opacity(0.16), in: .capsule)
                .contentShape(.capsule)
            }
            .accessibilityLabel(focusReturn.canRestore ? "Back to view" : "Zoom in")
            .accessibilityHint(focusReturn.canRestore
                ? "Returns to the framing before your focus zoom without clicking your Mac"
                : "Focuses your view without clicking your Mac")
            if !compactBetaViewChrome {
                Button { setMode(.fit) } label: {
                    Text("Fit").fixedSize().frame(minWidth: 44, minHeight: 44)
                }
            }
            Menu {
                if compactBetaViewChrome {
                    Button("Fit desktop") { setMode(.fit) }
                    Divider()
                }
                Button("Pan left") { _ = handle(.pan(CGSize(width: 80, height: 0))) }
                Button("Pan right") { _ = handle(.pan(CGSize(width: -80, height: 0))) }
                Button("Pan up") { _ = handle(.pan(CGSize(width: 0, height: 80))) }
                Button("Pan down") { _ = handle(.pan(CGSize(width: 0, height: -80))) }
            } label: {
                if compactBetaViewChrome {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                } else {
                    Text("Look around")
                        .fixedSize().frame(minWidth: 44, minHeight: 44)
                }
            }
            .accessibilityLabel(compactBetaViewChrome ? "View options" : "Look around")
            .accessibilityHint(compactBetaViewChrome ? "Fit desktop or pan your view" : "Pan your view")
        }
    }

    private func betaZoomTitle(returning: Bool) -> String {
        if compactBetaViewChrome && dynamicTypeSize.isAccessibilitySize {
            return returning ? "Back" : "Zoom"
        }
        return returning ? "Back to view" : "Zoom in"
    }

    private var showsSessionRecoveryHint: Bool {
        model.sessionPolishEnabled && ((!offlineLayoutCheck && !connection.connected) || LaunchOptions.has("--ui-reconnecting"))
    }

    @ViewBuilder private var centerNotices: some View {
        if showsSessionRecoveryHint {
            EmptyView()
        } else if !offlineLayoutCheck && model.hostPresence == .displayAsleep {
            VStack(spacing: Farside.Space.s) {
                Label("Your Mac’s display is asleep", systemImage: "moon.zzz")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                if model.canWakeDisplay {
                    Button("Wake display", action: model.wakeMacDisplay)
                        .buttonStyle(FarsidePrimaryButtonStyle(height: PhoneCommandAccessibility.target(40, enabled: PhoneCommandAccessibility.targetsEnabled)))
                        .fixedSize()
                        .accessibilityHint("Turns your Mac’s display back on")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
        } else if couch {
            EmptyView()
        } else if (!offlineLayoutCheck && model.showsSharingStoppedCard) || LaunchOptions.has("--ui-issue-sharing") {
            SessionIssueCard(error: .screenSharingOff)
                .allowsHitTesting(false)
        } else if !offlineLayoutCheck && !model.fresh && !lockVisible && model.bigText.pendingTarget == nil {
            Label("Waiting for your Mac’s screen…", systemImage: "hourglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: 420)
                .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                .padding(.horizontal, Farside.Space.m)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var topPills: some View {
        VStack(spacing: 8) {
            if connection.connected && model.awayState == .covered && !regularSessionLayout {
                Text("Mac covered · requests a lock if touched")
                    .font(.footnote).foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel, stroke: Farside.Palette.line)
                    .accessibilityIdentifier("remote.awayCovered")
            }
            if regularSessionLayout {
                regularSessionPill
                if !offlineLayoutCheck || LaunchOptions.has("--ui-arrival") {
                    SessionRouteToast(macName: macName,
                                      diagnostics: LaunchOptions.has("--ui-arrival") ? Self.previewDiagnostics : connection.diagnostics,
                                      pictureReady: model.fresh || LaunchOptions.has("--ui-arrival"), plain: bottomControls)
                }
                if !keyboardOpen {
                    if model.dragging { holdChip.transition(.opacity) }
                    if dockHintVisible && !model.dragging {
                        Text("Tap the pill for controls · double tap to type")
                            .farsideCaption(Farside.Palette.bone)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.void.opacity(0.92), stroke: Farside.Palette.line2)
                            .allowsHitTesting(false)
                    }
                    if showControls && controlsAsOverlay {
                        overlayControls
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    } else {
                        regularDock
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dockFrame = $0 }
                    }
                }
            } else {
                if couch { couchTopLine }
                if (!offlineLayoutCheck && !connection.connected) || LaunchOptions.has("--ui-reconnecting") {
                    ReconnectPill(macName: connection.invitation?.name ?? LaunchOptions.demoMacName ?? "your Mac",
                                  end: model.disconnect)
                        .transition(.opacity)
                } else if reconnectBack || LaunchOptions.has("--ui-reconnect-back") {
                    ReconnectBackPill(macName: connection.invitation?.name ?? LaunchOptions.demoMacName ?? "your Mac",
                                      diagnostics: LaunchOptions.has("--ui-reconnect-back") ? Self.previewDiagnostics : connection.diagnostics, plain: bottomControls)
                }
                if connection.connected, let busy = model.busy, busy.isVisible {
                    MacBusyPill(state: busy, device: UIDevice.current.model)
                        .transition(.opacity)
                }
            }
            if !model.privacyShield && !model.contentConcealed {
                ConnectionQualityBanner(content: QualityBannerContent.make(connected: connection.connected,
                    verdict: model.qualityVerdict, stall: model.wifiStallTip,
                    dismissed: model.dismissedQualityBanners, device: UIDevice.current.model), dismiss: model.dismissQualityBanner)
            }
            if let warning = dataWarningContent {
                DataWarningCard(content: warning, useLessData: model.useLessData, keep: model.keepDataQuality)
                    .frame(maxHeight: adaptiveLayout ? dataWarningAvailableHeight : nil, alignment: .top)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { dataWarningTop = $0 }
                    .transition(.opacity)
            }
            if streamStatsEnabled && !model.streamSummaryLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    let lines = model.streamSummaryLines + [model.cropSummary?.caption, SmoothMotionController.overlayLine].compactMap { $0 }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: 380, alignment: .leading)
                .background(.black.opacity(0.78), in: .rect(cornerRadius: 10))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if panMode && !regularSessionLayout && !compactBetaViewChrome {
                HStack(spacing: 10) {
                    Image(systemName: "hand.draw").accessibilityHidden(true)
                    Text("View · drag or pinch").font(.subheadline.weight(.medium))
                    Button("Control") { setInteractionMode(false) }
                        .buttonStyle(FarsidePrimaryButtonStyle(height: PhoneCommandAccessibility.target(34, enabled: PhoneCommandAccessibility.targetsEnabled)))
                        .fixedSize()
                        .accessibilityLabel("Control desktop")
                        .accessibilityShowsLargeContentViewer()
                }
                .foregroundStyle(Farside.Palette.bone)
                .dynamicTypeSize(...(accessibleCommands ? dynamicTypeSize : (adaptiveLayout ? DynamicTypeSize.xxxLarge : dynamicTypeSize)))
                .padding(.leading, 16).padding(.trailing, 5).padding(.vertical, 5)
                .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                .transition(.opacity)
            }
            FileTransferCapsule(files: model.files, inbox: model.sendToMac, hidesNotice: showControls)
            clipboardStatus
            if !regularSessionLayout { bigTextStatus }
            if !offlineLayoutCheck, !panMode, !keyboardOpen, !showControls,
               let hint = model.first60InlineHint {
                Text(hint)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                    .accessibilityIdentifier("remote.first60.hint")
                    .allowsHitTesting(false)
            }
            if let notice = model.sessionNotice, !regularSessionLayout {
                FarsideNotice(message: notice, tone: .info)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            // A transient badge in measured Workspace chrome would alter its safe
            // inset and clear the focus bookmark. Named zoom controls and announcements
            // already provide feedback there; ordinary desktop feedback stays visible.
            if let zoomBadge, !couch, !(FarsideBeta.isEnabled && model.virtualDisplayActive) {
                Text(zoomBadge)
                    .font(Farside.Typeface.caption(.subheadline).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) {
            if !regularSessionLayout && (!offlineLayoutCheck || LaunchOptions.has("--ui-arrival")) {
                SessionRouteToast(macName: connection.invitation?.name ?? LaunchOptions.demoMacName ?? "Your Mac",
                                  diagnostics: LaunchOptions.has("--ui-arrival") ? Self.previewDiagnostics : connection.diagnostics,
                                  pictureReady: model.fresh || LaunchOptions.has("--ui-arrival"), plain: bottomControls)
            }
        }
        .background { ReconnectWatcher(connected: connection.connected, back: $reconnectBack) }
        .animation(Farside.Motion.easeOut(), value: reconnectBack)
        .padding(.top, regularSessionLayout ? 6 : 8)
    }

    private var regularSessionLayout: Bool { horizontalSizeClass == .regular && ipadSessionLayoutEnabled }

    private var sessionPillReconnecting: Bool {
        (!offlineLayoutCheck && !connection.connected) || LaunchOptions.has("--ui-reconnecting")
    }

    private var sessionPillBusy: BusyPresentation? {
        #if DEBUG
        if offlineLayoutCheck && LaunchOptions.has("--ui-mac-busy") {
            return BusyPresentation(BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "encoding"), device: UIDevice.current.model)
        }
        #endif
        guard connection.connected, let busy = model.busy else { return nil }
        return BusyPresentation(busy, device: UIDevice.current.model)
    }

    private var sessionPillBigText: String? {
        #if DEBUG
        if offlineLayoutCheck && LaunchOptions.has("--ui-big-text-changing") { return "Making text bigger…" }
        #endif
        return model.bigTextPillTarget.map { $0 == 0 ? "Restoring text size…" : "Making text bigger…" }
    }

    private var sessionPillPersistent: Bool {
        SessionChromePolicy.persistent(reconnecting: sessionPillReconnecting,
            reconnectBack: reconnectBack || LaunchOptions.has("--ui-reconnect-back"), busy: sessionPillBusy != nil,
            bigText: sessionPillBigText != nil, notice: model.sessionNotice != nil, pan: panMode,
            viewOnly: model.captureScopeViewOnly, connected: connection.connected, covered: model.awayState == .covered)
    }

    private var sessionPillIdleKey: String {
        "\(regularSessionLayout)-\(sessionPillCollapsed)-\(sessionPillPersistent)-\(controlsCollapsed)-\(keyboardOpen)-\(showControls)"
    }

    /// One semantic anchor. State rows belong to the same plate and retain their original IDs;
    /// End and Control remain separate buttons, reachable by Full Keyboard Access and VoiceOver.
    private var regularSessionPill: some View {
        SessionPill(macName: macName, caption: couch ? couchCaption : regularPillCaption,
                    live: handleLive, liveState: liveState,
                    collapsed: sessionPillCollapsed && !sessionPillPersistent && controlsCollapsed && !showControls,
                    expandedDock: !controlsCollapsed || showControls,
                    reconnecting: sessionPillReconnecting,
                    back: reconnectBack || LaunchOptions.has("--ui-reconnect-back")
                        ? "Back · \((bottomControls ? nil : SessionRouteCaption.parse(LaunchOptions.has("--ui-reconnect-back") ? Self.previewDiagnostics : connection.diagnostics).text) ?? macName)" : nil,
                    busy: sessionPillBusy, bigText: sessionPillBigText,
                    notice: connection.connected && model.awayState == .covered
                        ? "Mac covered · requests a lock if touched" : model.sessionNotice,
                    noticeID: connection.connected && model.awayState == .covered ? "remote.awayCovered" : "remote.session.notice",
                    viewOnly: panMode || model.captureScopeViewOnly, canReturnToControl: panMode,
                    toggle: {
                        recordChromeHitProbe("pill toggle")
                        noteSessionPillActivity()
                        if showControls { closeControls() }
                        else { controlsCollapsed ? revealControls() : collapseControls() }
                    }, keyboard: openKeyboard, end: model.disconnect,
                    control: { setInteractionMode(false) })
            .frame(maxWidth: 560)
            .padding(.horizontal, 8)
    }

    private var regularPillCaption: String {
        var parts = [macName]
        if !bottomControls, let rtt = model.link?.roundTripMs { parts.append("\(rtt) ms") }
        return parts.joined(separator: " · ")
    }

    private var regularDock: some View {
        VStack(spacing: 10) {
            if unifiedClipboard && model.clipboardAvailable && model.clipboard.showsPasteChip {
                pasteToMacButton.labelStyle(.titleAndIcon).buttonBorderShape(.capsule)
            }
            if !controlsCollapsed {
                dockPanel
                    .background {
                        FarsideDotScreen()
                            .padding(.vertical, -24)
                            .allowsHitTesting(false)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 560)
    }

    private func noteSessionPillActivity() {
        guard regularSessionLayout else { return }
        sessionPillActivity.note()
        if sessionPillCollapsed { sessionPillCollapsed = false }
    }

    private var dataWarningContent: DataWarningContent? {
        #if DEBUG
        if offlineLayoutCheck && LaunchOptions.has("--ui-data-warning-lower"), model.dataWarning != nil {
            // Layout-only fixture: no negotiated preset or Mac input is fabricated.
            return DataWarningContent.make(quality: .sharp, audio: true, canLower: true)
        }
        #endif
        return model.dataWarning
    }

    /// The notice can scroll, but must leave the measured dock and its End action uncovered.
    private var dataWarningAvailableHeight: CGFloat {
        let bottom = !regularSessionLayout && dockFrame.height > 0 ? min(safeFrame.maxY, dockFrame.minY) : safeFrame.maxY
        return max(0, bottom - max(safeFrame.minY + 8, dataWarningTop) - 12)
    }

    /// A measured route for offline layout checks and screenshots.
    private static let previewDiagnostics = "Direct · video/H264 · 60 fps · 14 ms network RTT"

    @ViewBuilder private var clipboardStatus: some View {
        if model.clipboard.activity != .idle {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Farside.Palette.bone)
                Text(model.clipboard.activity == .sending ? "Sending to your Mac…" : "Copying from your Mac…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        } else if let notice = model.clipboard.notice, !showControls {
            FarsideNotice(message: notice.message, tone: notice.tone == .success ? .success : .caution)
                .frame(maxWidth: 420)
                .padding(.horizontal, 16)
                .transition(.opacity)
                .onTapGesture { model.clipboard.clearNotice() }
                .accessibilityIdentifier("remote.clipboard.notice")
        }
    }

    @ViewBuilder private var bigTextStatus: some View {
        if let target = model.bigTextPillTarget {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Farside.Palette.bone)
                Text(target == 0 ? "Restoring text size…" : "Making text bigger…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote.bigText.pill")
        }
    }

    private var privacyShield: some View {
        ZStack {
            Farside.Palette.void
            VStack(spacing: Farside.Space.m) {
                FarsideMark(height: 44)
                Text("Hidden while you look away").farsideCaption()
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remote screen hidden")
        .accessibilityIdentifier("remote.privacyShield")
    }

    private var keyboardButtonEligible: Bool {
        !keyboardOpen && !couch && !panMode && model.canControl && scenePhase == .active &&
            !showControls && !showOverlaySettings && !showVoiceInput
    }

    private var keyboardButton: some View {
        Button(action: openKeyboard) {
            Image(systemName: "keyboard")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        .accessibilityLabel("Keyboard")
        .accessibilityIdentifier("remote.keyboard.open")
    }

    // MARK: - Dock

    private var dock: some View {
        VStack(spacing: 10) {
            if unifiedClipboard && model.clipboardAvailable && model.clipboard.showsPasteChip && !keyboardOpen {
                pasteToMacButton
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
            }
            if controlsCollapsed && !couch {
                if model.dragging { holdChip.transition(.opacity) }
                if dockHintVisible && !model.dragging {
                    Text("Swipe up for controls · double tap to type")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Farside.Palette.bone)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.void.opacity(0.92), stroke: Farside.Palette.line2)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                dockHandle
            } else {
                dockPanel
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, controlsCollapsed && !couch ? 0 : 6)
        .frame(maxWidth: adaptiveLayout && compactHeight ? .infinity : (wideDock ? 760 : (compactHeight ? 620 : 560)))
    }

    private var compactHeight: Bool { verticalSizeClass == .compact }
    private var wideDock: Bool { compactHeight && (adaptiveLayout || bottomControls) }

    private var dockPanel: some View {
        Group {
            if wideDock && !couch && !showVoiceInput && !showClipboardRow {
                // Use landscape width to preserve a scrollable notice above all dock controls.
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 10) { if !regularSessionLayout { grabHandle }; tilesRow }
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 10) { segmentsRow; dockFooter }
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: compactHeight ? 10 : 14) {
                    if !couch && !regularSessionLayout { grabHandle }
                    if !couchSideTiles { tilesRow }
                    if showVoiceInput {
                        dictationRow
                    } else if showClipboardRow {
                        clipboardRow
                    }
                    if !couch && (!compactHeight || !(showVoiceInput || showClipboardRow)) {
                        segmentsRow
                    }
                    dockFooter
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, couch ? 16 : 6)
        .padding(.bottom, 16)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Farside.Palette.panel.opacity(0.97))
                .overlay(alignment: .top) {
                    DotBand()
                        .frame(height: 64)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, y: -10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.dock")
        // Compact chrome must leave a touchable desktop even with AX-XXXL text.
        .dynamicTypeSize(...(accessibleCommands ? dynamicTypeSize : (adaptiveLayout ? DynamicTypeSize.xxxLarge : dynamicTypeSize)))
    }

    private var grabHandle: some View {
        let taps = TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
        return Capsule()
            .fill(Farside.Palette.dim)
            .frame(width: 40, height: 5)
            .frame(width: 120, height: PhoneCommandAccessibility.target(26, enabled: PhoneCommandAccessibility.targetsEnabled))
            .contentShape(.rect)
            .gesture(taps.onEnded { result in
                switch result {
                case .first: openKeyboard()
                case .second: collapseControls()
                }
            })
            .highPriorityGesture(DragGesture(minimumDistance: 8).onEnded { value in
                let movement = value.translation
                guard abs(movement.height) > 12, abs(movement.height) > abs(movement.width), movement.height > 0 else { return }
                collapseControls()
            })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Hide controls")
            .accessibilityHint("Swipe down to hide the controls. Double-tap to type.")
            .accessibilityAction { collapseControls() }
            .accessibilityAction(named: Text("Show keyboard")) { openKeyboard() }
    }

    @ViewBuilder private var tilesRow: some View {
        if couch {
            HStack(alignment: .top, spacing: 0) { couchTiles(wide: true) }
        } else {
            pictureTilesRow
        }
    }

    private var showsDictateEntry: Bool {
        #if DEBUG
        if PhoneE2E.active?.voiceTranscript != nil { return true }
        #endif
        return !bottomControls && !FarsideBeta.isEnabled
    }

    private var showsMicOrReleaseTile: Bool { showsDictateEntry || model.dragging || showVoiceInput }

    private var moreTileTitle: String { bottomControls ? "More" : "Controls" }

    private var moreTileSymbol: String { bottomControls ? "ellipsis.circle" : "command" }

    private func touchModeSegments(set: @escaping (Bool) -> Void) -> some View {
        FarsideSegmented(label: "Touch mode",
                         options: [(false, "Control"), (true, "View")],
                         selection: Binding(get: { panMode }, set: set),
                         spokenTitles: [false: "Control desktop", true: "Move view"],
                         symbols: [false: "cursorarrow", true: "hand.draw"])
    }

    private var panelTouchModeSegments: some View {
        touchModeSegments { view in
            setInteractionMode(view)
            if view {
                closeControls()
                collapseControls()
            }
        }
    }

    private var showsTouchModeInPanel: Bool { bottomControls && !couch }

    private var pictureTilesRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { openKeyboard() } label: { Label("Keyboard", systemImage: "keyboard") }
                .buttonStyle(FarsideTileButtonStyle())
                .accessibilityShowsLargeContentViewer()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Keyboard")
            if showsMicOrReleaseTile { micOrReleaseTile.frame(maxWidth: .infinity) }
            Button(action: toggleClipboardRow) { Label(unifiedClipboard ? "Files" : "Clipboard", systemImage: unifiedClipboard ? "folder" : "list.clipboard") }
                .buttonStyle(FarsideTileButtonStyle(selected: showClipboardRow))
                .accessibilityShowsLargeContentViewer()
                .frame(maxWidth: .infinity)
                .disabled(!(unifiedClipboard ? model.fileTransferSupported : showsClipboard) || showVoiceInput)
                .accessibilityLabel(unifiedClipboard ? "Files" : "Clipboard")
                .accessibilityHint(unifiedClipboard ? "Send a file or photo, or get a file from your Mac" : "Paste to or copy from your Mac")
            Button { openControls() } label: { Label(moreTileTitle, systemImage: moreTileSymbol) }
                .buttonStyle(FarsideTileButtonStyle())
                .accessibilityShowsLargeContentViewer()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(moreTileTitle)
                .accessibilityHint(bottomControls ? "Right-click, Mission Control, Spaces, Control or View, and more"
                                                  : "Right-click, Mission Control, Spaces and more")
        }
    }

    @ViewBuilder private var micOrReleaseTile: some View {
        if model.dragging {
            Button { model.cancelInput() } label: { Label("Drop", systemImage: "arrow.down.to.line") }
                .buttonStyle(FarsideTileButtonStyle(emphasized: true))
                .accessibilityLabel("Drop")
                .accessibilityHint("Lets go of the mouse button on your Mac")
        } else if showVoiceInput {
            Button { cancelVoiceInput() } label: { Label("Dictate", systemImage: "waveform") }
                .buttonStyle(FarsideTileButtonStyle(on: voiceInput.phase == .listening))
                .disabled(voiceInput.phase == .finishing || model.voiceDeliveryStatus == .waiting)
                .accessibilityLabel("Cancel voice input")
        } else {
            Button(action: openVoiceInput) { Label("Dictate", systemImage: "mic.fill") }
                .buttonStyle(FarsideTileButtonStyle())
                .accessibilityShowsLargeContentViewer()
                .disabled(!voiceEntryAvailable)
                .accessibilityLabel("Voice input")
                .accessibilityHint(DeviceWord.copy("Speak on this device, then tap Insert on Mac to send the text"))
        }
    }

    private var segmentsRow: some View {
        HStack(spacing: 8) {
            if !bottomControls { touchModeSegments { setInteractionMode($0) } }
            FarsideSegmented(label: "Screen size",
                             options: [(ViewportMode.fit, "Fit"), (ViewportMode.fill, "Fill")],
                             selection: Binding(get: { viewport.mode }, set: { setMode($0) }),
                             spokenTitles: [.fit: "Fit whole display", .fill: "Fill screen"],
                             symbols: [.fit: "arrow.down.right.and.arrow.up.left", .fill: "arrow.up.left.and.arrow.down.right"])
        }
    }

    private var dockFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if !couch {
                    HStack(spacing: 7) {
                        LiveDot(state: liveState, size: 7)
                        Text(bottomControls ? plainLinkCaption : linkCaption)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Farside.Palette.bone)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                if let scope = model.captureScopeDescription {
                    Text(scope).font(.footnote).foregroundStyle(Farside.Palette.bone)
                        .accessibilityIdentifier("remote.captureScope")
                }
                if !lockedMouseNotice.isEmpty {
                    Text(lockedMouseNotice).font(.footnote).foregroundStyle(Farside.Palette.bone)
                        .accessibilityIdentifier("remote.mouse.status")
                }
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(offlineLayoutCheck ? "Offline layout check. No Mac is connected." : [bottomControls && !couch ? plainLinkSpoken : linkAccessibility, model.captureScopeDescription, status, lockedMouseNotice.isEmpty ? nil : lockedMouseNotice].compactMap { $0 }.joined(separator: ". "))
            // The plain line drops route, round trip and picture size; VoiceOver can still read them here.
            .accessibilityValue(bottomControls && !offlineLayoutCheck && !couch ? linkDetailsSpoken : "")
            Spacer(minLength: 4)

            Button("End session") { model.disconnect() }
                .buttonStyle(FarsideEndButtonStyle())
                .fixedSize()
                .accessibilityLabel("End session")
                .accessibilityShowsLargeContentViewer()
        }
    }

    private var dockHandle: some View {
        let taps = TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
        return HandleDots(live: handleLive)
            .frame(width: 110, height: 44)
            .contentShape(.rect)
            .gesture(taps.onEnded { result in
                switch result {
                case .first: openKeyboard()
                case .second: controlsCollapsed ? revealControls() : collapseControls()
                }
            })
            .highPriorityGesture(DragGesture(minimumDistance: 8).onEnded { value in
                let movement = value.translation
                guard abs(movement.height) > 12, abs(movement.height) > abs(movement.width) else { return }
                if movement.height > 0 { collapseControls() } else { revealControls() }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(controlsCollapsed ? "Show controls" : "Hide controls")
            .accessibilityHint("Swipe up for controls, swipe down to hide them. Double-tap to type.")
            .accessibilityAction { controlsCollapsed ? revealControls() : collapseControls() }
            .accessibilityAction(named: Text("Show keyboard")) { openKeyboard() }
    }

    private var handleLive: Bool {
        connection.connected && (couch ? model.canControl : model.fresh && model.captureHealthy)
    }

    private var macName: String { connection.invitation?.name ?? LaunchOptions.demoMacName ?? "Your Mac" }

    private var linkCaption: String {
        if offlineLayoutCheck { return "Offline preview" }
        var parts = [macName]
        if !bottomControls, let route = model.link?.route { parts.append(route == "Relay" ? "Relayed" : route) }
        if !bottomControls, let rtt = model.link?.roundTripMs { parts.append("\(rtt) ms") }
        if let crop = model.cropSummary {
            parts.append(crop.caption)
        } else if let size = model.link?.pictureSize {
            parts.append(size)
        }
        return parts.joined(separator: " · ")
    }

    private var plainLinkCaption: String {
        if offlineLayoutCheck && !LaunchOptions.has("--ui-reconnecting") { return "Offline preview" }
        return "\(macName) · \(sessionPillReconnecting ? "Reconnecting…" : "Connected")"
    }

    private var plainLinkSpoken: String {
        if offlineLayoutCheck && !LaunchOptions.has("--ui-reconnecting") { return "Offline preview" }
        return "\(macName), \(sessionPillReconnecting ? "reconnecting" : "connected")"
    }

    private var linkDetailsSpoken: String {
        var parts: [String] = []
        if let route = model.link?.route { parts.append(route == "Relay" ? "relayed connection" : "direct connection") }
        if let rtt = model.link?.roundTripMs { parts.append("network round trip \(rtt) milliseconds") }
        if let crop = model.cropSummary {
            parts.append(crop.spoken)
        } else if let size = model.link?.pictureSize {
            parts.append("picture \(size.replacingOccurrences(of: "×", with: " by "))")
        }
        return parts.joined(separator: ", ")
    }

    private var linkAccessibility: String {
        if couch {
            var parts = [macName, "Couch mode, no picture"]
            if !offlineLayoutCheck, let rtt = model.link?.roundTripMs { parts.append("network round trip \(rtt) milliseconds") }
            return parts.joined(separator: ", ")
        }
        var parts = [macName]
        if let route = model.link?.route { parts.append(route == "Relay" ? "relayed connection" : "direct connection") }
        if let rtt = model.link?.roundTripMs { parts.append("network round trip \(rtt) milliseconds") }
        if let crop = model.cropSummary {
            parts.append(crop.spoken)
        } else if let size = model.link?.pictureSize {
            parts.append("picture \(size.replacingOccurrences(of: "×", with: " by "))")
        }
        return parts.joined(separator: ", ")
    }

    private var sessionHealth: ConnectionHealth? {
        guard !offlineLayoutCheck else { return nil }
        return ConnectionHealth.session(.init(connected: connection.connected, fresh: model.fresh,
                                              captureHealthy: model.captureHealthy, hostPresence: model.recoveryHostPresence,
                                              canWakeDisplay: model.canWakeDisplay, route: model.link?.route,
                                              slowRoundTripMs: model.slowRoundTripMs, blocker: model.sessionBlocker,
                                              wifiStall: model.wifiStallTip, linkHint: model.linkHint, vitals: model.currentMacVitals(),
                                              quality: model.qualityVerdict, device: UIDevice.current.model),
                                        lockedStatusEnabled: model.sessionPolishEnabled)
    }

    private var status: String {
        if offlineLayoutCheck { return "No Mac connected · nothing is sent" }
        if model.dragging {
            return model.explicitHoldDeadline != nil ? "Mouse button held · tap Drop to let go" : "Holding click · lift to drop"
        }
        if couch {
            if model.couchStalled { return CouchCopy.notAnswering }
            if connection.inputRecovering { return "Input catching up…" }
            if model.canControl && clickAcknowledged { return "Click sent" }
            if model.canControl { return "Controlling your Mac · no picture" }
            return model.controlAllowed ? "Waiting for your Mac · controls paused" : "Mouse and keyboard are off on your Mac"
        }
        if model.sessionPolishEnabled, model.recoveryHostPresence == .locked,
           let health = sessionHealth { return health.sessionLine }
        if !model.fresh || !model.captureHealthy { return "Reconnecting the picture · controls paused" }
        if connection.inputRecovering { return "Input catching up…" }
        let health = sessionHealth
        if let health, !health.isSlowOnly { return health.sessionLine }
        if panMode { return "View · drag or pinch to look around" }
        if model.canControl && clickAcknowledged { return "Click sent" }
        if let health { return health.sessionLine }
        if model.canControl { return directTouch ? "Controlling your Mac · direct touch" : "Controlling your Mac" }
        return model.controlAllowed ? "View only" : "Mouse and keyboard are off on your Mac"
    }

    private var liveState: LiveDot.State {
        if offlineLayoutCheck { return .idle }
        if couch { return model.canControl || model.dragging ? .live : .busy }
        if !model.fresh || !model.captureHealthy { return .busy }
        return model.canControl || model.dragging ? .live : .idle
    }

    private func toggleClipboardRow() {
        cancelGesture()
        withAnimation(reduceMotion ? nil : Farside.Motion.easeOut()) { showClipboardRow.toggle() }
    }

    // MARK: - Clipboard row

    private var clipboardRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !unifiedClipboard {
                HStack(spacing: 8) {
                    pasteToMacButton
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                    Button { model.copySelectionFromMac() } label: {
                        Label("Copy from Mac", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(FarsideSecondaryButtonStyle(height: 44, fullWidth: false))
                    .disabled(!model.canControl || !model.clipboardAvailable || model.clipboard.isBusy)
                    .accessibilityHint(DeviceWord.copy("Presses Command-C on your Mac, then copies the selection to this device"))
                }
                HStack {
                    Text("Text · 256 KB max").farsideCaption()
                    Spacer(minLength: 8)
                    Button("Get Mac clipboard") { model.fetchMacClipboard() }
                        .buttonStyle(FarsideLinkButtonStyle())
                        .disabled(!model.clipboardAvailable || model.clipboard.isBusy)
                        .accessibilityHint(DeviceWord.copy("Copies what is already on your Mac’s clipboard to this device"))
                }
                Divider().overlay(Farside.Palette.line)
            }
            FileTransferRow(model: model, files: model.files)
        }
        .padding(14)
        .farsidePlate(22, fill: Farside.Palette.ink)
        .accessibilityIdentifier("remote.clipboard.row")
    }

    // MARK: - Keyboard

    private var keyboardKeys: some View {
        HStack(spacing: 0) {
            modifierButton("Command", "command", "command")
            modifierButton("Option", "option", "option")
            modifierButton("Control", "control", "control")
            modifierButton("Shift", "shift", "shift")
            keySeparator
            keyButton("Escape", "escape", "escape")
            keyButton("Tab", "arrow.right.to.line", "tab")
            keySeparator
            keyButton("Left arrow", "arrow.left", "left")
            keyButton("Down arrow", "arrow.down", "down")
            keyButton("Up arrow", "arrow.up", "up")
            keyButton("Right arrow", "arrow.right", "right")
            keySeparator
            keyButton("Delete", "delete.left", "delete")
            keyButton("Return", "return", "return")
            if !unifiedClipboard && showsClipboard {
                keySeparator
                pasteToMacButton
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .padding(.horizontal, 4)
                iconButton("Copy from Mac", "doc.on.doc", enabled: model.canControl && !model.clipboard.isBusy,
                           action: model.copySelectionFromMac)
                    .accessibilityHint(DeviceWord.copy("Presses Command-C on your Mac, then copies the selection to this device"))
            }
        }
        .padding(.horizontal, 6)
    }

    private var regularHardwareKeyboard: Bool {
        guard regularSessionLayout else { return false }
        return sessionHardwareKeyboard
    }

    private var sessionHardwareKeyboard: Bool {
        #if DEBUG
        if offlineLayoutCheck && LaunchOptions.has("--ui-hardware-keyboard") { return true }
        if offlineLayoutCheck && LaunchOptions.has("--ui-software-keyboard") { return false }
        #endif
        return peripherals.keyboardConnected
    }

    private var keyboardContainerAreaProbe: Bool {
        #if DEBUG
        regularSessionLayout && offlineLayoutCheck && LaunchOptions.has("--ui-keyboard-container-area")
        #else
        false
        #endif
    }

    @ViewBuilder private var keyboardDockContent: some View {
        #if DEBUG
        if regularSessionLayout && offlineLayoutCheck && LaunchOptions.has("--ui-keyboard-ax-contain") {
            keyboardBar.accessibilityElement(children: .contain)
                .accessibilityIdentifier("remote.keyboard.dock")
        } else {
            keyboardBar
        }
        #else
        keyboardBar
        #endif
    }

    private var shortcutChipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.shortcutChips) { chip in
                    Button { model.tapShortcut(chip) } label: {
                        Text(chip.label)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Farside.Palette.bone)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel, stroke: Farside.Palette.line2)
                    .accessibilityHint("Uses this shortcut on your Mac")
                    .accessibilityIdentifier("remote.shortcut.\(chip.key).\(chip.modifiers.joined(separator: "."))")
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("remote.shortcuts")
    }

    private var keyboardBar: some View {
        VStack(spacing: 8) {
            if !model.shortcutChips.isEmpty { shortcutChipRow }
            if SessionChromePolicy.keyboardBar(regular: regularSessionLayout, hardware: regularHardwareKeyboard) {
                HStack(spacing: 8) {
                    Group {
                        if regularSessionLayout {
                            keyboardKeys.frame(maxWidth: .infinity)
                        } else {
                            ScrollView(.horizontal) { keyboardKeys }
                                .scrollIndicators(.hidden)
                        }
                    }
                    .frame(height: 46)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
                    .clipShape(.capsule)
                    .accessibilityIdentifier("remote.keys")

                    if unifiedClipboard && model.clipboardAvailable && model.clipboard.showsPasteChip {
                        pasteToMacButton
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                    }
                    if model.dragging {
                        Button { model.cancelInput() } label: {
                            Image(systemName: "hand.raised.fill").frame(width: 46, height: 46)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Farside.Palette.ink)
                        .background(Farside.Palette.bone, in: .circle)
                        .accessibilityLabel("Release")
                        .accessibilityHint("Drops the held item on your Mac")
                    }
                    Button { closeKeyboard() } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .foregroundStyle(Farside.Palette.bone)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("remote.keyboard.hide")
                }
            }
            HStack(alignment: .center, spacing: 8) {
                textField
                if regularHardwareKeyboard {
                    Button { closeKeyboard() } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .foregroundStyle(Farside.Palette.bone)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("remote.keyboard.hide")
                }
                if showsDictateEntry {
                    Button(action: openVoiceInput) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(Farside.Palette.bone)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
                    .disabled(!voiceEntryAvailable)
                    .opacity(voiceEntryAvailable ? 1 : 0.4)
                    .accessibilityLabel("Voice input")
                }
                Button { model.sendText() } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend ? Farside.Palette.ink : Farside.Palette.ash)
                        .frame(width: 38, height: 38)
                        .background(canSend ? Farside.Palette.bone : Farside.Palette.panel2, in: .circle)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send text")
            }
            if let limit = model.textLimitMessage {
                Text(limit).font(.caption).foregroundStyle(Farside.Palette.bone)
            } else if model.textEditable && !model.textStatus.isEmpty {
                Text(model.textStatus).font(.caption).foregroundStyle(Farside.Palette.ash)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .padding(.top, 6)
        .frame(maxWidth: regularSessionLayout ? .infinity : 640)
    }

    private var keySeparator: some View {
        Rectangle().fill(Farside.Palette.line2).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private var canSend: Bool { model.canControl && model.textCanSend }

    // MARK: - Voice

    private var dictationRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voiceContentHidden {
                Label("Voice input hidden", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(Farside.Palette.bone)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .accessibilityIdentifier("remote.voice.hidden")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    DotWaveform(active: voiceInput.phase == .listening)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(voiceCaption)
                            .farsideCaption(voiceInput.phase == .listening ? Farside.Palette.ember : Farside.Palette.ash)
                        ViewThatFits(in: .vertical) {
                            transcriptText
                            ScrollView { transcriptText }
                                .scrollIndicators(.visible)
                        }
                        .frame(maxHeight: compactHeight ? 64 : 116, alignment: .top)
                    }
                    voiceAction
                }
                ForEach(voiceMessages, id: \.self) { message in
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.bone)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.voiceRetryTranscript.isEmpty && model.voiceDeliveryStatus != .waiting {
                    Button("Record again") { model.discardVoiceRetry(); beginVoiceCapture() }
                        .buttonStyle(FarsideLinkButtonStyle())
                        .disabled(!model.canControl)
                }
            }
        }
        .padding(14)
        .farsidePlate(22, fill: Farside.Palette.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.voice")
    }

    private var transcriptText: some View {
        Text(displayedVoiceTranscript.isEmpty ? "Your words will appear here as you speak." : displayedVoiceTranscript)
            .font(.body)
            .foregroundStyle(displayedVoiceTranscript.isEmpty ? Farside.Palette.ash : Farside.Palette.bone)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("remote.voice.transcript")
    }

    @ViewBuilder private var voiceAction: some View {
        if voiceInput.phase == .requestingPermission || voiceInput.phase == .finishing || model.voiceDeliveryStatus == .waiting {
            ProgressView()
                .tint(Farside.Palette.bone)
                .frame(width: 44, height: commandTargetHeight)
                .accessibilityLabel(model.voiceDeliveryStatus == .waiting ? "Waiting for your Mac to confirm insertion"
                                                                         : "Finishing speech")
        } else if [.refused, .uncertain, .notQueued].contains(model.voiceDeliveryStatus), !displayedVoiceTranscript.isEmpty {
            Button("Retry", action: retryVoiceInsertion)
                .buttonStyle(FarsidePrimaryButtonStyle(height: commandTargetHeight))
                .fixedSize()
                .disabled(!model.canControl || model.isComposingText || voiceLimitMessage != nil)
                .accessibilityLabel("Try insertion again")
                .accessibilityHint("Check your Mac first if delivery was uncertain")
        } else {
            Button("Insert on Mac") { voiceInput.finish(insertVoiceTranscript) }
                .buttonStyle(FarsidePrimaryButtonStyle(height: commandTargetHeight))
                .fixedSize()
                .disabled(!voiceInput.canFinish ||
                          displayedVoiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          !model.canControl || model.isComposingText || !model.textEditable ||
                          voiceLimitMessage != nil)
                .accessibilityIdentifier("remote.voice.done")
        }
    }

    private var voiceCaption: String {
        if model.voiceDeliveryStatus == .waiting { return "Waiting for your Mac" }
        switch voiceInput.phase {
        case .requestingPermission: return "Checking microphone access"
        case .listening: return "Listening · speak, then Insert on Mac"
        case .finishing: return "Finishing speech"
        case .ready: return "Ready · tap Insert on Mac"
        case .idle: return "Voice input"
        }
    }

    private var voiceMessages: [String] {
        [voiceInput.message, voiceDeliveryMessage, voiceLimitMessage].compactMap { $0 }
    }

    private var voiceDeliveryMessage: String? {
        switch model.voiceDeliveryStatus {
        case .idle, .accepted: nil
        case .waiting: nil
        case .refused: "Your Mac refused the text. The transcript is still here."
        case .uncertain: "Delivery is uncertain. Check your Mac before retrying; the text was not sent again."
        case .notQueued: "Text was not queued. Check the connection and text length, then try again."
        }
    }

    private var displayedVoiceTranscript: String {
        voiceInput.transcript.isEmpty ? model.voiceRetryTranscript : voiceInput.transcript
    }

    private var voiceContentHidden: Bool {
        scenePhase != .active || model.privacyShield || model.contentConcealed
    }

    private var voiceEntryAvailable: Bool {
        model.canControl && !model.dragging &&
        (model.textEditable || (model.voiceDeliveryStatus == .uncertain && !model.voiceRetryTranscript.isEmpty))
    }

    private var voiceLocked: Bool {
        voiceInput.phase == .finishing || model.voiceDeliveryStatus == .waiting
    }

    private var autoKeyboardPreview: Bool {
        #if DEBUG
        offlineLayoutCheck && LaunchOptions.has("--ui-auto-keyboard-preview-check")
        #else
        false
        #endif
    }

    private var voiceLimitMessage: String? {
        if displayedVoiceTranscript.utf8.count > 4_096 { return "That’s too long to send at once. Record a shorter message." }
        if displayedVoiceTranscript.utf16.count > 1_024 { return "That’s too long to send at once. Record a shorter message." }
        return nil
    }

    private func openVoiceInput() {
        guard voiceEntryAvailable else { return }
        if !offlineLayoutCheck && PermissionPrimer.needsPriming(.microphone) {
            cancelGesture()
            if keyboardOpen { closeKeyboard() }
            primingMicrophone = true
            return
        }
        cancelGesture()
        if keyboardOpen { closeKeyboard() }
        model.prepareVoiceInput()
        voiceInput.cancel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.sheetSpring) {
            showClipboardRow = false
            controlsCollapsed = false
            showVoiceInput = true
        }
        #if DEBUG
        // E2E: exercise the Done-to-insert delivery path without a microphone.
        if model.voiceRetryTranscript.isEmpty, let transcript = PhoneE2E.active?.voiceTranscript {
            voiceInput.loadNonRecordingPreview(transcript)
            return
        }
        #endif
        if model.voiceRetryTranscript.isEmpty { beginVoiceCapture() }
    }

    private func beginVoiceCapture() {
        guard let expectedMedia = connection.media else { return }
        voiceInput.cancel()
        Task {
            await voiceInput.start(whileAllowed: {
                showVoiceInput && scenePhase == .active && model.canControl &&
                connection.connected && connection.media === expectedMedia &&
                !model.contentConcealed && !model.privacyShield
            })
        }
    }

    private func insertVoiceTranscript(_ transcript: String?) {
        guard let transcript else { return }
        model.stageVoiceRetry(transcript)
        guard showVoiceInput,
              scenePhase == .active, model.canControl, model.textEditable,
              !model.isComposingText, !model.contentConcealed, !model.privacyShield else { return }
        _ = model.sendVoiceText(transcript)
    }

    private func retryVoiceInsertion() {
        guard model.voiceDeliveryStatus != .waiting, scenePhase == .active,
              model.canControl, !model.isComposingText else { return }
        if model.voiceDeliveryStatus == .uncertain { model.clearUncertainVoiceText() }
        _ = model.sendVoiceText(displayedVoiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cancelVoiceInput() {
        voiceInput.cancel()
        showVoiceInput = false
    }

    private var textField: some View {
        ZStack(alignment: .leading) {
            CommittedTextField(text: $model.draft, isComposing: $model.isComposingText, focusOnAppear: true,
                               secure: model.passwordFieldFocused, draftOwner: model)
                .disabled(!model.textEditable)
                .opacity(model.textEditable ? 1 : 0)
                .allowsHitTesting(model.textEditable)
                .privacySensitive()
            if model.textEditable && model.draft.isEmpty {
                Text(model.passwordFieldFocused ? "Password for your Mac" : "Type for your Mac")
                    .foregroundStyle(Farside.Palette.ash)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if !model.textEditable {
                if model.textStatus.hasPrefix("Delivery is uncertain") {
                    Button("Edit or send again", action: model.clearUncertainText)
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.bone)
                        .padding(.leading, 16)
                        .accessibilityHint(model.textStatus)
                } else {
                    Text(model.textStatus.isEmpty ? "Waiting for your Mac…" : model.textStatus)
                        .font(.footnote)
                        .lineLimit(1)
                        .foregroundStyle(Farside.Palette.ash)
                        .padding(.leading, 16)
                }
            }
        }
        .overlay(alignment: .trailing) { PasswordFieldLock(visible: model.passwordFieldFocused) }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .farsidePlate(23, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
    }

    private var unifiedClipboard: Bool {
        model.automaticClipboardSupported && !UserDefaults.standard.bool(forKey: PhoneClipboard.pasteChipDisabledKey)
    }

    private var showsClipboard: Bool { model.clipboardSupported || offlineLayoutCheck }

    /// The system paste control reads the iPhone clipboard without a paste prompt because the
    /// person tapped it; Farside never reads the iPhone clipboard on its own.
    private var pasteToMacButton: some View {
        let offeredCount = model.clipboard.pasteChipChangeCount
        return PasteButton(payloadType: String.self) { strings in
            Task { @MainActor in model.pasteToMac(strings, sourceChangeCount: offeredCount) }
        }
        .tint(Farside.Palette.panel2)
        .disabled(!model.clipboardAvailable || model.clipboard.isBusy)
        .accessibilityIdentifier("remote.clipboard.paste")
    }

    private func iconButton(_ label: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: commandTargetHeight, height: commandTargetHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    private func keyButton(_ label: String, _ symbol: String, _ key: String) -> some View {
        Button { model.key(key) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: commandTargetHeight, height: commandTargetHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.canControl)
        .opacity(model.canControl ? 1 : 0.45)
        .accessibilityLabel(label)
    }

    private func modifierButton(_ label: String, _ symbol: String, _ modifier: String) -> some View {
        let active = model.modifiers.contains(modifier)
        return Button {
            if active { model.modifiers.remove(modifier) } else { model.modifiers.insert(modifier) }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(active ? .bold : .medium))
                .foregroundStyle(active ? Farside.Palette.ink : Farside.Palette.bone)
                .frame(width: 38, height: 38)
                .background(active ? Farside.Palette.bone : .clear, in: .circle)
                .frame(width: PhoneCommandAccessibility.target(42, enabled: PhoneCommandAccessibility.targetsEnabled), height: commandTargetHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Controls panel

    /// Pages pushed inside Controls. The key panel is the root.
    private enum ControlsPage: String, Hashable, CaseIterable {
        case settings, display, picture, pointer, touch, view, clipboard, keyboard, steer, diagnostics

        static func named(_ name: String) -> ControlsPage? { ControlsPage(rawValue: name) }
    }

    /// iPhone portrait shows Controls as a short sheet with the trackpad live above it. A sheet in
    /// landscape on iPhone, or on iPad, cannot stop at a short height, so there the keys are an
    /// overlay like the dock and Settings opens as its own sheet.
    private var controlsAsOverlay: Bool { compactHeight || horizontalSizeClass == .regular }

    /// Settings pages cover the picture; the key panel never does.
    private var controlsBlockInput: Bool {
        guard showControls else { return false }
        if controlsAsOverlay { return showOverlaySettings || controlsNeedScrolling }
        return !controlsPath.isEmpty || controlsDetent == .large
    }

    private var controlsSheetPresented: Binding<Bool> {
        Binding(get: { showControls && !controlsAsOverlay }, set: { if !$0 { closeControls() } })
    }

    /// Couch shows no picture, so there is no display to choose and nothing to hide it from.
    private var showsCurtainRow: Bool {
        !couch && ((model.curtainSupported && model.curtainState != nil) || curtainPreview)
    }

    private var showsDisplayRow: Bool { !couch && model.displaySelectionSupported && model.displays.count > 1 }

    private var showsBigTextRow: Bool { model.bigTextSupported && model.bigText.savedWidth != nil }

    /// Couch moved here from the old Mode tile's long-press menu.
    private var showsCouchRow: Bool { !couch && model.couchSwitchAvailable }

    private var showsSessionRows: Bool {
        if bottomControls { return showsDisplayRow }
        return showsCurtainRow || showsDisplayRow || showsBigTextRow || showsCouchRow || model.awaySupported
    }

    /// Reserve the navigation row as well as the existing keys; shorter windows can scroll.
    private var panelHeight: CGFloat {
        var height: CGFloat = 368
        if bottomControls {
            if showsTouchModeInPanel { height += 56 }
            if showsDisplayRow { height += 14 + 52 }
            return height
        }
        if showsSessionRows { height += 14 }
        if model.awaySupported { height += 112 }
        if showsCurtainRow { height += 61 }
        if showsDisplayRow { height += showsCurtainRow ? 53 : 52 }
        if showsBigTextRow { height += showsCurtainRow || showsDisplayRow ? 53 : 52 }
        if showsCouchRow { height += showsCurtainRow || showsDisplayRow || showsBigTextRow ? 53 : 52 }
        return height
    }

    private var controlsNeedScrolling: Bool { dynamicTypeSize.isAccessibilitySize || accessibleCommands }
    private var panelDetent: PresentationDetent { controlsNeedScrolling ? .large : .height(panelHeight) }

    private var macKeysDisabled: Bool { !model.canControl || panMode }

    private var openAppAvailable: Bool {
        showControls && controlsPath.isEmpty && !showOverlaySettings && scenePhase == .active &&
            !panMode && !keyboardOpen && !showVoiceInput && !primingMicrophone &&
            voiceInput.phase == .idle && !voiceLocked && model.canOpenMacApp
    }

    private func openAppFromControls() {
        // Read local presentation state again at invocation; canControl alone does not encode View.
        guard openAppAvailable, model.openMacApp() else { return }
        closeControls() // Queue acceptance only. Keep Keyboard a separate, deliberate action.
    }

    private var openAppRow: some View {
        Button(action: openAppFromControls) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open app…").font(.subheadline.weight(.semibold))
                    Text("Spotlight · ⌘Space").font(.caption).foregroundStyle(Farside.Palette.ash)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Farside.Palette.bone)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .farsidePlate(Farside.Radius.control, fill: Farside.Palette.panel, stroke: Farside.Palette.line2)
        }
        .buttonStyle(.plain)
        .disabled(!openAppAvailable)
        .accessibilityLabel("Open app…")
        .accessibilityHint("Shows or hides Spotlight on your Mac. Use Keyboard to search.")
        .accessibilityIdentifier("remote.navigation.openApp")
    }

    private var controlsSheet: some View {
        NavigationStack(path: $controlsPath) {
            controlsPanel
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ControlsPage.self) { controlsPage($0) }
        }
        .tint(Farside.Palette.bone)
        .presentationDetents(controlsNeedScrolling ? [.large] : [panelDetent, .large], selection: $controlsDetent)
        .presentationBackgroundInteraction(.enabled(upThrough: panelDetent))
        .presentationDragIndicator(.visible)
        .farsideSheet()
        .onChange(of: controlsPath) { _, path in
            withAnimation(reduceMotion ? nil : Farside.Motion.sheetSpring) {
                controlsDetent = path.isEmpty ? panelDetent : .large
            }
        }
        .onChange(of: panelHeight) { _, _ in
            if controlsPath.isEmpty { controlsDetent = panelDetent }
        }
        .onAppear { controlsDetent = controlsPath.isEmpty ? panelDetent : .large }
    }

    private var controlsPanel: some View {
        ScrollViewReader { reader in
            ScrollView { controlsPanelContent }
                // Pointer following needs the stationary occluding viewport, not its moving content.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
                .accessibilityIdentifier("remote.controls.scroll")
                #if DEBUG
                .overlay(alignment: .bottomTrailing) {
                    if controlsGeometryProbeEnabled {
                        VStack {
                            Color.clear.frame(width: 1, height: 1)
                                .allowsHitTesting(false)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Controls geometry probe")
                                .accessibilityValue(controlsGeometryProbeValue)
                                .accessibilityIdentifier("remote.controls.geometryProbe")
                            Button("Scroll fixture") {
                                // Scroll real overflowing content without changing the sheet detent.
                                reader.scrollTo("controls.geometry.bottom", anchor: .bottom)
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("remote.controls.geometryScroll")
                        }
                    }
                }
                #endif
        }
    }

    #if DEBUG
    private var controlsGeometryProbeEnabled: Bool {
        offlineLayoutCheck && model.inputProbe != nil && !controlsAsOverlay &&
            LaunchOptions.has("--ui-controls-scroll-geometry")
    }

    private var controlsGeometryProbeValue: String {
        func rect(_ frame: CGRect) -> String {
            [frame.minX, frame.minY, frame.width, frame.height].map { String(Double($0)) }.joined(separator: ",")
        }
        return "panel=\(rect(panelFrame));content=\(rect(controlsProbeContentFrame));blocked=\(controlsBlockInput)"
    }
    #endif

    private var controlsPanelContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(moreTileTitle)
                        .font(.headline)
                        .foregroundStyle(Farside.Palette.bone)
                        .accessibilityAddTraits(.isHeader)
                    if let vitals = model.currentMacVitals() {
                        let words = MacVitalsPresentation(vitals)
                        ViewThatFits(in: .horizontal) {
                            ForEach(words.captions, id: \.self) { caption in
                                Text(caption)
                                    .lineLimit(1)
                                    .minimumScaleFactor(caption == words.captions.last ? 0.75 : 1)
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(words.isWarning ? Farside.Palette.bone : Farside.Palette.ash)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(words.spoken)
                        .accessibilityIdentifier("remote.controls.vitals")
                    }
                }
                Spacer(minLength: 8)
                NavigationLink(value: ControlsPage.settings) {
                    Label("Settings", systemImage: "gearshape")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Farside.Palette.bone)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("remote.controls.settings")
                controlsDoneButton
                    .accessibilityShowsLargeContentViewer()
            }
            .frame(minHeight: 44)
            // Past xxxLarge the header wraps and pushes the keys below the fixed panel height.
            .dynamicTypeSize(...commandTypeLimit)
            .padding(.bottom, 12)
            if showsTouchModeInPanel {
                panelTouchModeSegments.dynamicTypeSize(...commandTypeLimit).padding(.bottom, 12)
            }
            openAppRow.padding(.bottom, 12)
            macKeys(compact: false)
            if showsSessionRows {
                // Keep the existing row typography; overflow remains reachable by scrolling.
                sessionRows.padding(.top, 14)
                    .dynamicTypeSize(...commandTypeLimit)
            }
            Spacer(minLength: 0)
            #if DEBUG
            if controlsGeometryProbeEnabled {
                Color.clear.frame(height: 600)
                    .id("controls.geometry.bottom")
                    .accessibilityHidden(true)
            }
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Farside.Palette.void2)
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            if controlsGeometryProbeEnabled { controlsProbeContentFrame = $0 }
        }
        #endif
        .onAppear { if model.displays.isEmpty { model.requestDisplays() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.controls.content")
    }

    private var controlsDoneButton: some View {
        Button { closeControls() } label: {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Farside.Palette.ink)
                .frame(width: 36, height: 36)
                .background(Farside.Palette.bone, in: .circle)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done")
    }

    /// Things you do to the Mac, each printed with its Mac shortcut or phone gesture.
    private func macKeys(compact: Bool) -> some View {
        // Keep the existing eight eager keys. They remain present after
        // keyboard rotation/dismissal, when a lazy grid can retain a zero-sized viewport.
        let columns = PhoneCommandAccessibility.columns(compact: compact, accessible: accessibleCommands)
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<(8 / columns), id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        macKey(at: row * columns + column, compact: accessibleCommands ? false : compact)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        // Fixed-size keys: past xLarge their two-line titles truncate, so they stop growing there
        // and a long press shows the Large Content Viewer instead.
        .dynamicTypeSize(...(accessibleCommands ? dynamicTypeSize : DynamicTypeSize.xLarge))
        .accessibilityIdentifier(accessibleCommands ? "remote.keys.accessible" : "remote.keys.fixed")
    }

    @ViewBuilder private func macKey(at index: Int, compact: Bool) -> some View {
        switch index {
        case 0:
            macKey("Space left", "arrow.left.square", hint: "⌃←", label: "Move left a Space", compact: compact) {
                _ = model.gesture(.workspaceSwipe(direction: .right))
            }
            .disabled(macKeysDisabled)
        case 1:
            macKey("Mission Control", "rectangle.3.group", hint: "⌃↑", compact: compact) {
                _ = model.gesture(.workspaceSwipe(direction: .up))
            }
            .disabled(macKeysDisabled)
        case 2:
            macKey("App windows", "rectangle.stack", hint: "⌃↓", label: "Application windows", compact: compact) {
                _ = model.gesture(.workspaceSwipe(direction: .down))
            }
            .disabled(macKeysDisabled)
        case 3:
            macKey("Space right", "arrow.right.square", hint: "⌃→", label: "Move right a Space", compact: compact) {
                _ = model.gesture(.workspaceSwipe(direction: .left))
            }
            .disabled(macKeysDisabled)
        case 4:
            macKey("Right-click", "contextualmenu.and.cursorarrow", hint: "2-finger tap", compact: compact) {
                model.action("right")
            }
            .disabled(macKeysDisabled)
        case 5:
            macKey("Double-click", "cursorarrow.click.2", hint: "double tap", compact: compact) {
                model.action("double")
            }
            .disabled(macKeysDisabled)
        case 6:
            holdKey(compact: compact)
        case 7:
            macKey("Show Desktop", "menubar.dock.rectangle", hint: "F11", compact: compact) {
                _ = model.hardwareKey("f11", modifiers: [])
            }
            .disabled(macKeysDisabled || !model.extendedKeysSupported)
            .accessibilityHint(model.extendedKeysSupported || offlineLayoutCheck
                               ? "Presses F11 on your Mac" : "Needs the updated Farside on your Mac")
        default: EmptyView()
        }
    }

    @ViewBuilder private func holdKey(compact: Bool) -> some View {
        if model.dragging {
            macKey("Drop", "arrow.down.to.line", hint: "lets go", compact: compact) { model.cancelInput() }
                .accessibilityHint("Lets go of the mouse button on your Mac")
        } else {
            macKey("Hold click", "cursorarrow.and.square.on.square.dashed", hint: "tap, hold", compact: compact) {
                model.drag()
            }
            .disabled(macKeysDisabled || !model.nativeInteractionSupported)
            .accessibilityHint("Holds the mouse button down so you can drag with one finger. It drops by itself after \(Int(PhoneRemoteModel.explicitHoldLimit)) seconds.")
        }
    }

    private func macKey(_ title: String, _ symbol: String, hint: String, label: String? = nil,
                        compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: compact ? 4 : 5) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 19 : 21, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(accessibleCommands ? nil : 2)
                    .minimumScaleFactor(accessibleCommands ? 1 : 0.8)
                    .frame(height: accessibleCommands ? nil : (compact ? 26 : 30))
                if !compact {
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Farside.Palette.ash)
                        .lineLimit(accessibleCommands ? nil : 1)
                        .minimumScaleFactor(accessibleCommands ? 1 : 0.8)
                }
            }
            .foregroundStyle(Farside.Palette.bone)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .buttonStyle(ControlsKeyStyle(compact: compact))
        .accessibilityLabel(label ?? title)
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
    }

    private var sessionRows: some View {
        VStack(spacing: 0) {
            if bottomControls {
                if showsDisplayRow { displayPanelRow }
            } else {
                legacySessionRows
            }
        }
        .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel, stroke: Farside.Palette.line)
    }

    @ViewBuilder private var legacySessionRows: some View {
        if model.awaySupported {
            VStack(alignment: .leading, spacing: 8) {
                if model.awayState == .covered {
                    Text("Mac covered · requests a lock if touched").font(.footnote)
                }
                if let status = model.lockMacStatus { Text(status).font(.footnote) }
                Button("End and lock Mac") { _ = model.endAndLockMac() }
                    .frame(minHeight: 44)
                    .disabled(!model.canLockMac)
                    .accessibilityHint("Requests Lock Screen, then ends this session. Unlock at your Mac.")
                    .accessibilityIdentifier("remote.endAndLockMac")
            }.padding()
            sessionRowDivider
        }
        if showsCurtainRow { curtainPanelRow }
        if showsCurtainRow && showsDisplayRow { sessionRowDivider }
        if showsDisplayRow { displayPanelRow }
        if showsBigTextRow && (showsCurtainRow || showsDisplayRow) { sessionRowDivider }
        if showsBigTextRow { bigTextPanelRow }
        if showsCouchRow && (showsCurtainRow || showsDisplayRow || showsBigTextRow) { sessionRowDivider }
        if showsCouchRow { couchPanelRow }
    }

    private var sessionRowDivider: some View {
        Rectangle().fill(Farside.Palette.line).frame(height: 1).padding(.leading, 50)
    }

    private var couchPanelRow: some View {
        Button { _ = model.requestMode(.couch) } label: {
            HStack(spacing: 12) {
                Image(systemName: "sofa")
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Switch to Couch mode").foregroundStyle(Farside.Palette.bone)
                Spacer(minLength: 8)
                Text(CouchCopy.entryCaption)
                    .font(.footnote)
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remote.mode.couch")
    }

    private var bigTextPanelRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat.size")
                .foregroundStyle(Farside.Palette.ash)
                .frame(width: 24)
                .accessibilityHidden(true)
            Toggle("Big Text", isOn: Binding(get: { !model.bigText.sessionOff },
                                             set: { model.setBigTextOffForSession(!$0) }))
                .toggleStyle(FarsideSwitchStyle())
                .accessibilityIdentifier("remote.bigTextRow")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
    }

    private var curtainPanelRow: some View {
        let state = model.curtainState ?? .off
        return HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Farside.Palette.ash)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide Mac screen").foregroundStyle(Farside.Palette.bone).accessibilityHidden(true)
                if state == .liftedLocally && !curtainPreview {
                    Button("Lifted at your Mac · Hide it again") { model.setMacCurtain(true) }
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.bone)
                        .disabled(!model.canChangeCurtain)
                } else {
                    Text(curtainCaption(state))
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.ash)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { !curtainPreview && state.preferenceOn },
                                 set: { model.setMacCurtain($0) })) { EmptyView() }
                .toggleStyle(FarsideSwitchStyle())
                .fixedSize()
                .accessibilityLabel("Hide Mac screen")
                .disabled(!model.canChangeCurtain)
                .opacity(model.canChangeCurtain || curtainPreview ? 1 : 0.45)
                .accessibilityIdentifier("remote.macCurtain")
                .accessibilityHint(macCurtainFooter(state))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
    }

    private func curtainCaption(_ state: PrivacyCurtainState) -> String {
        switch state {
        case .off: "Off · anyone at the Mac can watch"
        case .pending: "Covers once the picture is live"
        case .up: "Covered · Esc three times at the Mac lifts it"
        case .liftedLocally: "Lifted at your Mac"
        case .unavailable: "Needs Accessibility permission on your Mac"
        case .failed: "Couldn’t confirm it was hidden, so it stayed visible"
        }
    }

    private var currentDisplayName: String {
        model.displays.first { $0.id == model.currentDisplayID }?.name ?? "Choose"
    }

    private var displayPanelRow: some View {
        NavigationLink(value: ControlsPage.display) {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Display").foregroundStyle(Farside.Palette.bone)
                Spacer(minLength: 8)
                Text(currentDisplayName)
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Farside.Palette.dim)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remote.displayRow")
    }

    /// Landscape and iPad keep Settings and Done outside the scrollable command content.
    private var overlayControls: some View {
        Group {
            if controlsNeedScrolling {
                VStack(spacing: 10) {
                    HStack {
                        Text(moreTileTitle).font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button { showOverlaySettings = true } label: { Image(systemName: "gearshape") }
                            .buttonStyle(FarsideRoundButtonStyle(diameter: 44))
                            .accessibilityLabel("Settings")
                            .accessibilityIdentifier("remote.controls.settings")
                        controlsDoneButton
                    }
                    if showsTouchModeInPanel { panelTouchModeSegments }
                    ScrollView {
                        VStack(spacing: 10) {
                            openAppRow
                            macKeys(compact: false)
                        }
                    }
                    .accessibilityIdentifier("remote.controls.scroll")
                }
                .padding(12)
                .frame(maxWidth: 860)
                .frame(maxHeight: max(180, min(620, canvasFrame.height * 0.8)))
                .farsidePlate(Farside.Radius.sheet, fill: Farside.Palette.void2.opacity(0.97), stroke: Farside.Palette.line2)
                .padding(.horizontal, 8)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("remote.controls.content")
            } else {
                compactOverlayControls
            }
        }
        // Under the Settings sheet the keys are covered; VoiceOver should not reach them either.
        .accessibilityHidden(showOverlaySettings)
        .sheet(isPresented: $showOverlaySettings, onDismiss: { controlsPath = [] }) {
            NavigationStack(path: $controlsPath) {
                settingsPage(session: true)
                    .navigationDestination(for: ControlsPage.self) { controlsPage($0) }
            }
            .tint(Farside.Palette.bone)
            .presentationDetents([.large])
            .farsideSheet()
        }
    }

    private var compactOverlayControls: some View {
        VStack(spacing: 10) {
            if showsTouchModeInPanel {
                panelTouchModeSegments
                    .dynamicTypeSize(...commandTypeLimit)
                    .frame(maxWidth: 360)
            }
            HStack(alignment: .center, spacing: 10) {
                ScrollView {
                    VStack(spacing: 10) {
                        openAppRow
                        macKeys(compact: true)
                    }
                }
                .accessibilityIdentifier("remote.controls.scroll")
                .frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    Button { showOverlaySettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(FarsideRoundButtonStyle(diameter: 44))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("remote.controls.settings")
                    controlsDoneButton
                }
            }
        }
        .padding(12)
        .farsidePlate(Farside.Radius.sheet, fill: Farside.Palette.void2.opacity(0.97), stroke: Farside.Palette.line2)
        .padding(.horizontal, 8)
        .padding(.bottom, regularSessionLayout ? 0 : 6)
        .frame(maxWidth: 860)
        .frame(maxHeight: max(180, min(620, canvasFrame.height * 0.8)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
        .onAppear { if model.displays.isEmpty { model.requestDisplays() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.controls.content")
    }

    @ViewBuilder private func controlsPage(_ page: ControlsPage) -> some View {
        switch page {
        case .settings: settingsPage(session: bottomControls)
        case .display: settingsForm("Display") { displaySection }
        case .picture: settingsForm("Picture") { pictureSection }
        case .pointer: settingsForm("Pointer") { feelSection }
        case .touch:
            settingsForm("Touch") {
                touchSection
                PrecisionTapSettingsSection(directTouch: touchMode == .direct)
            }
        case .view:
            settingsForm("View") {
                zoomSection
                KeyboardViewSettingsSection()
                miniMapSection
            }
        case .clipboard: settingsForm("Clipboard") { clipboardSettingsSection }
        case .keyboard: settingsForm("Keyboard and pointer") { hardwareSection }
        case .steer: settingsForm("How to steer") { gesturesSection }
        case .diagnostics:
            settingsForm("Diagnostics") {
                connectionHealthSection
                macVitalsSection
                diagnosticsSection
            }
        }
    }

    private func settingsForm<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .scrollContentBackground(.hidden)
            .background(Farside.Palette.void2)
            .accessibilityIdentifier("remote.controls.page")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { closeControls() }
                        .accessibilityIdentifier("remote.controls.page.done")
                }
            }
    }

    /// One row per setting with its current value; each opens its own page.
    private func settingsPage(session: Bool) -> some View {
        settingsForm("Settings") {
            if session && showsCouchRow {
                Section { couchPanelRow }
            }
            if session && model.awaySupported {
                Section {
                    Button("End and lock Mac") { _ = model.endAndLockMac() }
                        .frame(minHeight: 44).disabled(!model.canLockMac)
                        .accessibilityIdentifier("remote.endAndLockMac")
                    if let status = model.lockMacStatus { Text(status).font(.footnote) }
                } footer: { Text("Requests Lock Screen, then ends this session. Unlock at your Mac.") }
            }
            if session && (showsCurtainRow || showsDisplayRow) {
                macPrivacySection
                if showsDisplayRow {
                    Section {
                        summaryRow("Display", "display", value: currentDisplayName, page: .display)
                    }
                }
            }
            Section {
                summaryRow("Picture", "photo", value: model.pictureMode.localizedTitle(), page: .picture)
                summaryRow("Pointer", "cursorarrow", value: "", page: .pointer)
                summaryRow("View", "arrow.up.left.and.arrow.down.right", value: zoomDescription, page: .view)
                if showsClipboard && !model.automaticClipboardSupported {
                    summaryRow("Clipboard", "list.clipboard",
                               value: model.clipboard.pasteAfterSending ? "⌘V after sending" : "Send only", page: .clipboard)
                }
                summaryRow("Keyboard and pointer", "keyboard",
                           value: peripherals.keyboardConnected ? "Keyboard connected" : "", page: .keyboard)
            }
            if session {
                Section {
                    NavigationLink { LANWakeView(model: model) } label: {
                        Label("Wake another Mac on this LAN", systemImage: "power")
                            .frame(minHeight: 44)
                    }
                }
            }
            Section {
                summaryRow("How to steer", "hand.draw", value: "", page: .steer)
                summaryRow("Diagnostics", "waveform.path.ecg", value: streamStatsEnabled ? "Statistics on" : "", page: .diagnostics)
            }
        }
    }

    private func summaryRow(_ title: String, _ symbol: String, value: String, page: ControlsPage) -> some View {
        NavigationLink(value: page) {
            SettingsSummaryLabel(title: title, symbol: symbol, value: value)
        }
        .listRowBackground(Farside.Palette.panel)
        .accessibilityIdentifier("remote.settings.\(page)")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Farside.Palette.ash)
            .textCase(nil)
    }

    private func openControls() {
        recordChromeHitProbe("open Controls")
        cancelGesture()
        controlsPath = []
        showOverlaySettings = false
        controlsDetent = panelDetent
        showControls = true
    }

    private func closeControls() {
        showOverlaySettings = false
        showControls = false
        controlsPath = []
    }

    // MARK: - Hold states

    /// A finger drag drops when the finger lifts, so it only needs a status line. A Hold click
    /// from Controls stays down after lifting, so its chip carries Drop and the countdown.
    @ViewBuilder private var holdChip: some View {
        if let deadline = model.explicitHoldDeadline {
            HStack(spacing: 12) {
                contactDot
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mouse button held")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Farside.Palette.bone)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Slide one finger to move it. Drops by itself in \(holdSecondsLeft(deadline)) s")
                            .font(.footnote)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("Drop") { model.cancelInput() }
                    .buttonStyle(DropButtonStyle())
                    .accessibilityHint("Lets go of the mouse button on your Mac")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .farsidePlate(16, fill: Farside.Palette.void2.opacity(0.94), stroke: Farside.Palette.line2)
            .frame(maxWidth: 440)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.holdChip")
        } else {
            HStack(spacing: 10) {
                contactDot
                HStack(spacing: 0) {
                    Text("Holding click").foregroundStyle(Farside.Palette.bone)
                    Text(" · lift to drop").foregroundStyle(Farside.Palette.ash)
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .farsidePlate(14, fill: Farside.Palette.void2.opacity(0.94), stroke: Farside.Palette.line2)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Holding click. Lift your finger to drop.")
            .accessibilityIdentifier("remote.holdChip")
        }
    }

    private var contactDot: some View {
        Circle()
            .fill(Farside.Palette.ember)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private func holdSecondsLeft(_ deadline: TimeInterval) -> Int {
        max(0, Int((deadline - ProcessInfo.processInfo.systemUptime).rounded(.up)))
    }

    private var touchSection: some View {
        Section {
            FarsideSegmented(label: "Touch",
                             options: TouchInputMode.allCases.map { (value: $0, title: $0.title) },
                             selection: Binding(get: { touchMode }, set: setTouchMode))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .accessibilityIdentifier("remote.touchMode")
        } header: {
            sectionHeader("Touch")
        } footer: {
            Text(touchFooter)
                .foregroundStyle(Farside.Palette.ash)
                .accessibilityIdentifier("remote.touchMode.footer")
        }
    }

    private var touchFooter: String {
        switch touchMode {
        case .trackpad:
            "Trackpad: slide one finger to move the pointer, tap to click. Precise on small targets."
        case .direct where !model.absolutePointerSupported && !offlineLayoutCheck:
            "Direct touch needs the updated Farside on your Mac. Until then, touches work as a trackpad."
        case .direct:
            "Direct: tap exactly where you want to click; drag, or touch and hold, to click and drag. Two fingers still scroll and pinch."
        }
    }

    @ViewBuilder private var displaySection: some View {
        if model.displaySelectionSupported && model.displays.count > 1 {
            Section {
                ForEach(model.displays) { display in
                    let current = display.id == model.currentDisplayID
                    Button { model.selectDisplay(display.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: display.main ? "laptopcomputer" : "display")
                                .foregroundStyle(Farside.Palette.ash)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display.name).foregroundStyle(Farside.Palette.bone)
                                Text(display.resolution).farsideCaption()
                            }
                            Spacer(minLength: 8)
                            if display.id == model.pendingDisplayID {
                                ProgressView().tint(Farside.Palette.bone)
                            } else if current {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Farside.Palette.bone)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!current && !model.canChooseDisplay)
                    .accessibilityLabel("\(display.name), \(display.resolution)")
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .accessibilityHint(current ? "Showing now" : "Shows this display instead")
                    .accessibilityIdentifier("remote.display.\(display.id)")
                    .listRowBackground(Farside.Palette.panel)
                }
            } header: {
                sectionHeader("Display")
            } footer: {
                Text(model.canControl || offlineLayoutCheck
                     ? "Your Mac has more than one display. Farside remembers your choice for this Mac."
                     : "Choosing a display needs control of your Mac.")
                    .foregroundStyle(Farside.Palette.ash)
            }
        }
    }

    private var miniMapSection: some View {
        Section {
            if UIDevice.current.userInterfaceIdiom == .pad {
                Toggle("Mini map", isOn: $miniMapPad)
                    .toggleStyle(FarsideSwitchStyle())
                    .listRowBackground(Farside.Palette.panel)
                    .accessibilityIdentifier("remote.minimap.setting")
            } else {
                Toggle("Mini map in landscape", isOn: $miniMapPhone)
                    .toggleStyle(FarsideSwitchStyle())
                    .listRowBackground(Farside.Palette.panel)
                    .accessibilityIdentifier("remote.minimap.setting")
            }
        } header: {
            sectionHeader("Mini map")
        } footer: {
            Text("While part of your Mac’s screen is off the edge, a small overview appears in the corner. Drag its outline to move around, or tap to jump. It fades when you stop moving.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    private var hardwareSection: some View {
        Section {
            Label(peripherals.keyboardConnected ? "Keyboard connected · keys go to your Mac" : "No hardware keyboard connected",
                  systemImage: "keyboard")
                .foregroundStyle(Farside.Palette.bone)
                .listRowBackground(Farside.Palette.panel)
                .accessibilityIdentifier("remote.hardware.keyboard")
            if peripherals.mouseConnected {
                Label("Mouse or trackpad connected", systemImage: "computermouse")
                    .foregroundStyle(Farside.Palette.bone)
                    .listRowBackground(Farside.Palette.panel)
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Button("Lock relative mouse") { model.cancelInput(); lockedMouseNotice = ""; showControls = false; lockedMouseRequested = true }
                    .disabled(!peripherals.mouseConnected || !model.canControl)
                    .accessibilityIdentifier("remote.mouse.lock")
                if !lockedMouseNotice.isEmpty { Text(lockedMouseNotice).font(.footnote) }
                Text(model.pencilSupported ? "Pencil places the pointer, presses with pressure and ignores resting fingers during contact. Drawing support depends on the Mac app." : "Pencil input needs a compatible Mac and a live picture session.")
                    .font(.footnote)
            }
            Toggle("Use ⌃⌥ for shortcuts iPadOS keeps", isOn: $remapShortcuts)
                .toggleStyle(FarsideSwitchStyle())
                .listRowBackground(Farside.Palette.panel)
                .accessibilityIdentifier("remote.hardware.remap")
            if remapShortcuts {
                DisclosureGroup("Shortcuts") {
                    ForEach(ShortcutRemap.defaults) { remap in
                        LabeledContent {
                            Text("\(remap.chord) → \(remap.result)")
                                .font(Farside.Typeface.caption(.footnote))
                                .foregroundStyle(Farside.Palette.bone)
                        } label: {
                            Text(remap.title).foregroundStyle(Farside.Palette.bone)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .tint(Farside.Palette.ash)
                .foregroundStyle(Farside.Palette.bone)
                .listRowBackground(Farside.Palette.panel)
            }
        } header: {
            sectionHeader("Keyboard and pointer")
        } footer: {
            Text("Keys go to your Mac by position, so keep the same keyboard layout on both. Esc always reaches the Mac; End session never uses a key. On iPad, a mouse or trackpad points exactly where you move it, right-clicks with the secondary button and middle-clicks with the middle button.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    private func setTouchMode(_ mode: TouchInputMode) {
        guard mode != touchMode else { return }
        cancelGesture()
        model.pointerLocator.clear()
        touchMode = mode
    }

    @ViewBuilder private var clipboardSettingsSection: some View {
        if showsClipboard {
            Section {
                if !model.automaticClipboardSupported {
                    Toggle("Press ⌘V after sending", isOn: Binding(get: { model.clipboard.pasteAfterSending },
                                                                   set: { model.clipboard.pasteAfterSending = $0 }))
                        .toggleStyle(FarsideSwitchStyle())
                        .listRowBackground(Farside.Palette.panel)
                }
            } footer: {
                Text(model.automaticClipboardSupported
                     ? DeviceWord.copy("Mac text copies arrive here automatically while you control it. Paste sends this device’s text only when you tap. Text only, up to 256 KB; items marked as passwords are never shared.")
                     : "Send and copy from the dock’s Clip button. Text only, up to 256 KB. Farside reads your Mac’s clipboard only when you ask, and never shares items marked as passwords.")
                    .foregroundStyle(Farside.Palette.ash)
            }
        }
    }

    private var zoomSection: some View {
        Section {
            VStack(spacing: 2) {
                LabeledContent {
                    Text(zoomDescription)
                        .font(Farside.Typeface.caption(.body))
                        .monospacedDigit()
                        .foregroundStyle(Farside.Palette.bone)
                        .accessibilityLabel("Current zoom")
                        .accessibilityValue(String(format: "%.1f", Double(viewport.zoom)))
                } label: {
                    Text("Zoom").foregroundStyle(Farside.Palette.bone)
                }
                zoomSlider
            }
            .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("Zoom")
        } footer: {
            Text("Pinch on the picture does the same. Fit and Fill are in the dock.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    private var gesturesSection: some View {
        Section {
            Text(panMode ? (FarsideBeta.isEnabled
                          ? "View: drag to look around. Pinch to zoom. Double-tap to focus or return. Back to view restores the framing before focus; Fit shows the whole display."
                          : "View: drag with one or two fingers to move the screen. Pinch to zoom. Double-tap to zoom in or fit the whole display.")
                 : (directTouch
                    ? "Control, direct: tap to click where you touch; drag to click and drag. Two fingers scroll what is under them. Pinch to zoom the view."
                    : "Control: drag one finger to move the pointer. Two fingers scroll. Pinch to zoom the view.")
                   + " Three fingers left or right switch Spaces; up opens Mission Control; down opens App Exposé."
                   + (model.middleButtonSupported ? " Tap with three fingers to middle-click." : ""))
                .foregroundStyle(Farside.Palette.bone)
                .listRowBackground(Farside.Palette.panel)
            Button(CommerceLocalization.text("REPLAY_COACH", "Practice gestures again")) {
                model.usefulSession.count("coachReplay")
                closeControls()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { replayCoach() }
            }
            .frame(minHeight: 44)
            .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("Gestures")
        }
    }

    private var zoomBinding: Binding<Double> {
        Binding(get: { Double(viewport.zoom) }, set: { value in
            cancelGesture()
            let center = CGPoint(x: viewport.safeRect.midX, y: viewport.safeRect.midY)
            viewport.setZoom(CGFloat(value), anchoredAt: center)
        })
    }

    private var zoomSlider: some View {
        let range = viewport.zoomRange
        let bounds: ClosedRange<Double> = Double(range.lowerBound)...Double(range.upperBound)
        return Slider(value: zoomBinding, in: bounds, onEditingChanged: settleSlider)
            .tint(Farside.Palette.bone)
            .accessibilityLabel("Zoom level")
    }

    private func settleSlider(_ editing: Bool) {
        guard !editing else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) {
            _ = viewport.settleZoom()
        }
        reportSettledViewport()
    }

    @ViewBuilder private var pictureSection: some View {
        if adaptiveLayout {
            pictureQualitySection
            macAudioSection
        } else {
            macAudioSection
            pictureQualitySection
        }
        bigTextSection
        Section { FullColorSettingRows() } header: { sectionHeader("Experimental full color") }
    }

    private var macAudioSection: some View {
        Section {
            if model.pipAdmission != nil {
                LivePiPPreview(layer: model.livePiP.displayLayer)
                    .overlay { if model.privacyShield || model.contentConcealed { Farside.Palette.void } }
                    .frame(height: 120)
                    .accessibilityLabel("Live Mac preview for Picture in Picture")
                Button(model.pipState == .active ? "Stop Picture in Picture" : "Start Picture in Picture") {
                    if model.pipState == .active { model.stopPictureInPicture() }
                    else { model.startPictureInPicture() }
                }
                .frame(minHeight: 44)
                .disabled(model.pipState != .active && model.pipState != .ready)
                Text("Live view only. Control, Mac audio, clipboard and files stop while Picture in Picture is active.")
                    .font(.footnote)
            }
            Toggle("Listen to Mac audio", isOn: Binding(get: { !model.macAudioMuted },
                                                       set: { model.setMacAudioMuted(!$0) }))
                .accessibilityIdentifier("remote.macAudio")
                .disabled(model.captureScopeViewOnly)
            Text(model.captureScopeViewOnly ? "Audio is off while sharing an app or window." : model.phoneAudioRequestSupported ? "Sound may come from every Mac app. Stops when you leave Farside or dictate. Your Mac can block listening in Settings." : "Requires Share Mac audio on your Mac. Sound may come from every app. Stops when you leave Farside or dictate.")
                .font(.footnote).foregroundStyle(Farside.Palette.ash)
        } header: { sectionHeader("Mac audio") }
    }

    private var pictureQualitySection: some View {
        Section {
            FarsideSegmented(label: CommerceLocalization.text("PICTURE_MODE", "Picture mode"),
                             options: PictureMode.allCases.map { (value: $0, title: $0.localizedTitle()) },
                             selection: Binding(get: { model.pictureMode }, set: { model.pictureMode = $0 }),
                             accessibilityStacked: true)
                .accessibilityIdentifier("remote.pictureMode")
                .disabled(model.appliedStreamQuality == nil && !offlineLayoutCheck)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            Text(model.pictureMode.localizedDescription)
                .font(.footnote).foregroundStyle(Farside.Palette.ash)
                .listRowBackground(Farside.Palette.panel)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PictureMode.allCases, id: \.self) { mode in
                    let quality = mode.streamQuality
                    let estimate = model.dataUseEstimate(for: quality)
                    Text(DataUseCopy.presetLine(quality, estimate))
                        .foregroundStyle(quality == model.streamQuality ? Farside.Palette.bone : Farside.Palette.ash)
                        .accessibilityLabel(DataUseCopy.presetSpoken(quality, estimate))
                        .accessibilityAddTraits(quality == model.streamQuality ? .isSelected : [])
                }
                Text(DataUseCopy.note()).foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.dataUseEstimates")
            .listRowBackground(Farside.Palette.panel)
            if !offlineLayoutCheck, let link = model.link {
                Text("Frame rate · \(link.frameRate ?? "60 fps")").font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .accessibilityIdentifier("remote.pictureFrameRate")
                    .listRowBackground(Farside.Palette.panel)
            }
            if !offlineLayoutCheck, let status = model.streamQualityStatus {
                Text(status).font(.footnote).foregroundStyle(Farside.Palette.bone)
                    .listRowBackground(Farside.Palette.panel)
            }
        } header: {
            sectionHeader(CommerceLocalization.text("PICTURE_MODE", "Picture mode"))
        }
    }

    private var connectionHealthSection: some View {
        Section {
            let health = sessionHealth
            VStack(alignment: .leading, spacing: 4) {
                Text(health?.title ?? "Nothing wrong observed")
                    .foregroundStyle(Farside.Palette.bone)
                Text(health.map { "\($0.detail) \($0.nextStep)" } ?? healthyRouteSummary)
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote.health")
            .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("Connection")
        }
    }

    @ViewBuilder private var macVitalsSection: some View {
        if !offlineLayoutCheck || model.previewingVitals {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.macVitalsSupported {
                        Text(MacVitalsPresentation.tooOld)
                            .font(.footnote).foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let vitals = model.currentMacVitals() {
                        ForEach(MacVitalsPresentation(vitals).rows, id: \.title) { row in
                            LabeledContent(row.title, value: row.value)
                                .foregroundStyle(Farside.Palette.bone)
                                .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text(MacVitalsPresentation.waiting)
                            .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("remote.vitals")
                .listRowBackground(Farside.Palette.panel)
            } header: {
                sectionHeader("Mac")
            }
        }
    }

    @ViewBuilder private var bigTextSection: some View {
        if model.bigTextSupported {
            Section {
                bigTextOption(title: "Off", caption: "Your Mac's own size", width: nil, id: "remote.bigText.off")
                ForEach(Array(model.bigText.steps.enumerated()), id: \.offset) { index, step in
                    bigTextOption(title: Self.bigTextNames[min(index, Self.bigTextNames.count - 1)],
                                  caption: "looks like \(Int(step.width)) × \(Int(step.height))",
                                  width: step.width, id: "remote.bigText.step.\(index)")
                }
                if model.bigText.steps.isEmpty && model.bigText.baselineWidth != nil {
                    Text("Already at the largest size")
                        .font(.footnote).foregroundStyle(Farside.Palette.ash)
                        .listRowBackground(Farside.Palette.panel)
                }
                if model.bigText.savedWidth != nil {
                    Toggle("Off for this session", isOn: Binding(get: { model.bigText.sessionOff },
                                                                 set: { model.setBigTextOffForSession($0) }))
                        .toggleStyle(FarsideSwitchStyle())
                        .listRowBackground(Farside.Palette.panel)
                        .accessibilityIdentifier("remote.bigText.sessionOff")
                }
            } header: {
                sectionHeader("Big Text")
            } footer: {
                Text("Makes everything on your Mac bigger while this phone is connected. Saved for this Mac.")
                    .foregroundStyle(Farside.Palette.ash)
            }
        }
    }

    private var healthyRouteSummary: String {
        let parts = [model.link?.route.map { $0 == "Relay" ? "Relayed route" : "Direct route" },
                     model.link?.roundTripMs.map { "\($0) ms round trip" }].compactMap { $0 }
        return parts.isEmpty ? "No route measured yet." : parts.joined(separator: " · ")
    }

    private static let bigTextNames = ["Large", "Larger", "Very large", "Largest"]

    private func bigTextOption(title: String, caption: String, width: Double?, id: String) -> some View {
        let selected = model.bigText.savedWidth == width
        return Button { model.chooseBigText(width) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Farside.Palette.bone)
                    Text(caption).farsideCaption()
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Farside.Palette.bone)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
        .listRowBackground(Farside.Palette.panel)
    }

    private var diagnosticsSection: some View {
        Section {
            DiagnosticReportRows(model: model)

            if !offlineLayoutCheck {
                Text(codecDiagnostics)
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .accessibilityIdentifier("remote.codecDiagnostics")
                    .listRowBackground(Farside.Palette.panel)
            }
            if let lastResume = model.lastResume {
                Text("Last return · \(lastResume.summary)")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .accessibilityIdentifier("remote.lastResume")
                    .listRowBackground(Farside.Palette.panel)
            }
            if let percent = model.frameHealthPercent {
                Text("Picture · \(Int(percent.rounded()))% of frames did not reach the picture in the last measured window.")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .listRowBackground(Farside.Palette.panel)
            }
            if let spread = model.roundTripSpreadMs {
                Text("Round-trip variation · \(Int(spread.rounded())) ms")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .listRowBackground(Farside.Palette.panel)
            }
            if let tip = model.wifiStallTip, let extra = tip.secondary(device: UIDevice.current.model) {
                Text(extra).font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .listRowBackground(Farside.Palette.panel)
            }
            SmoothMotionDiagnosticsRows(upscale: $smoothMotionUpscale, showsTestingControls: streamStatsEnabled)
            #if DEBUG
            Toggle("Stream statistics", isOn: $streamStatsEnabled)
                .toggleStyle(FarsideSwitchStyle())
                .listRowBackground(Farside.Palette.panel)
            if streamStatsEnabled {
                Text(DeviceWord.copy("Shows per-stage timing over the picture and records it on this device for export."))
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .listRowBackground(Farside.Palette.panel)
                Toggle("Read bench marker", isOn: $markerReadingEnabled)
                    .toggleStyle(FarsideSwitchStyle())
                    .listRowBackground(Farside.Palette.panel)
                Text("Per-frame latency and legibility from the Mac's bench window. Off keeps the statistics without touching the frame path.")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .listRowBackground(Farside.Palette.panel)
                if let log = StreamDebug.logFileURL {
                    ShareLink(item: log) {
                        Label("Export statistics log", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Farside.Palette.bone)
                    }
                    .listRowBackground(Farside.Palette.panel)
                }
                Toggle("Previous stream tuning", isOn: $legacyStreamTuning)
                    .toggleStyle(FarsideSwitchStyle())
                    .listRowBackground(Farside.Palette.panel)
                Text("For comparison tests. Applies after Farside is closed and reopened.")
                    .font(.footnote).foregroundStyle(Farside.Palette.ash)
                    .listRowBackground(Farside.Palette.panel)
            }
            #endif
        } header: {
            sectionHeader("For testing")
        }
    }

    /// Negotiated level, decoder and the level-5.2 capability probe, e.g.
    /// "H.264 5.2 · hardware decode · hardware level 5.2 (cached)".
    private var codecDiagnostics: String {
        [model.link?.codecLevel, model.link?.frameRate, model.link?.decoder, NativeCodecCapability.outcomeDescription]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder private var macPrivacySection: some View {
        if model.curtainSupported, let state = model.curtainState {
            Section {
                Toggle("Hide Mac screen", isOn: Binding(get: { state.preferenceOn },
                                                        set: { model.setMacCurtain($0) }))
                    .toggleStyle(FarsideSwitchStyle())
                    .disabled(!model.canChangeCurtain)
                    .opacity(model.canChangeCurtain ? 1 : 0.45)
                    .accessibilityIdentifier("remote.macCurtain")
                    .listRowBackground(Farside.Palette.panel)
                if state == .liftedLocally {
                    Button("Hide it again") { model.setMacCurtain(true) }
                        .foregroundStyle(Farside.Palette.bone)
                        .disabled(!model.canChangeCurtain)
                        .listRowBackground(Farside.Palette.panel)
                }
            } header: {
                sectionHeader("Mac privacy")
            } footer: {
                Text(macCurtainFooter(state))
                    .foregroundStyle(Farside.Palette.ash)
            }
        }
    }

    private func macCurtainFooter(_ state: PrivacyCurtainState) -> String {
        switch state {
        case .off: "Off, so anyone at the Mac can watch what you do. On covers its displays while you’re connected; you still see everything here."
        case .pending: "Your Mac covers its screen once the picture is live."
        case .up: "Your Mac’s screen is covered. Anyone at the Mac can press Esc three times to lift it."
        case .liftedLocally: "Someone at your Mac lifted the curtain for this session."
        case .unavailable: "Your Mac needs Accessibility permission for Farside before it can hide its screen."
        case .failed: "Your Mac couldn’t confirm the curtain was hidden from this stream, so its screen stayed visible."
        }
    }

    private var feelSection: some View {
        Section {
            Toggle("Click haptics", isOn: $model.hapticsEnabled)
                .toggleStyle(FarsideSwitchStyle())
                .listRowBackground(Farside.Palette.panel)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pointer speed").foregroundStyle(Farside.Palette.bone)
                Slider(value: $sensitivity, in: 0.5...1.8) {
                    Text("Pointer speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").foregroundStyle(Farside.Palette.ash).accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "hare").foregroundStyle(Farside.Palette.ash).accessibilityHidden(true)
                }
                .tint(Farside.Palette.bone)
                .accessibilityLabel("Pointer sensitivity")
            }
            .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("Feel")
        } footer: {
            Text(DeviceWord.copy("This device draws the Mac pointer at every zoom level, larger when Larger Text is on. An older Mac companion shows its streamed pointer instead. While zoomed in, the picture eases after the pointer near an edge."))
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    private var zoomDescription: String {
        if viewport.zoom == 1 { return viewport.mode == .fill ? "Fill" : "Fit" }
        let magnification = viewport.fitScale > 0 ? viewport.scale / viewport.fitScale : 1
        return String(format: "%.1f×", Double(magnification))
    }

    // MARK: - Behaviour

    private func handle(_ command: NativeGestureCommand) -> Bool {
        noteSessionPillActivity()
        guard !controlsBlockInput, !showVoiceInput, !model.privacyShield, !model.contentConcealed else { return false }
        if stackedPicture && !padTouched { padTouched = true }
        if couch {
            // No picture to look around or aim at.
            switch command {
            case .zoom, .zoomEnded, .zoomToggle, .navigate, .pan, .pointTo, .precision: return false
            default: break
            }
            if !couchTouched { couchTouched = true }
        }
        if command.movesViewport { manualViewportRevision &+= 1 }
        switch command {
        case .precision(let phase, let finger):
            return precisionTap.handle(phase, finger: finger, viewport: viewport, model: model)
        case .zoomToggle(let anchor):
            if FarsideBeta.isEnabled {
                guard panMode else { return false }
                return toggleSmartZoom(at: pictureAnchor(anchor))
            }
            model.pointerLocator.clear()
            pinchRevision &+= 1
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) {
                viewport.toggleZoom(anchoredAt: pictureAnchor(anchor))
            }
            reportSettledViewport()
            showZoomBadge()
            return true
        case .navigate(let factor, let anchor, let translation):
            cancelSmartZoom(clearBookmark: false)
            model.pointerLocator.clear()
            pinchRevision &+= 1
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewport.setZoom(viewport.zoom * factor, anchoredAt: pictureAnchor(anchor))
                viewport.pan(by: translation)
            }
            showZoomBadge()
            return true
        case .zoom(let factor, let anchor):
            cancelSmartZoom(clearBookmark: false)
            model.pointerLocator.clear()
            pinchRevision &+= 1
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewport.setZoom(viewport.zoom * factor, anchoredAt: pictureAnchor(anchor))
            }
            showZoomBadge()
            return true
        case .zoomEnded:
            let endedPinch = pinchRevision
            let endedInputRevision = revision
            let endedModelInputRevision = model.inputRevision
            let endedGeometry = model.geometryEpoch
            DispatchQueue.main.async {
                // A new pinch, cancellation or display change can precede this queued settle.
                guard pinchRevision == endedPinch, revision == endedInputRevision,
                      model.inputRevision == endedModelInputRevision,
                      model.geometryEpoch == endedGeometry, scenePhase == .active,
                      !controlsBlockInput, !showVoiceInput,
                      !model.privacyShield, !model.contentConcealed else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) {
                    _ = viewport.settleZoom()
                }
                reportSettledViewport()
                showZoomBadge()
            }
            return true
        case .pan(let delta):
            cancelSmartZoom(clearBookmark: false)
            model.pointerLocator.clear()
            viewport.pan(by: delta)
            return true
        case .pointTo(let point):
            guard !model.coordinateInputFenced else { return false }
            // Letterbox bands and anything outside the picture have no Mac point: no click there.
            guard let source = DirectTouchMapping.sourcePoint(for: point, in: viewport) else { return false }
            return model.pointTo(source)
        default:
            return model.gesture(command)
        }
    }

    @discardableResult
    private func toggleSmartZoom(at anchor: CGPoint) -> Bool {
        guard smartZoomMayStart, viewport.sourcePoint(fromView: anchor) != nil else { return false }
        cancelSmartZoom(clearBookmark: false)
        let returning = focusReturn.canRestore
        guard let target = focusReturn.destination(from: viewport, anchoredAt: anchor) else { return false }
        return startSmartZoom(to: target, returning: returning)
    }

    private func restoreSmartZoom() {
        guard smartZoomMayStart else { return }
        cancelSmartZoom(clearBookmark: false)
        guard let target = focusReturn.restoreDestination(for: viewport) else { return }
        startSmartZoom(to: target, returning: true)
    }

    private func cancelSmartZoom(clearBookmark: Bool) {
        smartZoomTask?.cancel(); smartZoomTask = nil
        if let token = smartZoomToken { model.finishSmartZoomTransition(token, visible: viewport.visibleSourceRect) }
        smartZoomToken = nil
        if clearBookmark { focusReturn.clear() }
    }

    private var smartZoomMayStart: Bool {
        model.smartZoomStartAllowed(interactionBlocked: controlsBlockInput || showVoiceInput || scenePhase != .active)
    }

    @discardableResult
    private func startSmartZoom(to target: ViewportTransform, returning: Bool) -> Bool {
        guard smartZoomMayStart,
              let token = model.beginSmartZoomTransition(interactionBlocked: controlsBlockInput || showVoiceInput || scenePhase != .active) else { return false }
        let from = viewport
        let required = from.visibleSourceRect.union(target.visibleSourceRect)
        guard model.constrainSmartZoomPresentation(required, generation: token) else {
            model.finishSmartZoomTransition(token, visible: from.visibleSourceRect)
            model.announce("Waiting for more of your Mac’s picture. Try again.")
            return false
        }
        smartZoomToken = token
        pinchRevision &+= 1
        model.pointerLocator.clear()
        let geometry = model.geometryEpoch
        let scope = model.sharedCaptureScope?.epoch
        smartZoomTask = Task { @MainActor in
            // Every exit owns cleanup; an older task may never alter a newer fence/constraint.
            defer {
                model.finishSmartZoomTransition(token, visible: viewport.visibleSourceRect)
                if smartZoomToken == token { smartZoomToken = nil; smartZoomTask = nil }
            }
            // The renderer drains old GPU/presentation flights and then requires this generation's
            // covering original presentation. A cached earlier wide receipt cannot start the camera.
            guard smartZoomStillCurrent(token, geometry: geometry, scope: scope, requiresCoverage: false) else { return }
            var coverage = from
            coverage.fit()
            model.viewportChanged(coverage.captureRequest(displayScale: displayScale), settled: true)
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            while !model.smartZoomPresentationReady(generation: token) {
                guard smartZoomStillCurrent(token, geometry: geometry, scope: scope, requiresCoverage: false),
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    if smartZoomToken == token { model.announce("Waiting for more of your Mac’s picture. Try again.") }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            let start = ProcessInfo.processInfo.systemUptime
            while true {
                guard smartZoomStillCurrent(token, geometry: geometry, scope: scope) else { return }
                let t = reduceMotion ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.36)
                let eased = t * t * (3 - 2 * t)
                guard let sampled = from.interpolated(to: target, progress: CGFloat(eased)) else {
                    focusReturn.clear(); return
                }
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) { viewport = sampled }
                if t >= 1 { break }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            // Scheduling protection only; the endpoint keeps a presentation coverage constraint.
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            guard smartZoomStillCurrent(token, geometry: geometry, scope: scope) else { return }
            if returning { focusReturn.clear() }
            model.finishSmartZoomTransition(token, visible: viewport.visibleSourceRect)
            smartZoomToken = nil; smartZoomTask = nil
            reportSettledViewport(); showZoomBadge()
            model.announce(returning ? "Back to your view" : "Zoomed in. Back to view restores your framing.")
        }
        return true
    }

    private func smartZoomStillCurrent(_ token: UInt64, geometry: UInt64, scope: UInt64?, requiresCoverage: Bool = true) -> Bool {
        !Task.isCancelled && smartZoomToken == token && model.viewportTransitionGeneration == token
            && model.geometryEpoch == geometry && model.sharedCaptureScope?.epoch == scope
            && scenePhase == .active && connection.connected && !controlsBlockInput && !showVoiceInput
            && !model.privacyShield && !model.contentConcealed
            && (!requiresCoverage || model.smartZoomPresentationReady(generation: token))
    }

    private var followUsableRect: CGRect {
        // With Controls open, the pointer stays clear of the panel rather than the dock.
        PointerFollowLayout.usableRect(safeRect: viewport.safeRect, canvasFrame: canvasFrame,
                                       dockFrame: showControls ? panelFrame : dockFrame, topAnchor: regularSessionLayout)
    }

    private var followAllowed: Bool {
        !couch && followStyle.follows && model.canControl && !model.coordinateInputFenced && !keyboardOpen && !controlsBlockInput && !panMode
            && !model.privacyShield && !model.contentConcealed
    }

    private func follow(_ point: CGPoint) {
        // D34 amendment: follow also applies while a click is held. Then the margin only catches a
        // pointer pushed past the edge band; the band itself belongs to drag auto-pan.
        guard followAllowed else { return }
        let margin = model.dragging ? DragAutoPan.revealMargin : followStyle.margin
        withAnimation(followStyle.animation(reduceMotion: reduceMotion)) {
            _ = viewport.reveal(sourcePoint: point, in: followUsableRect, margin: margin)
        }
    }

    /// While a click is held, a pointer resting in the edge band scrolls the picture toward that
    /// edge. The pointer keeps its screen position and the Mac pointer moves to the source point
    /// now under it, so what is dropped lands where it is drawn.
    private func runDragAutoPan() async {
        guard model.dragging else { return }
        var last = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled, model.dragging {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            let dt = now - last
            last = now
            guard followAllowed, model.absolutePointerSupported,
                  let pointer = model.pointerOverlay.displayedPoint else { continue }
            var next = viewport
            guard let source = DragAutoPan.step(&next, pointerSource: pointer, usable: followUsableRect, dt: dt),
                  model.pointTo(source) else { continue }
            viewport = next
            SmoothMotionController.note(.autoPan)
        }
    }

    private func showZoomBadge() {
        zoomBadge = zoomDescription
        zoomBadgeToken &+= 1
    }

    // MARK: - Mini map

    /// On by default on iPad; an option on iPhone, in landscape only.
    private var miniMapSetting: Bool {
        if UIDevice.current.userInterfaceIdiom == .pad { return miniMapPad }
        return miniMapPhone && compactHeight
    }

    private var miniMapEligible: Bool {
        !couch && miniMapSetting && viewport.isCropped && controlsCollapsed && !keyboardOpen && !showControls
            && !showVoiceInput && !model.privacyShield && !model.contentConcealed && !lockVisible
    }

    private var miniMapMotion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.easeOut(Farside.Motion.standard)
    }

    private func pokeMiniMap() {
        var next = miniMap
        let restart = next.viewportChanged(eligible: miniMapEligible)
        guard next != miniMap else {
            if restart { miniMapToken &+= 1 }
            return
        }
        withAnimation(miniMapMotion) { miniMap = next }
        if restart { miniMapToken &+= 1 }
    }

    private var miniMapSize: CGSize {
        UIDevice.current.userInterfaceIdiom == .pad ? CGSize(width: 220, height: 150) : CGSize(width: 150, height: 96)
    }

    private var sessionMiniMap: some View {
        MiniMapPointerSource(model: model.pointerOverlay, viewport: viewport) { pointer, current in
            MiniMapView(viewport: current, pointer: pointer, maxSize: miniMapSize, thumbnail: miniMapThumbnail,
                        onPan: { translation in
                            cancelSmartZoom(clearBookmark: false)
                            model.pointerLocator.clear()
                            viewport.pan(by: translation)
                            #if DEBUG
                            let visible = viewport.visibleSourceRect
                            model.inputProbe?.note(String(format: "minimap pan %.1f %.1f to %.0f %.0f", translation.width,
                                                          translation.height, visible.midX, visible.midY))
                            #endif
                        },
                        onJump: { point in
                            cancelSmartZoom(clearBookmark: false)
                            model.pointerLocator.clear()
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0)) {
                                viewport.center(onSourcePoint: point)
                            }
                            #if DEBUG
                            model.inputProbe?.note(String(format: "minimap jump %.0f %.0f", point.x, point.y))
                            #endif
                        },
                        onTouch: { active in
                            if miniMap.touch(active, eligible: miniMapEligible) { miniMapToken &+= 1 }
                            if !active { reportSettledViewport() }
                            #if DEBUG
                            model.inputProbe?.note("minimap touch \(active)")
                            if !active, model.inputProbe != nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    let visible = viewport.visibleSourceRect
                                    model.inputProbe?.note(String(format: "minimap settled %.0f %.0f", visible.midX, visible.midY))
                                }
                            }
                            #endif
                        },
                        onShowAll: { setMode(.fit) })
        }
        .sensoryFeedback(.selection, trigger: miniMap.touching) { _, touching in touching }
    }

    @ViewBuilder private func miniMapThumbnail(_ size: CGSize) -> some View {
        if let track = connection.remoteVideo, !model.contentConcealed, let region = model.picturePlacementRegion {
            let placement = ViewportTransform.placement(of: region.rect, displaySize: model.sourceSize,
                                                        in: CGRect(origin: .zero, size: size))
            ZStack(alignment: .topLeading) {
                Farside.Palette.void2
                MiniMapVideo(track: track, admission: model.inlinePresentationAdmission)
                    .frame(width: placement.width, height: placement.height)
                    .offset(x: placement.minX, y: placement.minY)
            }
        } else if let track = connection.remoteVideo, !model.contentConcealed {
            MiniMapVideo(track: track, admission: model.inlinePresentationAdmission)
        } else if offlineLayoutCheck {
            DesktopPreview(size: model.sourceSize)
                .scaleEffect(size.width / max(model.sourceSize.width, 1), anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            Farside.Palette.void2
        }
    }

    private func scheduleGeometry() {
        guard !geometryPending else { return }
        geometryPending = true
        let generation = model.workspaceMeasurementGeneration
        DispatchQueue.main.async {
            geometryPending = false
            guard generation == model.workspaceMeasurementGeneration else { scheduleGeometry(); return }
            applyGeometry()
        }
    }

    /// Rotation, iPad resizing and new source sizes remap the viewport; the keyboard and
    /// other bottom obstructions only change the safe insets.
    private func applyGeometry() {
        guard canvasFrame.width > 0, canvasFrame.height > 0, safeFrame.width > 0, safeFrame.height > 0 else { return }
        let nextStacked = !couch && SessionWindowLayout.stacked(regular: regularSessionLayout,
            window: canvasFrame.size, source: workspaceLayoutSource, wasStacked: stackedPicture)
        if nextStacked != stackedPicture {
            withAnimation(reduceMotion ? nil : Farside.Motion.windowLayout) {
                stackedPicture = nextStacked
                padTouched = false
            }
        }
        let size = SessionWindowLayout.pictureSize(window: canvasFrame.size, source: workspaceLayoutSource, stacked: nextStacked)
        let picture = CGRect(origin: canvasFrame.origin, size: size)
        let measuredUsable = IPadWorkspaceGeometry.usableRect(picture: picture,
            safe: safeFrame, topChrome: topChromeFrame,
            bottomChrome: !regularSessionLayout && !keyboardOpen ? dockFrame : .zero,
            keyboardDock: keyboardBarFrame, keyboardOpen: keyboardOpen && !sessionHardwareKeyboard, scale: displayScale)
        var draftGeometry = workspaceDraftGeometry
        let usable = draftGeometry.update(picture: picture, safe: safeFrame, scale: displayScale,
            measured: measuredUsable, hardwareKeyboard: model.workspaceDeviceEligible && sessionHardwareKeyboard,
            keyboardOpen: keyboardOpen)
        if model.workspaceDeviceEligible, draftGeometry != workspaceDraftGeometry { workspaceDraftGeometry = draftGeometry }
        let keyboardBottom = SessionChromePolicy.keyboardBottom(regular: regularSessionLayout, stacked: nextStacked,
            couch: couch, keyboardOpen: keyboardOpen, barFrame: keyboardBarFrame, canvas: canvasFrame)
        // The keyboard takes space from the pad; the top Fit picture stays fixed.
        var insets = nextStacked ? ViewportInsets.zero : ViewportInsets(top: max(0, safeFrame.minY - canvasFrame.minY),
                                    left: max(0, safeFrame.minX - canvasFrame.minX),
                                    bottom: max(keyboardBottom, max(0, canvasFrame.maxY - safeFrame.maxY)),
                                    right: max(0, canvasFrame.maxX - safeFrame.maxX))
        if model.virtualDisplayActive, let usable {
            insets = ViewportInsets(top: usable.minY - canvasFrame.minY, left: usable.minX - canvasFrame.minX,
                bottom: canvasFrame.minY + size.height - usable.maxY, right: canvasFrame.minX + size.width - usable.maxX)
        }
        if viewport.canvasSize != size || viewport.sourceSize != model.sourceSize {
            cancelGesture()
            viewport.resize(sourceSize: model.sourceSize, canvasSize: size, safeInsets: insets)
        } else if viewport.safeInsets != insets {
            cancelSmartZoom(clearBookmark: true)
            if model.virtualDisplayActive { cancelGesture() }
            withAnimation(reduceMotion ? nil : .snappy) { viewport.updateSafeInsets(insets) }
        }
        if model.workspaceDeviceEligible {
            model.workspaceGeometryApplied(source: viewport.sourceSize, generation: model.workspaceMeasurementGeneration)
            let fps = UIApplication.shared.connectedScenes.compactMap { scene -> Int? in
                guard scene.activationState == .foregroundActive, let windowScene = scene as? UIWindowScene,
                      windowScene.screen.scale == displayScale else { return nil }
                return windowScene.screen.maximumFramesPerSecond
            }.min() ?? 60
            model.virtualDisplayViewportChanged(size: usable?.size ?? .zero, scale: displayScale, maximumFPS: fps,
                                                generation: model.workspaceMeasurementGeneration)
        }
    }

    private func pictureAnchor(_ point: CGPoint) -> CGPoint {
        stackedPicture ? SessionWindowLayout.zoomAnchor(point, picture: pictureSize) : point
    }

    /// Only a view of the display the model is streaming counts; a stale canvas mid-resize does not.
    private var recordableViewport: ResumeViewport? {
        guard !offlineLayoutCheck, viewport.sourceSize == model.sourceSize, viewport.canvasSize.width > 0 else { return nil }
        return viewport.resumeViewport(viewOnly: panMode)
    }

    private func applyResume(_ resume: ResumeViewport) {
        model.viewportResumeApplied()
        guard !offlineLayoutCheck else { return }
        if viewport.sourceSize != model.sourceSize { applyGeometry() }
        guard viewport.sourceSize == model.sourceSize, viewport.canvasSize.width > 0 else { return }
        if let current = recordableViewport, current.matches(resume) { return }
        cancelGesture()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) { viewport.restore(resume) }
        setInteractionMode(resume.viewOnly)
        reportSettledViewport()
        model.announce("Back where you left off")
    }

    private func setMode(_ mode: ViewportMode) {
        guard !FarsideBeta.isEnabled || smartZoomMayStart else { return }
        cancelSmartZoom(clearBookmark: true)
        guard mode != viewport.mode || !viewport.isAtBaseline else { return }
        cancelGesture()
        if FarsideBeta.isEnabled {
            var target = viewport
            target.setMode(mode)
            startSmartZoom(to: target, returning: false)
        } else {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) { viewport.setMode(mode) }
            reportSettledViewport()
            showZoomBadge()
        }
    }

    /// A gesture or a jump has ended, so the Mac hears about the new viewport at once.
    private func reportSettledViewport() {
        model.viewportChanged(viewport.captureRequest(displayScale: displayScale), settled: true)
    }

    private func toggleMode() { setMode(viewport.mode.toggled) }

    private func setInteractionMode(_ viewMode: Bool) {
        guard panMode != viewMode else { return }
        cancelGesture()
        model.pointerLocator.clear()
        withAnimation(reduceMotion ? nil : .snappy) { panMode = viewMode }
    }

    private func recordChromeHitProbe(_ action: String) {
        #if DEBUG
        guard offlineLayoutCheck, LaunchOptions.has("--ui-keyboard-hit-probe") else { return }
        NSLog("%@", "[B7 chromeHit] \(action) regular=\(regularSessionLayout) couch=\(couch) collapsed=\(controlsCollapsed) controls=\(showControls) keyboard=\(keyboardOpen) voiceLocked=\(voiceLocked)")
        #endif
    }

    private func cancelGesture() {
        cancelSmartZoom(clearBookmark: true)
        pinchRevision &+= 1
        model.cancelInput()
        revision &+= 1
    }

    private func revealControls() {
        recordChromeHitProbe("reveal dock")
        guard controlsCollapsed else { return }
        cancelGesture()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.sheetSpring) { controlsCollapsed = false }
    }

    private func collapseControls() {
        recordChromeHitProbe("collapse dock")
        guard (!couch || regularSessionLayout), !controlsCollapsed, !voiceLocked else { return }
        cancelGesture()
        if showVoiceInput { cancelVoiceInput() }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.sheetSpring) {
            controlsCollapsed = true
            showClipboardRow = false
        }
    }

    private func openKeyboard() {
        recordChromeHitProbe("open keyboard")
        cancelGesture()
        if showVoiceInput {
            guard !voiceLocked else { return }
            cancelVoiceInput()
        }
        keyboardOpen = true
    }

    private func closeKeyboard() {
        recordChromeHitProbe("close keyboard")
        dismissedAutoKeyboardRevision = model.autoKeyboardRevision
        cancelGesture()
        keyboardOpen = false
    }
}

/// Geometry is measured in the scene's coordinates. Align the usable rectangle inward before
/// proposing a raster, so neither the host nor encoder rounds a negotiated workspace afterward.
enum IPadWorkspaceGeometry {
    /// Deliberate hardware-keyboard composition is local chrome, not a Mac workspace resize.
    /// A different window/picture/safe rectangle or display scale always replaces the hold.
    struct DraftGeometry: Equatable {
        private var picture: CGRect = .zero
        private var safe: CGRect = .zero
        private var scale: CGFloat = 0
        private var usable: CGRect?
        private var hardwareKeyboard = false

        mutating func update(picture: CGRect, safe: CGRect, scale: CGFloat, measured: CGRect?,
                             hardwareKeyboard: Bool, keyboardOpen: Bool) -> CGRect? {
            let attachingKeyboard = hardwareKeyboard && !self.hardwareKeyboard
            self.hardwareKeyboard = hardwareKeyboard
            if hardwareKeyboard && keyboardOpen && !attachingKeyboard,
               self.picture == picture, self.safe == safe, self.scale == scale, let usable {
                return usable
            }
            self.picture = picture; self.safe = safe; self.scale = scale; usable = measured
            return measured
        }
    }

    static func mayOpenAutomaticDraft(isPad: Bool, hardwareKeyboard: Bool) -> Bool {
        !(isPad && hardwareKeyboard)
    }

    /// A virtual source aspect must not feed back into the shipping picture/pad split.
    static func layoutSource(current: CGSize, reference: CGSize?, active: Bool) -> CGSize {
        active ? reference ?? current : current
    }

    static func usableRect(picture: CGRect, safe: CGRect, topChrome: CGRect, bottomChrome: CGRect,
                           keyboardDock: CGRect, keyboardOpen: Bool, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, (1...3).contains(scale), valid(picture), valid(safe) else { return nil }
        var usable = picture.intersection(safe)
        guard valid(usable) else { return nil }
        if valid(topChrome), usable.intersects(topChrome) {
            let bottom = usable.maxY
            usable.origin.y = max(usable.minY, topChrome.maxY)
            usable.size.height = bottom - usable.minY
        }
        for obstruction in [bottomChrome, keyboardOpen ? keyboardDock : .zero] {
            if valid(obstruction), usable.intersects(obstruction) {
                usable.size.height = min(usable.maxY, obstruction.minY) - usable.minY
            }
        }
        guard valid(usable) else { return nil }
        let left = ceil((usable.minX - picture.minX) * scale / 2) * 2
        let top = ceil((usable.minY - picture.minY) * scale / 2) * 2
        let right = floor((usable.maxX - picture.minX) * scale / 2) * 2
        let bottom = floor((usable.maxY - picture.minY) * scale / 2) * 2
        guard right > left, bottom > top else { return nil }
        return CGRect(x: picture.minX + left / scale, y: picture.minY + top / scale,
                      width: (right - left) / scale, height: (bottom - top) / scale)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0
    }
}

#if DEBUG
private struct QuietInputProbe: View {
    @ObservedObject var probe: InputProbe

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("remote.inputProbe")
            .accessibilityLabel("Input probe")
            .accessibilityValue(probe.entries.joined(separator: " | "))
    }
}
#endif

/// Keeps automatic pointer follow above the dock without reserving permanent
/// screen space when the controls are collapsed.
enum PointerFollowLayout {
    static func usableRect(safeRect: CGRect, canvasFrame: CGRect, dockFrame: CGRect, topAnchor: Bool = false) -> CGRect {
        if topAnchor {
            let top = dockFrame.height > 0 && canvasFrame.intersects(dockFrame)
                ? min(safeRect.maxY - 1, max(safeRect.minY, dockFrame.maxY - canvasFrame.minY + 12))
                : safeRect.minY
            return CGRect(x: safeRect.minX, y: top, width: safeRect.width, height: max(1, safeRect.maxY - top))
        }
        let measuredTop = dockFrame.minY - canvasFrame.minY - 12
        let bottom = dockFrame.height > 0 && canvasFrame.intersects(dockFrame) &&
            measuredTop > safeRect.minY
            ? min(safeRect.maxY, measuredTop)
            : safeRect.maxY - 34
        return CGRect(x: safeRect.minX, y: safeRect.minY,
                      width: safeRect.width, height: max(1, bottom - safeRect.minY))
    }
}

/// Regular-window chrome is a real Button for keyboard navigation; its status/actions share
/// one top plate. It accepts taps only, keeping the system's top-edge gestures unclaimed.
private struct SessionPill: View {
    let macName: String
    let caption: String
    let live: Bool
    let liveState: LiveDot.State
    let collapsed: Bool
    let expandedDock: Bool
    let reconnecting: Bool
    let back: String?
    let busy: BusyPresentation?
    let bigText: String?
    let notice: String?
    let noticeID: String
    let viewOnly: Bool
    let canReturnToControl: Bool
    let toggle: () -> Void
    let keyboard: () -> Void
    let end: () -> Void
    let control: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasState: Bool { reconnecting || back != nil || busy != nil || bigText != nil || notice != nil || viewOnly }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Group {
                        if collapsed {
                            HandleDots(live: live)
                        } else {
                            HStack(spacing: 7) {
                                LiveDot(state: liveState, size: 7)
                                if !hasState { Text(caption).lineLimit(1).minimumScaleFactor(0.8) }
                                else { stateCaption }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    .frame(height: PhoneCommandAccessibility.target(dynamicTypeSize.isAccessibilitySize ? 36 : 28,
                                                                  enabled: PhoneCommandAccessibility.targetsEnabled))
                    .frame(minWidth: PhoneCommandAccessibility.target(42, enabled: PhoneCommandAccessibility.targetsEnabled))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .highPriorityGesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { result in
                    switch result {
                    case .first: keyboard()
                    case .second: toggle()
                    }
                })
                .accessibilityIdentifier(primaryIdentifier)
                .accessibilityLabel(expandedDock ? "Hide controls" : "Show controls")
                .accessibilityValue(spokenStatus)
                .accessibilityHint("Tap for controls. Double-tap to type.")
                .accessibilityAction(named: Text("Show keyboard")) { keyboard() }
                if reconnecting {
                    Button("End", action: end)
                        .buttonStyle(FarsideEndButtonStyle(height: PhoneCommandAccessibility.target(24, enabled: PhoneCommandAccessibility.targetsEnabled)))
                        .fixedSize()
                        .accessibilityLabel("End session")
                        .padding(.trailing, 4)
                } else if canReturnToControl {
                    Button("Control", action: control)
                        .buttonStyle(FarsidePrimaryButtonStyle(height: PhoneCommandAccessibility.target(24, enabled: PhoneCommandAccessibility.targetsEnabled)))
                        .fixedSize()
                        .accessibilityLabel("Control desktop")
                        .padding(.trailing, 4)
                }
            }
            // Simultaneous states must stay visible too (for example busy during a Big Text change).
            if reconnecting, let back { status(back, id: "remote.back") }
            if let busy, reconnecting || back != nil { status(busy.title, id: "remote.macBusy", spoken: busy.accessibilityLabel) }
            if let bigText, reconnecting || back != nil || busy != nil { status(bigText, id: "remote.bigText.pill") }
            if let notice, reconnecting || back != nil || busy != nil || bigText != nil { status(notice, id: noticeID) }
            if viewOnly && (reconnecting || back != nil || busy != nil || bigText != nil || notice != nil) {
                status("View only", id: "remote.viewOnly")
            }
        }
        .font(Farside.Typeface.caption(.footnote))
        .foregroundStyle(Farside.Palette.bone)
        .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.void.opacity(0.92), stroke: Farside.Palette.line2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.session.pill")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }

    private var spokenStatus: String {
        if reconnecting { return "Reconnecting to \(macName)…" }
        if let back { return back }
        if let busy { return busy.accessibilityLabel }
        if let bigText { return bigText }
        if let notice { return notice }
        return viewOnly ? "\(caption) · View only" : caption
    }

    private var primaryIdentifier: String {
        if reconnecting { return "remote.reconnecting" }
        if back != nil { return "remote.back" }
        if busy != nil { return "remote.macBusy" }
        if bigText != nil { return "remote.bigText.pill" }
        if notice != nil { return noticeID }
        return viewOnly ? "remote.viewOnly" : "remote.session.pill.toggle"
    }

    @ViewBuilder private var stateCaption: some View {
        if reconnecting { status("Reconnecting to \(macName)…", id: "remote.reconnecting") }
        else if let back { status(back, id: "remote.back") }
        else if let busy { status([busy.title, busy.detail].compactMap { $0 }.joined(separator: " · "), id: "remote.macBusy", spoken: busy.accessibilityLabel) }
        else if let bigText { status(bigText, id: "remote.bigText.pill") }
        else if let notice { status(notice, id: noticeID) }
        else { status("\(caption) · View only", id: "remote.viewOnly") }
    }

    private func status(_ text: String, id: String, spoken: String? = nil) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(spoken ?? text)
            .accessibilityIdentifier(id)
    }
}

/// The resting dock handle: five dots on a small void plate; the middle one is ember while live.
private struct HandleDots: View {
    let live: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index == 2 && live ? Farside.Palette.ember : Farside.Palette.bone)
                    .frame(width: 5, height: 5)
                    .shadow(color: index == 2 && live ? Farside.Palette.ember.opacity(0.8) : .clear, radius: 3)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Farside.Palette.void.opacity(0.72), in: .capsule)
        .overlay(Capsule().strokeBorder(Farside.Palette.line2, lineWidth: 1))
    }
}

/// A faint band of bone dots along the dock's top edge, so it reads as a sheet without a heavy shadow.
private struct DotBand: View {
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            let pitch: CGFloat = 6
            for y in stride(from: pitch / 2, to: size.height, by: pitch) {
                let fade = 1 - y / size.height
                let radius = 1.1 * fade
                guard radius > 0.2 else { continue }
                for x in stride(from: pitch / 2, to: size.width, by: pitch) {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
            context.fill(dots, with: .color(Farside.Palette.bone.opacity(0.14)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Six dotted ember bars that breathe while the microphone is listening.
private struct DotWaveform: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let heights: [CGFloat] = [0.36, 0.76, 0.52, 1, 0.42, 0.64]
                for (index, base) in heights.enumerated() {
                    let wobble = active && !reduceMotion ? 0.55 + 0.45 * abs(sin(time * 3 + Double(index) * 0.9)) : 1
                    let height = size.height * base * CGFloat(wobble)
                    let x = CGFloat(index) * 7 + 2
                    var y = (size.height - height) / 2
                    while y < (size.height + height) / 2 {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y, width: 3.2, height: 3.2)),
                                     with: .color(active ? Farside.Palette.ember : Farside.Palette.dim))
                        y += 5
                    }
                }
            }
        }
        .frame(width: 42, height: 36)
        .accessibilityHidden(true)
    }
}

/// At accessibility sizes the value goes under the title so neither breaks mid-word or truncates.
private struct SettingsSummaryLabel: View {
    let title: String
    let symbol: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(Farside.Palette.bone)
                if !value.isEmpty {
                    Text(value).foregroundStyle(Farside.Palette.ash)
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Farside.Palette.bone)
                Spacer(minLength: 8)
                if !value.isEmpty {
                    Text(value)
                        .foregroundStyle(Farside.Palette.ash)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A key in the Controls panel: a quiet plate that darkens while pressed.
private struct ControlsKeyStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, compact: compact)
    }

    private struct KeyBody: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: compact ? 66 : 92)
                .background(configuration.isPressed ? Farside.Palette.panel2 : Farside.Palette.panel,
                            in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Farside.Palette.line, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect)
        }
    }
}

/// The one action in the Hold click chip: a small bone key, not a pill.
private struct DropButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Farside.Palette.ink)
            .padding(.horizontal, 18)
            .frame(minHeight: PhoneCommandAccessibility.target(42, enabled: PhoneCommandAccessibility.targetsEnabled))
            .background(Farside.Palette.bone.opacity(configuration.isPressed ? 0.82 : 1),
                        in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
    }
}

/// Bone track with a void knob when on; a quiet plate when off.
struct FarsideSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label.foregroundStyle(Farside.Palette.bone)
                Spacer(minLength: 12)
                Capsule()
                    .fill(configuration.isOn ? Farside.Palette.bone : Farside.Palette.panel2)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Farside.Palette.line2, lineWidth: 1))
                    .frame(width: 50, height: 30)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Farside.Palette.ink : Farside.Palette.ash)
                            .frame(width: 24, height: 24)
                            .padding(3)
                    }
                    .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
