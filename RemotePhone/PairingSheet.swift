import SwiftUI

/// Pairing, after Apple Home's Add Accessory sheet: camera first, steps beneath, and a
/// paste alternative whose confirm button stays pinned above the keyboard at every text size.
struct PairingSheet: View {
    @ObservedObject var model: PhoneRemoteModel
    @State private var entry: PairingEntry
    @State private var cameraUnavailable = false
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: PhoneRemoteModel, entry: PairingEntry) {
        self.model = model
        _entry = State(initialValue: entry)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Pairing method", selection: $entry) {
                        Text("Scan").tag(PairingEntry.scan)
                        Text("Paste Code").tag(PairingEntry.paste)
                    }
                    .pickerStyle(.segmented)

                    if entry == .scan { scanner } else { pasteField }

                    if !model.error.isEmpty {
                        Label(model.error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(PhoneTheme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    steps
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PhoneTheme.background.ignoresSafeArea())
            .navigationTitle("Pair Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if entry == .paste {
                    Button(action: pair) {
                        Text("Pair Mac").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(model.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 560)
                }
            }
        }
        .onChange(of: entry) { _, value in codeFocused = value == .paste }
        .accessibilityIdentifier("pairing.sheet")
    }

    private var scanner: some View {
        ZStack {
            if cameraUnavailable {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Camera unavailable")
                        .font(.headline)
                    Text("Allow camera access for PocketDesk in Settings, or paste the code instead.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Paste Code Instead") { entry = .paste }
                        .buttonStyle(.glass)
                        .padding(.top, 4)
                }
                .padding(24)
            } else {
                ScannerView(onCode: { code in
                    let paired = model.enroll(code)
                    if paired { dismiss() }
                    return paired
                }, onUnavailable: { cameraUnavailable = true })
                .accessibilityLabel("Camera viewfinder")
                ViewfinderCorners()
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(44)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: 340)
        .background(cameraUnavailable ? AnyShapeStyle(PhoneTheme.card) : AnyShapeStyle(Color.black),
                    in: .rect(cornerRadius: 28, style: .continuous))
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Code from your Mac", text: $model.pairingCode, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(3...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .focused($codeFocused)
                .padding(14)
                .background(PhoneTheme.card, in: .rect(cornerRadius: 18, style: .continuous))
                .accessibilityLabel("Pairing code")
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { model.pairingCode = first }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                Spacer()
                if !model.pairingCode.isEmpty {
                    Button("Clear", role: .destructive) { model.pairingCode = "" }
                        .buttonStyle(.borderless)
                }
            }
            Text("On your Mac, click Copy pairing code, then paste it here. Keep it private.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(1, "On your Mac, open PocketDesk and click Pair a phone.")
            step(2, entry == .scan ? "Point this iPhone at the code within two minutes."
                                   : "Paste the copied code within two minutes.")
            step(3, "Click Approve on your Mac to finish.")
        }
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(PhoneTheme.tint)
                .font(.title3)
        }
    }

    private func pair() {
        if model.enroll(model.pairingCode) { dismiss() }
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
