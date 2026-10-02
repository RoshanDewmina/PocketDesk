import Foundation
import CryptoKit

extension FileTransferStatus: Error {}

/// The `file` data channel as the transfer engine sees it. Called from the engine's I/O queue.
protocol FileChannelLink: AnyObject {
    func sendFile(_ data: Data) -> Bool
    var fileBufferedAmount: UInt64? { get }
    func permitsFileSend(bytes: Int, at now: TimeInterval) -> Bool
    /// Whole message size, header included, for the next chunk.
    func fileMessageBytes(at now: TimeInterval) -> Int
    /// The queue the link's lane allows now (2 MiB on the calm-LAN fast lane, else 32 KiB).
    func fileQueueBytes(at now: TimeInterval) -> UInt64
}

extension FileChannelLink {
    // In-memory test links do not share a real association. PeerMedia overrides these.
    func permitsFileSend(bytes: Int, at now: TimeInterval) -> Bool { true }
    func fileMessageBytes(at now: TimeInterval) -> Int { FileTransferLimits.maximumOutgoingMessageBytes }
    func fileQueueBytes(at now: TimeInterval) -> UInt64 { FileTransferLimits.directHighWater }
}

protocol FileByteSource: AnyObject {
    var byteCount: Int64 { get }
    func read(upTo count: Int) throws -> Data
    func close()
}

protocol FileByteSink: AnyObject {
    func write(_ data: Data) throws
    /// Called only after the whole-file digest matched. Returns where the file now lives.
    func commit() throws -> URL
    func discard()
}

enum FileTransferDirection: Equatable {
    case outgoing, incoming
}

struct FileTransferOffer: Equatable {
    let transfer: String
    let name: String
    let bytes: Int64
    let type: String?
}

struct FileTransferSnapshot: Equatable {
    enum Phase: Equatable { case waiting, transferring, verifying }
    let transfer: String
    let direction: FileTransferDirection
    var name: String
    var total: Int64
    var bytes: Int64
    var phase: Phase

    var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
}

struct FileTransferFinish: Equatable {
    let transfer: String
    let direction: FileTransferDirection
    let name: String?
    let status: FileTransferStatus
    let savedURL: URL?
    /// The Mac's stated reason for a refusal, when it gave one.
    var reason: String? = nil
    /// Local lifetime identity; a deferred finish must not update a newer receive's UI.
    var admissionID: UUID? = nil
}

final class DataByteSource: FileByteSource {
    private let data: Data
    private var position = 0

    init(_ data: Data) { self.data = data }

    var byteCount: Int64 { Int64(data.count) }

    func read(upTo count: Int) throws -> Data {
        let end = min(data.count, position + count)
        defer { position = end }
        return data.subdata(in: position..<end)
    }

    func close() {}
}

final class FileHandleByteSource: FileByteSource {
    let byteCount: Int64
    private let handle: FileHandle
    private let onClose: () -> Void
    private var closed = false

    /// Refuses directories, packages and anything that is not a regular file.
    init(url: URL, onClose: @escaping () -> Void = {}) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileSizeKey])
        guard values.isRegularFile == true else { throw FileTransferStatus.unsupported }
        byteCount = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        handle = try FileHandle(forReadingFrom: url)
        self.onClose = onClose
    }

    func read(upTo count: Int) throws -> Data {
        try handle.read(upToCount: count) ?? Data()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        onClose()
    }

    deinit { close() }
}

/// Writes to a hidden partial file created exclusively without following links, then renames it into
/// place without ever replacing an existing file ("report.pdf", "report 2.pdf", …).
final class FolderFileSink: FileByteSink {
    private let folder: URL
    private let name: String
    private let partial: URL
    private let finalize: (URL) throws -> Void
    private var handle: FileHandle?

