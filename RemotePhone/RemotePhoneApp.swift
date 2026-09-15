import SwiftUI
import WebRTC
import AVFoundation

@main
struct RemotePhoneApp: App {
    @StateObject private var model = PhoneRemoteModel()
    @Environment(\.scenePhase) private var phase
    @State private var hasBeenActive = false

    var body: some Scene {
        WindowGroup {
            PhoneRemoteView(model: model, connection: model.connection)
                .onAppear {
                    if phase == .active { hasBeenActive = true }
                }
                .onChange(of: phase) { _, value in
                    if value == .active {
                        hasBeenActive = true
                    } else if hasBeenActive {
                        model.concealForInactiveScene()
                    }
                }
        }
    }
}

private struct PendingText {
    let requestID: String
    let draft: String
    let sentAt: TimeInterval
}

@MainActor
final class PhoneRemoteModel: ObservableObject {
    let connection = RemoteCoordinator(isHost: false)

    @Published var pairing = ""
    @Published var error = ""
    @Published var showScanner = false
    @Published var draft = ""
    @Published var dragging = false
    @Published var modifiers: Set<String> = []
    @Published var controlAllowed = false
    @Published var fresh = false
    @Published var captureHealthy = false
    @Published var geometryEpoch: UInt64 = 0
    @Published var textStatus = ""
    @Published private(set) var contentConcealed = false

    private var lastFrame = 0.0
    private var lastCaptureHealth = 0.0
    private var pendingText: PendingText?
    private var timer: Timer?

