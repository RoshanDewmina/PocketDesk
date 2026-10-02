import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Send to My Mac: one file, photo, video, piece of text or web link from any app's share sheet.
/// It needs Farside paired with a Mac that is connected now or was within the reconnect window;
/// otherwise it says so and keeps nothing. It never talks to the Mac itself: the app does, over its
/// end-to-end encrypted session.
final class ShareViewController: UIViewController {
    private lazy var model = ShareSendModel(finish: { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: nil)
    }, cancel: { [weak self] in
        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    })

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareSendView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.load(providers)
    }
}

@MainActor
final class ShareSendModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable(String)
        case sending(Double?, String)
        case handedOff(String)
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var summary = ""
    @Published private(set) var macName = "your Mac"

    private let finish: () -> Void
    private let cancel: () -> Void
    private var beacon: SendToMacBeacon?
    private var item: SendToMacItem?
    private var payload: URL?
    private var poll: Task<Void, Never>?

    init(finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.finish = finish
        self.cancel = cancel
    }

    func load(_ providers: [NSItemProvider]) {
        _ = SendToMacOutbox.pending()
        guard SendToMacOutbox.root != nil, let beacon = SendToMacOutbox.loadBeacon() else {
            phase = .unavailable("Open Farside and pair using a fresh owner-approved QR code, then share again.")
            return
        }
        self.beacon = beacon
        macName = beacon.macName
        guard beacon.isConnectable(at: Date()) else {
            phase = .unavailable("\(beacon.macName) isn’t connected. Open Farside and connect, then share again.")
            return
        }
        guard let provider = providers.first else {
            phase = .unavailable("There’s nothing here Farside can send.")
            return
        }
        Task { await extract(provider, extra: providers.count - 1) }
    }

    private func extract(_ provider: NSItemProvider, extra: Int) async {
        let now = Date()
        let note = extra > 0 ? " Only the first item is sent." : ""
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  url.absoluteString.utf8.count <= SendToMacItem.maximumLinkBytes else {
                phase = .unavailable("Only web links can be sent.")
                return
            }
            guard beacon?.filesSupported == true else { phase = .unavailable(Self.updateMac); return }
            item = SendToMacItem(id: SendToMacOutbox.makeID(), kind: .link, text: url.absoluteString, created: now,
                                 expires: now.addingTimeInterval(SendToMacItem.lifetime), immediate: false)
            summary = (url.host() ?? "Link") + note
            phase = .ready
            return
        }
        // A shared document (it has a file URL) goes as a file even when it is text, like a .txt or .swift file.
        let isDocument = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        if let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: {
            $0.conforms(to: .data) && (isDocument || !$0.conforms(to: .text))
        }) {
            guard beacon?.filesSupported == true else { phase = .unavailable(Self.updateMac); return }
            await loadFile(provider, type: type, note: note, now: now)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
           !text.isEmpty {
            guard text.utf8.count <= SendToMacItem.maximumTextBytes else {
                phase = .unavailable("That text is over 256 KB, the clipboard limit.")
                return
            }
            item = SendToMacItem(id: SendToMacOutbox.makeID(), kind: .text, text: text, created: now,
                                 expires: now.addingTimeInterval(SendToMacItem.lifetime), immediate: false)
            summary = "Text for your Mac’s clipboard" + note
            phase = .ready
            return
        }
        phase = .unavailable("There’s nothing here Farside can send.")
    }

    private func loadFile(_ provider: NSItemProvider, type: UTType, note: String, now: Date) async {
        let staged: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let target = folder.appendingPathComponent(url.lastPathComponent, isDirectory: false)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try SendToMacOutbox.protectStagedContent(at: folder)
                    try FileManager.default.copyItem(at: url, to: target)
                    try SendToMacOutbox.protectStagedContent(at: target)
                    continuation.resume(returning: target)
                } catch {
                    if SendToMacOutbox.protectionEnabled { try? FileManager.default.removeItem(at: folder) }
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let staged,
              let values = try? staged.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            if SendToMacOutbox.protectionEnabled, let staged {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            }
            phase = .unavailable("Farside couldn’t read that item. Folders can’t be sent; zip them first.")
            return
        }
        guard size > 0, Int64(size) <= SendToMacItem.maximumFileBytes else {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            phase = .unavailable(size == 0 ? "That file is empty." : "That file is over 1 GB, the limit for now.")
            return
        }
        let name = Self.name(suggested: provider.suggestedName, file: staged)
        payload = staged
        item = SendToMacItem(id: SendToMacOutbox.makeID(), kind: .file, name: name, bytes: Int64(size), created: now,
                             expires: now.addingTimeInterval(SendToMacItem.lifetime), immediate: false)
        summary = name + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + note
        phase = .ready
    }

    func send() {
        guard var item, let beacon else { return }
        guard let destination = beacon.destination, destination.isValid else {
            phase = .failed("Open Farside and select a paired Mac, then share again.")
            return
        }
        // The target shown when the sheet opened is frozen. A newer beacon only decides whether
        // this same target/session is still live; it never substitutes a different Mac or grant.
        let current = SendToMacOutbox.loadBeacon()
        item.destination = destination
        item.destinationName = beacon.macName
        item.liveSessionID = beacon.liveSessionID
        item.immediate = beacon.isLive(at: Date()) && current?.isLive(at: Date()) == true
            && current?.destination == destination && current?.liveSessionID == beacon.liveSessionID
        do {
            try SendToMacOutbox.stage(item, payload: payload)
        } catch {
            phase = .failed("Farside couldn’t hold that item. Try again.")
            return
        }
        payload = nil
        self.item = item
        SendToMacOutbox.postOutboxChanged()
        phase = .sending(nil, "Handing it to Farside…")
        let id = item.id, name = beacon.macName
        poll = Task { @MainActor [weak self] in
            let started = Date()
            var taken = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                if let receipt = SendToMacOutbox.loadReceipt(id) {
                    taken = true
                    switch receipt.state {
                    case .sending: self.phase = .sending(receipt.fraction, receipt.message)
                    case .sent:
                        SendToMacOutbox.removeReceipt(id)
                        self.phase = .finished(receipt.message)
                        return
                    case .failed:
                        SendToMacOutbox.removeReceipt(id)
                        self.phase = .failed(receipt.message)
                        return
                    }
                } else if !taken, Date().timeIntervalSince(started) > 2.5 {
                    let cleanup = SendToMacOutbox.protectionEnabled ? " Expired items are cleared on next use." : ""
                    self.phase = .handedOff("Open Farside to finish sending to \(name). It asks before sending, and this expires in 10 minutes." + cleanup)
                    return
                }
            }
        }
    }

    func close() {
        poll?.cancel()
        if let payload { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        switch phase {
        case .loading, .ready, .unavailable: cancel()
        default: finish()
        }
    }

    private static let updateMac = "Files and links need the updated Farside on your Mac."

    static func name(suggested: String?, file: URL) -> String {
        let ext = file.pathExtension
        guard let suggested, !suggested.isEmpty else { return file.lastPathComponent }
        if ext.isEmpty || suggested.lowercased().hasSuffix("." + ext.lowercased()) { return suggested }
        return suggested + "." + ext
    }
}

