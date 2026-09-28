import SwiftUI

/// Full-bleed remote desktop with Liquid Glass chrome that stays out of the way.
/// Video stays in its Metal renderer; this view owns only low-frequency chrome and viewport state.
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
    @State private var showControls = false
    @State private var panMode = false
    @State private var clickAcknowledged = false
    @State private var zoomBadge: String?
    @State private var zoomBadgeToken = 0
    @State private var revision: UInt64 = 0
    @AppStorage("pointerSensitivity") private var sensitivity = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let sideSlot: CGFloat = 52

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
        .background(PhoneTheme.letterbox.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .vertical)
        .sheet(isPresented: $showControls) { controlsSheet }
        .sensoryFeedback(.selection, trigger: viewport.mode)
        .onChange(of: viewport.mode) { _, mode in ViewportPreference.store(mode) }
        .onChange(of: model.sourceSize) { _, _ in scheduleGeometry() }
        .onDisappear { model.cancelInput() }
        .task(id: model.acceptedClicks) {
            guard model.acceptedClicks > 0 else { return }
            clickAcknowledged = true
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            clickAcknowledged = false
        }
        .task(id: zoomBadgeToken) {
            guard zoomBadge != nil else { return }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            withAnimation(.easeOut(duration: 0.25)) { zoomBadge = nil }
        }
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            videoLayer
            NativeTrackpadSurface(enabled: model.canControl && !panMode && !showControls, panMode: panMode,
                                  revision: model.inputRevision &+ revision, sensitivity: CGFloat(sensitivity),
                                  pointerScale: viewport.scale, doubleClickInterval: model.doubleClickInterval,
                                  onCommand: handle,
                                  onPointerMotionEnded: { model.pointerLocator.stopFollowing() })
                .accessibilityIdentifier("remote.canvas")
                .allowsHitTesting(!showControls && !model.privacyShield && !model.contentConcealed)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            canvasFrame = frame
            scheduleGeometry()
        }
        .onReceive(model.pointerLocator.followUpdates, perform: follow)
        .privacySensitive()
    }

    private var videoLayer: some View {
        ZStack(alignment: .topLeading) {
            PhoneTheme.letterbox
            let rect = viewport.contentRect
            if let track = connection.remoteVideo {
                RemoteVideoSurface(track: track, onFrame: model.frameReceived)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            } else if offlineLayoutCheck {
                DesktopPreview(size: model.sourceSize)
                    .scaleEffect(viewport.scale, anchor: .topLeading)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .position(x: rect.midX, y: rect.midY)
            }
            PointerLocatorOverlay(locator: model.pointerLocator, viewport: viewport)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var centerNotices: some View {
        if !offlineLayoutCheck && (!model.fresh || !model.captureHealthy) {
            Label(model.fresh ? "Screen sharing needs attention on your Mac" : "Waiting for a fresh picture",
                  systemImage: model.fresh ? "exclamationmark.display" : "hourglass")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var topPills: some View {
        VStack(spacing: 8) {
            if StreamDebug.enabled && !model.streamSummaryLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.streamSummaryLines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: 320, alignment: .leading)
                .background(.black.opacity(0.78), in: .rect(cornerRadius: 10))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if panMode {
                HStack(spacing: 10) {
                    Image(systemName: "hand.draw").accessibilityHidden(true)
                    Text("View · drag or pinch").font(.subheadline.weight(.medium))
                    Button("Control") { setInteractionMode(false) }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Control desktop")
                }
                .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity)
            }
            if let zoomBadge {
                Text(zoomBadge)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 8)
    }

    private var privacyShield: some View {
        ZStack {
            PhoneTheme.letterbox
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .ignoresSafeArea()
        .accessibilityLabel("Remote screen hidden")
        .accessibilityIdentifier("remote.privacyShield")
    }

    // MARK: - Dock

    private var dock: some View {
        VStack(spacing: 10) {
            if !controlsCollapsed {
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 10) {
                        statusPill
                        HStack(spacing: 10) {
                            endButton.frame(width: sideSlot)
                            dockCluster
                            releaseSlot.frame(width: sideSlot)
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            dockHandle
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 560)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusColor)
            Text(status)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(offlineLayoutCheck ? "Offline layout check. No Mac is connected." : status)
    }

    private var endButton: some View {
        Button { model.disconnect() } label: {
            Text("End")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: sideSlot, height: 48)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("End session")
    }

    private var dockCluster: some View {
        HStack(spacing: 0) {
            dockButton("Keyboard", "keyboard") { openKeyboard() }
            dockButton(viewport.mode == .fill ? "Fit whole display" : "Fill screen",
                       viewport.mode == .fill ? "arrow.down.right.and.arrow.up.left"
                                              : "arrow.up.left.and.arrow.down.right") { toggleMode() }
            dockButton(panMode ? "Control desktop" : "Move view", panMode ? "cursorarrow.motionlines" : "hand.draw") {
                setInteractionMode(!panMode)
            }
            dockButton("Controls", "slider.horizontal.3") { cancelGesture(); showControls = true }
        }
        .padding(.horizontal, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder private var releaseSlot: some View {
        if model.dragging {
            Button { model.cancelInput() } label: {
                Image(systemName: "hand.raised.fill")
                    .font(.title3)
                    .frame(width: sideSlot, height: 48)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(PhoneTheme.caution).interactive(), in: .capsule)
            .accessibilityLabel("Release")
            .accessibilityHint("Drops the held item on your Mac")
        } else {
            Color.clear.frame(height: 48).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func dockButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 52, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var dockHandle: some View {
        let taps = TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
        return Capsule()
            .fill(.white.opacity(0.92))
            .frame(width: 40, height: 5)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
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

    private var status: String {
        if offlineLayoutCheck { return "Offline preview" }
        if model.dragging { return "Holding · tap Release to drop" }
        if !model.fresh || !model.captureHealthy { return "Input paused" }
        if panMode { return "Moving view" }
        if model.canControl && clickAcknowledged { return "Click sent" }
        return model.canControl ? "Controlling your Mac" : "View only"
    }

    private var statusColor: Color {
        if offlineLayoutCheck || !model.fresh || !model.captureHealthy { return PhoneTheme.busy }
        if model.dragging { return PhoneTheme.caution }
        if panMode { return .secondary }
        return model.canControl ? PhoneTheme.ready : .secondary
    }

    // MARK: - Keyboard

    private var keyboardBar: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            keyButton("Escape", "escape", "escape")
                            keyButton("Tab", "arrow.right.to.line", "tab")
                            Divider().frame(height: 22).padding(.horizontal, 4)
                            modifierButton("Control", "control", "control")
                            modifierButton("Option", "option", "option")
                            modifierButton("Shift", "shift", "shift")
                            modifierButton("Command", "command", "command")
                            Divider().frame(height: 22).padding(.horizontal, 4)
                            keyButton("Left arrow", "arrow.left", "left")
                            keyButton("Down arrow", "arrow.down", "down")
                            keyButton("Up arrow", "arrow.up", "up")
                            keyButton("Right arrow", "arrow.right", "right")
                            Divider().frame(height: 22).padding(.horizontal, 4)
                            keyButton("Delete", "delete.left", "delete")
                            keyButton("Return", "return", "return")
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 44)
                    .clipShape(.capsule)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityIdentifier("remote.keys")

                    if model.dragging {
                        Button { model.cancelInput() } label: {
                            Image(systemName: "hand.raised.fill").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .glassEffect(.regular.tint(PhoneTheme.caution).interactive(), in: .circle)
                        .accessibilityLabel("Release")
                        .accessibilityHint("Drops the held item on your Mac")
                    }
                    Button { closeKeyboard() } label: {
                        Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Hide keyboard")
                }

                HStack(alignment: .center, spacing: 8) {
                    textField
                    Button { model.sendText() } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(canSend ? PhoneTheme.tint : Color.gray.opacity(0.5), in: .circle)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send text")
                }
                if let limit = model.textLimitMessage {
                    Text(limit).font(.caption).foregroundStyle(PhoneTheme.caution)
                } else if model.textEditable && !model.textStatus.isEmpty {
                    Text(model.textStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 640)
    }

    private var canSend: Bool { model.canControl && model.textCanSend }

    private var textField: some View {
        ZStack(alignment: .leading) {
            CommittedTextField(text: $model.draft, isComposing: $model.isComposingText, focusOnAppear: true)
                .disabled(!model.textEditable)
                .opacity(model.textEditable ? 1 : 0)
                .allowsHitTesting(model.textEditable)
                .privacySensitive()
            if model.textEditable && model.draft.isEmpty {
                Text("Type for your Mac")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if !model.textEditable {
                if model.textStatus.hasPrefix("Delivery is uncertain") {
                    Button("Edit or send again", action: model.clearUncertainText)
                        .font(.footnote)
                        .padding(.leading, 16)
                        .accessibilityHint(model.textStatus)
                } else {
                    Text(model.textStatus.isEmpty ? "Waiting for your Mac…" : model.textStatus)
                        .font(.footnote)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func keyButton(_ label: String, _ symbol: String, _ key: String) -> some View {
        Button { model.key(key) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.canControl)
        .accessibilityLabel(label)
    }

    private func modifierButton(_ label: String, _ symbol: String, _ modifier: String) -> some View {
        let active = model.modifiers.contains(modifier)
        return Button {
            if active { model.modifiers.remove(modifier) } else { model.modifiers.insert(modifier) }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(active ? .bold : .medium))
                .foregroundStyle(active ? PhoneTheme.tint : .primary)
                .frame(width: 40, height: 40)
                .background(active ? PhoneTheme.tint.opacity(0.18) : .clear, in: .circle)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Controls sheet

    private var controlsSheet: some View {
        NavigationStack {
            Form {
                viewSection
                pointerSection
                gesturesSection
                workspaceSection
                pictureSection
                feelSection
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
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.medium, .large])
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
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            .listRowBackground(Color.clear)
        } header: {
            Text("Pointer")
        } footer: {
            Text(panMode ? "Switch to Control to send clicks to your Mac."
                         : "Move one finger to point. Tap to click, two fingers to right-click, or double-tap and hold to drag.")
        }
    }

    private var viewSection: some View {
        Section {
            Picker("Screen", selection: Binding(get: { viewport.mode }, set: { setMode($0) })) {
                Text("Fill").tag(ViewportMode.fill)
                Text("Fit").tag(ViewportMode.fit)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Screen size")
            LabeledContent {
                Text(zoomDescription)
                    .monospacedDigit()
                    .accessibilityLabel("Current zoom")
                    .accessibilityValue(String(format: "%.1f", Double(viewport.zoom)))
            } label: {
                Text("Zoom")
            }
            zoomSlider
            Button {
                showControls = false
                setInteractionMode(!panMode)
            } label: {
                Label(panMode ? "Control desktop" : "Move view", systemImage: panMode ? "cursorarrow.motionlines" : "hand.draw")
            }
        } header: {
            Text("View")
        } footer: {
            Text("Fill uses the whole screen. Fit keeps the entire display inside the safe area. In View, drag to move, pinch to zoom, or double-tap to switch between close-up and Fit.")
        }
    }

    private var gesturesSection: some View {
        Section("Gestures") {
            if panMode {
                Text("View: drag with one or two fingers to move the screen. Pinch to zoom. Double-tap to zoom in or fit the whole display.")
            } else {
                Text("Control: drag one finger to move the pointer. Two fingers scroll. Pinch to zoom the view. Three fingers left or right switch Spaces; up opens Mission Control; down opens App Exposé.")
            }
        }
    }

    private var workspaceSection: some View {
        Section("Mac workspace") {
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
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            .listRowBackground(Color.clear)
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
            Picker("Picture quality", selection: $model.streamQuality) {
                ForEach(StreamQuality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Picture quality")
            .disabled(model.appliedStreamQuality == nil && !offlineLayoutCheck)
            Text(model.streamQuality == .sharp ? "Sharper text and detail. Uses more bandwidth."
                                               : "Lower resolution for a more responsive connection.")
                .font(.footnote).foregroundStyle(.secondary)
            if !offlineLayoutCheck, let status = model.streamQualityStatus {
                Text(status).font(.footnote).foregroundStyle(PhoneTheme.caution)
            }
        } header: {
            Text("Picture")
        }
    }

    private var feelSection: some View {
        Section {
            Toggle("Click haptics", isOn: $model.hapticsEnabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pointer speed")
                Slider(value: $sensitivity, in: 0.5...1.8) {
                    Text("Pointer speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "hare").accessibilityHidden(true)
                }
                .accessibilityLabel("Pointer sensitivity")
            }
        } header: {
            Text("Feel")
        }
    }

    private func actionTile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .accessibilityLabel(title)
    }

    private var zoomDescription: String {
        if viewport.zoom == 1 { return viewport.mode == .fill ? "Fill" : "Fit" }
        let magnification = viewport.fitScale > 0 ? viewport.scale / viewport.fitScale : 1
        return String(format: "%.1f×", Double(magnification))
    }

    // MARK: - Behaviour

    private func handle(_ command: NativeGestureCommand) -> Bool {
        guard !showControls, !model.privacyShield, !model.contentConcealed else { return false }
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
        withAnimation(reduceMotion ? nil : .snappy) { controlsCollapsed = false }
    }

    private func collapseControls() {
        guard !controlsCollapsed else { return }
        cancelGesture()
        withAnimation(reduceMotion ? nil : .snappy) {
            controlsCollapsed = true
        }
    }

    private func openKeyboard() {
        cancelGesture()
        keyboardOpen = true
    }

    private func closeKeyboard() {
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
