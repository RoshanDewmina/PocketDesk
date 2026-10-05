import SwiftUI
import UIKit

@MainActor
final class FrozenTextController: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var image: CGImage?
    @Published var text = ""
    @Published private(set) var status = ""
    private var token = UUID()
    private var timer: Timer?
    private var admission: VideoPresentationAdmission?
    private var allowed: (() -> Bool)?
    private weak var session: VideoPresentationSession?
    private static weak var active: FrozenTextController?
    static func cancelActive() { active?.cancel() }
    private static let workGate = FrozenTextWorkGate()
    private static let queue = DispatchQueue(label: "farside.text-recognition", qos: .userInitiated)

    func start(model: PhoneRemoteModel, visible: CGRect) {
        cancel()
        guard !Self.workGate.isBusy else {
            isPresented = true; status = "The previous recognition is finishing. Close and try again in a moment."; return
        }
        guard model.textRecognitionAvailable, !model.passwordFieldFocused,
              !model.contentConcealed, !model.privacyShield, !model.captureScopeViewOnly,
              let admission = model.inlinePresentationAdmission,
              let session = VideoPresentationSession.active, session.admissionIdentity == admission.identity,
              let crop = FrozenTextSnapshot.normalizedCrop(visible: visible,
                placement: model.placementRegion?.rect ?? CGRect(origin: .zero, size: model.sourceSize)) else { return }
        Self.active?.cancel(); Self.active = self
        self.admission = admission; self.session = session
        allowed = { [weak model, weak session] in
            guard let model, let session else { return false }
            return model.textRecognitionAvailable && !model.passwordFieldFocused &&
                !model.contentConcealed && !model.privacyShield && !model.captureScopeViewOnly &&
                model.inlinePresentationAdmission?.identity == admission.identity &&
                model.inlinePresentationAdmission?.permits(at: ProcessInfo.processInfo.systemUptime) == true &&
                session.admissionLifetime.isActive && !session.isTerminal
        }
        let job = token
        isPresented = true; status = "Capturing the next displayed frame…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.allowed?() != true { self.cancel() }
            }
        }
        session.requestTextSnapshot(crop: crop) { [weak self] copied in
            DispatchQueue.main.async {
                guard let self, self.token == job, self.allowed?() == true else { return }
                guard let copied else { self.status = "This frame could not be copied. Close and try again."; return }
                guard Self.workGate.begin() else { self.status = "Recognition is still finishing. Close and try again."; return }
                self.image = copied; self.status = "Recognizing text on this device…"
                Self.queue.async {
                    let result = try? FrozenTextSnapshot.recognize(copied)
                    Self.workGate.finish()
                    DispatchQueue.main.async {
                        guard self.token == job, self.allowed?() == true else { return }
                        self.text = result ?? ""
                        self.status = result == nil ? "Text recognition failed. Close and try again." :
                            self.text.isEmpty ? "No text found in this frame." : "Review recognized text before copying."
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+4) { [weak self] in
            guard let self, self.token == job, self.image == nil else { return }
            session.cancelTextSnapshot()
            self.status = "A displayed frame was unavailable. Close and try again."
        }
    }
    func copyText() {
        guard allowed?() == true, let admission, text.utf8.count <= 256*1024 else { cancel(); return }
        _ = admission.lifetime.withActive { UIPasteboard.general.string = text }
    }
    func cancel() {
        token = UUID(); session?.cancelTextSnapshot(); session = nil
        timer?.invalidate(); timer = nil; admission = nil; allowed = nil
        if Self.active === self { Self.active = nil }
        image = nil; text = ""; status = ""; isPresented = false
    }
}

struct FrozenTextSheet: View {
    @ObservedObject var controller: FrozenTextController
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = controller.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 220)
                        .accessibilityLabel("Frozen picture used for recognition")
                }
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $controller.text).font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Recognized text, editable")
                Button("Copy reviewed text") { controller.copyText() }.buttonStyle(.borderedProminent)
                    .disabled(controller.image == nil || controller.text.isEmpty)
                Text("Processed on this device. Closing clears the frozen picture and text.").font(.caption)
            }.padding().navigationTitle("Select text")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { controller.cancel() } } }
        }
    }
}