    init(folder: URL, partialFolder: URL, name: String, transfer: String,
         finalize: @escaping (URL) throws -> Void = { _ in }) throws {
        self.folder = folder
        self.name = FileNameSanitizer.sanitize(name)
        self.finalize = finalize
        partial = partialFolder.appendingPathComponent(".farside-\(transfer).partial", isDirectory: false)
        let descriptor = partial.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw Self.status(for: errno) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(_ data: Data) throws {
        guard let handle else { throw FileTransferStatus.invalid }
        do { try handle.write(contentsOf: data) } catch { throw Self.status(for: error) }
    }

    func commit() throws -> URL {
        guard let handle else { throw FileTransferStatus.invalid }
        self.handle = nil
        do { try handle.close() } catch { discardPartial(); throw Self.status(for: error) }
        do { try finalize(partial) } catch { discardPartial(); throw Self.status(for: error) }
        for attempt in 1...999 {
            let target = folder.appendingPathComponent(FileNameSanitizer.candidate(name, attempt: attempt), isDirectory: false)
            let result = partial.withUnsafeFileSystemRepresentation { source in
                target.withUnsafeFileSystemRepresentation { destination -> Int32 in
                    guard let source, let destination else { return -1 }
                    return renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return target }
            guard errno == EEXIST else { let code = errno; discardPartial(); throw Self.status(for: code) }
        }
        discardPartial()
        throw FileTransferStatus.busy
    }

    func discard() {
        try? handle?.close()
        handle = nil
        discardPartial()
    }

    private func discardPartial() {
        _ = partial.withUnsafeFileSystemRepresentation { path in path.map { unlink($0) } }
    }

    static func status(for error: Error) -> FileTransferStatus {
        if let status = error as? FileTransferStatus { return status }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return status(for: Int32(nsError.code)) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return status(for: Int32(underlying.code))
        }
        switch nsError.code {
        case NSFileWriteOutOfSpaceError: return .diskFull
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .denied
        default: return .invalid
        }
    }

    static func status(for code: Int32) -> FileTransferStatus {
        switch code {
        case ENOSPC, EDQUOT: .diskFull
        case EACCES, EPERM, EROFS: .denied
        default: .invalid
        }
    }
}

/// Runs one outgoing and one incoming transfer over a session. Control frames and state live on the
/// main actor; reading, hashing, writing and chunk sends run on a private serial queue, so file bytes
/// never occupy the main thread that handles input. Nothing here logs names or contents.
@MainActor
final class FileTransferEngine {
    var sendControl: ((FileFrame) -> Bool)?
    /// The live `file` channel, read once when a transfer starts.
    var link: (() -> FileChannelLink?)?
    var isRelayed: () -> Bool = { false }
    /// Decides an incoming offer: a sink to write into, or the refusal to send back. It may answer
    /// later on the main actor (a first write into Downloads can wait on a macOS consent prompt).
    var admit: ((FileTransferOffer, @escaping @MainActor (Result<FileByteSink, FileTransferStatus>) -> Void) -> Void)?
    /// Host: the phone asked for a file chosen on the Mac.
    var onRequest: ((String) -> Void)?
    var onLink: ((String, String) -> Void)?
    /// A result for a transfer the engine does not track, such as a link.
    var onOtherResult: ((String, FileTransferStatus) -> Void)?
    var onChange: (() -> Void)?
    var onFinish: ((FileTransferFinish) -> Void)?

    private(set) var outgoing: FileTransferSnapshot?
    private(set) var incoming: FileTransferSnapshot?
    private(set) var pendingRequest: String?

    private let acceptsUnsolicitedOffers: Bool
    private let clock: () -> TimeInterval
    private let io: FileTransferIO
    private var outgoingWork: FileTransferIO.Outgoing?
    private var incomingLease: TransferEffectLease?
    private var outgoingActivity: TimeInterval = 0
    private var incomingActivity: TimeInterval = 0
    private(set) var incomingAdmissionID: UUID?
    private var requestSince: TimeInterval = 0
    private var progressThrottle = FileProgressThrottle()
    private var watchdog: Timer?

    init(acceptsUnsolicitedOffers: Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, io: FileTransferIO = FileTransferIO()) {
        self.io = io
        self.acceptsUnsolicitedOffers = acceptsUnsolicitedOffers
        self.clock = clock
        io.events = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
    }

    var isIdle: Bool { outgoing == nil && incoming == nil && pendingRequest == nil }

    // MARK: Sending

    @discardableResult
    func send(_ source: FileByteSource, name: String, type: String?, transfer: String? = nil) -> Result<String, FileTransferStatus> {
        guard outgoing == nil else { source.close(); return .failure(.busy) }
        guard source.byteCount > 0 else { source.close(); return .failure(.empty) }
        guard source.byteCount <= FileTransferLimits.maximumBytes else { source.close(); return .failure(.tooLarge) }
        let id = transfer ?? FileTransferID.make()
        let wireName = FileNameSanitizer.sanitize(name)
        let wireType = type.flatMap { FileFrame.isWellFormedType($0) ? $0 : nil }
        let work = io.reserveSending(transfer: id, source: source)
        outgoingWork = work
        outgoing = FileTransferSnapshot(transfer: id, direction: .outgoing, name: wireName, total: source.byteCount,
                                        bytes: 0, phase: .waiting)
        outgoingActivity = clock()
        guard sendControl?(.offer(id, name: wireName, bytes: source.byteCount, type: wireType)) == true,
              outgoingWork === work, work.lease.isActive else {
            io.stopSending(work)
            if outgoingWork === work { outgoingWork = nil; outgoing = nil }
            return .failure(.connectionLost)
        }
        startWatchdog()
        onChange?()
        return .success(id)
    }

