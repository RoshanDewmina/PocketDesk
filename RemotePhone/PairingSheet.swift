import SwiftUI
import AVFoundation

/// Pairing: camera first, steps beneath, and a paste alternative whose confirm button stays
/// pinned above the keyboard at every text size. Wrong or expired codes say so right away.
struct PairingSheet: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject private var connection: RemoteCoordinator
    let replacing: String?
    let onPaired: () -> Void
    @State private var entry: PairingEntry
    @State private var camera: CameraState
    @State private var problem: PairingCodeProblem?
    @State private var problemSerial = 0
    @State private var burst = false
    @State private var waitingForApproval = false
    @State private var foundCode: String?
    @State private var foundMacName = ""
    @State private var networkResult: First60LocalNetworkCheck.Result?
    @State private var checkingNetwork = false
    @State private var localNetworkCheck = First60LocalNetworkCheck()
    @State private var networkTask: Task<Void, Never>?
    @State private var networkGeneration = UUID()

    @State private var showsReplacementConfirmation = false
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    private enum CameraState { case priming, scanning, denied, unavailable }

    init(model: PhoneRemoteModel, entry: PairingEntry, replacing: String? = nil, onPaired: @escaping () -> Void = {}) {
        self.model = model
        _connection = ObservedObject(wrappedValue: model.connection)
        self.replacing = replacing
        self.onPaired = onPaired
        _entry = State(initialValue: entry)
        let initial: CameraState
        #if DEBUG
        if LaunchOptions.has("--ui-camera-priming") { initial = .priming }
        else if LaunchOptions.has("--ui-camera-denied") { initial = .denied }
        else if !First60.isEnabled(), PermissionPrimer.needsPriming(.camera) { initial = .priming }
        else if PermissionPrimer.cameraDenied { initial = .denied }
        else { initial = .scanning }
        #else
        initial = !First60.isEnabled() && PermissionPrimer.needsPriming(.camera)
            ? .priming : (PermissionPrimer.cameraDenied ? .denied : .scanning)
        #endif
        _camera = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Farside.Space.l) {
                    FarsideHeading("Pair your Mac.", accent: "your", size: 30)
                    if waitingForApproval { approvalWaiting }
                    else if foundCode != nil { foundMac }
                    else {
                        FarsideSegmented(label: "Pairing method",
                                         options: [(PairingEntry.scan, "Scan"), (PairingEntry.paste, "Paste Code")],
                                         selection: $entry, accessibilityStacked: true)

                        if entry == .scan { scanner } else { pasteField }

                        if let problem {
                            FarsideNotice(message: problem.message, tone: .caution)
                                .transition(.opacity)
                                .id(problemSerial)
                                .accessibilityIdentifier("pairing.feedback")
                        } else if !model.error.isEmpty {
                            FarsideNotice(message: model.error, tone: .caution)
                        }

                        steps
                    }

                    if let replacing {
                        Text("Add another Mac. \(replacing) stays paired with this \(DeviceWord.current).")
                            .font(.footnote)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Farside.Palette.void2.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        cancelNetworkCheck()
                        model.cancelPairingLocalAccess()
                        if waitingForApproval { connection.stop() }
                        dismiss()
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if entry == .paste && !waitingForApproval && foundCode == nil {
                    Button(action: pair) {
                        Text("Pair Mac")
                    }
                    .buttonStyle(FarsidePrimaryButtonStyle())
                    .disabled(model.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 560)
                }
            }
        }
        .overlay {
            if burst { PairingBurstView().transition(.opacity) }
        }
        .tint(Farside.Palette.bone)
        .farsideSheet()
        .interactiveDismissDisabled(burst || waitingForApproval || checkingNetwork)
        .confirmationDialog("Replace this Mac pairing?", isPresented: $showsReplacementConfirmation,
                            titleVisibility: .visible, presenting: model.pendingPairReplacement) { pending in
            Button("Replace pairing") { if model.confirmPairReplacement(pending) { waitingForApproval = true } }
            Button("Cancel", role: .cancel) { model.cancelPairReplacement(); entry = .paste }
        } message: { pending in
            Text("Replace the saved pairing for \(pending.oldName) with this QR for \(pending.approval.enrollment.name)? The current session ends first. Your Mac must still approve this \(DeviceWord.current).")
        }
        .onChange(of: model.pendingPairReplacement?.id) { _, id in showsReplacementConfirmation = id != nil }
        .onChange(of: showsReplacementConfirmation) { _, shown in
            if !shown, model.pendingPairReplacement != nil { model.cancelPairReplacement(); entry = .paste }
        }
        .onDisappear {
            cancelNetworkCheck()
            model.cancelPairReplacement()
            if waitingForApproval, connection.enrollmentPending { connection.stop() }
        }
        .onChange(of: connection.enrollmentPending) { _, pending in
            if waitingForApproval, !pending, connection.invitation?.version == 1, connection.isRunning,
               !First60.isEnabled() {
                waitingForApproval = false
                celebrate()
            }
        }
        .onChange(of: connection.connected) { _, connected in
            if First60.isEnabled(), waitingForApproval, connected, !connection.enrollmentPending {
                waitingForApproval = false
                celebrate()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, camera == .denied, !PermissionPrimer.cameraDenied { camera = .scanning }
        }
        .animation(Farside.Motion.easeOut(), value: problemSerial)
        .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: burst)
        .sensoryFeedback(.warning, trigger: problemSerial)
        .onChange(of: entry) { _, value in
            codeFocused = value == .paste
            problem = nil
        }
        .onChange(of: model.pairingCode) { _, _ in if entry == .paste { problem = nil } }
        .onAppear {
            if First60.isEnabled(), !model.pairingCode.isEmpty { _ = stageCode(model.pairingCode) }
            #if DEBUG
            if LaunchOptions.has("--ui-pairing-burst") { burst = true }
            if LaunchOptions.has("--ui-pairing-expired") {
                problem = .expired
                problemSerial &+= 1
            }
            #endif
        }
        .accessibilityIdentifier("pairing.sheet")
    }

    /// This explicit action is also the reverse-pairing defense for links opened by Camera.
    /// A scan/link supplies a name, never authority; the six-digit comparison and Mac Allow follow.
    private var foundMac: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            Text("Found \(foundMacName).")
                .font(.headline)
                .privacySensitive()
                .accessibilityIdentifier("pairing.foundMac")
            Text("Only continue if this Mac is in front of you and you opened its Farside pairing window. Never pair from a code someone sent you.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if checkingNetwork {
                ProgressView().tint(Farside.Palette.bone)
                Text("Allow Wi-Fi access so Farside can reach it. Choose Allow in the iOS Local Network alert.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if networkResult == .denied {
                Text(LocalNetworkAccess.deniedTitle).font(.subheadline.weight(.semibold))
                Text(LocalNetworkAccess.deniedNextStep).font(.subheadline)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(FarsidePrimaryButtonStyle())
                Button("Check again", action: checkNetwork).buttonStyle(FarsideLinkButtonStyle())
            } else if networkResult == .unavailable || networkResult == .cancelled {
                Text("Farside couldn’t verify Wi-Fi access. Keep this device and your Mac on the same Wi-Fi, then check again.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again", action: checkNetwork).buttonStyle(FarsidePrimaryButtonStyle())
            } else {
                Text("Allow Wi-Fi access so Farside can reach it. Your Mac must then show the same six-digit code and choose Allow.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Wi-Fi access", action: checkNetwork)
                    .buttonStyle(FarsidePrimaryButtonStyle())
                    .accessibilityIdentifier("pairing.localNetwork.allow")
            }
            Button("Use another code") {
                cancelNetworkCheck()
                model.cancelPairingLocalAccess()
                foundCode = nil; foundMacName = ""; networkResult = nil
                model.pairingCode = ""
            }
            .buttonStyle(FarsideLinkButtonStyle())
            .disabled(checkingNetwork)
        }
        .padding(Farside.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .farsidePlate()
        .accessibilityIdentifier("pairing.localNetwork")
    }

    private func cancelNetworkCheck() {
        networkGeneration = UUID()
        networkTask?.cancel(); networkTask = nil
        localNetworkCheck.cancel()
        checkingNetwork = false
    }

    @discardableResult
    private func stageCode(_ code: String) -> Bool {
        guard First60.isEnabled() else {
            let paired = model.enroll(code)
            if paired { waitingForApproval = true }
            return paired
        }
        do {
            let code = try PairInvitation.normalizedCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
            let invitation = try PairInvitation.parse(code)
            cancelNetworkCheck()
            model.cancelPairingLocalAccess()
            foundCode = code; foundMacName = invitation.name
            networkResult = nil; problem = nil; model.error = ""
            codeFocused = false
            return true
        } catch {
            problem = PairingCodeProblem(code: code); problemSerial &+= 1
            return false
        }
    }

    private func checkNetwork() {
        guard let code = foundCode, !checkingNetwork else { return }
        // A long Settings visit can outlive the invitation. No stale authorization is retained.
        guard (try? PairInvitation.parse(code)) != nil else {
            foundCode = nil; problem = .expired; problemSerial &+= 1
            return
        }
        cancelNetworkCheck()
        let generation = networkGeneration
        checkingNetwork = true; networkResult = nil
        PermissionPrimer.markPrimed(.localNetwork)
        networkTask = Task { @MainActor in
            let result = await localNetworkCheck.check()
            guard !Task.isCancelled, networkGeneration == generation, foundCode == code else { return }
            checkingNetwork = false; networkResult = result
            guard result == .allowed else { return }
            model.approvePairingLocalAccess(code)
            if model.enroll(code) {
                foundCode = nil
                waitingForApproval = true
            } else if model.pendingPairReplacement == nil {
                model.cancelPairingLocalAccess()
                foundCode = nil
                problem = PairingCodeProblem(code: code); problemSerial &+= 1
            }
        }
    }

    private var approvalWaiting: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            if First60.isEnabled(), let wait = connection.permissionWait {
                ProgressView().tint(Farside.Palette.bone)
                Text(wait.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.macPermissionWait")
            } else if let code = connection.pairingComparisonCode {
                Text("Check your Mac.")
                    .font(.headline)
                Text(verbatim: code)
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Farside.Palette.bone)
                    .privacySensitive()
                    .accessibilityLabel("Comparison code: \(code)")
                    .accessibilityIdentifier("pairing.comparisonCode")
                Text("If your Mac shows this same code, choose Allow on the Mac to finish. If the codes differ, choose Decline there and scan a new code.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if connection.enrollmentPending { ProgressView().tint(Farside.Palette.bone) }
                Text(connection.status)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Farside.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .farsidePlate()
        .accessibilityIdentifier("pairing.waiting")
    }

    @ViewBuilder private var scanner: some View {
        switch camera {
        case .priming:
            VStack(alignment: .leading, spacing: Farside.Space.m) {
                FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04), scene: FarsideArt.priming(.camera))
                    .frame(height: 170)
                    .clipShape(.rect(cornerRadius: Farside.Radius.card, style: .continuous))
                Text("Farside uses the camera only to read the pairing code on your Mac. Nothing is recorded. iOS asks next; choose Allow.")
                    .font(.subheadline)
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Continue") {
                    PermissionPrimer.markPrimed(.camera)
                    camera = .scanning
                }
                .buttonStyle(FarsidePrimaryButtonStyle())
                .accessibilityIdentifier("pairing.camera.continue")
            }
            .padding(Farside.Space.m)
            .farsidePlate()
        case .denied, .unavailable:
            VStack(alignment: .leading, spacing: Farside.Space.s) {
                Image(systemName: "camera")
                    .font(.title2)
                    .foregroundStyle(Farside.Palette.bone)
                    .accessibilityHidden(true)
                Text(camera == .denied ? "Camera is off for Farside" : "No camera here")
                    .font(.headline)
                    .foregroundStyle(Farside.Palette.bone)
                Text(camera == .denied ? "Turn on Camera for Farside in Settings, or paste the code instead."
                                       : "This device can’t scan. Paste the code instead.")
                    .font(.subheadline)
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                if camera == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 48))
                    .padding(.top, Farside.Space.xxs)
                }
                Button("Paste Code Instead") { entry = .paste }
                    .buttonStyle(FarsideLinkButtonStyle())
            }
            .padding(Farside.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .farsidePlate()
        case .scanning:
            ZStack {
                ScannerView(onCode: { code in
                    if burst { return true }
                    return stageCode(code)
                }, onRejected: { reason in
                    problem = reason
                    problemSerial &+= 1
                }, onUnavailable: {
                    camera = PermissionPrimer.cameraDenied ? .denied : .unavailable
                })
                .accessibilityLabel("Camera viewfinder")
                ViewfinderCorners()
                    .stroke(Farside.Palette.bone, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(44)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack {
                    Spacer()
                    Text("Aim at the code on your Mac")
                        .farsideCaption(Farside.Palette.bone)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Farside.Palette.void.opacity(0.8), in: .capsule)
                        .padding(.bottom, 14)
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: SessionChromePolicy.cameraMaxHeight(regular: horizontalSizeClass == .regular, enabled: FarsideShellLayout.enabled))
            .background(Color.black, in: .rect(cornerRadius: Farside.Radius.sheet, style: .continuous))
            .clipShape(.rect(cornerRadius: Farside.Radius.sheet, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Farside.Radius.sheet, style: .continuous).strokeBorder(Farside.Palette.line, lineWidth: 1))
        }
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Code from your Mac", text: $model.pairingCode, axis: .vertical)
                .font(.callout.monospaced())
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(3...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .focused($codeFocused)
                .padding(14)
                .farsidePlate(Farside.Radius.card - 2, fill: Farside.Palette.panel, stroke: Farside.Palette.line2)
                .accessibilityLabel("Pairing code")
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { model.pairingCode = first }
                }
                .tint(Farside.Palette.panel2)
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                Spacer()
                if !model.pairingCode.isEmpty {
                    Button("Clear") { model.pairingCode = "" }
                        .buttonStyle(FarsideLinkButtonStyle())
                }
            }
            Text("On your Mac, copy the pairing code, then paste it here. Keep it private.")
                .font(.footnote)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, "On your Mac, open Farside and choose Pair a phone.")
            step(2, entry == .scan ? "Point this \(DeviceWord.current) at the code within two minutes."
                                   : "Paste the copied code within two minutes.")
            step(3, "Check that both screens show the same code, then choose Allow on your Mac.", last: true)
        }
        .farsidePlate(Farside.Radius.card, fill: .clear)
    }

    private func step(_ number: Int, _ text: String, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Farside.Space.s) {
            Text("\(number)")
                .font(Farside.Typeface.caption(.footnote).weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Farside.Palette.bone)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Farside.Space.m)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Farside.Palette.line).frame(height: 1).padding(.leading, 52) }
        }
        .accessibilityElement(children: .combine)
    }

    /// Celebrate only after the Mac has approved this exact handshake and trust is saved.
    private func celebrate() {
        codeFocused = false
        burst = true
        onPaired()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { dismiss() }
    }

    private func pair() {
        let code = model.pairingCode
        _ = stageCode(code)
    }
}

private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.16
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return path
    }
}