    init() {
        #if DEBUG
        contentConcealed = ProcessInfo.processInfo.arguments.contains("--ui-background-concealed-check")
        #endif
        connection.restore()
        connection.onAuthenticated = { [weak self] in
            guard let self else { return }
            self.contentConcealed = false
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
        connection.connected && controlAllowed && fresh && captureHealthy && geometryEpoch > 0
    }

    var textCanSend: Bool {
        !draft.isEmpty && draft.utf8.count <= 4_096 && draft.utf16.count <= 1_024 && pendingText == nil
    }

    var textLimitMessage: String? {
        guard !draft.isEmpty else { return nil }
        if draft.utf8.count > 4_096 { return "Text is limited to 4,096 UTF-8 bytes." }
        if draft.utf16.count > 1_024 { return "Text is limited to 1,024 UTF-16 units." }
        return nil
    }

    func enroll(_ code: String) {
        do {
            try connection.enroll(code.trimmingCharacters(in: .whitespacesAndNewlines))
            pairing = ""
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func frameReceived() {
        lastFrame = ProcessInfo.processInfo.systemUptime
        fresh = true
    }

    func action(_ name: String, x: Double = 0, y: Double = 0) {
        guard canControl else { return }
        _ = connection.sendControl(RemoteAction(action: name, x: x, y: y, epoch: geometryEpoch))
    }

    func key(_ key: String) {
        guard canControl else { return }
        _ = connection.sendControl(RemoteAction(action: "key", key: key, modifiers: Array(modifiers), epoch: geometryEpoch))
        modifiers.removeAll()
    }

    func sendText() {
        guard canControl, textCanSend else { return }
        let pending = PendingText(
            requestID: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            draft: draft,
            sentAt: ProcessInfo.processInfo.systemUptime
        )
        guard connection.sendControl(RemoteAction(action: "text", text: pending.draft, key: pending.requestID, epoch: geometryEpoch)) else {
            textStatus = "Text was not queued. Your draft is still here."
            return
        }
        pendingText = pending
        textStatus = "Waiting for your Mac to confirm text delivery…"
    }

    func drag() {
        guard canControl else { return }
        dragging.toggle()
        action(dragging ? "dragDown" : "dragUp")
    }

    func release() {
        if connection.connected {
            _ = connection.sendControl(RemoteAction(action: "release", epoch: geometryEpoch))
        }
        dragging = false
        modifiers.removeAll()
    }

    func disconnect() {
        release()
        connection.stop()
        end()
    }

    func concealForInactiveScene() {
        contentConcealed = true
        disconnect()
    }

    func dismissConcealment() {
        guard !connection.connected else { return }
        contentConcealed = false
    }

    func clearUncertainText() {
        pendingText = nil
        textStatus = ""
    }

    private func receive(_ action: RemoteAction) {
        switch action.action {
        case "viewing":
            controlAllowed = action.x == 1
            if !controlAllowed { release() }
        case "capture":
            captureHealthy = action.x == 1
            lastCaptureHealth = captureHealthy ? ProcessInfo.processInfo.systemUptime : 0
            if !captureHealthy { release() }
        case "geometry":
            guard action.epoch != geometryEpoch else { return }
            release()
            geometryEpoch = action.epoch
            fresh = false
            captureHealthy = false
            lastFrame = 0
            lastCaptureHealth = 0
        case "textResult":
            receiveTextResult(action)
        case "release":
            dragging = false
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
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if connection.connected {
            _ = connection.sendControl(RemoteAction(action: "heartbeat", epoch: geometryEpoch))
        }
        if fresh && now - lastFrame > 2 {
            fresh = false
            release()
        }
        if captureHealthy && now - lastCaptureHealth > 2 {
            captureHealthy = false
            release()
        }
        if let pending = pendingText, now - pending.sentAt > 4, textStatus.hasPrefix("Waiting") {
            textStatus = "Delivery is uncertain. Your draft is still here; it was not sent again."
        }
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        fresh = false
        captureHealthy = false
        controlAllowed = false
        dragging = false
        modifiers.removeAll()
        geometryEpoch = 0
        lastFrame = 0
        lastCaptureHealth = 0
        pendingText = nil
        textStatus = ""
    }
}

struct PhoneRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator

    var body: some View {
        Group {
            if model.contentConcealed {
                ConcealedRemoteView(model: model)
            } else if connection.connected || connection.remoteVideo != nil {
                PhoneSessionView(model: model, connection: connection, offlineLayoutCheck: false)
            } else if layoutCheck {
                PhoneSessionView(model: model, connection: connection, offlineLayoutCheck: true)
            } else {
                home
            }
        }
        .sheet(isPresented: $model.showScanner) {
            ScannerView { code in
                model.showScanner = false
                model.enroll(code)
            }
            .ignoresSafeArea()
        }
    }

    private var home: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                        .padding(.top, 32)
                    Text("A small task.\nYour whole Mac.")
                        .font(.largeTitle.bold())
                    Text("Pair with your Mac once. To connect while you’re away, leave it awake with remote access enabled.")
                        .foregroundStyle(.secondary)
                    if let invitation = connection.invitation {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(invitation.name, systemImage: "laptopcomputer").font(.headline)
                                Text(connection.status).font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    Button("Connect") { connection.start() }.buttonStyle(.borderedProminent)
                                    Button("Cancel", action: model.disconnect)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    }
                    Button {
                        model.showScanner = true
                    } label: {
                        Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(8)
                    }
                    .buttonStyle(.bordered)
                    DisclosureGroup("Paste a pairing code") {
                        TextField("Code from your Mac", text: $model.pairing, axis: .vertical)
                            .accessibilityLabel("Pairing code")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                        Button("Pair Mac") { model.enroll(model.pairing) }
                            .disabled(model.pairing.isEmpty)
                    }
                    DisclosureGroup("Developer connection details") {
                        Toggle("Relay-only test", isOn: relayOnlyBinding)
                            .disabled(connection.connected)
                        Text(connection.diagnostics)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).font(.callout) }
                    if connection.invitation == nil { Text(connection.status).font(.callout).foregroundStyle(.secondary) }
                    Text("Early prototype · Mac must be awake and unlocked. Remote service setup is required before cellular use.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if connection.invitation != nil {
                        Button("Forget Mac", role: .destructive) { connection.revoke() }
                    }
                }
                .padding(24)
            }
            .navigationTitle(connection.invitation?.name ?? "PocketDesk")
        }
    }

    private var relayOnlyBinding: Binding<Bool> {
        Binding(get: { connection.forceRelay }, set: { connection.forceRelay = $0 })
    }

    private var layoutCheck: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-layout-check")
        #else
        false
        #endif
    }

}

private struct ConcealedRemoteView: View {
    @ObservedObject var model: PhoneRemoteModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill").font(.largeTitle)
            Text("Remote view hidden")
                .font(.title3.weight(.semibold))
            Text("PocketDesk ended the session while it was inactive.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Return to PocketDesk", action: model.dismissConcealment)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.concealed")
    }
}