    /// Phone: ask the Mac to show a file picker on its own screen.
    @discardableResult
    func request() -> Result<String, FileTransferStatus> {
        guard pendingRequest == nil, incoming == nil else { return .failure(.busy) }
        let id = FileTransferID.make()
        guard sendControl?(.request(id)) == true else { return .failure(.connectionLost) }
        pendingRequest = id
        requestSince = clock()
        startWatchdog()
        onChange?()
        return .success(id)
    }

    /// Host: the phone's request ended without a file (the picker was cancelled or refused).
    func answerRequest(_ transfer: String, _ status: FileTransferStatus, reason: String? = nil) {
        _ = sendControl?(.result(transfer, status, reason: reason))
    }

    func cancelAll(status: FileTransferStatus = .cancelled, notify: Bool = true) {
        if let outgoing { finishOutgoing(outgoing.transfer, status, notify: notify ? .cancel : .none) }
        if let incoming { finishIncoming(incoming.transfer, status, url: nil, notify: notify ? .cancel : .none) }
        if let pendingRequest { finishRequest(pendingRequest, status, notify: notify) }
    }

    func cancel(_ transfer: String) {
        if outgoing?.transfer == transfer { finishOutgoing(transfer, .cancelled, notify: .cancel) }
        if incoming?.transfer == transfer { finishIncoming(transfer, .cancelled, url: nil, notify: .cancel) }
        if pendingRequest == transfer { finishRequest(transfer, .cancelled, notify: true) }
    }

    /// The session ended: stop quietly, since there is no peer left to tell.
    func reset() {
        cancelAll(status: .connectionLost, notify: false)
    }

    // MARK: Receiving

    nonisolated func receiveChunk(_ data: Data) {
        io.receive(data)
    }

    nonisolated func fileBufferedAmountChanged() {
        io.wake()
    }

    func receive(_ frame: FileFrame) {
        let now = clock()
        switch frame.op {
        case "offer":
            receiveOffer(frame)
        case "accept":
            guard var current = outgoing, current.transfer == frame.transfer, current.phase == .waiting,
                  let work = outgoingWork else { return }
            guard let channel = link?() else {
                finishOutgoing(current.transfer, .connectionLost, notify: .cancel)
                return
            }
            current.phase = .transferring
            outgoing = current
            outgoingActivity = now
            let relayed = isRelayed()
            io.beginSending(work, link: channel,
                            chunk: FileTransferLimits.chunkPayload(relayed: relayed),
                            highWater: FileTransferLimits.highWater(relayed: relayed),
                            pacer: FilePacer(bytesPerSecond: relayed ? FileTransferLimits.relayBytesPerSecond : nil))
            onChange?()
        case "progress":
            guard var current = outgoing, current.transfer == frame.transfer, current.phase != .waiting,
                  let bytes = frame.bytes, bytes <= current.total else { return }
            current.bytes = max(current.bytes, bytes)
            outgoing = current
            outgoingActivity = now
            onChange?()
        case "complete":
            guard let current = incoming, current.transfer == frame.transfer, let digest = frame.digest else { return }
            incomingActivity = now
            io.receiveDigest(transfer: current.transfer, digest: digest)
        case "result":
            let status = frame.status.flatMap(FileTransferStatus.init(rawValue:)) ?? .invalid
            if outgoing?.transfer == frame.transfer {
                finishOutgoing(frame.transfer, status, notify: .none, reason: frame.reason)
            } else if pendingRequest == frame.transfer {
                finishRequest(frame.transfer, status, notify: false, reason: frame.reason)
            } else {
                onOtherResult?(frame.transfer, status)
            }
        case "cancel":
            if outgoing?.transfer == frame.transfer { finishOutgoing(frame.transfer, .cancelled, notify: .none) }
            if incoming?.transfer == frame.transfer { finishIncoming(frame.transfer, .cancelled, url: nil, notify: .none) }
            if pendingRequest == frame.transfer { finishRequest(frame.transfer, .cancelled, notify: false) }
            if acceptsUnsolicitedOffers { onRequestCancelled?(frame.transfer) }
        case "request":
            guard acceptsUnsolicitedOffers else { _ = sendControl?(.result(frame.transfer, .notAllowed)); return }
            guard outgoing == nil, let onRequest else { _ = sendControl?(.result(frame.transfer, .busy)); return }
            onRequest(frame.transfer)
        case "link":
            guard let url = frame.url else { return }
            guard let onLink else { _ = sendControl?(.result(frame.transfer, .unsupported)); return }
            onLink(frame.transfer, url)
        default:
            break
        }
    }

