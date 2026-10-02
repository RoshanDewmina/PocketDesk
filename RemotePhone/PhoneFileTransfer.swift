import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A received file the phone offers to share, save or open elsewhere.
struct ReceivedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// Phone half of file transfer: one file each way, only in the foreground, with progress and cancel.
/// Files from the Mac arrive only after the phone asked for one; they land in the app's Documents,
/// which Files shows as On My iPhone › Farside. Names and contents are never logged.
@MainActor
final class PhoneFileTransfer: ObservableObject {
    @Published private(set) var snapshot: FileTransferSnapshot?
    @Published private(set) var waitingForMac = false
    @Published private(set) var notice: ClipboardNotice?
    @Published var received: ReceivedFile?

    let engine: FileTransferEngine
    /// The share extension's hand-off for the transfer in flight, so it can show progress.
    var receipts: ((String, FileTransferSnapshot?, FileTransferFinish?) -> Void)?
    var onLinkResult: ((FileTransferStatus) -> Void)?

    private let idleTimer: PhoneIdleTimer
    private let idleOwner = PhoneIdleTimer.Owner.transfer(UUID())
    private let destination: () -> URL?
    private let staging: URL
    private let availableSpace: (URL) -> Int64?
    private var cleanup: [String: () -> Void] = [:]
    private var pendingLink: String?
    private var cancelledHere = false
    private var noticeSerial: UInt64 = 0

    init(destination: @escaping () -> URL? = { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first },
         staging: URL = FileManager.default.temporaryDirectory,
         availableSpace: @escaping (URL) -> Int64? = PhoneFileTransfer.availableSpace,
         idleTimer: PhoneIdleTimer = .shared,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        engine = FileTransferEngine(acceptsUnsolicitedOffers: false, clock: clock)
        self.idleTimer = idleTimer
        self.destination = destination
        self.staging = staging
        self.availableSpace = availableSpace
        engine.admit = { [weak self] offer, answer in answer(self?.admit(offer) ?? .failure(.notAllowed)) }
        engine.onChange = { [weak self] in self?.engineChanged() }
        engine.onFinish = { [weak self] finish in self?.finished(finish) }
        engine.onOtherResult = { [weak self] transfer, status in self?.linkResult(transfer, status) }
    }

    var isBusy: Bool { !engine.isIdle || pendingLink != nil }

    /// Only a boolean leaves this device: a refusal code when there is no room, never the free-space value.
    nonisolated static func availableSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Phone → Mac

    /// `release` runs when the transfer ends: stop security-scoped access or delete a staged copy.
    func send(fileAt url: URL, name: String? = nil, release: @escaping () -> Void = {}) -> FileTransferStatus? {
        let source: FileHandleByteSource
        do {
            source = try FileHandleByteSource(url: url)
        } catch {
            release()
            let status = (error as? FileTransferStatus) ?? .unreadable
            post(Self.message(sending: status), .caution)
            return status
        }
        return send(prepared: source, url: url, name: name, release: release)
    }

    /// The App Group inbox has already opened and inspected its payload off main. Ownership of
    /// this source moves to the engine; its close implementation also stays off main on refusal.
    func send(prepared source: FileByteSource, url: URL, name: String? = nil,
              release: @escaping () -> Void = {}) -> FileTransferStatus? {
        let type = UTType(filenameExtension: url.pathExtension)?.identifier
        switch engine.send(source, name: name ?? url.lastPathComponent, type: type) {
        case .success(let transfer):
            cleanup[transfer] = release
            notice = nil
            return nil
        case .failure(let status):
            release()
            post(Self.message(sending: status), .caution)
            return status
        }
    }

    func sendLink(_ url: URL) -> Bool {
        guard pendingLink == nil else { post("Wait for the current link to reach your Mac.", .caution); return false }
        let transfer = FileTransferID.make()
        guard FileFrame.isWellFormedLink(url.absoluteString),
              engine.sendControl?(.link(transfer, url: url.absoluteString)) == true else {
            post("That link couldn’t be sent. Only web links up to 2 KB work.", .caution)
            return false
        }
        pendingLink = transfer
        updateIdleTimer()
        return true
    }

    // MARK: Mac → phone

    func requestFromMac() {
        switch engine.request() {
        case .success:
            notice = nil
        case .failure(let status):
            post(Self.message(receiving: status), .caution)
        }
    }

    func cancel() {
        cancelledHere = true
        engine.cancelAll()
        cancelledHere = false
    }

    /// The Mac started a new capture geometry (display, scope or Big Text change): an older Mac drops its side of
    /// the transfer without saying so, so stop here, tell it, and say why instead of hanging until the stall timeout.
    func stopForMacChange() {
        guard isBusy else { return }
        cancelledHere = true
        engine.cancelAll(status: .cancelled)
        cancelledHere = false
        pendingLink = nil
        updateIdleTimer()
        post("Your Mac changed what it’s sharing, so the transfer stopped. Send it again.", .caution)
    }

    /// Transfers are foreground-only in 1.0; leaving the screen stops them and tells the Mac.
    func stopForBackground() {
        engine.cancelAll(status: .backgrounded)
        pendingLink = nil
        updateIdleTimer()
    }

    func reset() {
        engine.reset()
        pendingLink = nil
        received = nil
        updateIdleTimer()
    }

    /// Reacquire only current engine ownership when an inactive foreground scene becomes active.
    func refreshIdleTimer() { updateIdleTimer() }

    func clearNotice() { notice = nil }

    func postUnavailable(_ message: String) { post(message, .caution) }

    // MARK: Engine

