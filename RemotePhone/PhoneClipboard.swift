import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ClipboardNotice: Equatable, Identifiable {
    enum Tone: Equatable { case success, caution }
    let id: UInt64
    let message: String
    let tone: Tone
}

/// Phone half of explicit clipboard transfer. Sends paced chunks, waits for the Mac's
/// acknowledgment, and reports a visible result. Clipboard contents are never logged or shown.
@MainActor
final class PhoneClipboard: ObservableObject {
    enum Activity: Equatable { case idle, sending, receiving }

    private struct Pending {
        enum Direction { case toMac, fromMac }
        let transfer: String
        let direction: Direction
        let pasteAfter: Bool
        let characters: Int
        var lastActivity: TimeInterval
    }

    static let pasteAfterKey = "clipboardPasteAfterSending"
    static let sendTimeout: TimeInterval = 8
    static let receiveTimeout: TimeInterval = 15

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var notice: ClipboardNotice?
    @Published var pasteAfterSending: Bool {
        didSet { defaults.set(pasteAfterSending, forKey: Self.pasteAfterKey) }
    }

    var transport: ((ClipboardFrame) -> Bool)?
    var bufferedAmount: (() -> UInt64?)?
    var pressPaste: (() -> Bool)?
    var writeToPasteboard: (ClipboardPayload) -> Void = PhoneClipboard.writeToSystemPasteboard

    private let defaults: UserDefaults
    private let clock: () -> TimeInterval
    private var outbox = ClipboardOutbox()
    private var assembler = ClipboardAssembler()
    private var pending: Pending?
    private var pacer: Timer?
    private var watchdog: Timer?
    private var noticeSerial: UInt64 = 0

    init(defaults: UserDefaults = .standard,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.clock = clock
        pasteAfterSending = defaults.object(forKey: Self.pasteAfterKey) == nil ? true : defaults.bool(forKey: Self.pasteAfterKey)
    }

    var isBusy: Bool { pending != nil }

    /// Paste to Mac: replaces the Mac clipboard with this text, then optionally presses ⌘V.
    func send(_ text: String) {
        guard pending == nil else { post("Wait for the current clipboard transfer to finish.", .caution); return }
        let transfer = ClipboardTransferID.make()
        let frames: [ClipboardFrame]
        do {
            frames = try ClipboardChunker.frames(for: ClipboardPayload(text: text), operation: "push", transfer: transfer)
        } catch ClipboardRefusal.tooLarge {
            post("Clipboard text is too large to send. The limit is 256 KB.", .caution); return
        } catch {
            post("Your iPhone clipboard has no text to send.", .caution); return
        }
        pending = Pending(transfer: transfer, direction: .toMac, pasteAfter: pasteAfterSending,
                          characters: text.count, lastActivity: clock())
        activity = .sending
        outbox.load(frames)
        startWatchdog()
        pump()
    }

    /// Copy from Mac: asks the Mac for its current clipboard text. With `afterCopy`, the Mac
    /// first waits briefly for the ⌘C the phone just sent to change its clipboard.
    func requestFromMac(afterCopy: Bool = false) {
        guard pending == nil else { post("Wait for the current clipboard transfer to finish.", .caution); return }
        let transfer = ClipboardTransferID.make()
        guard transport?(.pull(transfer, afterCopy: afterCopy)) == true else {
            post("Your Mac isn't connected. Try again when the session is live.", .caution); return
        }
        pending = Pending(transfer: transfer, direction: .fromMac, pasteAfter: false, characters: 0, lastActivity: clock())
        activity = .receiving
        assembler.reset()
        startWatchdog()
    }

    func receive(_ frame: ClipboardFrame) {
        guard var current = pending, frame.transfer == current.transfer else { return }
        current.lastActivity = clock()
        pending = current
        switch (frame.op, current.direction) {
        case ("result", .toMac):
            finishSend(status: frame.status.flatMap(ClipboardStatus.init(rawValue:)), pasteAfter: current.pasteAfter)
        case ("result", .fromMac):
            let status = frame.status.flatMap(ClipboardStatus.init(rawValue:))
            finish(Self.message(forMacClipboard: status), .caution)
        case ("data", .fromMac):
            switch assembler.accept(frame, at: clock()) {
            case .progress:
                break
            case .complete(_, let payload):
                writeToPasteboard(payload)
                finish("Copied from your Mac · \(Self.characters(payload.text.count))", .success)
            case .failed:
                finish("The clipboard transfer from your Mac failed. Try again.", .caution)
            }
        default:
            break
        }
    }

    func cancel() {
        pending = nil
        activity = .idle
        outbox.cancel()
        assembler.reset()
        stopTimers()
    }

    func clearNotice() {
        notice = nil
    }

    func postUnavailable(_ message: String) {
        post(message, .caution)
    }

