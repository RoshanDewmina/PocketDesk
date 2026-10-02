import Foundation
import Combine

/// Engine admission can refuse and call close synchronously on main. Keep the descriptor close
/// on the outbox lane as well as its open/stat, including abandoned preparation results.
final class SendToMacPreparedSource: FileByteSource {
    let byteCount: Int64
    private var source: FileByteSource?
    private let io: SendToMacFileIO
    private let closeLock = NSLock()

    init(source: FileByteSource, io: SendToMacFileIO) {
        self.source = source
        self.io = io
        byteCount = source.byteCount
    }

    func read(upTo count: Int) throws -> Data {
        closeLock.lock()
        let source = self.source
        closeLock.unlock()
        guard let source else { throw FileTransferStatus.unreadable }
        return try source.read(upTo: count)
    }

    func close() {
        closeLock.lock()
        let source = self.source
        self.source = nil
        closeLock.unlock()
        guard let source else { return }
        io.write { _ in source.close() }
    }

    deinit { close() }
}

/// The app side of Send to My Mac. The share extension stages one item in the App Group and posts a
/// Darwin notification. A live foreground session sends an item staged while it was live at once;
/// anything else waits (at most ten minutes) for the person to confirm it in a connected session.
@MainActor
final class SendToMacInbox: ObservableObject {
    @Published private(set) var offer: SendToMacItem?
    @Published private(set) var selectedDestination: SendToMacDestination?
    @Published private(set) var selectedName = "selected Mac"
    private var liveSessionID: String?

    /// Called before checking items, and on every End/selection change. Old handoffs stay staged,
    /// but can never automatically regain eligibility by switching A → B → A.
    func updateDestination(_ destination: SendToMacDestination?, name: String?, liveSessionID: String?) {
        let valid = destination?.isValid == true ? destination : nil
        if selectedDestination != valid { selectedDestination = valid }
        let name = name ?? "selected Mac"
        if selectedName != name { selectedName = name }
        self.liveSessionID = liveSessionID
    }

    /// Production reads the coordinator's current selected pair at the actual send boundary;
    /// the published display snapshot alone may lag a system-route selection by one main turn.
    var destinationNow: (() -> SendToMacDestination?)?
    var liveSessionNow: (() -> String?)?
    private var currentDestination: SendToMacDestination? {
        if let destinationNow { return destinationNow() }
        return selectedDestination
    }
    private var currentLiveSessionID: String? {
        if let liveSessionNow { return liveSessionNow() }
        return liveSessionID
    }

    var canSend: () -> Bool = { false }
    var canSendText: () -> Bool = { false }
    var sendFile: (URL, String?, @escaping () -> Void) -> FileTransferStatus? = { _, _, _ in .unsupported }
    var sendPreparedFile: ((FileByteSource, URL, String?, @escaping () -> Void) -> FileTransferStatus?)?
    var prepareFile: (URL) throws -> FileByteSource = { try FileHandleByteSource(url: $0) }
    var preparationFailed: (FileTransferStatus) -> Void = { _ in }
    var sendText: (String) -> Bool = { _ in false }
    var sendLink: (URL) -> Bool = { _ in false }

    private let fileIO: SendToMacFileIO
    private var sending: SendToMacItem?
    private var transferItems: [String: String] = [:]
    private var observing = false
    private var scanInFlight = false
    private var scanAgain = false
    private var scanGeneration: UInt64 = 0
    private var retargetID: String?

    init(root: URL?, useBackgroundIO: Bool? = nil, ioQueue: DispatchQueue = SendToMacFileIO.queue) {
        fileIO = SendToMacFileIO(rootProvider: { root }, useBackgroundIO: useBackgroundIO, queue: ioQueue)
    }

    init(useBackgroundIO: Bool? = nil, ioQueue: DispatchQueue = SendToMacFileIO.queue) {
        fileIO = SendToMacFileIO(useBackgroundIO: useBackgroundIO, queue: ioQueue)
    }

