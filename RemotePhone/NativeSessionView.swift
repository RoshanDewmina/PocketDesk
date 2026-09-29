import SwiftUI

/// Full-bleed remote desktop. The Mac picture stays crisp in its Metal renderer; the only
/// resting chrome is the dock handle. This view owns low-frequency chrome and viewport state.
struct NativeSessionView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    let offlineLayoutCheck: Bool

    @State private var viewport = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                                    canvasSize: .zero, mode: ViewportPreference.stored())
    @State private var canvasFrame: CGRect = .zero
    @State private var safeFrame: CGRect = .zero
    @State private var dockFrame: CGRect = .zero
    @State private var geometryPending = false
    @State private var controlsCollapsed = true
    @State private var keyboardOpen = false
    @State private var dismissedAutoKeyboardRevision: UInt64 = 0
    @State private var autoKeyboardPreviewEmitted = false
    @State private var showControls = false
    @State private var showVoiceInput = false
    @State private var showClipboardRow = false
    @State private var primingMicrophone = false
    @State private var dockHintVisible = false
    @State private var lockVisible = false
    @StateObject private var voiceInput = VoiceInputController()
    @State private var panMode = false
    @State private var clickAcknowledged = false
    @State private var zoomBadge: String?
    @State private var zoomBadgeToken = 0
    @State private var revision: UInt64 = 0
    @AppStorage("pointerSensitivity") private var sensitivity = 1.0
    @AppStorage(PointerSizePreference.key) private var pointerSize: PointerSizePreference = .medium
    @AppStorage(StreamDebug.defaultsKey) private var streamStatsEnabled = false
    @AppStorage(StreamTuning.legacyDefaultsKey) private var legacyStreamTuning = false
    @AppStorage("dockHintSessions") private var dockHintSessions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            stage.ignoresSafeArea()
            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    safeFrame = frame
                    scheduleGeometry()
                }
            centerNotices
        }
        .overlay {
            if !controlsCollapsed && !keyboardOpen {
                FarsideDotScreen()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { topPills }
        .overlay(alignment: .bottom) {
            if !keyboardOpen {
                dock.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dockFrame = $0 }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardOpen { keyboardBar }
        }
        .overlay {
            if model.privacyShield { privacyShield }
        }
        .background(Farside.Palette.void.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .vertical)
        .sheet(isPresented: $showControls) { controlsSheet }
        .fullScreenCover(isPresented: $primingMicrophone) {
            PermissionPrimingView(kind: .microphone) {
                primingMicrophone = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openVoiceInput() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelVoiceInput() }
            else if phase == .inactive && voiceInput.phase != .requestingPermission {
                voiceInput.pauseForInterruption()
            }
        }
        .onChange(of: connection.connected) { _, connected in
            if !connected { cancelVoiceInput() }
            if !offlineLayoutCheck && !model.fresh { lockVisible = true }
        }
        .onChange(of: model.contentConcealed) { _, concealed in if concealed { cancelVoiceInput() } }
        .onChange(of: model.privacyShield) { _, shielded in
            if shielded && voiceInput.phase != .requestingPermission { voiceInput.pauseForInterruption() }
        }
        .onChange(of: model.canControl) { _, allowed in
            if !allowed && voiceInput.phase == .listening { voiceInput.pauseForInterruption() }
        }
        .onChange(of: model.autoKeyboardRevision) { _, value in
            guard value > dismissedAutoKeyboardRevision, !keyboardOpen, !panMode,
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
        .sensoryFeedback(.selection, trigger: viewport.mode)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: controlsCollapsed)
        .sensoryFeedback(trigger: model.dragging) { _, holding in
            holding ? .impact(weight: .medium) : .impact(weight: .light)
        }
        .sensoryFeedback(trigger: voiceInput.phase) { old, new in
            if new == .listening { return .start }
            return old == .listening && new != .listening ? .stop : nil
        }
        .onChange(of: viewport.mode) { _, mode in ViewportPreference.store(mode) }
        .onChange(of: model.sourceSize) { _, _ in scheduleGeometry() }
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
            if offlineLayoutCheck && LaunchOptions.has("--ui-keyboard-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { keyboardOpen = true }
            }
            if offlineLayoutCheck && LaunchOptions.has("--ui-controls-check") { showControls = true }
            if offlineLayoutCheck && LaunchOptions.has("--ui-dock-open") { controlsCollapsed = false }
            if offlineLayoutCheck && LaunchOptions.has("--ui-clipboard-row") {
                controlsCollapsed = false
                showClipboardRow = true
            }
            #endif
        }
        .onDisappear { model.cancelInput(); cancelVoiceInput() }
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

    /// Layers, bottom to top: the Mac picture, the pre-first-frame lock, then the input surface.
    /// Alternative input modes replace `inputSurface`; chrome lives in the overlays above `stage`.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            videoLayer
            if lockVisible {
                ResolutionLockView(connected: connection.connected || offlineLayoutCheck, pictureReady: model.fresh,
                                   fixedStage: LaunchOptions.value("--ui-lock-stage=").flatMap(Int.init)) {
                    lockVisible = false
                }
                .transition(.opacity)
            }
            inputSurface
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            canvasFrame = frame
            scheduleGeometry()
        }
        .onReceive(model.pointerLocator.followUpdates, perform: follow)
        .onReceive(model.pointerOverlay.followUpdates, perform: follow)
        .privacySensitive()
    }

    private var inputSurface: some View {
            NativeTrackpadSurface(enabled: model.canControl && !panMode && !showControls && !showVoiceInput, panMode: panMode,
                                  revision: model.inputRevision &+ revision, sensitivity: CGFloat(sensitivity),
                                  pointerScale: viewport.scale, doubleClickInterval: model.doubleClickInterval,
                                  onCommand: handle,
                                  onPointerMotionEnded: { model.pointerLocator.stopFollowing() })
                .accessibilityIdentifier("remote.canvas")
                .allowsHitTesting(!showControls && !showVoiceInput && !model.privacyShield && !model.contentConcealed)
    }

    private var videoLayer: some View {
        ZStack(alignment: .topLeading) {
            Farside.Palette.void
            let rect = viewport.contentRect
            if let track = connection.remoteVideo, !model.contentConcealed {
                RemoteVideoSurface(track: track, counters: connection.media?.counters, onFrame: model.frameReceived)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            } else if offlineLayoutCheck {
                DesktopPreview(size: model.sourceSize)
                    .scaleEffect(viewport.scale, anchor: .topLeading)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .position(x: rect.midX, y: rect.midY)
            }
            PointerOverlayView(model: model.pointerOverlay, viewport: viewport, size: pointerSize)
            PointerAccentView(model: model.pointerOverlay, viewport: viewport, size: pointerSize,
                              acceptedClicks: model.acceptedClicks,
                              clickKind: ContactRipple.Kind(action: model.lastAcceptedClick), holding: model.dragging,
                              preview: offlineLayoutCheck && LaunchOptions.has("--ui-pointer-accent-preview"))
            #if DEBUG
            if offlineLayoutCheck && LaunchOptions.has("--ui-pointer-gallery") {
                PointerGlyphGallery(size: pointerSize)
            }
            #endif
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var centerNotices: some View {
        if !offlineLayoutCheck && model.hostPresence == .displayAsleep {
            VStack(spacing: Farside.Space.s) {
                Label("Your Mac’s display is asleep", systemImage: "moon.zzz")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                if model.canWakeDisplay {
                    Button("Wake display", action: model.wakeMacDisplay)
                        .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
                        .fixedSize()
                        .accessibilityHint("Turns your Mac’s display back on")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
        } else if (!offlineLayoutCheck && model.fresh && !model.captureHealthy) || LaunchOptions.has("--ui-issue-sharing") {
            SessionIssueCard(error: .screenSharingOff)
                .allowsHitTesting(false)
        } else if !offlineLayoutCheck && !model.fresh && !lockVisible {
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
            if (!offlineLayoutCheck && !connection.connected) || LaunchOptions.has("--ui-reconnecting") {
                ReconnectPill(macName: macName, end: model.disconnect)
                    .transition(.opacity)
            }
            if streamStatsEnabled && !model.streamSummaryLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.streamSummaryLines.enumerated()), id: \.offset) { _, line in
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
            if panMode {
                HStack(spacing: 10) {
                    Image(systemName: "hand.draw").accessibilityHidden(true)
                    Text("View · drag or pinch").font(.subheadline.weight(.medium))
                    Button("Control") { setInteractionMode(false) }
                        .buttonStyle(FarsidePrimaryButtonStyle(height: 34))
                        .fixedSize()
                        .accessibilityLabel("Control desktop")
                }
                .foregroundStyle(Farside.Palette.bone)
                .padding(.leading, 16).padding(.trailing, 5).padding(.vertical, 5)
                .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                .transition(.opacity)
            }
            clipboardStatus
            if let notice = model.sessionNotice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if let zoomBadge {
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
        .padding(.top, 8)
    }

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

    // MARK: - Dock

    private var dock: some View {
        VStack(spacing: 10) {
            if controlsCollapsed {
                if model.dragging { releaseChip.transition(.opacity) }
                if dockHintVisible && !model.dragging {
                    Text("Swipe up for controls · double tap to type")
                        .farsideCaption(Farside.Palette.bone)
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
        .padding(.bottom, controlsCollapsed ? 0 : 6)
        .frame(maxWidth: compactHeight ? 620 : 560)
    }

    private var compactHeight: Bool { verticalSizeClass == .compact }

    private var dockPanel: some View {
        VStack(spacing: compactHeight ? 10 : 14) {
            grabHandle
            tilesRow
            if showVoiceInput {
                dictationRow
            } else if showClipboardRow {
                clipboardRow
            }
            if !compactHeight || !(showVoiceInput || showClipboardRow) {
                segmentsRow
            }
            dockFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
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
    }

    private var grabHandle: some View {
        let taps = TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
        return Capsule()
            .fill(Farside.Palette.dim)
            .frame(width: 40, height: 5)
            .frame(width: 120, height: 26)
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

    private var tilesRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { openKeyboard() } label: { Label("Keys", systemImage: "keyboard") }
                .buttonStyle(FarsideTileButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Keyboard")
            micOrReleaseTile.frame(maxWidth: .infinity)
            Button(action: toggleClipboardRow) { Label("Clip", systemImage: "list.clipboard") }
                .buttonStyle(FarsideTileButtonStyle(selected: showClipboardRow))
                .frame(maxWidth: .infinity)
                .disabled(!showsClipboard || showVoiceInput)
                .accessibilityLabel("Clipboard")
                .accessibilityHint(showsClipboard ? "Paste to or copy from your Mac" : "Clipboard needs the updated Farside on your Mac")
            Button { toggleMode() } label: {
                Label("Fit", systemImage: viewport.mode == .fill ? "arrow.down.right.and.arrow.up.left"
                                                                 : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(FarsideTileButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityLabel(viewport.mode == .fill ? "Fit whole display" : "Fill screen")
            Button { setInteractionMode(!panMode) } label: {
                Label("Mode", systemImage: panMode ? "cursorarrow.motionlines" : "hand.draw")
            }
            .buttonStyle(FarsideTileButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityLabel(panMode ? "Control desktop" : "Move view")
        }
    }

    @ViewBuilder private var micOrReleaseTile: some View {
        if model.dragging {
            Button { model.cancelInput() } label: { Label("Release", systemImage: "hand.raised.fill") }
                .buttonStyle(FarsideTileButtonStyle(emphasized: true))
                .accessibilityLabel("Release")
                .accessibilityHint("Drops the held item on your Mac")
        } else if showVoiceInput {
            Button { cancelVoiceInput() } label: { Label("Mic", systemImage: "waveform") }
                .buttonStyle(FarsideTileButtonStyle(on: voiceInput.phase == .listening))
                .disabled(voiceInput.phase == .finishing || model.voiceDeliveryStatus == .waiting)
                .accessibilityLabel("Cancel voice input")
        } else {
            Button(action: openVoiceInput) { Label("Mic", systemImage: "mic.fill") }
                .buttonStyle(FarsideTileButtonStyle())
                .disabled(!voiceEntryAvailable)
                .accessibilityLabel("Voice input")
                .accessibilityHint("Speak on this iPhone, then tap Done to insert text on your Mac")
        }
    }

    private var segmentsRow: some View {
        HStack(spacing: 8) {
            FarsideSegmented(label: "Screen size",
                             options: [(ViewportMode.fit, "Fit"), (ViewportMode.fill, "Fill")],
                             selection: Binding(get: { viewport.mode }, set: { setMode($0) }))
            FarsideSegmented(label: "Touch mode",
                             options: [(true, "View"), (false, "Control")],
                             selection: Binding(get: { panMode }, set: { setInteractionMode($0) }))
        }
    }

    private var dockFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    LiveDot(state: liveState, size: 7)
                    Text(linkCaption)
                        .farsideCaption(Farside.Palette.bone)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(offlineLayoutCheck ? "Offline layout check. No Mac is connected." : "\(linkAccessibility). \(status)")
            Spacer(minLength: 4)
            Button { cancelGesture(); showControls = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(FarsideRoundButtonStyle(diameter: 40))
            .accessibilityLabel("Controls")
            Button("End session") { model.disconnect() }
                .buttonStyle(FarsideEndButtonStyle())
                .fixedSize()
                .accessibilityLabel("End session")
        }
    }

    private var releaseChip: some View {
        Button { model.cancelInput() } label: {
            Label("Release", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
        .fixedSize()
        .accessibilityLabel("Release")
        .accessibilityHint("Drops the held item on your Mac")
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

    private var handleLive: Bool { connection.connected && model.fresh && model.captureHealthy }

    private var macName: String { connection.invitation?.name ?? LaunchOptions.demoMacName ?? "Your Mac" }

    private var linkCaption: String {
        if offlineLayoutCheck { return "Offline preview" }
        var parts = [macName]
        if let route = model.link?.route { parts.append(route == "Relay" ? "Relayed" : route) }
        if let rtt = model.link?.roundTripMs { parts.append("\(rtt) ms") }
        return parts.joined(separator: " · ")
    }

    private var linkAccessibility: String {
        var parts = [macName]
        if let route = model.link?.route { parts.append(route == "Relay" ? "relayed connection" : "direct connection") }
        if let rtt = model.link?.roundTripMs { parts.append("network round trip \(rtt) milliseconds") }
        return parts.joined(separator: ", ")
    }

    private var status: String {
        if offlineLayoutCheck { return "No Mac connected · nothing is sent" }
        if model.dragging { return "Holding · tap Release to drop" }
        if !model.fresh || !model.captureHealthy { return "Reconnecting the picture · controls paused" }
        if panMode { return "View · drag or pinch to look around" }
        if model.canControl && clickAcknowledged { return "Click sent" }
        if model.canControl { return "Controlling your Mac" }
        return model.controlAllowed ? "View only" : "Mouse and keyboard are off on your Mac"
    }

    private var liveState: LiveDot.State {
        if offlineLayoutCheck { return .idle }
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
                .accessibilityHint("Presses Command-C on your Mac, then copies the selection to this iPhone")
            }
            HStack {
                Text("Text only · up to 256 KB").farsideCaption()
                Spacer(minLength: 8)
                Button("Get Mac clipboard") { model.fetchMacClipboard() }
                    .buttonStyle(FarsideLinkButtonStyle())
                    .disabled(!model.clipboardAvailable || model.clipboard.isBusy)
                    .accessibilityHint("Copies what is already on your Mac’s clipboard to this iPhone")
            }
        }
        .padding(14)
        .farsidePlate(22, fill: Farside.Palette.ink)
        .accessibilityIdentifier("remote.clipboard.row")
    }

    // MARK: - Keyboard

    private var keyboardBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
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
                        if showsClipboard {
                            keySeparator
                            pasteToMacButton
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.circle)
                                .padding(.horizontal, 4)
                            iconButton("Copy from Mac", "doc.on.doc", enabled: model.canControl && !model.clipboard.isBusy,
                                       action: model.copySelectionFromMac)
                                .accessibilityHint("Presses Command-C on your Mac, then copies the selection to this iPhone")
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .frame(height: 46)
                .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
                .clipShape(.capsule)
                .accessibilityIdentifier("remote.keys")

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
            }

            HStack(alignment: .center, spacing: 8) {
                textField
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
        .frame(maxWidth: 640)
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
                .frame(width: 44, height: 40)
                .accessibilityLabel(model.voiceDeliveryStatus == .waiting ? "Waiting for your Mac to confirm insertion"
                                                                         : "Finishing speech")
        } else if [.refused, .uncertain, .notQueued].contains(model.voiceDeliveryStatus), !displayedVoiceTranscript.isEmpty {
            Button("Retry", action: retryVoiceInsertion)
                .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
                .fixedSize()
                .disabled(!model.canControl || model.isComposingText || voiceLimitMessage != nil)
                .accessibilityLabel("Try insertion again")
                .accessibilityHint("Check your Mac first if delivery was uncertain")
        } else {
            Button("Done") { voiceInput.finish(insertVoiceTranscript) }
                .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
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
        case .listening: return "Listening · speak, then Done"
        case .finishing: return "Finishing speech"
        case .ready: return "Ready · tap Done to insert"
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
            CommittedTextField(text: $model.draft, isComposing: $model.isComposingText, focusOnAppear: true)
                .disabled(!model.textEditable)
                .opacity(model.textEditable ? 1 : 0)
                .allowsHitTesting(model.textEditable)
                .privacySensitive()
            if model.textEditable && model.draft.isEmpty {
                Text("Type for your Mac")
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
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .farsidePlate(23, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
    }

    private var showsClipboard: Bool { model.clipboardSupported || offlineLayoutCheck }

    /// The system paste control reads the iPhone clipboard without a paste prompt because the
    /// person tapped it; Farside never reads the iPhone clipboard on its own.
    private var pasteToMacButton: some View {
        PasteButton(payloadType: String.self) { strings in
            Task { @MainActor in model.pasteToMac(strings) }
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
                .frame(width: 40, height: 40)
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
                .frame(width: 40, height: 40)
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
                .frame(width: 42, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Controls sheet

    private var controlsSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    viewSection
                    pointerSection
                    clipboardSection
                    gesturesSection
                    workspaceSection
                    pictureSection
                    macPrivacySection
                    feelSection
                }
                .scrollContentBackground(.hidden)
                .background(Farside.Palette.void2)
                .onAppear {
                    #if DEBUG
                    if offlineLayoutCheck && LaunchOptions.has("--ui-clipboard-check") {
                        proxy.scrollTo("remote.clipboard", anchor: .top)
                    }
                    #endif
                }
            }
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { showControls = false }
                }
            }
            .accessibilityIdentifier("remote.controls.content")
        }
        .tint(Farside.Palette.bone)
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.medium, .large])
        .farsideSheet()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).farsideCaption()
    }

    private var pointerSection: some View {
        Section {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    actionTile("Click", "cursorarrow.click") { model.action("click") }
                    actionTile("Right-click", "contextualmenu.and.cursorarrow") { model.action("right") }
                }
                GridRow {
                    actionTile("Double-click", "cursorarrow.click.2") { model.action("double") }
                    actionTile(model.dragging ? "Release" : "Drag", model.dragging ? "hand.raised.fill" : "hand.point.up.left.and.text") {
                        model.drag()
                    }
                    .disabled(!model.dragging && !model.nativeInteractionSupported)
                    .accessibilityHint("Starts a visible drag for up to ten seconds. Use Release to drop.")
                }
            }
            .disabled((!model.canControl || panMode) && !model.dragging)
            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            sectionHeader("Pointer")
        } footer: {
            Text(panMode ? "Switch to Control to send clicks to your Mac."
                         : "Move one finger to point. Tap to click, two fingers to right-click, or double-tap and hold to drag.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    @ViewBuilder private var clipboardSection: some View {
        if showsClipboard {
            Section {
                HStack(spacing: 12) {
                    Label("Send iPhone text to your Mac", systemImage: "iphone.and.arrow.forward")
                        .foregroundStyle(Farside.Palette.bone)
                    Spacer(minLength: 8)
                    pasteToMacButton
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                }
                .id("remote.clipboard")
                .listRowBackground(Farside.Palette.panel)
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        actionTile("Copy selection", "doc.on.doc") { model.copySelectionFromMac() }
                            .disabled(!model.canControl || !model.clipboardAvailable || model.clipboard.isBusy)
                            .accessibilityHint("Presses Command-C on your Mac, then copies the selection to this iPhone")
                        actionTile("Get Mac clipboard", "arrow.down.doc") { model.fetchMacClipboard() }
                            .disabled(!model.clipboardAvailable || model.clipboard.isBusy)
                            .accessibilityHint("Copies what is already on your Mac’s clipboard to this iPhone")
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                Toggle("Press ⌘V after sending", isOn: Binding(get: { model.clipboard.pasteAfterSending },
                                                               set: { model.clipboard.pasteAfterSending = $0 }))
                    .toggleStyle(FarsideSwitchStyle())
                    .listRowBackground(Farside.Palette.panel)
                if model.clipboard.activity != .idle {
                    ProgressView(model.clipboard.activity == .sending ? "Sending to your Mac…" : "Copying from your Mac…")
                        .listRowBackground(Farside.Palette.panel)
                } else if let notice = model.clipboard.notice {
                    Label(notice.message, systemImage: notice.tone == .success ? "checkmark" : "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Farside.Palette.bone)
                        .listRowBackground(Farside.Palette.panel)
                }
            } header: {
                sectionHeader("Clipboard")
            } footer: {
                Text("Text only, up to 256 KB. Farside reads your Mac’s clipboard only when you ask, and never shares items marked as passwords.")
                    .foregroundStyle(Farside.Palette.ash)
            }
        }
    }

    private var viewSection: some View {
        Section {
            FarsideSegmented(label: "Screen size",
                             options: [(ViewportMode.fill, "Fill"), (ViewportMode.fit, "Fit")],
                             selection: Binding(get: { viewport.mode }, set: { setMode($0) }))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
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
            Button {
                showControls = false
                setInteractionMode(!panMode)
            } label: {
                Label(panMode ? "Control desktop" : "Move view", systemImage: panMode ? "cursorarrow.motionlines" : "hand.draw")
                    .foregroundStyle(Farside.Palette.bone)
            }
            .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("View")
        } footer: {
            Text("Fill uses the whole screen; Fit shows all of it. In View, drag, pinch or double-tap to look around.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    private var gesturesSection: some View {
        Section {
            Text(panMode ? "View: drag with one or two fingers to move the screen. Pinch to zoom. Double-tap to zoom in or fit the whole display."
                         : "Control: drag one finger to move the pointer. Two fingers scroll. Pinch to zoom the view. Three fingers left or right switch Spaces; up opens Mission Control; down opens App Exposé.")
                .foregroundStyle(Farside.Palette.bone)
                .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("Gestures")
        }
    }

    private var workspaceSection: some View {
        Section {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    actionTile("Previous Space", "arrow.left") { _ = model.gesture(.workspaceSwipe(direction: .right)) }
                    actionTile("Next Space", "arrow.right") { _ = model.gesture(.workspaceSwipe(direction: .left)) }
                }
                GridRow {
                    actionTile("Mission Control", "rectangle.3.group") { _ = model.gesture(.workspaceSwipe(direction: .up)) }
                    actionTile("App Exposé", "rectangle.stack") { _ = model.gesture(.workspaceSwipe(direction: .down)) }
                }
            }
            .disabled(!model.canControl || panMode)
            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            sectionHeader("Mac workspace")
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
    }

    private var pictureSection: some View {
        Section {
            FarsideSegmented(label: "Picture quality",
                             options: StreamQuality.allCases.map { (value: $0, title: $0.title) },
                             selection: $model.streamQuality)
                .disabled(model.appliedStreamQuality == nil && !offlineLayoutCheck)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            Text(model.streamQuality == .sharp ? "Sharper text and detail. Uses more bandwidth."
                                               : "Lower resolution for a more responsive connection.")
                .font(.footnote).foregroundStyle(Farside.Palette.ash)
                .listRowBackground(Farside.Palette.panel)
            if !offlineLayoutCheck, let status = model.streamQualityStatus {
                Text(status).font(.footnote).foregroundStyle(Farside.Palette.bone)
                    .listRowBackground(Farside.Palette.panel)
            }
            Toggle("Stream statistics", isOn: $streamStatsEnabled)
                .toggleStyle(FarsideSwitchStyle())
                .listRowBackground(Farside.Palette.panel)
            if streamStatsEnabled {
                Text("Shows per-stage timing over the picture and records it on this iPhone for export.")
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
        } header: {
            sectionHeader("Picture")
        }
    }

    @ViewBuilder private var macPrivacySection: some View {
        if model.curtainSupported, let state = model.curtainState {
            Section {
                Toggle("Hide Mac screen", isOn: Binding(get: { state.preferenceOn },
                                                        set: { model.setMacCurtain($0) }))
                    .disabled(!model.canChangeCurtain)
                    .accessibilityIdentifier("remote.macCurtain")
                if state == .liftedLocally {
                    Button("Hide it again") { model.setMacCurtain(true) }
                        .disabled(!model.canChangeCurtain)
                }
            } header: {
                Text("Mac privacy")
            } footer: {
                Text(macCurtainFooter(state))
            }
        }
    }

    private func macCurtainFooter(_ state: PrivacyCurtainState) -> String {
        switch state {
        case .off: "Covers your Mac’s displays while you’re connected. You still see the desktop here."
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
            Picker("Pointer size", selection: $pointerSize) {
                ForEach(PointerSizePreference.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .foregroundStyle(Farside.Palette.bone)
            .accessibilityIdentifier("remote.pointerSize")
            .listRowBackground(Farside.Palette.panel)
        } header: {
            sectionHeader("Feel")
        } footer: {
            Text("Your iPhone draws the Mac pointer at this size at every zoom level. An older Mac companion shows its streamed pointer instead.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }

    private func actionTile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(Farside.Palette.bone)
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(.rect)
        }
        .buttonStyle(ActionTileStyle())
        .accessibilityLabel(title)
    }

    private var zoomDescription: String {
        if viewport.zoom == 1 { return viewport.mode == .fill ? "Fill" : "Fit" }
        let magnification = viewport.fitScale > 0 ? viewport.scale / viewport.fitScale : 1
        return String(format: "%.1f×", Double(magnification))
    }

    // MARK: - Behaviour

    private func handle(_ command: NativeGestureCommand) -> Bool {
        guard !showControls, !showVoiceInput, !model.privacyShield, !model.contentConcealed else { return false }
        switch command {
        case .zoomToggle(let anchor):
            model.pointerLocator.clear()
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) {
                viewport.toggleZoom(anchoredAt: anchor)
            }
            showZoomBadge()
            return true
        case .navigate(let factor, let anchor, let translation):
            model.pointerLocator.clear()
            viewport.setZoom(viewport.zoom * factor, anchoredAt: anchor)
            viewport.pan(by: translation)
            showZoomBadge()
            return true
        case .zoom(let factor, let anchor):
            model.pointerLocator.clear()
            viewport.setZoom(viewport.zoom * factor, anchoredAt: anchor)
            showZoomBadge()
            return true
        case .zoomEnded:
            DispatchQueue.main.async {
                guard !showControls, !model.privacyShield, !model.contentConcealed else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) {
                    _ = viewport.settleZoom()
                }
                showZoomBadge()
            }
            return true
        case .pan(let delta):
            model.pointerLocator.clear()
            viewport.pan(by: delta)
            return true
        default:
            return model.gesture(command)
        }
    }

    private func follow(_ point: CGPoint) {
        guard model.canControl, !model.dragging, !keyboardOpen, !showControls, !panMode,
              !model.privacyShield, !model.contentConcealed else { return }
        let usable = PointerFollowLayout.usableRect(safeRect: viewport.safeRect,
                                                   canvasFrame: canvasFrame,
                                                   dockFrame: dockFrame)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) {
            _ = viewport.reveal(sourcePoint: point, in: usable)
        }
    }

    private func showZoomBadge() {
        zoomBadge = zoomDescription
        zoomBadgeToken &+= 1
    }

    private func scheduleGeometry() {
        guard !geometryPending else { return }
        geometryPending = true
        DispatchQueue.main.async {
            geometryPending = false
            applyGeometry()
        }
    }

    /// Rotation, iPad resizing and new source sizes remap the viewport; the keyboard and
    /// other bottom obstructions only change the safe insets.
    private func applyGeometry() {
        guard canvasFrame.width > 0, canvasFrame.height > 0, safeFrame.width > 0, safeFrame.height > 0 else { return }
        let insets = ViewportInsets(top: max(0, safeFrame.minY - canvasFrame.minY),
                                    left: max(0, safeFrame.minX - canvasFrame.minX),
                                    bottom: max(0, canvasFrame.maxY - safeFrame.maxY),
                                    right: max(0, canvasFrame.maxX - safeFrame.maxX))
        if viewport.canvasSize != canvasFrame.size || viewport.sourceSize != model.sourceSize {
            cancelGesture()
            viewport.resize(sourceSize: model.sourceSize, canvasSize: canvasFrame.size, safeInsets: insets)
        } else if viewport.safeInsets != insets {
            withAnimation(reduceMotion ? nil : .snappy) { viewport.updateSafeInsets(insets) }
        }
    }

    private func setMode(_ mode: ViewportMode) {
        guard mode != viewport.mode || !viewport.isAtBaseline else { return }
        cancelGesture()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)) { viewport.setMode(mode) }
        showZoomBadge()
    }

    private func toggleMode() { setMode(viewport.mode.toggled) }

    private func setInteractionMode(_ viewMode: Bool) {
        guard panMode != viewMode else { return }
        cancelGesture()
        model.pointerLocator.clear()
        withAnimation(reduceMotion ? nil : .snappy) { panMode = viewMode }
    }

    private func cancelGesture() {
        model.cancelInput()
        revision &+= 1
    }

    private func revealControls() {
        guard controlsCollapsed else { return }
        cancelGesture()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.sheetSpring) { controlsCollapsed = false }
    }

    private func collapseControls() {
        guard !controlsCollapsed, !voiceLocked else { return }
        cancelGesture()
        if showVoiceInput { cancelVoiceInput() }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.sheetSpring) {
            controlsCollapsed = true
            showClipboardRow = false
        }
    }

    private func openKeyboard() {
        cancelGesture()
        if showVoiceInput {
            guard !voiceLocked else { return }
            cancelVoiceInput()
        }
        keyboardOpen = true
    }

    private func closeKeyboard() {
        dismissedAutoKeyboardRevision = model.autoKeyboardRevision
        cancelGesture()
        keyboardOpen = false
    }
}

/// Keeps automatic pointer follow above the dock without reserving permanent
/// screen space when the controls are collapsed.
enum PointerFollowLayout {
    static func usableRect(safeRect: CGRect, canvasFrame: CGRect, dockFrame: CGRect) -> CGRect {
        let measuredTop = dockFrame.minY - canvasFrame.minY - 12
        let bottom = dockFrame.height > 0 && canvasFrame.intersects(dockFrame) &&
            measuredTop > safeRect.minY
            ? min(safeRect.maxY, measuredTop)
            : safeRect.maxY - 34
        return CGRect(x: safeRect.minX, y: safeRect.minY,
                      width: safeRect.width, height: max(1, bottom - safeRect.minY))
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

/// Plate-style press feedback for the Controls sheet tiles.
private struct ActionTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Farside.Palette.panel2 : Farside.Palette.panel,
                            in: .rect(cornerRadius: Farside.Radius.card - 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Farside.Radius.card - 2, style: .continuous)
                    .strokeBorder(Farside.Palette.line, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
        }
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