    private func finishSend(status: ClipboardStatus?, pasteAfter: Bool) {
        guard status == .stored else {
            finish(Self.message(forSendRefusal: status), .caution)
            return
        }
        if pasteAfter {
            let pasted = pressPaste?() == true
            finish(pasted ? "Pasted on your Mac" : "On your Mac’s clipboard. Press ⌘V on the Mac to paste.", .success)
        } else {
            finish("Copied to your Mac’s clipboard", .success)
        }
    }

    private func finish(_ message: String, _ tone: ClipboardNotice.Tone) {
        cancel()
        post(message, tone)
    }

    private func post(_ message: String, _ tone: ClipboardNotice.Tone) {
        noticeSerial &+= 1
        notice = ClipboardNotice(id: noticeSerial, message: message, tone: tone)
    }

    private func pump() {
        guard var current = pending else { return }
        for frame in outbox.release(bufferedAmount: bufferedAmount?()) {
            guard transport?(frame) == true else {
                finish("The connection dropped during the clipboard transfer.", .caution)
                return
            }
            current.lastActivity = clock()
        }
        pending = current
        if outbox.isEmpty {
            pacer?.invalidate(); pacer = nil
        } else if pacer == nil {
            pacer = Timer.scheduledTimer(withTimeInterval: ClipboardLimits.pacingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTimeout() }
        }
    }

    func checkTimeout() {
        guard let current = pending else { stopTimers(); return }
        let limit = current.direction == .toMac ? Self.sendTimeout : Self.receiveTimeout
        guard clock() - current.lastActivity > limit else { return }
        finish(current.direction == .toMac
               ? "Delivery is uncertain. Check your Mac’s clipboard before sending again."
               : "Your Mac didn’t return its clipboard in time. Check your Mac for a prompt.", .caution)
    }

    private func stopTimers() {
        pacer?.invalidate(); pacer = nil
        watchdog?.invalidate(); watchdog = nil
    }

    static func message(forSendRefusal status: ClipboardStatus?) -> String {
        switch status {
        case .notAllowed: "Your Mac isn’t allowing control right now, so its clipboard wasn’t changed."
        case .busy: "Your Mac is busy with another clipboard transfer. Try again."
        case .tooLarge: "Clipboard text is too large to send. The limit is 256 KB."
        default: "Your Mac couldn’t update its clipboard. Try again."
        }
    }

    static func message(forMacClipboard status: ClipboardStatus?) -> String {
        switch status {
        case .concealed: "Your Mac’s clipboard holds a password or private item, so it wasn’t shared."
        case .empty: "Your Mac’s clipboard has no text."
        case .unsupported: "Only text can be copied from your Mac for now."
        case .tooLarge: "Your Mac’s clipboard is larger than 256 KB, so it wasn’t copied."
        case .denied: "macOS is blocking Farside from reading the clipboard. Allow it in Privacy & Security on your Mac."
        case .unchanged: "Nothing new was copied. Select text on your Mac first."
        case .notAllowed: "Your Mac isn’t allowing control right now, so its clipboard wasn’t shared."
        case .busy: "Your Mac didn’t return its clipboard in time. Check your Mac for a prompt."
        default: "Your Mac couldn’t share its clipboard. Try again."
        }
    }

    static func characters(_ count: Int) -> String {
        let number = count.formatted(.number)
        return count == 1 ? "1 character" : "\(number) characters"
    }

    /// Local-only: a Mac item copied here must not bounce back through Universal Clipboard.
    static func writeToSystemPasteboard(_ payload: ClipboardPayload) {
        var item: [String: Any] = [UTType.utf8PlainText.identifier: payload.text]
        if payload.kind == .url,
           let url = URL(string: payload.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            item[UTType.url.identifier] = url
        }
        UIPasteboard.general.setItems([item], options: [.localOnly: true])
    }
}

/// Wraps UIKit's finite task-completion window. Begun as early as `.inactive`, as Apple
/// recommends, and always ended on return or expiry.
@MainActor
protocol BackgroundExecution: AnyObject {
    var isActive: Bool { get }
    var remainingTime: TimeInterval? { get }
    @discardableResult func begin(onExpiration: @escaping @MainActor () -> Void) -> Bool
    func end()
}

@MainActor
final class SystemBackgroundExecution: BackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expiration: (@MainActor () -> Void)?

    var isActive: Bool { identifier != .invalid }

    var remainingTime: TimeInterval? {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        return remaining.isFinite && remaining < 3600 ? remaining : nil
    }

    @discardableResult
    func begin(onExpiration: @escaping @MainActor () -> Void) -> Bool {
        expiration = onExpiration
        guard identifier == .invalid else { return true }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "PocketDesk session handoff") { [weak self] in
            MainActor.assumeIsolated { self?.expire() }
        }
        return identifier != .invalid
    }

    func end() {
        expiration = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    private func expire() {
        let handler = expiration
        expiration = nil
        handler?()
        end()
    }
}