    /// Starts listening for the extension. Safe to call more than once.
    func start() {
        guard !observing else { return }
        observing = true
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let inbox = Unmanaged<SendToMacInbox>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { inbox.check() } }
        }, SendToMacOutbox.outboxNotification as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
    }

    /// Looks for staged items; call when a session becomes able to send, or the app returns.
    func check(now: Date = Date()) {
        guard sending == nil, retargetID == nil else { return }
        guard !scanInFlight else { scanAgain = true; return }
        scanInFlight = true
        let generation = scanGeneration
        fileIO.read({ SendToMacOutbox.pending(at: now, root: $0) }) { [weak self] items in
            guard let self else { return }
            self.scanInFlight = false
            let again = self.scanAgain || generation != self.scanGeneration
            self.scanAgain = false
            if generation == self.scanGeneration, self.sending == nil, self.retargetID == nil {
                // I/O may have waited behind a file write. Re-read live authority and wall time on
                // main, rather than carrying eligibility from the start of the scan.
                self.accept(items, now: Date())
            }
            if again { self.check() }
        }
    }

    private func accept(_ items: [SendToMacItem], now: Date) {
        if let offer, !items.contains(where: { $0.id == offer.id }) { self.offer = nil }
        guard let next = items.first, next.expires > now, able(next) else { return }
        if next.canAutomaticallySend(to: currentDestination, liveSessionID: currentLiveSessionID, at: now) {
            send(next, automatically: true)
        } else if offer != next {
            offer = next
        }
    }

    func confirm() {
        guard let offer, sending == nil, retargetID == nil else { return }
        guard offer.isBound(to: currentDestination), able(offer), offer.expires > Date() else { return }
        self.offer = nil
        send(offer)
    }

    /// A separate, explicitly labelled action. The displayed target is captured by the view, so a
    /// selection change between rendering and tapping cannot retarget to an unseen destination.
    func retargetAndConfirm(to expected: SendToMacDestination) {
        guard var offer, selectedDestination == expected, currentDestination == expected, expected.isValid,
              sending == nil, retargetID == nil, able(offer), offer.expires > Date() else { return }
        offer.destination = expected
        offer.destinationName = selectedName
        offer.liveSessionID = nil
        offer.immediate = false
        let session = currentLiveSessionID
        let item = offer
        retargetID = item.id
        scanGeneration &+= 1
        fileIO.read({ root -> Bool in
            do { try SendToMacOutbox.stage(item, root: root); return true } catch { return false }
        }) { [weak self] staged in
            guard let self, self.retargetID == item.id else { return }
            self.retargetID = nil
            guard staged, self.offer?.id == item.id, self.selectedDestination == expected,
                  self.currentDestination == expected, self.currentLiveSessionID == session,
                  self.able(item), item.expires > Date() else { self.check(); return }
            self.offer = nil
            self.send(item)
        }
    }

    func discard() {
        guard let offer else { return }
        self.offer = nil
        retargetID = nil
        scanGeneration &+= 1
        fileIO.write { SendToMacOutbox.remove(offer.id, root: $0) }
        check()
    }

    /// The file engine reported progress or an ending for one of its transfers.
    func transferChanged(_ transfer: String, _ snapshot: FileTransferSnapshot?, _ finish: FileTransferFinish?) {
        guard let id = transferItems[transfer] else { return }
        if let snapshot {
            receipt(id, .sending, fraction: snapshot.fraction, "Sending to your Mac…")
        } else if let finish {
            transferItems[transfer] = nil
            let stored = finish.status == .stored
            receipt(id, stored ? .sent : .failed, fraction: stored ? 1 : nil,
                    stored ? "Saved to Downloads › Farside on your Mac"
                        : PhoneFileTransfer.message(refusal: finish.reason, status: finish.status) ?? PhoneFileTransfer.message(sending: finish.status))
            done(id)
        }
    }

    func linkFinished(_ status: FileTransferStatus) {
        guard let item = sending, item.kind == .link else { return }
        let ok = status == .offered || status == .copied
        receipt(item.id, ok ? .sent : .failed, fraction: nil,
                ok ? "Sent. Click Open on your Mac to open it." : PhoneFileTransfer.message(sending: status))
        done(item.id)
    }

    private func able(_ item: SendToMacItem) -> Bool {
        item.kind == .text ? canSendText() : canSend()
    }

    private func send(_ item: SendToMacItem, automatically: Bool = false) {
        guard sending == nil, item.isBound(to: currentDestination), item.expires > Date(), able(item) else { offer = item; return }
        sending = item
        scanGeneration &+= 1
        switch item.kind {
        case .file:
            let session = currentLiveSessionID
            let io = fileIO
            let prepare = prepareFile
            fileIO.read({ root -> Result<(URL, FileByteSource), FileTransferStatus> in
                guard let url = SendToMacOutbox.payloadURL(for: item, root: root) else { return .failure(.unreadable) }
                do {
                    return .success((url, SendToMacPreparedSource(source: try prepare(url), io: io)))
                } catch { return .failure((error as? FileTransferStatus) ?? .unreadable) }
            }) { [weak self] prepared in
                guard let self, self.sending?.id == item.id else {
                    if case .success((_, let source)) = prepared { source.close() }
                    return
                }
                guard item.isBound(to: self.currentDestination), self.currentLiveSessionID == session,
                      item.expires > Date(), self.able(item),
                      !automatically || item.canAutomaticallySend(to: self.currentDestination,
                                                                  liveSessionID: self.currentLiveSessionID, at: Date()) else {
                    if case .success((_, let source)) = prepared { source.close() }
                    self.sending = nil
                    self.offer = item
                    self.check()
                    return
                }
                guard case .success((let url, let source)) = prepared else {
                    if case .failure(let status) = prepared {
                        self.preparationFailed(status)
                        self.receipt(item.id, .failed, fraction: nil, PhoneFileTransfer.message(sending: status))
                    }
                    io.write { SendToMacOutbox.remove(item.id, root: $0) }
                    self.done(item.id)
                    return
                }
                self.receipt(item.id, .sending, fraction: 0, "Sending to your Mac…")
                let before = Set(self.transferItems.keys)
                let release = { io.write { SendToMacOutbox.remove(item.id, root: $0) } }
                let status: FileTransferStatus?
                if let sendPrepared = self.sendPreparedFile {
                    status = sendPrepared(source, url, item.name, release)
                } else {
                    // Legacy fixture/API path. Production always consumes the prepared source.
                    source.close()
                    status = self.sendFile(url, item.name, release)
                }
                if let status {
                    self.receipt(item.id, .failed, fraction: nil, PhoneFileTransfer.message(sending: status))
                    self.done(item.id)
                } else if let transfer = self.pendingTransfer?(), !before.contains(transfer) {
                    self.transferItems[transfer] = item.id
                }
            }
        case .text:
            guard let text = item.text, sendText(text) else { fail(item); return }
            receipt(item.id, .sent, fraction: nil, "Sent to your Mac’s clipboard")
            fileIO.write { SendToMacOutbox.remove(item.id, root: $0) }
            done(item.id)
        case .link:
            guard let text = item.text, let url = URL(string: text), sendLink(url) else { fail(item); return }
            receipt(item.id, .sending, fraction: nil, "Sending the link…")
            fileIO.write { SendToMacOutbox.remove(item.id, root: $0) }
        }
    }

    /// The transfer id the file engine just started, so progress can be matched to the item.
    var pendingTransfer: (() -> String?)?

    private func fail(_ item: SendToMacItem) {
        receipt(item.id, .failed, fraction: nil, "Farside couldn’t send that. Share it again.")
        fileIO.write { SendToMacOutbox.remove(item.id, root: $0) }
        done(item.id)
    }

    private func done(_ id: String) {
        if sending?.id == id { sending = nil }
        check()
    }

    private func receipt(_ id: String, _ state: SendToMacReceipt.State, fraction: Double?, _ message: String) {
        let receipt = SendToMacReceipt(id: id, state: state, fraction: fraction, message: message)
        fileIO.write { SendToMacOutbox.storeReceipt(receipt, root: $0) }
    }
}
