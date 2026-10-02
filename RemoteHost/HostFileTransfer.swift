import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Mac half of file transfer. Files from the phone land in ~/Downloads/Farside, quarantined so
/// Gatekeeper checks them, never overwrite anything and are never opened automatically. A file for
/// the phone is always chosen by someone in an open panel on the Mac's own (streamed) screen.
/// Names and contents stay out of logs; only the local notification shows a name.
@MainActor
final class HostFileTransferService {
    let engine: FileTransferEngine
    /// Nil when this session may transfer files, otherwise the refusal to send.
    var refusal: () -> FileTransferStatus? = { .notAllowed }
    /// Which condition refused, sent with the refusal so the phone can say why (and logged by the owner).
    var refusalReason: () -> String? = { nil }

    private let destination: () -> URL?
    private let pasteboard: HostPasteboardAccess
    private let queue: DispatchQueue
    private let linkOffer: HostLinkOffer
    private var effectLease = TransferEffectLease()
    private var linkOfferID: UUID?
    private let notifier = HostTransferNotifier()
    private var panel: NSOpenPanel?
    private var panelTransfer: String?
    private var authorityGeneration = UUID()

    init(destination: @escaping () -> URL? = HostFileTransferService.defaultDestination,
         pasteboard: HostPasteboardAccess = SystemHostPasteboard(),
         queue: DispatchQueue = DispatchQueue(label: "Farside.file-destination", qos: .userInitiated),
         linkOffer: HostLinkOffer? = nil, io: FileTransferIO = FileTransferIO()) {
        self.engine = FileTransferEngine(acceptsUnsolicitedOffers: true, io: io)
        self.destination = destination
        self.pasteboard = pasteboard
        self.queue = queue; self.linkOffer = linkOffer ?? .shared
        engine.admit = { [weak self] offer, answer in
            guard let self else { answer(.failure(.notAllowed)); return }
            self.admit(offer, answer: answer)
        }
        engine.onRequest = { [weak self] transfer in self?.presentPicker(for: transfer) }
        engine.onRequestCancelled = { [weak self] transfer in self?.closePicker(matching: transfer) }
        engine.onLink = { [weak self] transfer, url in self?.receiveLink(transfer, url) }
        engine.onFinish = { [weak self] finish in self?.finished(finish) }
    }

    /// Why files are refused, first failing condition wins. Travels as the result's `reason`.
    enum Refusal: String {
        case viewOnlyScope, noSession, notSharing, controlDisabled, paused, viewOnly, locking, lockFailed
        var status: FileTransferStatus { self == .viewOnlyScope ? .disabled : .notAllowed }
    }

    /// MS05: there is no Mac setting. A view-only sharing scope refuses files; otherwise only a current,
    /// unpaused, sharing session with owner control consent that is not in live view only or locking may transfer. A stored legacy
    /// `allowFileTransfer` value is never read.
    nonisolated static func refusal(viewOnlyScope: Bool, connected: Bool, sharing: Bool, controlAllowed: Bool, paused: Bool,
                                    liveViewOnly: Bool, locking: Bool, lockFailed: Bool = false) -> Refusal? {
        if viewOnlyScope { return .viewOnlyScope }
        if !connected { return .noSession }
        if !sharing { return .notSharing }
        if !controlAllowed { return .controlDisabled }
        if paused { return .paused }
        if liveViewOnly { return .viewOnly }
        if lockFailed { return .lockFailed }
        if locking { return .locking }
        return nil
    }

