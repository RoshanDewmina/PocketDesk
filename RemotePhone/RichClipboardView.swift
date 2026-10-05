import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Image bytes enter only from the system's explicit Paste action. Metadata checks cover every
/// representation before any provider is loaded; a changed clipboard or retired UI drops the load.
@MainActor
final class PhoneRichImageLoader: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var notice: String?
    private var generation = UUID()
    private var progress: Progress?
    func cancel() { generation = UUID(); progress?.cancel(); progress = nil; loading = false }
    func load(_ providers: [NSItemProvider], model: PhoneRemoteModel) {
        guard !loading, providers.count == 1, model.richClipboardAvailable, !model.richClipboard.busy else { return }
        let types = Set(providers.flatMap(\.registeredTypeIdentifiers) + UIPasteboard.general.types + UIPasteboard.general.itemProviders.flatMap(\.registeredTypeIdentifiers))
        guard ClipboardPrivacy.verdict(forTypes: types) == .shareable else { notice = "This clipboard is marked private and cannot be shared."; return }
        let provider = providers[0]
        let type = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ? UTType.png.identifier : provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        guard let type else { notice = "The clipboard has no supported image."; return }
        let count = UIPasteboard.general.changeCount, generation = UUID(); self.generation = generation; loading = true; notice = nil
        progress = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self, weak model] url, _ in
            let result: Result<RichClipboardPNG, Error> = Result {
                guard let url else { throw ClipboardStatus.unsupported }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                guard try handle.seekToEnd() <= UInt64(RichClipboardLimits.encodedBytes) else { throw ClipboardStatus.tooLarge }
                try handle.seek(toOffset: 0)
                guard let data = try handle.read(upToCount: RichClipboardLimits.encodedBytes + 1), !data.isEmpty,
                      data.count <= RichClipboardLimits.encodedBytes else { throw ClipboardStatus.tooLarge }
                return try RichClipboardPNG.normalize(data)
            }
            Task { @MainActor in
                guard let self, let model, self.generation == generation else { return }
                self.loading = false; self.progress = nil
                guard model.richClipboardAvailable, UIPasteboard.general.changeCount == count else { self.notice = "The clipboard changed. Tap Paste again."; return }
                switch result {
                case .success(let png): model.richClipboard.sendImage(RichClipboardSource(png: png, stillCurrent: { UIPasteboard.general.changeCount == count }))
                case .failure: self.notice = "Use a single image under 8 MB and 16 megapixels."
                }
            }
        }
    }
}
struct RichImagePasteControl: UIViewRepresentable {
    let enabled: Bool
    let receive: ([NSItemProvider]) -> Void
    func makeUIView(context: Context) -> Target {
        let view = Target(); view.receive = receive
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        let control = UIPasteControl(configuration: configuration); control.target = view
        control.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(control); view.control = control
        NSLayoutConstraint.activate([control.topAnchor.constraint(equalTo: view.topAnchor), control.leadingAnchor.constraint(equalTo: view.leadingAnchor), control.bottomAnchor.constraint(equalTo: view.bottomAnchor), control.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        control.accessibilityLabel = "Copy clipboard image to your Mac"
        return view
    }
    func updateUIView(_ view: Target, context: Context) { view.receive = receive; view.control?.isUserInteractionEnabled = enabled; view.alpha = enabled ? 1 : 0.4 }
    final class Target: UIView {
        var receive: (([NSItemProvider]) -> Void)?
        var control: UIPasteControl?
        override func paste(itemProviders: [NSItemProvider]) { receive?(itemProviders) }
    }
}
struct RichClipboardRow: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var clipboard: RichClipboardEndpoint
    @StateObject private var loader = PhoneRichImageLoader()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image clipboard").font(.subheadline.weight(.semibold))
            HStack {
                RichImagePasteControl(enabled: model.richClipboardAvailable && !clipboard.busy && !loader.loading && !model.clipboard.isBusy) { loader.load($0, model: model) }
                    .frame(width: 110, height: 44)
                    .accessibilityIdentifier("remote.clipboard.imageToMac")
                Button("Get Mac image") { clipboard.requestImage() }
                    .buttonStyle(FarsideSecondaryButtonStyle(height: 44, fullWidth: false))
                    .disabled(!model.richClipboardAvailable || clipboard.busy || loader.loading || model.clipboard.isBusy)
                    .accessibilityIdentifier("remote.clipboard.imageFromMac")
            }
            Text("Copy only · paste in the receiving app when ready · 8 MB / 16 MP max").farsideCaption()
            if loader.loading { ProgressView("Preparing image…") }
            if clipboard.busy {
                HStack { ProgressView(value: clipboard.progress); Button("Cancel", action: clipboard.cancel) }
            }
            if let notice = loader.notice ?? clipboard.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .onDisappear { loader.cancel() }
        .onChange(of: model.richClipboardAvailable) { _, available in if !available { loader.cancel(); clipboard.reset() } }
    }
}