    /// Host: the phone withdrew a request (for example while the Mac's picker is still open).
    var onRequestCancelled: ((String) -> Void)?

    private func receiveOffer(_ frame: FileFrame) {
        guard let rawName = frame.name, let bytes = frame.bytes else { return }
        let solicited = pendingRequest == frame.transfer
        guard acceptsUnsolicitedOffers || solicited else {
            _ = sendControl?(.result(frame.transfer, .notAllowed))
            return
        }
        if solicited { pendingRequest = nil }
        let offer = FileTransferOffer(transfer: frame.transfer, name: FileNameSanitizer.sanitize(rawName),
                                      bytes: bytes, type: frame.type)
        if incoming != nil {
            refuse(offer, .busy, solicited: solicited)
        } else if bytes > FileTransferLimits.maximumBytes {
            refuse(offer, .tooLarge, solicited: solicited)
        } else if let admit {
            incoming = FileTransferSnapshot(transfer: offer.transfer, direction: .incoming, name: offer.name,
                                            total: bytes, bytes: 0, phase: .waiting)
            incomingActivity = clock()
            progressThrottle = FileProgressThrottle()
            let lease = TransferEffectLease(nonblockingAdmission: io.usesReceiveBudget)
            incomingLease = lease
            let admission = lease.id
            incomingAdmissionID = admission
            startWatchdog()
            onChange?()
            guard incomingLease === lease, lease.isActive else { return }
            admit(offer) { [weak self, io] result in
                guard let self else {
                    if case .success(let sink) = result { io.discardUnadmittedSink(sink) }
                    return
                }
                self.admitted(offer, result, admission: admission)
            }
        } else {
            refuse(offer, .unsupported, solicited: solicited)
        }
    }

    private func admitted(_ offer: FileTransferOffer, _ result: Result<FileByteSink, FileTransferStatus>, admission: UUID) {
        guard incomingAdmissionID == admission, let lease = incomingLease, lease.id == admission, lease.isActive,
              var current = incoming, current.transfer == offer.transfer, current.phase == .waiting else {
            if case .success(let sink) = result { io.discardUnadmittedSink(sink) }
            return
        }
        switch result {
        case .success(let sink):
            current.phase = .transferring
            incoming = current
            incomingActivity = clock()
            io.beginReceiving(transfer: offer.transfer, bytes: offer.bytes, sink: sink, lease: lease)
            onChange?()
        case .failure(let status):
            finishIncoming(offer.transfer, status, url: nil, notify: .result)
        }
    }

    private func refuse(_ offer: FileTransferOffer, _ status: FileTransferStatus, solicited: Bool) {
        _ = sendControl?(.result(offer.transfer, status))
        guard solicited else { return }
        stopWatchdogIfIdle()
        onFinish?(FileTransferFinish(transfer: offer.transfer, direction: .incoming, name: offer.name, status: status, savedURL: nil))
        onChange?()
    }

    // MARK: I/O events

