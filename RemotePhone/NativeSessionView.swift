import SwiftUI

/// Low-frequency chrome and viewport state; video remains in its Metal renderer.
struct NativeSessionView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    let offlineLayoutCheck: Bool
    @State private var viewport = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900), canvasSize: .zero)
    @State private var panel: Panel?
    @State private var controlsCollapsed = true
    @State private var panMode = false
    @State private var clickAcknowledged = false
    @State private var revision: UInt64 = 0
    @AppStorage("pointerSensitivity") private var sensitivity = 1.0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    private enum Panel { case actions, keyboard, zoom }
    private var palette: PocketDeskPalette { .resolve(colorScheme) }

    var body: some View {
        canvas
            .statusBarHidden(true)
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if panel != .keyboard {
                    bottomChrome
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if panel == .keyboard {
                    bottomChrome
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: model.sourceSize) { _, size in
                cancelGesture()
                viewport.resize(sourceSize: size, canvasSize: viewport.canvasSize)
            }
            .onDisappear { model.cancelInput() }
            .task(id: model.acceptedClicks) {
                guard model.acceptedClicks > 0 else { return }
                clickAcknowledged = true
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                clickAcknowledged = false
            }
    }

    private var canvas: some View {
        GeometryReader { safeGeometry in
            // The input surface and chrome use the safe rectangle. Only the picture
            // expands into scene edges; the keyboard's reserved region stays excluded.
            let insets = safeGeometry.safeAreaInsets
            ZStack(alignment: .topLeading) {
                NativeTrackpadSurface(enabled: model.canControl, panMode: panMode,
                    revision: model.inputRevision &+ revision, sensitivity: CGFloat(sensitivity),
                    pointerScale: viewport.scale, doubleClickInterval: model.doubleClickInterval,
                    onCommand: { handle($0, canvasOrigin: CGPoint(x: insets.leading, y: insets.top)) },
                    onPointerMotionEnded: { model.pointerLocator.stopFollowing() })
                    .frame(width: safeGeometry.size.width, height: safeGeometry.size.height)
                    .accessibilityIdentifier("remote.canvas")

                if !offlineLayoutCheck && (!model.fresh || !model.captureHealthy) {
                    Label(model.fresh ? "Screen sharing needs attention on your Mac" : "Waiting for a fresh picture",
                          systemImage: model.fresh ? "exclamationmark.display" : "display")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: safeGeometry.size.width, height: safeGeometry.size.height)
            .background {
                GeometryReader { videoGeometry in
                    videoCanvas
                        .frame(width: videoGeometry.size.width, height: videoGeometry.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                        .onAppear { resize(videoGeometry.size) }
                        .onChange(of: videoGeometry.size) { _, size in resize(size) }
                }
                .ignoresSafeArea(.container, edges: panel == .keyboard ? [.top, .leading, .trailing] : .all)
            }
            .onReceive(model.pointerLocator.followUpdates) { point in
                guard model.canControl, !model.dragging, controlsCollapsed, panel == nil, !panMode else { return }
                let usable = CGRect(x: insets.leading, y: insets.top,
                    width: safeGeometry.size.width, height: max(0, safeGeometry.size.height - 56))
                _ = viewport.reveal(sourcePoint: point, in: usable)
            }
            .privacySensitive()
        }
    }

    private var videoCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let track = connection.remoteVideo {
                RemoteVideoSurface(track: track, onFrame: model.frameReceived)
                    .frame(width: viewport.contentRect.width, height: viewport.contentRect.height)
                    .position(x: viewport.contentRect.midX, y: viewport.contentRect.midY)
            } else if offlineLayoutCheck {
                offlineCanvas
                    .frame(width: model.sourceSize.width, height: model.sourceSize.height)
                    .scaleEffect(viewport.scale)
                    .frame(width: viewport.contentRect.width, height: viewport.contentRect.height)
                    .position(x: viewport.contentRect.midX, y: viewport.contentRect.midY)
            }
            PointerLocatorOverlay(locator: model.pointerLocator, viewport: viewport)
        }
    }

    private var offlineCanvas: some View {
        ZStack {
            // A distinct, full-source fixture makes uncovered screen edges visible
            // in UI captures even when Fill intentionally crops the source corners.
            Color(red: 0.12, green: 0.20, blue: 0.27)
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 2)
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 2)
            VStack(spacing: 16) {
                Text("PocketDesk").font(.system(size: 54, weight: .medium, design: .serif))
                Text("MAC DISPLAY CENTER")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                Text("Move to point  •  Pinch to zoom  •  Pan to explore")
                    .font(.system(size: 19))
                Text("Offline preview · no remote actions")
                    .font(.system(size: 17, design: .monospaced))
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.white)
            .padding(36)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 6) {
            if panel == .keyboard {
                compactKeyboard
            } else {
                if !controlsCollapsed {
                    if let panel { panelView(panel) }
                    sessionHeader
                    dock
                }
                dockHandleRail
            }
        }
        .frame(maxWidth: 500)
    }

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(offlineLayoutCheck ? palette.warning : model.canControl ? palette.sage : palette.muted)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .accessibilityLabel(offlineLayoutCheck ? "Offline layout check. No Mac is connected." : status)
            Spacer(minLength: 4)
            if panMode {
                Button("Done") { cancelGesture(); panMode = false }
                    .accessibilityLabel("Done panning")
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.bordered)
            }
            Button("End", role: .destructive) { model.disconnect() }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("End session")
                .buttonStyle(.bordered)
                .tint(palette.warning)
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.line))
        .contentShape(Capsule())
        .onTapGesture {}
    }

    private var status: String {
        if panMode { return "Pan view · move the desktop" }
        if offlineLayoutCheck { return "Offline layout check" }
        if model.dragging { return "Dragging · Release to drop" }
        if !model.fresh || !model.captureHealthy { return "Input paused" }
        if model.canControl && clickAcknowledged { return "Click accepted on this device" }
        return model.canControl ? "Controlling your Mac" : "View only"
    }

    private var dock: some View {
        HStack(spacing: 4) {
            dockButton("Keyboard", "keyboard") { setPanel(.keyboard) }
            dockButton(viewport.mode == .fill ? "Fit whole display" : "Fill screen",
                       viewport.mode == .fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                cancelGesture()
                if viewport.mode == .fill { viewport.fit() } else { viewport.fill() }
            }
            dockButton("Controls", "slider.horizontal.3") { setPanel(panel == .actions ? nil : .actions) }
        }
        .buttonStyle(.borderless)
        .tint(palette.accent)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.line))
        .contentShape(Capsule())
        .onTapGesture {}
    }

    private var dockHandleRail: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
            Spacer(minLength: 0)
            dockHandle
            Spacer(minLength: 0)
            if model.dragging {
                Button { model.cancelInput() } label: {
                    Image(systemName: "hand.raised.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.warning)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("Release")
                .accessibilityHint("Drops the held item on your Mac")
            } else {
                Color.clear.frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private var dockHandle: some View {
        let taps = TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
        return Capsule()
            .fill(palette.ink.opacity(0.85))
            .frame(width: 34, height: 5)
            .frame(width: 88, height: 44)
            .contentShape(Rectangle())
        .gesture(taps.onEnded { result in
            switch result {
            case .first: openKeyboard()
            case .second: controlsCollapsed ? revealControls() : collapseControls()
            }
        })
        .highPriorityGesture(DragGesture(minimumDistance: 8).onChanged { value in
            let movement = value.translation
            guard abs(movement.height) > 12, abs(movement.height) > abs(movement.width) else { return }
            if movement.height > 0 { collapseControls() }
            else { revealControls() }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(controlsCollapsed ? "Show controls" : "Hide controls")
        .accessibilityHint("Activate to show or hide controls. Use the Show keyboard action to type.")
        .accessibilityAction { controlsCollapsed ? revealControls() : collapseControls() }
        .accessibilityAction(named: Text("Show keyboard")) { openKeyboard() }
    }

    private func dockButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(palette.ink)
                .frame(width: 44, height: 44)
                .accessibilityLabel(title)
        }
    }

    private func panelView(_ selected: Panel) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(selected == .keyboard ? "Keyboard" : selected == .zoom ? "Zoom" : "Controls")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.ink)
                Spacer()
                Button("Hide") { setPanel(nil) }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(selected == .keyboard ? "Hide keyboard" : "Hide controls")
            }
            ScrollView {
                switch selected {
                case .actions: actions
                case .zoom: zoomControls
                case .keyboard: EmptyView()
                }
            }
            .frame(maxHeight: verticalSizeClass == .compact ? 115 : 180)
            .accessibilityIdentifier("remote.controls.content")
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .frame(maxWidth: 500)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.line))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture {}
        .tint(palette.accent)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move anywhere to point. Taps click at the Mac pointer.")
                .font(.caption).foregroundStyle(palette.muted)
            HStack {
                Button("Click") { model.action("click") }
                Button("Right-click") { model.action("right") }
                Button("Double-click") { model.action("double") }
            }.disabled(!model.canControl)
            HStack {
                Button("Drag") { model.drag() }
                    .disabled(!model.canControl || !model.nativeInteractionSupported)
                    .accessibilityHint("Starts a visible drag for up to ten seconds. Use Release to drop.")
                Button("Pan view") { setPanel(nil); cancelGesture(); panMode = true }
                Button("Adjust zoom") { setPanel(.zoom) }
            }
            Picker("Picture quality", selection: $model.streamQuality) {
                ForEach(StreamQuality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Picture quality")
            .disabled(model.appliedStreamQuality == nil && !offlineLayoutCheck)
            Text(model.streamQuality == .sharp ? "Sharper text · up to native 4K. Uses more bandwidth." : "Lower resolution for a more responsive connection.")
                .font(.caption).foregroundStyle(palette.muted)
            if !offlineLayoutCheck, let status = model.streamQualityStatus {
                Text(status).font(.caption).foregroundStyle(palette.warning)
            }
            Toggle("Click haptics", isOn: $model.hapticsEnabled)
            Text("Pointer sensitivity").font(.caption).foregroundStyle(palette.ink)
            Slider(value: $sensitivity, in: 0.5...1.8)
                .accessibilityLabel("Pointer sensitivity")
            Text("Pinch zooms this view. Two-finger scrolling stays in the Mac app.")
                .font(.caption).foregroundStyle(palette.muted)
        }.buttonStyle(.bordered)
    }

    private var zoomControls: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { Double(viewport.zoom) }, set: { value in
                cancelGesture()
                viewport.setZoom(CGFloat(value), anchoredAt: CGPoint(x: viewport.canvasSize.width / 2, y: viewport.canvasSize.height / 2))
            }), in: 1...3).accessibilityLabel("Zoom level")
            Text(viewport.zoom, format: .number.precision(.fractionLength(1)))
                .accessibilityLabel("Current zoom")
                .accessibilityValue(String(format: "%.1f", Double(viewport.zoom)))
            HStack {
                Button("Fill screen") { cancelGesture(); viewport.fill() }
                Button("Fit whole display") { cancelGesture(); viewport.fit() }
                Button("Pan view") { setPanel(nil); panMode = true }
            }.buttonStyle(.bordered)
        }
    }

    private var compactKeyboard: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ZStack {
                    CommittedTextField(text: $model.draft, isComposing: $model.isComposingText, focusOnAppear: true)
                        .disabled(!model.textEditable)
                        .opacity(model.textEditable ? 1 : 0)
                        .allowsHitTesting(model.textEditable)
                        .privacySensitive()
                    if !model.textEditable {
                        if model.textStatus.hasPrefix("Delivery is uncertain") {
                            Button("Edit or send again", action: model.clearUncertainText)
                                .font(.caption)
                                .accessibilityHint(model.textStatus)
                        } else {
                            Text(model.textStatus.isEmpty ? "Waiting for your Mac…" : model.textStatus)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(palette.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                Button { model.sendText() } label: {
                    Image(systemName: "paperplane.fill").frame(width: 44, height: 44)
                }
                .disabled(!model.canControl || !model.textCanSend)
                .accessibilityLabel("Send text")
                Group {
                    if model.dragging {
                        Button { model.cancelInput() } label: {
                            Image(systemName: "hand.raised.fill").frame(width: 44, height: 44)
                        }
                        .foregroundStyle(palette.warning)
                        .accessibilityLabel("Release")
                        .accessibilityHint("Drops the held item on your Mac")
                    } else {
                        Menu {
                            ForEach(["command", "option", "control", "shift"], id: \.self) { modifier in
                                Button {
                                    if model.modifiers.contains(modifier) { model.modifiers.remove(modifier) }
                                    else { model.modifiers.insert(modifier) }
                                } label: {
                                    Label(modifier.capitalized,
                                          systemImage: model.modifiers.contains(modifier) ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            Divider()
                            ForEach(["escape", "tab", "delete", "return", "left", "down", "up", "right"], id: \.self) { key in
                                Button(key.capitalized) { model.key(key) }.disabled(!model.canControl)
                            }
                        } label: {
                            Image(systemName: "command").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Keyboard commands")
                    }
                }
                Button { setPanel(nil) } label: {
                    Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Hide keyboard")
                Button("End", role: .destructive) { model.disconnect() }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("End session")
                    .tint(palette.warning)
            }
            if let limit = model.textLimitMessage {
                Text(limit).font(.caption).foregroundStyle(palette.warning)
            } else if model.textEditable && !model.textStatus.isEmpty {
                Text(model.textStatus).font(.caption).foregroundStyle(palette.muted)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.line))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {}
        .tint(palette.accent)
    }

    private func handle(_ command: NativeGestureCommand, canvasOrigin: CGPoint) -> Bool {
        switch command {
        case .zoom(let factor, let anchor):
            model.pointerLocator.clear()
            // Gesture coordinates start at the safe input layer; the video starts at the screen edge.
            let canvasAnchor = CGPoint(x: anchor.x + canvasOrigin.x, y: anchor.y + canvasOrigin.y)
            viewport.setZoom(viewport.zoom * factor, anchoredAt: canvasAnchor)
            return true
        case .pan(let delta):
            model.pointerLocator.clear()
            viewport.pan(by: delta)
            return true
        default: return model.gesture(command)
        }
    }

    private func resize(_ size: CGSize) {
        guard size != viewport.canvasSize else { return }
        cancelGesture()
        viewport.resize(sourceSize: model.sourceSize, canvasSize: size)
    }

    private func cancelGesture() {
        model.cancelInput()
        revision &+= 1
    }

    private func setPanel(_ newPanel: Panel?) {
        guard panel != newPanel else { return }
        cancelGesture()
        panMode = false
        panel = newPanel
    }

    private func revealControls() {
        guard controlsCollapsed else { return }
        cancelGesture()
        controlsCollapsed = false
    }

    private func collapseControls() {
        guard !controlsCollapsed else { return }
        cancelGesture()
        panMode = false
        panel = nil
        controlsCollapsed = true
    }

    private func openKeyboard() {
        if controlsCollapsed { revealControls() }
        setPanel(.keyboard)
    }
}