    nonisolated static func defaultDestination() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Farside", isDirectory: true)
    }

    func receive(_ frame: FileFrame, current: Bool) {
        // Fence every control frame, including completion of an already admitted transfer.
        guard current else { return }
        if ["offer", "request", "link"].contains(frame.op), let status = refusal() {
            _ = engine.sendControl?(.result(frame.transfer, status, reason: refusalReason()))
            return
        }
        engine.receive(frame)
    }

    /// Authority changed mid-transfer: stop and tell the phone.
    func revoke() {
        effectLease.retire(); effectLease = TransferEffectLease()
        if let linkOfferID { linkOffer.dismiss(matching: linkOfferID) }; linkOfferID = nil
        authorityGeneration = UUID()
        closePicker(matching: nil)
        engine.cancelAll(status: .notAllowed)
    }

    /// The session ended or paused: stop without messages, since the phone is gone or backgrounded.
    func reset() {
        effectLease.retire(); effectLease = TransferEffectLease()
        if let linkOfferID { linkOffer.dismiss(matching: linkOfferID) }; linkOfferID = nil
        authorityGeneration = UUID()
        closePicker(matching: nil)
        engine.reset()
    }

    // MARK: Phone → Mac

    private func admit(_ offer: FileTransferOffer,
                       answer: @escaping @MainActor (Result<FileByteSink, FileTransferStatus>) -> Void) {
        guard refusal() == nil else { answer(.failure(refusal() ?? .notAllowed)); return }
        guard let folder = destination() else { answer(.failure(.denied)); return }
        // Off the main thread: the first write into Downloads can wait on a macOS consent prompt,
        // and input from the phone must keep flowing so someone can answer it remotely.
        let generation = authorityGeneration, lease = effectLease
        queue.async { [weak self] in
            guard lease.isActive else {
                SessionLog.log.error("file refused: superseded (session reset while admitting)")
                DispatchQueue.main.async { MainActor.assumeIsolated { answer(.failure(.notAllowed)) } }; return
            }
            let result = Self.prepareSink(for: offer, in: folder)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.authorityGeneration == generation else {
                    SessionLog.log.error("file refused: superseded (session reset while admitting)")
                    if case .success(let sink) = result { sink.discard() }
                    answer(.failure(.notAllowed)); return
                }
                if let refusal = self.refusal() {
                    if case .success(let sink) = result { sink.discard() }
                    answer(.failure(refusal)); return
                }
                answer(result)
            } }
        }
    }

    nonisolated static func prepareSink(for offer: FileTransferOffer, in folder: URL) -> Result<FileByteSink, FileTransferStatus> {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            guard FileTransferLimits.hasRoom(for: offer.bytes, available: available) else { return .failure(.diskFull) }
            let sink = try FolderFileSink(folder: folder, partialFolder: folder, name: offer.name,
                                          transfer: offer.transfer, finalize: quarantine)
            return .success(sink)
        } catch {
            return .failure(FolderFileSink.status(for: error))
        }
    }

    /// Marks a received file as downloaded, so Gatekeeper checks apps and scripts before they run.
    nonisolated static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Farside",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String
        ]
        var target = url
        try target.setResourceValues(values)
    }

    private func finished(_ finish: FileTransferFinish) {
        guard finish.direction == .incoming, finish.status == .stored, let url = finish.savedURL else { return }
        notifier.announceReceived(url)
    }

    // MARK: Links

    private func receiveLink(_ transfer: String, _ text: String) {
        guard refusal() == nil else { _ = engine.sendControl?(.result(transfer, .notAllowed)); return }
        guard let url = URL(string: text) else { _ = engine.sendControl?(.result(transfer, .invalid)); return }
        let pasteboard = self.pasteboard, lease = effectLease
        queue.async { _ = lease.performIfActive { pasteboard.write(ClipboardPayload(text: text, kind: .url)) } }
        linkOfferID = linkOffer.present(url, lease: lease, authorized: { [weak self] in
            guard let self else { return false }; return self.effectLease === lease && self.refusal() == nil
        })
        _ = engine.sendControl?(.result(transfer, .offered))
    }

    // MARK: Mac → phone

    private func presentPicker(for transfer: String) {
        if let status = refusal() { engine.answerRequest(transfer, status, reason: refusalReason()); return }
        guard panel == nil else { engine.answerRequest(transfer, .busy); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true
        panel.title = "Send to your iPhone"
        panel.message = "Choose one file to send to your iPhone. It is saved in Files › Farside."
        panel.prompt = "Send"
        self.panel = panel
        panelTransfer = transfer
        HostAppActivation.shared.bringForward()
        panel.begin { [weak self, weak panel] response in
            MainActor.assumeIsolated {
                guard let self, let panel, self.panel === panel else { return }
                self.panel = nil
                self.panelTransfer = nil
                self.picked(response == .OK ? panel.url : nil, transfer: transfer)
            }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func picked(_ url: URL?, transfer: String) {
        guard let url else { engine.answerRequest(transfer, .cancelled); return }
        if let status = refusal() { engine.answerRequest(transfer, status, reason: refusalReason()); return }
        let source: FileHandleByteSource
        do {
            source = try FileHandleByteSource(url: url)
        } catch {
            engine.answerRequest(transfer, (error as? FileTransferStatus) ?? .unreadable)
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.identifier
        if case .failure(let status) = engine.send(source, name: url.lastPathComponent, type: type, transfer: transfer) {
            engine.answerRequest(transfer, status)
        }
    }

    private func closePicker(matching transfer: String?) {
        guard let panel, transfer == nil || transfer == panelTransfer else { return }
        self.panel = nil
        panelTransfer = nil
        panel.cancel(nil)
    }
}

/// "Received report.pdf" with Show in Finder. Asks for notification permission the first time a file
/// arrives; without it, the file still lands and the phone still confirms.
@MainActor
final class HostTransferNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "farside.file.received"
    static let revealAction = "reveal"
    private var configured = false

    func announceReceived(_ url: URL) {
        let center = UNUserNotificationCenter.current()
        if !configured {
            configured = true
            center.delegate = self
            let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder")
            center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [reveal],
                                                                     intentIdentifiers: [])])
        }
        let content = UNMutableNotificationContent()
        content.title = "Received from your iPhone"
        content.body = url.lastPathComponent + " is in Downloads › Farside."
        content.categoryIdentifier = Self.category
        content.userInfo = ["path": url.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        if response.notification.request.content.categoryIdentifier == Self.category, let path {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        completionHandler()
    }
}

/// A link from the phone. The Mac never opens it by itself: this small panel waits for a click on
/// Open, which someone at the Mac (or steering it from the phone) has to make.
@MainActor
final class HostLinkOffer {
    static let shared = HostLinkOffer()
    static let lifetime: TimeInterval = 120
    private var panel: NSPanel?
    private var expiry: Task<Void, Never>?
    private let showPanel: Bool
    private let opener: (URL) -> Bool
    private var lease: TransferEffectLease?
    private var authorized: (() -> Bool)?
    private var url: URL?
    private(set) var currentID: UUID?
    init(showPanel: Bool = true, opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.showPanel = showPanel; self.opener = opener
    }
    @discardableResult
    func present(_ url: URL, lease: TransferEffectLease, authorized: @escaping () -> Bool) -> UUID {
        dismiss()
        let id = UUID(); currentID = id
        self.url = url; self.lease = lease; self.authorized = authorized
        if showPanel {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: true)
            panel.title = "Link from your iPhone"; panel.level = .floating; panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: HostLinkOfferView(url: url, open: { [weak self] in
                self?.openOffer(id)
            }, dismiss: { [weak self] in self?.dismiss(matching: id) }))
            if let screen = NSScreen.main?.visibleFrame { panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - 16)) }
            panel.orderFrontRegardless(); self.panel = panel
        }
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }; self?.dismiss(matching: id)
        }
        return id
    }
    /// Both SwiftUI's queued button closure and expiry bind one exact offer, never a replacement.
    func openOffer(_ id: UUID) {
        guard currentID == id, let lease, lease.isActive, authorized?() == true, let url else { return }
        _ = opener(url) // Main-actor authority and offer checks are contiguous with this action.
        dismiss(matching: id)
    }
    func dismiss(matching id: UUID? = nil) {
        guard id == nil || currentID == id else { return }
        currentID = nil; lease = nil; authorized = nil; url = nil
        expiry?.cancel(); expiry = nil; panel?.close(); panel = nil
    }
}

private struct HostLinkOfferView: View {
    let url: URL
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(url.host() ?? url.absoluteString)
                .font(.headline)
                .lineLimit(1)
            Text("Also copied to the clipboard. Farside doesn’t open links by itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss", action: dismiss)
                    .accessibilityIdentifier("farside.link.dismiss")
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.link.open")
            }
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
    }
}
