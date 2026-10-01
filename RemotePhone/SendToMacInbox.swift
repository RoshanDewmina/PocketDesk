import Foundation
import Combine

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
    var sendText: (String) -> Bool = { _ in false }
    var sendLink: (URL) -> Bool = { _ in false }

    private let root: URL?
    private var sending: SendToMacItem?
    private var transferItems: [String: String] = [:]
    private var observing = false

    init(root: URL? = SendToMacOutbox.root) {
        self.root = root
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
        guard sending == nil else { return }
        let items = SendToMacOutbox.pending(at: now, root: root)
        if let offer, !items.contains(where: { $0.id == offer.id }) { self.offer = nil }
        guard let next = items.first, able(next) else { return }
        if next.canAutomaticallySend(to: currentDestination, liveSessionID: currentLiveSessionID, at: now) {
            send(next)
        } else if offer?.id != next.id {
            offer = next
        }
    }

    func confirm() {
        guard let offer else { return }
        guard offer.isBound(to: currentDestination), able(offer), offer.expires > Date() else { return }
        self.offer = nil
        send(offer)
    }

    /// A separate, explicitly labelled action. The displayed target is captured by the view, so a
    /// selection change between rendering and tapping cannot retarget to an unseen destination.
    func retargetAndConfirm(to expected: SendToMacDestination) {
        guard var offer, selectedDestination == expected, currentDestination == expected, expected.isValid,
              able(offer), offer.expires > Date() else { return }
        offer.destination = expected
        offer.destinationName = selectedName
        offer.liveSessionID = nil
        offer.immediate = false
        do { try SendToMacOutbox.stage(offer, root: root) } catch { return }
        self.offer = nil
        send(offer)
    }

    func discard() {
        guard let offer else { return }
        self.offer = nil
        SendToMacOutbox.remove(offer.id, root: root)
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

    private func send(_ item: SendToMacItem) {
        guard item.isBound(to: currentDestination), item.expires > Date(), able(item) else { offer = item; return }
        sending = item
        switch item.kind {
        case .file:
            guard let url = SendToMacOutbox.payloadURL(for: item, root: root) else { fail(item); return }
            let root = self.root
            receipt(item.id, .sending, fraction: 0, "Sending to your Mac…")
            let before = Set(transferItems.keys)
            if let status = sendFile(url, item.name, { SendToMacOutbox.remove(item.id, root: root) }) {
                receipt(item.id, .failed, fraction: nil, PhoneFileTransfer.message(sending: status))
                done(item.id)
            } else if let transfer = pendingTransfer?(), !before.contains(transfer) {
                transferItems[transfer] = item.id
            }
        case .text:
            guard let text = item.text, sendText(text) else { fail(item); return }
            receipt(item.id, .sent, fraction: nil, "Sent to your Mac’s clipboard")
            SendToMacOutbox.remove(item.id, root: root)
            done(item.id)
        case .link:
            guard let text = item.text, let url = URL(string: text), sendLink(url) else { fail(item); return }
            receipt(item.id, .sending, fraction: nil, "Sending the link…")
            SendToMacOutbox.remove(item.id, root: root)
        }
    }

    /// The transfer id the file engine just started, so progress can be matched to the item.
    var pendingTransfer: (() -> String?)?

    private func fail(_ item: SendToMacItem) {
        receipt(item.id, .failed, fraction: nil, "Farside couldn’t send that. Share it again.")
        SendToMacOutbox.remove(item.id, root: root)
        done(item.id)
    }

    private func done(_ id: String) {
        if sending?.id == id { sending = nil }
        check()
    }

    private func receipt(_ id: String, _ state: SendToMacReceipt.State, fraction: Double?, _ message: String) {
        SendToMacOutbox.storeReceipt(SendToMacReceipt(id: id, state: state, fraction: fraction, message: message), root: root)
    }
}
