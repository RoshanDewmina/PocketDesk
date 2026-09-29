import AppKit

enum HostPasteboardRead: Equatable {
    case text(ClipboardPayload)
    case refused(ClipboardStatus)
}

/// Every call runs on `HostClipboardService`'s serial queue, never on the main thread: a
/// lazily provided item or a macOS paste-privacy prompt must not freeze input handling.
protocol HostPasteboardAccess: AnyObject, Sendable {
    var changeCount: Int { get }
    func read(limit: Int) -> HostPasteboardRead
    func write(_ payload: ClipboardPayload) -> Bool
}

final class SystemHostPasteboard: HostPasteboardAccess, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func read(limit: Int) -> HostPasteboardRead {
        if pasteboard.accessBehavior == .alwaysDeny { return .refused(.denied) }
        // Type identifiers are metadata; contents are only read once markers allow sharing.
        var types = Set((pasteboard.types ?? []).map(\.rawValue))
        for item in pasteboard.pasteboardItems ?? [] { types.formUnion(item.types.map(\.rawValue)) }
        guard !types.isEmpty else { return .refused(.empty) }
        guard ClipboardPrivacy.verdict(forTypes: types) == .shareable else { return .refused(.concealed) }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) {
            guard let data = pasteboard.data(forType: .string) else { return .refused(.empty) }
            return Self.payload(from: data, limit: limit)
        }
        if types.contains(NSPasteboard.PasteboardType.URL.rawValue),
           let value = pasteboard.string(forType: .URL) {
            return Self.payload(from: Data(value.utf8), limit: limit)
        }
        return .refused(.unsupported)
    }

    func write(_ payload: ClipboardPayload) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(payload.text, forType: .string) else { return false }
        if payload.kind == .url,
           let url = URL(string: payload.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            item.setString(url.absoluteString, forType: .URL)
        }
        item.setString(Bundle.main.bundleIdentifier ?? "com.roshan.PocketDesk.RemoteHost",
                       forType: NSPasteboard.PasteboardType(ClipboardPrivacy.sourceType))
        item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPrivacy.pocketDeskMarker))
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func payload(from data: Data, limit: Int) -> HostPasteboardRead {
        guard !data.isEmpty else { return .refused(.empty) }
        guard data.count <= limit else { return .refused(.tooLarge) }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .refused(.empty) }
        return .text(ClipboardPayload(text: text))
    }
}

/// Answers explicit phone requests only. It never observes the pasteboard on its own and
/// never logs contents; frames carry only sizes, digests and opaque transfer identifiers.
@MainActor
final class HostClipboardService {
    var transport: ((ClipboardFrame) -> Bool)?
    var bufferedAmount: (() -> UInt64?)?

    private final class Baseline: @unchecked Sendable {
        var changeCount: Int?
    }

    private let pasteboard: HostPasteboardAccess
    private let queue: DispatchQueue
    private let clock: () -> TimeInterval
    private let readTimeout: TimeInterval
    private let copyWait: TimeInterval
    private let baseline = Baseline()
    private var assembler = ClipboardAssembler()
    private var outbox = ClipboardOutbox()
    private var generation: UInt64 = 0
    private var pendingRead: String?
    private var pacer: Timer?
    private var maintenance: Timer?

    init(pasteboard: HostPasteboardAccess = SystemHostPasteboard(),
         queue: DispatchQueue = DispatchQueue(label: "PocketDesk.clipboard", qos: .userInitiated),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readTimeout: TimeInterval = 12,
         copyWait: TimeInterval = 1.2) {
        self.pasteboard = pasteboard
        self.queue = queue
        self.clock = clock
        self.readTimeout = readTimeout
        self.copyWait = copyWait
    }

    var isIdle: Bool { pendingRead == nil && outbox.isEmpty && assembler.activeTransfer == nil }

