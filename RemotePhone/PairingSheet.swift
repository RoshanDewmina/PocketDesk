import SwiftUI
import AVFoundation

/// Pairing: camera first, steps beneath, and a paste alternative whose confirm button stays
/// pinned above the keyboard at every text size. Wrong or expired codes say so right away.
struct PairingSheet: View {
    @ObservedObject var model: PhoneRemoteModel
    let replacing: String?
    let onPaired: () -> Void
    @State private var entry: PairingEntry
    @State private var camera: CameraState
    @State private var problem: PairingCodeProblem?
    @State private var problemSerial = 0
    @State private var burst = false
    @State private var showsReplacementConfirmation = false
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum CameraState { case priming, scanning, denied, unavailable }

    init(model: PhoneRemoteModel, entry: PairingEntry, replacing: String? = nil, onPaired: @escaping () -> Void = {}) {
        self.model = model
        self.replacing = replacing
        self.onPaired = onPaired
        _entry = State(initialValue: entry)
        let initial: CameraState
        #if DEBUG
        if LaunchOptions.has("--ui-camera-priming") { initial = .priming }
        else if LaunchOptions.has("--ui-camera-denied") { initial = .denied }
        else if PermissionPrimer.needsPriming(.camera) { initial = .priming }
        else if PermissionPrimer.cameraDenied { initial = .denied }
        else { initial = .scanning }
        #else
        initial = PermissionPrimer.needsPriming(.camera) ? .priming : (PermissionPrimer.cameraDenied ? .denied : .scanning)
        #endif
        _camera = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Farside.Space.l) {
                    FarsideHeading("Pair your Mac.", accent: "your", size: 30)
                    FarsideSegmented(label: "Pairing method",
                                     options: [(PairingEntry.scan, "Scan"), (PairingEntry.paste, "Paste Code")],
                                     selection: $entry)

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

                    if let replacing {
                        Text("Add another Mac. \(replacing) stays paired with this iPhone.")
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
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if entry == .paste {
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
        .interactiveDismissDisabled(burst)
        .confirmationDialog("Replace this Mac pairing?", isPresented: $showsReplacementConfirmation,
                            titleVisibility: .visible, presenting: model.pendingPairReplacement) { pending in
            Button("Replace pairing") { if model.confirmPairReplacement(pending) { celebrate() } }
            Button("Cancel", role: .cancel) { model.cancelPairReplacement(); entry = .paste }
        } message: { pending in
            Text("Replace the saved pairing for \(pending.oldName) with this QR for \(pending.approval.enrollment.name)? The current session ends first. Your Mac must still approve this iPhone.")
        }
        .onChange(of: model.pendingPairReplacement?.id) { _, id in showsReplacementConfirmation = id != nil }
        .onChange(of: showsReplacementConfirmation) { _, shown in
            if !shown, model.pendingPairReplacement != nil { model.cancelPairReplacement(); entry = .paste }
        }
        .onDisappear { model.cancelPairReplacement() }
        .animation(Farside.Motion.easeOut(), value: problemSerial)
        .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: burst)
        .sensoryFeedback(.warning, trigger: problemSerial)
        .onChange(of: entry) { _, value in
            codeFocused = value == .paste
            problem = nil
        }
        .onChange(of: model.pairingCode) { _, _ in if entry == .paste { problem = nil } }
        .onAppear {
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
                    let paired = model.enroll(code)
                    if paired { celebrate() }
                    return paired
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
            .frame(maxHeight: 340)
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
            step(2, entry == .scan ? "Point this iPhone at the code within two minutes."
                                   : "Paste the copied code within two minutes.")
            step(3, "Choose Allow on your Mac to finish.", last: true)
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

    /// The code dissolves into the mark, then the sheet closes while the Mac asks for approval.
    private func celebrate() {
        codeFocused = false
        burst = true
        onPaired()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { dismiss() }
    }

    private func pair() {
        let code = model.pairingCode
        if model.enroll(code) {
            celebrate()
        } else if model.pendingPairReplacement == nil {
            problem = PairingCodeProblem(code: code)
            problemSerial &+= 1
        }
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