    private func admit(_ offer: FileTransferOffer) -> Result<FileByteSink, FileTransferStatus> {
        guard let folder = destination() else { return .failure(.denied) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileTransferLimits.hasRoom(for: offer.bytes, available: availableSpace(folder)) else {
                return .failure(.diskFull)
            }
            return .success(try FolderFileSink(folder: folder, partialFolder: staging, name: offer.name, transfer: offer.transfer))
        } catch {
            return .failure(FolderFileSink.status(for: error))
        }
    }

    private func engineChanged() {
        snapshot = engine.outgoing ?? engine.incoming
        waitingForMac = engine.pendingRequest != nil || engine.incoming?.phase == .waiting
        updateIdleTimer()
        if let outgoing = engine.outgoing { receipts?(outgoing.transfer, outgoing, nil) }
    }

    private func updateIdleTimer() { idleTimer.set(idleOwner, active: !engine.isIdle) }

    private func finished(_ finish: FileTransferFinish) {
        cleanup.removeValue(forKey: finish.transfer)?()
        receipts?(finish.transfer, nil, finish)
        if finish.status == .cancelled && cancelledHere {
            post("Transfer cancelled.", .caution)
            return
        }
        switch (finish.direction, finish.status) {
        case (.outgoing, .stored):
            post("Saved to Downloads › Farside on your Mac", .success)
        case (.outgoing, let status):
            post(Self.message(refusal: finish.reason, status: status) ?? Self.message(sending: status), .caution)
        case (.incoming, .stored):
            post("Saved to Files › On My iPhone › Farside", .success)
            if let url = finish.savedURL { received = ReceivedFile(url: url) }
        case (.incoming, let status):
            post(Self.message(refusal: finish.reason, status: status) ?? Self.message(receiving: status, fileOffered: finish.name != nil), .caution)
        }
    }

    private func linkResult(_ transfer: String, _ status: FileTransferStatus) {
        guard pendingLink == transfer else { return }
        pendingLink = nil
        updateIdleTimer()
        onLinkResult?(status)
        switch status {
        case .offered: post("Link sent. Click Open on your Mac to open it.", .success)
        case .copied: post("Link copied to your Mac’s clipboard", .success)
        default: post(Self.message(sending: status), .caution)
        }
    }

    private func post(_ message: String, _ tone: ClipboardNotice.Tone) {
        noticeSerial &+= 1
        notice = ClipboardNotice(id: noticeSerial, message: message, tone: tone)
    }

    // MARK: Copy

    /// A newer Mac says which condition refused files, so the phone can say why (1 Oct device report).
    static func message(refusal reason: String?, status: FileTransferStatus) -> String? {
        guard status == .notAllowed, let reason else { return nil }
        switch reason {
        case "noSession": return "Your Mac’s session ended. Reconnect, then try again."
        case "notSharing": return "Your Mac isn’t sharing its screen right now, so files are off. Start sharing on the Mac, then try again."
        case "controlDisabled": return "Allow control is off on your Mac, so files and links are off too."
        case "paused": return "Your Mac still has this session paused for the background. Reconnect, then try again."
        case "viewOnly": return "Files are off in live view only (Picture in Picture). Return to control, then try again."
        case "locking": return "Your Mac is locking, so files are off for now."
        case "lockFailed": return "Your Mac didn’t confirm it locked, so files are off. Lock or use your Mac, then try again."
        default: return nil
        }
    }

    static func message(sending status: FileTransferStatus) -> String {
        switch status {
        case .cancelled: "Transfer cancelled."
        case .tooLarge: "That file is over 1 GB, the limit for now."
        case .empty: "That file is empty."
        case .unsupported: "Folders and packages can’t be sent. Zip them first."
        case .unreadable: "Farside couldn’t read that file. Try saving it to Files first."
        case .disabled: "File transfer is off on your Mac right now."
        case .notAllowed: "Your Mac isn’t accepting files right now."
        case .busy: "Wait for the current transfer to finish."
        case .diskFull: "Your Mac doesn’t have enough space for that file."
        case .denied: "macOS blocked Farside from saving to Downloads. Allow it on your Mac, then send again."
        case .invalid: "The file didn’t arrive intact, so your Mac discarded it. Send again."
        case .timedOut: "Your Mac stopped answering. Send again."
        case .backgrounded: "Transfer stopped when Farside left the screen. Send again."
        case .connectionLost: "The connection dropped during the transfer. Send again."
        default: "The transfer didn’t finish. Send again."
        }
    }

    /// `fileOffered` is false while the Mac is still choosing (a request has no name yet).
    static func message(receiving status: FileTransferStatus, fileOffered: Bool = false) -> String {
        switch status {
        case .cancelled: "Cancelled on your Mac."
        case .tooLarge: "That file is over 1 GB, the limit for now."
        case .empty: "That file is empty."
        case .unsupported: "Folders and packages can’t be sent. Zip them on your Mac first."
        case .unreadable: "Your Mac couldn’t read that file."
        case .disabled: "File transfer is off on your Mac right now."
        case .notAllowed: "Your Mac isn’t sharing files right now."
        case .busy: "Your Mac is already choosing a file. Finish or cancel it on the Mac."
        case .diskFull: "Not enough space on this iPhone for that file."
        case .denied: "Farside couldn’t save the file on this iPhone."
        case .invalid: "The file didn’t arrive intact, so it was discarded. Try again."
        case .timedOut: fileOffered ? "Your Mac stopped sending the file. Try again." : "Nothing was chosen on your Mac in time."
        case .backgrounded: "Transfer stopped when Farside left the screen. Try again."
        case .connectionLost: "The connection dropped during the transfer. Try again."
        default: "The transfer didn’t finish. Try again."
        }
    }
}