    private func handle(_ delivery: FileTransferIO.Delivery) {
        // Overflow closes the lease at ingress, before another Data closure can be queued.
        // This one terminal delivery is allowed through only for that exact admission.
        if case .receiveOverflow(let transfer) = delivery.event {
            guard incomingLease === delivery.lease else { return }
            finishIncoming(transfer, .invalid, url: nil, notify: .result)
            return
        }
        guard delivery.lease.isActive else { return }
        switch delivery.event {
        case .sent, .sendFailed:
            guard outgoingWork?.lease === delivery.lease else { return }
        default:
            guard incomingLease === delivery.lease else { return }
        }
        let now = clock()
        switch delivery.event {
        case .receiverReady(let transfer):
            guard incoming?.transfer == transfer else { return }
            let accepted = sendControl?(.accept(transfer)) == true
            guard incomingLease === delivery.lease, delivery.lease.isActive else { return }
            if !accepted { finishIncoming(transfer, .connectionLost, url: nil, notify: .none) }
        case .received(let transfer, let bytes):
            guard var current = incoming, current.transfer == transfer else { return }
            current.bytes = bytes
            if bytes == current.total { current.phase = .verifying }
            incoming = current
            incomingActivity = now
            if progressThrottle.shouldReport(at: now, final: bytes == current.total) {
                _ = sendControl?(.progress(transfer, bytes: bytes))
            }
            onChange?()
        case .receivedFile(let transfer, let status, let url):
            guard incoming?.transfer == transfer else { return }
            finishIncoming(transfer, status, url: url, notify: .result)
        case .sent(let transfer, let digest):
            guard var current = outgoing, current.transfer == transfer else { return }
            current.phase = .verifying
            outgoing = current
            outgoingActivity = now
            let completed = sendControl?(.complete(transfer, digest: digest)) == true
            guard outgoingWork?.lease === delivery.lease, delivery.lease.isActive else { return }
            if !completed { finishOutgoing(transfer, .connectionLost, notify: .none); return }
            onChange?()
        case .sendFailed(let transfer, let status):
            guard outgoing?.transfer == transfer else { return }
            finishOutgoing(transfer, status, notify: .cancel)
        case .receiveOverflow: break // Handled above, including the closed lease.
        }
    }

    // MARK: Finishing

    private enum Notice { case none, cancel, result }

    private func finishOutgoing(_ transfer: String, _ status: FileTransferStatus, notify: Notice, reason: String? = nil) {
        guard let current = outgoing, current.transfer == transfer else { return }
        if let work = outgoingWork { io.stopSending(work) }
        outgoing = nil
        outgoingWork = nil
        if notify == .cancel { _ = sendControl?(.cancel(transfer)) }
        stopWatchdogIfIdle()
        onFinish?(FileTransferFinish(transfer: transfer, direction: .outgoing, name: current.name, status: status, savedURL: nil, reason: reason))
        onChange?()
    }

    private func finishIncoming(_ transfer: String, _ status: FileTransferStatus, url: URL?, notify: Notice) {
        guard let current = incoming, current.transfer == transfer else { return }
        let finish = FileTransferFinish(transfer: transfer, direction: .incoming, name: current.name, status: status,
                                        savedURL: url, admissionID: incomingAdmissionID)
        let lease = incomingLease
        if let lease {
            if io.usesReceiveBudget {
                io.stopReceiving(lease) { [weak self] in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFinish?(finish) } }
                }
            } else {
                io.stopReceiving(lease) // Kill switch restores the synchronous retirement fence.
            }
        }
        incoming = nil
        incomingAdmissionID = nil
        incomingLease = nil
        switch notify {
        case .none: break
        case .cancel: _ = sendControl?(.cancel(transfer))
        case .result: _ = sendControl?(.result(transfer, status))
        }
        stopWatchdogIfIdle()
        // UI/admission closes now; terminal completion means the admitted disk effects settled.
        if lease == nil || !io.usesReceiveBudget { onFinish?(finish) }
        onChange?()
    }

    private func finishRequest(_ transfer: String, _ status: FileTransferStatus, notify: Bool, reason: String? = nil) {
        guard pendingRequest == transfer else { return }
        pendingRequest = nil
        if notify { _ = sendControl?(.cancel(transfer)) }
        stopWatchdogIfIdle()
        onFinish?(FileTransferFinish(transfer: transfer, direction: .incoming, name: nil, status: status, savedURL: nil, reason: reason))
        onChange?()
    }

    // MARK: Timeouts

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTimeouts() }
        }
    }

    private func stopWatchdogIfIdle() {
        guard isIdle else { return }
        watchdog?.invalidate()
        watchdog = nil
    }

    func checkTimeouts() {
        let now = clock()
        if let current = outgoing {
            let limit = current.phase == .waiting ? FileTransferLimits.acceptTimeout : FileTransferLimits.stallTimeout
            if now - outgoingActivity > limit { finishOutgoing(current.transfer, .timedOut, notify: .cancel) }
        }
        if let current = incoming,
           now - incomingActivity > (current.phase == .waiting ? FileTransferLimits.acceptTimeout : FileTransferLimits.stallTimeout) {
            finishIncoming(current.transfer, .timedOut, url: nil, notify: .result)
        }
        if let pendingRequest, now - requestSince > FileTransferLimits.pickTimeout {
            finishRequest(pendingRequest, .timedOut, notify: true)
        }
        stopWatchdogIfIdle()
    }
}

