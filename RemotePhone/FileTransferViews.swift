import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Send file · Photo · From Mac, under the clipboard actions in the dock's Clip row.
struct FileTransferRow: View {
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var files: PhoneFileTransfer
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false

    /// Unavailable buttons stay tappable so a tap can say why; only a transfer in flight disables them.
    private var enabled: Bool { model.fileTransferSupported && !files.isBusy && !loadingPhoto }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { attempt { importing = true } } label: {
                    Label("File", systemImage: "doc.badge.arrow.up").font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Send a file to your Mac")
                .accessibilityIdentifier("remote.files.send")
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                    Label("Photo", systemImage: "photo").font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Send a photo or video to your Mac")
                .accessibilityIdentifier("remote.files.photo")
                Button { attempt { model.requestFileFromMac() } } label: {
                    Label("From Mac", systemImage: "arrow.down.doc").font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Get a file from your Mac")
                .accessibilityHint("Opens a file picker on your Mac’s screen")
                .accessibilityIdentifier("remote.files.fromMac")
            }
            .buttonStyle(FarsideSecondaryButtonStyle(height: 44, fullWidth: false))
            .disabled(!enabled)
            Text(caption).farsideCaption()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            model.sendFileToMac(url, securityScoped: true)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            loadingPhoto = true
            Task { @MainActor in
                defer { loadingPhoto = false }
                guard let picked = try? await item.loadTransferable(type: PickedMediaFile.self) else {
                    files.postUnavailable("That photo couldn’t be read. Try another, or save it to Files first.")
                    return
                }
                model.sendFileToMac(picked.url, securityScoped: false) { picked.discard() }
            }
        }
    }

    private var caption: String {
        if loadingPhoto { return "Preparing the photo…" }
        if !model.fileTransferSupported { return "Files need the updated Farside on your Mac" }
        return "Files · one at a time · 1 GB max · keep Farside open"
    }

    private func attempt(_ action: () -> Void) {
        guard model.fileTransferAvailable else { files.postUnavailable(model.fileTransferUnavailableMessage); return }
        action()
    }
}

/// A photo or video copied out of the picker's temporary file into Farside's own temporary folder.
struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Outgoing-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent, isDirectory: false)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMediaFile(url: target)
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// Progress with Cancel, "Choose a file on your Mac…", the share-sheet hand-off prompt and results.
struct FileTransferCapsule: View {
    @ObservedObject var files: PhoneFileTransfer
    @ObservedObject var inbox: SendToMacInbox
    var hidesNotice: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let snapshot = files.snapshot {
                progress(snapshot)
            } else if files.waitingForMac {
                plate {
                    ProgressView().controlSize(.small).tint(Farside.Palette.bone)
                    Text("Choose a file on your Mac…").font(.subheadline.weight(.medium))
                    cancelButton
                }
            } else if let offer = inbox.offer {
                plate {
                    Image(systemName: "square.and.arrow.up").accessibilityHidden(true)
                    Text(offer.isBound(to: inbox.selectedDestination) ? Self.offerTitle(offer)
                         : "Shared for \(offer.destinationName ?? "an unselected Mac"). Choose a destination before sending.").font(.subheadline.weight(.medium)).lineLimit(2)
                    if offer.isBound(to: inbox.selectedDestination) {
                        Button("Send", action: inbox.confirm)
                            .buttonStyle(FarsidePrimaryButtonStyle(height: 34)).fixedSize()
                            .accessibilityIdentifier("remote.files.shareSend")
                    } else if let destination = inbox.selectedDestination {
                        Button("Send to \(inbox.selectedName) instead") { inbox.retargetAndConfirm(to: destination) }
                            .buttonStyle(FarsidePrimaryButtonStyle(height: 34))
                            .accessibilityIdentifier("remote.files.shareRetarget")
                    }
                    Button("Discard", action: inbox.discard)
                        .buttonStyle(FarsideLinkButtonStyle())
                        .accessibilityIdentifier("remote.files.shareDiscard")
                }
            } else if let notice = files.notice, !hidesNotice {
                FarsideNotice(message: notice.message, tone: notice.tone == .success ? .success : .caution)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 16)
                    .onTapGesture { files.clearNotice() }
                    .accessibilityIdentifier("remote.files.notice")
            }
        }
        .transition(.opacity)
        .task(id: files.notice?.id) {
            guard files.notice != nil else { return }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { files.clearNotice() }
        }
        .onChange(of: files.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.message).post() }
        }
        .sensoryFeedback(trigger: files.notice?.id) { _, _ in
            guard let notice = files.notice else { return nil }
            return notice.tone == .success ? .success : .warning
        }
        .sheet(item: $files.received) { file in
            ActivitySheet(url: file.url).ignoresSafeArea()
        }
    }

    private func progress(_ snapshot: FileTransferSnapshot) -> some View {
        plate {
            if snapshot.phase == .waiting {
                ProgressView().controlSize(.small).tint(Farside.Palette.bone)
            } else {
                ProgressView(value: snapshot.fraction).tint(Farside.Palette.bone).frame(width: 64)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(Self.detail(snapshot)).farsideCaption().monospacedDigit()
            }
            cancelButton
        }
        .accessibilityValue(Text(snapshot.fraction, format: .percent.precision(.fractionLength(0))))
    }

    private var cancelButton: some View {
        Button { files.cancel() } label: {
            Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel transfer")
        .accessibilityIdentifier("remote.files.cancel")
    }

    private func plate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .foregroundStyle(Farside.Palette.bone)
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
    }

    static func detail(_ snapshot: FileTransferSnapshot) -> String {
        let direction = snapshot.direction == .outgoing ? "To Mac" : "From Mac"
        switch snapshot.phase {
        case .waiting: return direction + " · waiting for your Mac"
        case .verifying: return direction + " · checking"
        case .transferring:
            let sent = ByteCountFormatter.string(fromByteCount: snapshot.bytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: snapshot.total, countStyle: .file)
            return direction + " · " + sent + " of " + total
        }
    }

    static func offerTitle(_ item: SendToMacItem) -> String {
        switch item.kind {
        case .file: "Send “\(item.name ?? "file")” to your Mac?"
        case .text: "Send the shared text to your Mac’s clipboard?"
        case .link: "Send the shared link to your Mac?"
        }
    }
}

/// Share, Save to Files or open a received file elsewhere. Farside itself never opens it.
struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