struct ShareSendView: View {
    @ObservedObject var model: ShareSendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Send to My Mac").font(.headline)
                Spacer()
                Button(closeTitle) { model.close() }
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("share.close")
            }
            content
            Spacer(minLength: 0)
        }
        .foregroundStyle(Farside.Palette.bone)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Farside.Palette.void)
        .preferredColorScheme(.dark)
    }

    private var closeTitle: String {
        switch model.phase {
        case .loading, .ready, .unavailable: "Cancel"
        default: "Done"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(Farside.Palette.bone)
        case .ready:
            Text(model.summary).font(.subheadline).foregroundStyle(Farside.Palette.ash).lineLimit(3)
            Button { model.send() } label: {
                Text("Send to \(model.macName)")
                    .font(.headline)
                    .foregroundStyle(Farside.Palette.void)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Farside.Palette.bone, in: .capsule)
            }
            .accessibilityIdentifier("share.send")
            Text("Sent over your end-to-end encrypted Farside session. Files land in Downloads › Farside; text and links go to the Mac’s clipboard.")
                .font(.caption).foregroundStyle(Farside.Palette.ash)
        case .unavailable(let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").font(.subheadline)
        case .sending(let fraction, let message):
            if let fraction { ProgressView(value: fraction).tint(Farside.Palette.bone) } else { ProgressView().tint(Farside.Palette.bone) }
            Text(message).font(.subheadline)
        case .handedOff(let message):
            Label(message, systemImage: "arrow.up.forward.app").font(.subheadline)
        case .finished(let message):
            Label(message, systemImage: "checkmark").font(.subheadline)
        }
    }
}