    func receive(_ frame: ClipboardFrame, allowed: Bool) {
        guard allowed else {
            if assembler.activeTransfer == frame.transfer { assembler.reset() }
            reply(frame.transfer, .notAllowed)
            return
        }
        switch frame.op {
        case "push": receivePush(frame)
        case "pull": receivePull(frame)
        default: reply(frame.transfer, .invalid)
        }
    }

    /// Records the pasteboard generation before a phone-sent ⌘C is posted, so a following
    /// `afterCopy` request can wait for the copy instead of returning the previous item.
    func prepareForCopyShortcut() {
        let pasteboard = self.pasteboard, baseline = self.baseline
        queue.async { baseline.changeCount = pasteboard.changeCount }
    }

    func reset() {
        generation &+= 1
        assembler.reset()
        outbox.cancel()
        pendingRead = nil
        pacer?.invalidate(); pacer = nil
        maintenance?.invalidate(); maintenance = nil
        let baseline = self.baseline
        queue.async { baseline.changeCount = nil }
    }

    private func receivePush(_ frame: ClipboardFrame) {
        switch assembler.accept(frame, at: clock()) {
        case .progress:
            scheduleMaintenance()
        case .failed(let transfer):
            reply(transfer, .invalid)
        case .complete(let transfer, let payload):
            let generation = self.generation, pasteboard = self.pasteboard
            queue.async { [weak self] in
                let stored = pasteboard.write(payload)
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.reply(transfer, stored ? .stored : .invalid)
                }
            }
        }
    }

    private func receivePull(_ frame: ClipboardFrame) {
        guard pendingRead == nil, outbox.isEmpty else { reply(frame.transfer, .busy); return }
        let transfer = frame.transfer
        pendingRead = transfer
        let generation = self.generation, pasteboard = self.pasteboard, baseline = self.baseline
        let afterCopy = frame.afterCopy == true, copyWait = self.copyWait
        let timeout = readTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.generation == generation, self.pendingRead == transfer else { return }
            self.pendingRead = nil
            self.reply(transfer, .busy)
        }
        queue.async { [weak self] in
            let result: HostPasteboardRead
            if afterCopy, let before = baseline.changeCount {
                let deadline = Date().addingTimeInterval(copyWait)
                while pasteboard.changeCount == before, Date() < deadline { usleep(40_000) }
                result = pasteboard.changeCount == before ? .refused(.unchanged) : pasteboard.read(limit: ClipboardLimits.maximumBytes)
            } else {
                result = pasteboard.read(limit: ClipboardLimits.maximumBytes)
            }
            if afterCopy { baseline.changeCount = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.pendingRead == transfer else { return }
                self.pendingRead = nil
                self.deliver(result, transfer: transfer)
            }
        }
    }

    private func deliver(_ result: HostPasteboardRead, transfer: String) {
        switch result {
        case .refused(let status):
            reply(transfer, status)
        case .text(let payload):
            do {
                outbox.load(try ClipboardChunker.frames(for: payload, operation: "data", transfer: transfer))
                pump()
            } catch ClipboardRefusal.tooLarge {
                reply(transfer, .tooLarge)
            } catch {
                reply(transfer, .empty)
            }
        }
    }

    private func pump() {
        for frame in outbox.release(bufferedAmount: bufferedAmount?()) {
            guard transport?(frame) == true else { outbox.cancel(); break }
        }
        if outbox.isEmpty {
            pacer?.invalidate(); pacer = nil
        } else if pacer == nil {
            pacer = Timer.scheduledTimer(withTimeInterval: ClipboardLimits.pacingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
        }
    }

    private func scheduleMaintenance() {
        guard maintenance == nil else { return }
        maintenance = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let expired = self.assembler.expire(at: self.clock()) { self.reply(expired, .invalid) }
                if self.assembler.activeTransfer == nil {
                    self.maintenance?.invalidate(); self.maintenance = nil
                }
            }
        }
    }

    private func reply(_ transfer: String, _ status: ClipboardStatus) {
        guard ClipboardTransferID.isValid(transfer) else { return }
        _ = transport?(.result(transfer, status))
    }
}
