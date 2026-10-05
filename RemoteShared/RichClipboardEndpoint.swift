import Foundation
import Combine

struct RichClipboardSource {
    let png: RichClipboardPNG
    let stillCurrent: () -> Bool
}

/// One explicit PNG transaction per endpoint. File engine receipts mean verified bulk only;
/// `committed` is separately emitted after a fresh pasteboard mutation and revision barrier.
@MainActor
final class RichClipboardEndpoint: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var progress: Double = 0
    let engine: FileTransferEngine
    let isHost: Bool
    var allowed: () -> Bool = { false }
    var transport: ((WorkspaceFrame) -> Bool)?
    var beginExplicit: () -> UInt64 = { 1 }
    var finishExplicit: ((UInt64?, Bool) -> Void)?
    var readImage: ((TransferEffectLease, @escaping @MainActor (Result<RichClipboardSource, ClipboardStatus>) -> Void) -> Void)?
    var storeImage: ((RichClipboardPNG, UInt64, TransferEffectLease, @escaping @MainActor (Bool) -> Void) -> Void)?
    private struct Transaction {
        let id: String
        let direction: FileTransferDirection
        let lease: TransferEffectLease
        var revision: UInt64?
        var image: RichImageMetadata?
        var source: RichClipboardSource?
        var sink: RichClipboardSink?
        var bulkVerified = false
    }
    private var transaction: Transaction?
    private var timeout: Task<Void, Never>?
    init(isHost: Bool) {
        self.isHost = isHost; engine = FileTransferEngine(acceptsUnsolicitedOffers: isHost)
        engine.sendControl = { [weak self] frame in
            guard let self, let current = self.transaction, current.id == frame.transfer,
                  current.lease.isActive, self.allowed(), let revision = current.revision else { return false }
            if frame.op == "complete", current.source?.stillCurrent() == false {
                self.fail(.unchanged); return false
            }
            return self.send(RichClipboardMessage(operation: .control, transfer: current.id, revision: revision, control: frame))
        }
        engine.admit = { [weak self] offer, answer in
            guard let self, var current = self.transaction, current.direction == .incoming,
                  current.id == offer.transfer, current.lease.isActive, self.allowed(), let image = current.image,
                  offer.bytes == Int64(image.bytes), offer.type == "public.png", offer.name == "Clipboard image" else { answer(.failure(.notAllowed)); return }
            let sink = RichClipboardSink(expected: image); current.sink = sink; self.transaction = current
            answer(.success(sink))
        }
        engine.onFinish = { [weak self] finish in self?.finished(finish) }
        engine.onChange = { [weak self] in
            guard let self else { return }; self.progress = self.engine.incoming?.fraction ?? self.engine.outgoing?.fraction ?? 0
        }
    }
    func reset() {
        let old = transaction; transaction = nil; timeout?.cancel(); timeout = nil; busy = false; progress = 0
        old?.lease.closeAdmission(); engine.reset(); old?.sink?.discard()
        if let old { finishExplicit?(old.revision, false) }
    }
    func cancel() {
        if let current = transaction { _ = send(RichClipboardMessage(operation: .cancel, transfer: current.id)) }
        reset(); notice = "Image clipboard transfer canceled."
    }
    /// Phone invokes only after the system Paste control supplied a bounded image representation.
    func sendImage(_ source: RichClipboardSource) {
        guard !isHost, allowed(), !busy, source.stillCurrent() else { notice = "Image clipboard is unavailable or changed. Tap Paste again."; return }
        let id = FileTransferID.make(); _ = beginExplicit()
        transaction = Transaction(id: id, direction: .outgoing, lease: TransferEffectLease(), image: source.png.metadata, source: source)
        busy = true; notice = nil; startTimeout(id)
        if !send(RichClipboardMessage(operation: .push, transfer: id, image: source.png.metadata)) { fail(.notAllowed) }
    }
    /// Phone explicitly asks for the Mac's current image; nothing is read on the phone here.
    func requestImage() {
        guard !isHost, allowed(), !busy else { notice = "Image clipboard is unavailable right now."; return }
        let id = FileTransferID.make(); _ = beginExplicit()
        transaction = Transaction(id: id, direction: .incoming, lease: TransferEffectLease())
        busy = true; notice = nil; startTimeout(id)
        if !engine.requestBrowserDownload(id, send: { self.send(RichClipboardMessage(operation: .pull, transfer: id)) }) { fail(.notAllowed) }
    }
    func receive(_ frame: WorkspaceFrame) {
        guard let message = try? RichClipboardMessage.decode(frame) else { return }
        guard allowed() else {
            if transaction?.id == message.transfer { fail(.notAllowed) }
            else { _ = send(RichClipboardMessage(operation: .failed, transfer: message.transfer, status: ClipboardStatus.notAllowed.rawValue)) }
            return
        }
        if isHost, message.operation == .pull || message.operation == .push {
            guard !busy else { _ = send(RichClipboardMessage(operation: .failed, transfer: message.transfer, status: ClipboardStatus.busy.rawValue)); return }
            let revision = beginExplicit(), lease = TransferEffectLease()
            transaction = Transaction(id: message.transfer, direction: message.operation == .pull ? .outgoing : .incoming,
                                      lease: lease, revision: revision, image: message.image)
            busy = true; notice = nil; startTimeout(message.transfer)
            if message.operation == .pull {
                guard let readImage else { fail(.unsupported); return }
                readImage(lease) { [weak self] result in
                    guard let self, var current = self.transaction, current.id == message.transfer, current.lease === lease,
                          lease.isActive, self.allowed() else { return }
                    switch result {
                    case .success(let source):
                        guard source.stillCurrent() else { self.fail(.unchanged); return }
                        current.source = source; current.image = source.png.metadata; self.transaction = current
                        guard self.send(RichClipboardMessage(operation: .ready, transfer: current.id, revision: revision, image: source.png.metadata)) else { self.fail(.notAllowed); return }
                        self.startSending(current)
                    case .failure(let status): self.fail(status)
                    }
                }
            } else if !send(RichClipboardMessage(operation: .ready, transfer: message.transfer, revision: revision, image: message.image)) { fail(.notAllowed) }
            return
        }
        guard var current = transaction, current.id == message.transfer, current.lease.isActive else { return }
        switch message.operation {
        case .ready:
            guard !isHost, current.revision == nil, let revision = message.revision, let image = message.image,
                  current.image == nil || current.image == image else { fail(.invalid); return }
            current.revision = revision; current.image = image; transaction = current
            if current.direction == .outgoing { startSending(current) }
        case .control:
            guard message.revision == current.revision, let control = message.control else { fail(.invalid); return }
            engine.receive(control)
        case .committed:
            guard message.revision == current.revision else { fail(.invalid); return }
            guard current.direction == .outgoing, current.bulkVerified else { fail(.invalid); return }
            let revision = current.revision; finishExplicit?(revision, true)
            resetWithoutFinishing(); notice = isHost ? "Image copied to your phone." : "Image copied to your Mac’s clipboard."
        case .cancel: reset(); notice = "Image clipboard transfer canceled."
        case .failed:
            let status = message.status.flatMap(ClipboardStatus.init(rawValue:)) ?? .invalid
            reset(); notice = Self.message(status)
        default: fail(.invalid)
        }
    }
    private func startSending(_ current: Transaction) {
        guard let source = current.source, source.stillCurrent(), current.revision != nil, allowed() else { fail(.unchanged); return }
        if case .failure = engine.send(DataByteSource(source.png.data), name: "Clipboard image", type: "public.png", transfer: current.id) { fail(.invalid) }
    }
    private func finished(_ finish: FileTransferFinish) {
        guard var current = transaction, current.id == finish.transfer, current.lease.isActive, allowed() else { return }
        guard finish.status == .stored else { fail(.invalid); return }
        current.bulkVerified = true; transaction = current
        guard finish.direction == .incoming else { return }
        guard let png = current.sink?.take(), let revision = current.revision, let storeImage else { fail(.invalid); return }
        let lease = current.lease
        storeImage(png, revision, lease) { [weak self] stored in
            guard let self, let exact = self.transaction, exact.id == current.id, exact.lease === lease, lease.isActive, self.allowed() else { return }
            guard stored else { self.fail(.invalid); return }
            self.finishExplicit?(revision, true)
            guard self.send(RichClipboardMessage(operation: .committed, transfer: exact.id, revision: revision)) else { self.resetWithoutFinishing(); self.notice = "Image copied here; your other device did not confirm the receipt."; return }
            self.resetWithoutFinishing(); self.notice = self.isHost ? "Image copied to your Mac’s clipboard." : "Image copied from your Mac."
        }
    }
    private func resetWithoutFinishing() {
        let old = transaction; transaction = nil; timeout?.cancel(); timeout = nil; busy = false; progress = 0
        old?.lease.closeAdmission(); engine.reset(); old?.sink?.discard()
    }
    private func fail(_ status: ClipboardStatus) {
        if let current = transaction { _ = send(RichClipboardMessage(operation: .failed, transfer: current.id, status: status.rawValue)) }
        reset(); notice = Self.message(status)
    }
    private func send(_ message: RichClipboardMessage) -> Bool {
        guard (try? message.validate()) != nil,
              let frame = try? WorkspaceFrame(kind: .richClipboard, requestID: InputCausalEnvelope.identity(), value: message) else { return false }
        return transport?(frame) == true
    }
    private func startTimeout(_ id: String) {
        timeout?.cancel(); timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: RichClipboardLimits.timeout)
            guard !Task.isCancelled, self?.transaction?.id == id else { return }; self?.fail(.busy)
        }
    }
    private static func message(_ status: ClipboardStatus) -> String {
        switch status {
        case .concealed: "This clipboard is marked private and cannot be shared."
        case .unchanged: "The clipboard changed. Tap again to send its current image."
        case .tooLarge: "Image limit: 8 MB encoded, 16 megapixels."
        case .unsupported, .empty: "The clipboard has no supported image."
        case .busy: "Image delivery is uncertain. Check the clipboard before trying again."
        default: "The image clipboard transfer could not finish."
        }
    }
}