private struct PhoneSessionView: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    let offlineLayoutCheck: Bool
    @State private var zoom: CGFloat = 1
    @State private var panel: SessionPanel?
    @FocusState private var draftFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum SessionPanel: Equatable { case trackpad, keyboard, zoom }

    var body: some View {
        ZStack {
            viewport.ignoresSafeArea()
            sessionChrome
        }
        .background(.black)
    }

    private var viewport: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let track = connection.remoteVideo {
                    ScrollView([.horizontal, .vertical], showsIndicators: zoom > 1) {
                        RemoteVideoSurface(track: track, onFrame: model.frameReceived)
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                    }
                    .scrollDisabled(zoom <= 1)
                }
                if !model.fresh {
                    SessionStatus(label: "Waiting for a fresh picture", icon: "wifi.exclamationmark")
                } else if !model.captureHealthy {
                    SessionStatus(label: "Screen sharing needs attention on your Mac", icon: "rectangle.inset.filled.badge.exclamationmark")
                }
            }
            .clipped()
            .privacySensitive()
        }
    }

    @ViewBuilder
    private var sessionChrome: some View {
        VStack(spacing: 12) {
            if offlineLayoutCheck && verticalSizeClass != .compact {
                Label("Offline layout check · no Mac connected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel("Offline layout check. No Mac is connected.")
            }
            sessionBar
            Spacer(minLength: 0)
            if let panel {
                panelContainer(panel)
            }
            controlDock
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sessionBar: some View {
        HStack(spacing: 10) {
            Label(
                offlineLayoutCheck ? "Offline layout check" : (model.canControl ? "Control" : "View only"),
                systemImage: offlineLayoutCheck ? "exclamationmark.triangle.fill" : (model.canControl ? "cursorarrow.rays" : "eye")
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(offlineLayoutCheck ? .orange : (model.canControl ? .primary : .secondary))
            Spacer()
            Menu {
                Button("Fit view", systemImage: "arrow.down.right.and.arrow.up.left") { zoom = 1 }
                Button("Show trackpad", systemImage: "hand.draw") { setPanel(.trackpad) }
                Button("Show keyboard", systemImage: "keyboard") { setPanel(.keyboard) }
                Button("Adjust zoom", systemImage: "plus.magnifyingglass") { setPanel(.zoom) }
                Toggle("Relay-only test", isOn: relayOnlyBinding)
                    .disabled(connection.connected)
                Text(connection.diagnostics)
                Divider()
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive, action: model.disconnect)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .accessibilityLabel("Session options")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var controlDock: some View {
        ViewThatFits(in: .horizontal) {
            expandedControlDock
            compactControlDock
        }
    }

    private var expandedControlDock: some View {
        HStack(spacing: 10) {
            Button {
                setPanel(panel == .trackpad ? nil : .trackpad)
            } label: {
                Label("Trackpad", systemImage: "hand.draw")
            }
            Button {
                setPanel(panel == .keyboard ? nil : .keyboard)
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            Button("Fit") { zoom = 1 }
            Button("Zoom") { setPanel(panel == .zoom ? nil : .zoom) }
                .accessibilityLabel("Adjust zoom")
            if model.dragging {
                Button("Release", action: model.release)
                    .tint(.orange)
                    .accessibilityHint("Ends the remote drag immediately")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactControlDock: some View {
        HStack(spacing: 4) {
            compactButton("Trackpad", systemImage: "hand.draw") {
                setPanel(panel == .trackpad ? nil : .trackpad)
            }
            compactButton("Keyboard", systemImage: "keyboard") {
                setPanel(panel == .keyboard ? nil : .keyboard)
            }
            compactButton("Fit view", systemImage: "arrow.down.right.and.arrow.up.left") {
                zoom = 1
            }
            compactButton("Adjust zoom", systemImage: "plus.magnifyingglass") {
                setPanel(panel == .zoom ? nil : .zoom)
            }
            if model.dragging {
                compactButton("Release drag", systemImage: "hand.raised.fill", tint: .orange, action: model.release)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func compactButton(
        _ label: String,
        systemImage: String,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .accessibilityLabel(label)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func panelContainer(_ panel: SessionPanel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(panelTitle(panel), systemImage: panelIcon(panel))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Hide", action: closePanel)
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 36)
                    .accessibilityLabel("Hide \(panelTitle(panel).lowercased())")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            ScrollView(.vertical, showsIndicators: false) {
                inputPanel(panel)
            }
            .frame(maxHeight: verticalSizeClass == .compact ? 150 : 300)
        }
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .layoutPriority(1)
    }

    @ViewBuilder
    private func inputPanel(_ panel: SessionPanel) -> some View {
        switch panel {
        case .trackpad:
            VStack(spacing: 10) {
                TrackpadSurface(
                    onMove: { model.action("move", x: $0.width * 1.6, y: $0.height * 1.6) },
                    onScroll: { model.action("scroll", x: $0.width, y: $0.height) },
                    onClick: { model.action("click") },
                    onRightClick: { model.action("right") }
                )
                .frame(height: 132)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityIdentifier("remote.trackpad")
                HStack {
                    Button("Click") { model.action("click") }
                    Button("Right-click") { model.action("right") }
                    Button("Double-click") { model.action("double") }
                    Button(model.dragging ? "Release" : "Drag", action: model.drag)
                        .tint(model.dragging ? .orange : .accentColor)
                        .accessibilityValue(model.dragging ? "Dragging on your Mac" : "Not dragging")
                        .accessibilityHint(model.dragging ? "Ends the remote drag" : "Begins a remote drag")
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .frame(maxWidth: 420)
        case .zoom:
            VStack(alignment: .leading, spacing: 12) {
                Text("Zoom changes continuously from 1× to 3×. Drag the slider, then pan the enlarged view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...3)
                    .accessibilityLabel("Zoom level")
                    .accessibilityValue("\(zoom, format: .number.precision(.fractionLength(1))) times")
                HStack {
                    Text("1×")
                    Spacer()
                    Text("\(zoom, format: .number.precision(.fractionLength(1)))×")
                        .accessibilityLabel("Current zoom")
                        .accessibilityValue("\(zoom, format: .number.precision(.fractionLength(1)))")
                    Spacer()
                    Text("3×")
                }
                .font(.caption.monospacedDigit())
                Button("Fit view") { zoom = 1 }
            }
            .padding(14)
            .frame(maxWidth: 420)
        case .keyboard:
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["command", "option", "control", "shift"], id: \.self) { modifier in
                            Button(modifier.capitalized) { toggle(modifier) }
                                .tint(model.modifiers.contains(modifier) ? .orange : .accentColor)
                                .accessibilityValue(model.modifiers.contains(modifier) ? "Selected for the next key" : "Not selected")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                TextField("Text for your Mac", text: $model.draft, axis: .vertical)
                    .accessibilityLabel("Text for your Mac")
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .focused($draftFocused)
                if let textLimit = model.textLimitMessage {
                    Text(textLimit).font(.caption).foregroundStyle(.red)
                }
                if !model.textStatus.isEmpty {
                    HStack {
                        Text(model.textStatus).font(.caption).foregroundStyle(.secondary)
                        if model.textStatus.hasPrefix("Delivery is uncertain") {
                            Button("Edit or send again", action: model.clearUncertainText).font(.caption)
                        }
                    }
                }
                HStack {
                    Button("Send text", action: model.sendText).disabled(!model.canControl || !model.textCanSend)
                    Button("Esc") { model.key("escape") }
                        .accessibilityLabel("Escape")
                    Button("Tab") { model.key("tab") }
                    Button("⌫") { model.key("delete") }
                        .accessibilityLabel("Delete")
                    Button("↵") { model.key("return") }
                        .accessibilityLabel("Return")
                }
                .buttonStyle(.bordered)
                HStack {
                    ForEach(["left", "down", "up", "right"], id: \.self) { key in
                        Button { model.key(key) } label: { Image(systemName: "arrow.\(key)") }
                            .accessibilityLabel("\(key.capitalized) arrow")
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .frame(maxWidth: 460)
        }
    }

    private func toggle(_ modifier: String) {
        if model.modifiers.contains(modifier) {
            model.modifiers.remove(modifier)
        } else {
            model.modifiers.insert(modifier)
        }
    }

    private func setPanel(_ newPanel: SessionPanel?) {
        guard panel != newPanel else { return }
        model.release()
        if newPanel != .keyboard { draftFocused = false }
        panel = newPanel
    }

    private func closePanel() {
        draftFocused = false
        setPanel(nil)
    }

    private func panelTitle(_ panel: SessionPanel) -> String {
        switch panel {
        case .trackpad: return "Relative trackpad"
        case .keyboard: return "Keyboard"
        case .zoom: return "Zoom"
        }
    }

    private func panelIcon(_ panel: SessionPanel) -> String {
        switch panel {
        case .trackpad: return "hand.draw"
        case .keyboard: return "keyboard"
        case .zoom: return "plus.magnifyingglass"
        }
    }

    private var relayOnlyBinding: Binding<Bool> {
        Binding(get: { connection.forceRelay }, set: { connection.forceRelay = $0 })
    }
}

private struct SessionStatus: View {
    let label: String
    let icon: String

    var body: some View {
        Label(label, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding()
            .accessibilityLabel(label)
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
