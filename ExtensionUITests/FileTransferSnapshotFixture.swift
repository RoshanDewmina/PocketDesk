// TEST-ONLY COPY of FileTransferCapsule from RemotePhone/FileTransferViews.swift.
// Source SHA-256 before extraction: 5a48cadbcb54e213669f3cfa3eae97f400884af0e4531905d22292cf6e0f5f6f
// The production source is untouched. Keep this view body synchronized deliberately.
// OS-owned received-file Share UI is deliberately not seeded or imitated.

import SwiftUI

struct FileTransferSnapshot: Equatable {
    enum Phase: Equatable { case waiting, transferring, verifying }
    enum Direction: Equatable { case outgoing, incoming }
    let transfer: String
    let direction: Direction
    var name: String
    var total: Int64
    var bytes: Int64
    var phase: Phase
    var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
}

struct FixtureClipboardNotice: Equatable, Identifiable {
    enum Tone: Equatable { case success, caution }
    let id: UInt64
    let message: String
    let tone: Tone
}

struct FixtureReceivedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

@MainActor
final class PhoneFileTransfer: ObservableObject {
    @Published var snapshot: FileTransferSnapshot?
    @Published var waitingForMac = false
    @Published var notice: FixtureClipboardNotice?
    @Published var received: FixtureReceivedFile?
    func cancel() {}
    func clearNotice() {}
}

struct FixtureSendToMacItem {
    enum Kind { case file, text, link }
    let kind: Kind
    var name: String?
    var destinationName: String?
    var destinationID: String?
    func isBound(to destination: String?) -> Bool {
        guard let destinationID, let destination else { return false }
        return destinationID == destination
    }
}

@MainActor
final class SendToMacInbox: ObservableObject {
    @Published var offer: FixtureSendToMacItem?
    @Published var selectedDestination: String?
    @Published var selectedName = "selected Mac"
    func confirm() {}
    func retargetAndConfirm(to destination: String) {}
    func discard() {}
}

// Never seeded in these fixtures: the OS received-file Share sheet is listed as NOT CAPTURED.
struct ActivitySheet: View {
    let url: URL
    var body: some View { EmptyView() }
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

    static func offerTitle(_ item: FixtureSendToMacItem) -> String {
        switch item.kind {
        case .file: "Send “\(item.name ?? "file")” to your Mac?"
        case .text: "Send the shared text to your Mac’s clipboard?"
        case .link: "Send the shared link to your Mac?"
        }
    }
}