/// File-byte state and cleanup are serial; terminal leases additionally fence off-main effects.
final class FileTransferIO: @unchecked Sendable {
    enum Event {
        case receiverReady(String), received(String, Int64), receivedFile(String, FileTransferStatus, URL?)
        case sent(String, String), sendFailed(String, FileTransferStatus)
        case receiveOverflow(String)
    }
    struct Delivery { let event: Event; let lease: TransferEffectLease }
    final class Outgoing: @unchecked Sendable {
        let transfer: String, source: FileByteSource, lease = TransferEffectLease()
        private var closed = false // IO queue only, including waiting-transfer cleanup.
        init(transfer: String, source: FileByteSource) { self.transfer = transfer; self.source = source }
        func closeSource() { guard !closed else { return }; closed = true; source.close() }
    }
    private final class Sending {
        let work: Outgoing, link: FileChannelLink, chunk: Int, highWater: UInt64
        var pacer: FilePacer, hasher = SHA256(), sent: Int64 = 0, pumpScheduled = false, awaitingDrain = false
        init(work: Outgoing, link: FileChannelLink, chunk: Int, highWater: UInt64, pacer: FilePacer) {
            self.work = work; self.link = link; self.chunk = chunk; self.highWater = highWater; self.pacer = pacer
        }
    }
    private struct Receiving {
        var assembler: FileAssembler
        let sink: FileByteSink, lease: TransferEffectLease
        var lastReport: TimeInterval = 0
    }
    private struct IncomingAdmission {
        let transfer: String
        let lease: TransferEffectLease
    }
    let queue: DispatchQueue
    var events: ((Delivery) -> Void)?
    private let registryLock = NSLock()
    private var outgoingAdmission: Outgoing?
    private var incomingAdmission: IncomingAdmission?
    private var reservedReceiveBytes = 0, reservedReceiveChunks = 0
    private var wakeQueued = false
    private var sending: Sending? // IO queue only.
    private var receiving: Receiving?
    private static let chunksPerTurn = 64
    /// Refill comes from the channel's buffered-amount callbacks (`wake`); this timer is only a backstop.
    static let drainBackstop: TimeInterval = 0.02
    /// One internal switch controls P32's budget and P35's two-stage receive retirement.
    /// Explicit NO restores unbounded chunk enqueue and the old synchronous retirement fence.
    static let receiveBudgetKey = "PocketDeskReceiveBudget"
    static func receiveBudgetEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: receiveBudgetKey) == nil || defaults.bool(forKey: receiveBudgetKey)
    }
    /// Frozen for this process; change the internal defaults key before relaunching to compare.
    static let receiveBudgetIsOn = receiveBudgetEnabled()
    let usesReceiveBudget: Bool
    private let maximumPendingReceiveBytes: Int
    private let maximumPendingReceiveChunks: Int
    var pendingReceiveBytes: Int { registryLock.lock(); defer { registryLock.unlock() }; return reservedReceiveBytes }
    /// Both chunk and digest closures, including a write/commit currently in flight.
    var pendingReceiveChunks: Int { registryLock.lock(); defer { registryLock.unlock() }; return reservedReceiveChunks }
    init(queue: DispatchQueue = DispatchQueue(label: "Farside.file-transfer", qos: .utility),
         receiveBudgetEnabled: Bool = FileTransferIO.receiveBudgetIsOn,
         maximumPendingReceiveBytes: Int = 2 * 1024 * 1024, maximumPendingReceiveChunks: Int = 256) {
        self.queue = queue
        usesReceiveBudget = receiveBudgetEnabled
        self.maximumPendingReceiveBytes = max(1, maximumPendingReceiveBytes)
        self.maximumPendingReceiveChunks = max(1, maximumPendingReceiveChunks)
    }

    func reserveSending(transfer: String, source: FileByteSource) -> Outgoing {
        let work = Outgoing(transfer: transfer, source: source)
        registryLock.lock(); let old = outgoingAdmission; outgoingAdmission = work; registryLock.unlock()
        if let old { stopSending(old) }
        return work
    }
    func beginSending(_ work: Outgoing, link: FileChannelLink, chunk: Int, highWater: UInt64, pacer: FilePacer) {
        queue.async {
            guard work.lease.isActive else { work.closeSource(); return }
            self.sending = Sending(work: work, link: link, chunk: chunk, highWater: highWater, pacer: pacer)
            self.pump()
        }
    }
    func stopSending(_ work: Outgoing) {
        registryLock.lock(); if outgoingAdmission === work { outgoingAdmission = nil }; registryLock.unlock()
        work.lease.retire() // No registry lock through an effect/retirement wait.
        queue.async {
            if self.sending?.work === work { self.sending = nil }
            work.closeSource()
        }
    }
    func wake() {
        guard usesReceiveBudget else { queue.async { self.pump() }; return }
        registryLock.lock()
        guard !wakeQueued else { registryLock.unlock(); return }
        wakeQueued = true; registryLock.unlock()
        queue.async {
            self.registryLock.lock(); self.wakeQueued = false; self.registryLock.unlock()
            self.pump()
        }
    }
    private func emit(_ event: Event, lease: TransferEffectLease) {
        guard lease.isActive else { return }
        events?(Delivery(event: event, lease: lease)) // Never called inside final-effect lock.
    }
    private func pump() {
        guard let sending, sending.work.lease.isActive else { return }
        sending.pumpScheduled = false
        let work = sending.work, total = work.source.byteCount
        var turns = 0
        while sending.sent < total {
            guard work.lease.isActive else { return }
            guard let buffered = sending.link.fileBufferedAmount else { fail(sending, .connectionLost); return }
            let now = ProcessInfo.processInfo.systemUptime
            let chunk = min(sending.chunk, max(1, sending.link.fileMessageBytes(at: now) - FileTransferLimits.chunkHeaderBytes))
            let size = Int(min(Int64(chunk), total - sending.sent))
            // Low-water refill: once full, wait until half the queue has drained so each wake sends a batch.
            let highWater = min(sending.highWater, sending.link.fileQueueBytes(at: now))
            if buffered + UInt64(size + FileTransferLimits.chunkHeaderBytes) > highWater
                || (sending.awaitingDrain && buffered > highWater / 2) {
                sending.awaitingDrain = true; schedule(sending, after: Self.drainBackstop); return
            }
            sending.awaitingDrain = false
            guard sending.pacer.allows(size, at: now) else { schedule(sending, after: 0.01); return }
            guard sending.link.permitsFileSend(bytes: size + FileTransferLimits.chunkHeaderBytes, at: now) else {
                sending.pacer.refund(size); schedule(sending, after: 0.01); return
            }
            let payload: Data
            do { payload = try work.source.read(upTo: size) } catch { fail(sending, .unreadable); return }
            guard payload.count == size, let message = FileChunk.encode(transfer: work.transfer, offset: sending.sent, payload: payload)
            else { fail(sending, .unreadable); return }
            // Read may have blocked across revocation. Fence the actual bounded send, not only its callback.
            guard let sent = work.lease.performIfActive({ sending.link.sendFile(message) }) else { return }
            guard sent else { fail(sending, .connectionLost); return }
            sending.hasher.update(data: payload); sending.sent += Int64(size); turns += 1
            if turns >= Self.chunksPerTurn, sending.sent < total { schedule(sending, after: 0); return }
        }
        self.sending = nil; work.closeSource()
        emit(.sent(work.transfer, FileDigest.hex(sending.hasher.finalize())), lease: work.lease)
    }
    private func schedule(_ sending: Sending, after delay: TimeInterval) {
        guard sending.work.lease.isActive, !sending.pumpScheduled else { return }
        sending.pumpScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak sending] in
            guard let sending, self.sending === sending else { return }; self.pump()
        }
    }
    private func fail(_ sending: Sending, _ status: FileTransferStatus) {
        self.sending = nil; sending.work.closeSource()
        emit(.sendFailed(sending.work.transfer, status), lease: sending.work.lease)
    }
    func beginReceiving(transfer: String, bytes: Int64, sink: FileByteSink, lease: TransferEffectLease) {
        guard lease.isActive else { queue.async { sink.discard() }; return }
        registryLock.lock(); let old = incomingAdmission
        incomingAdmission = IncomingAdmission(transfer: transfer, lease: lease); registryLock.unlock()
        if let old, old.lease !== lease { stopReceiving(old.lease) }
        queue.async {
            guard lease.isActive else { sink.discard(); return }
            self.receiving?.sink.discard()
            self.receiving = Receiving(assembler: FileAssembler(transfer: transfer, expectedBytes: bytes), sink: sink, lease: lease)
            self.emit(.receiverReady(transfer), lease: lease)
        }
    }
    /// `settled` runs on the disk queue, after any admitted write/commit and cleanup.
    func stopReceiving(_ lease: TransferEffectLease, settled: (() -> Void)? = nil) {
        registryLock.lock(); if incomingAdmission?.lease === lease { incomingAdmission = nil }; registryLock.unlock()
        if usesReceiveBudget { lease.closeAdmission() } else { lease.retire() }
        queue.async {
            if self.usesReceiveBudget { lease.retire() }
            if let receiving = self.receiving, receiving.lease === lease {
                self.receiving = nil; receiving.sink.discard()
            }
            settled?()
        }
    }
    func discardUnadmittedSink(_ sink: FileByteSink) {
        if usesReceiveBudget { queue.async { sink.discard() } } else { sink.discard() }
    }
    private func currentIncoming() -> TransferEffectLease? {
        registryLock.lock(); defer { registryLock.unlock() }; return incomingAdmission?.lease
    }
    private func reserveReceiving(bytes: Int) -> TransferEffectLease? {
        guard usesReceiveBudget else { return currentIncoming() }
        registryLock.lock()
        guard let admission = incomingAdmission else { registryLock.unlock(); return nil }
        guard bytes <= maximumPendingReceiveBytes - reservedReceiveBytes,
              reservedReceiveChunks < maximumPendingReceiveChunks else {
            incomingAdmission = nil; registryLock.unlock()
            admission.lease.closeAdmission()
            events?(Delivery(event: .receiveOverflow(admission.transfer), lease: admission.lease))
            return nil
        }
        reservedReceiveBytes += bytes; reservedReceiveChunks += 1
        registryLock.unlock(); return admission.lease
    }
    private func releaseReceiving(bytes: Int) {
        guard usesReceiveBudget else { return }
        registryLock.lock(); defer { registryLock.unlock() }
        reservedReceiveBytes -= bytes; reservedReceiveChunks -= 1
    }
    func receive(_ data: Data) {
        guard let lease = reserveReceiving(bytes: data.count) else { return }
        queue.async {
            // Keep reservations across retirement/replacement until the captured Data is released.
            defer { self.releaseReceiving(bytes: data.count) }
            guard lease.isActive, var receiving = self.receiving, receiving.lease === lease else { return }
            guard let chunk = FileChunk.decode(data) else { self.settle(receiving, .invalid); return }
            guard chunk.transfer == receiving.assembler.transfer else { return }
            let outcome = receiving.assembler.accept(chunk)
            if outcome != .failed {
                do { guard try lease.performIfActive({ try receiving.sink.write(chunk.payload) }) != nil else { return } }
                catch { self.settle(receiving, FolderFileSink.status(for: error)); return }
            }
            self.receiving = receiving; self.apply(outcome, receiving)
        }
    }
    func receiveDigest(transfer: String, digest: String) {
        // Control ingress can drain on main while storage remains stalled; digest closures
        // therefore share the same count/byte budget as chunks, before their disk-queue hop.
        let bytes = digest.utf8.count
        guard let lease = reserveReceiving(bytes: bytes) else { return }
        queue.async {
            defer { self.releaseReceiving(bytes: bytes) }
            guard lease.isActive, var receiving = self.receiving, receiving.lease === lease, receiving.assembler.transfer == transfer else { return }
            let outcome = receiving.assembler.receiveDigest(digest)
            self.receiving = receiving; self.apply(outcome, receiving)
        }
    }
    private func apply(_ outcome: FileAssembler.Outcome, _ receiving: Receiving) {
        let transfer = receiving.assembler.transfer, lease = receiving.lease
        switch outcome {
        case .progress(let bytes):
            let now = ProcessInfo.processInfo.systemUptime
            if now - receiving.lastReport >= FileTransferLimits.progressInterval / 2 {
                self.receiving?.lastReport = now; emit(.received(transfer, bytes), lease: lease)
            }
        case .awaitingDigest: emit(.received(transfer, receiving.assembler.receivedBytes), lease: lease)
        case .verified:
            emit(.received(transfer, receiving.assembler.receivedBytes), lease: lease)
            do {
                guard let url = try lease.performIfActive({ try receiving.sink.commit() }) else { return }
                // An admitted commit may finish after closeAdmission. Keep its sink owned until
                // queued retirement performs cleanup and reports settlement in that case.
                if !usesReceiveBudget || lease.isActive { self.receiving = nil }
                emit(.receivedFile(transfer, .stored, url), lease: lease)
            } catch { settle(receiving, FolderFileSink.status(for: error)) }
        case .failed: settle(receiving, .invalid)
        }
    }
    private func settle(_ receiving: Receiving, _ status: FileTransferStatus) {
        receiving.sink.discard(); self.receiving = nil
        emit(.receivedFile(receiving.assembler.transfer, status, nil), lease: receiving.lease)
    }
}
