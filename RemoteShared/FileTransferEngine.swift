import Foundation
import CryptoKit

extension FileTransferStatus: Error {}

/// The `file` data channel as the transfer engine sees it. Called from the engine's I/O queue.
protocol FileChannelLink: AnyObject {
    func sendFile(_ data: Data) -> Bool
    var fileBufferedAmount: UInt64? { get }
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
    private let io = FileTransferIO()
    private var outgoingSource: FileByteSource?
    private var outgoingActivity: TimeInterval = 0
    private var incomingActivity: TimeInterval = 0
    private var requestSince: TimeInterval = 0
    private var progressThrottle = FileProgressThrottle()
    private var watchdog: Timer?

    init(acceptsUnsolicitedOffers: Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
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
        guard sendControl?(.offer(id, name: wireName, bytes: source.byteCount, type: wireType)) == true else {
            source.close()
            return .failure(.connectionLost)
        }
        outgoingSource = source
        outgoing = FileTransferSnapshot(transfer: id, direction: .outgoing, name: wireName, total: source.byteCount,
                                        bytes: 0, phase: .waiting)
        outgoingActivity = clock()
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
    func answerRequest(_ transfer: String, _ status: FileTransferStatus) {
        _ = sendControl?(.result(transfer, status))
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
                  let source = outgoingSource else { return }
            guard let channel = link?() else {
                finishOutgoing(current.transfer, .connectionLost, notify: .cancel)
                return
            }
            current.phase = .transferring
            outgoing = current
            outgoingActivity = now
            let relayed = isRelayed()
            io.beginSending(transfer: current.transfer, source: source, link: channel,
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
                finishOutgoing(frame.transfer, status, notify: .none)
            } else if pendingRequest == frame.transfer {
                finishRequest(frame.transfer, status, notify: false)
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
            startWatchdog()
            onChange?()
            admit(offer) { [weak self] result in self?.admitted(offer, result) }
        } else {
            refuse(offer, .unsupported, solicited: solicited)
        }
    }

    private func admitted(_ offer: FileTransferOffer, _ result: Result<FileByteSink, FileTransferStatus>) {
        guard var current = incoming, current.transfer == offer.transfer, current.phase == .waiting else {
            if case .success(let sink) = result { sink.discard() }
            return
        }
        switch result {
        case .success(let sink):
            current.phase = .transferring
            incoming = current
            incomingActivity = clock()
            onChange?()
            io.beginReceiving(transfer: offer.transfer, bytes: offer.bytes, sink: sink)
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

    private func handle(_ event: FileTransferIO.Event) {
        let now = clock()
        switch event {
        case .receiverReady(let transfer):
            guard incoming?.transfer == transfer else { return }
            if sendControl?(.accept(transfer)) != true {
                finishIncoming(transfer, .connectionLost, url: nil, notify: .none)
            }
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
            if sendControl?(.complete(transfer, digest: digest)) != true {
                finishOutgoing(transfer, .connectionLost, notify: .none)
                return
            }
            onChange?()
        case .sendFailed(let transfer, let status):
            guard outgoing?.transfer == transfer else { return }
            finishOutgoing(transfer, status, notify: .cancel)
        }
    }

    // MARK: Finishing

    private enum Notice { case none, cancel, result }

    private func finishOutgoing(_ transfer: String, _ status: FileTransferStatus, notify: Notice) {
        guard let current = outgoing, current.transfer == transfer else { return }
        outgoing = nil
        io.stopSending(transfer: transfer)
        outgoingSource?.close()
        outgoingSource = nil
        if notify == .cancel { _ = sendControl?(.cancel(transfer)) }
        stopWatchdogIfIdle()
        onFinish?(FileTransferFinish(transfer: transfer, direction: .outgoing, name: current.name, status: status, savedURL: nil))
        onChange?()
    }

    private func finishIncoming(_ transfer: String, _ status: FileTransferStatus, url: URL?, notify: Notice) {
        guard let current = incoming, current.transfer == transfer else { return }
        incoming = nil
        if status != .stored { io.stopReceiving(transfer: transfer) }
        switch notify {
        case .none: break
        case .cancel: _ = sendControl?(.cancel(transfer))
        case .result: _ = sendControl?(.result(transfer, status))
        }
        stopWatchdogIfIdle()
        onFinish?(FileTransferFinish(transfer: transfer, direction: .incoming, name: current.name, status: status, savedURL: url))
        onChange?()
    }

    private func finishRequest(_ transfer: String, _ status: FileTransferStatus, notify: Bool) {
        guard pendingRequest == transfer else { return }
        pendingRequest = nil
        if notify { _ = sendControl?(.cancel(transfer)) }
        stopWatchdogIfIdle()
        onFinish?(FileTransferFinish(transfer: transfer, direction: .incoming, name: nil, status: status, savedURL: nil))
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

/// Everything that touches file bytes. Confined to `queue`; reports back through `events`.
final class FileTransferIO: @unchecked Sendable {
    enum Event {
        case receiverReady(String)
        case received(String, Int64)
        case receivedFile(String, FileTransferStatus, URL?)
        case sent(String, String)
        case sendFailed(String, FileTransferStatus)
    }

    private final class Sending {
        let transfer: String
        let source: FileByteSource
        let link: FileChannelLink
        let chunk: Int
        let highWater: UInt64
        var pacer: FilePacer
        var hasher = SHA256()
        var sent: Int64 = 0
        var pumpScheduled = false

        init(transfer: String, source: FileByteSource, link: FileChannelLink, chunk: Int, highWater: UInt64, pacer: FilePacer) {
            self.transfer = transfer
            self.source = source
            self.link = link
            self.chunk = chunk
            self.highWater = highWater
            self.pacer = pacer
        }
    }

    private struct Receiving {
        var assembler: FileAssembler
        let sink: FileByteSink
        var lastReport: TimeInterval = 0
    }

    let queue = DispatchQueue(label: "Farside.file-transfer", qos: .utility)
    var events: ((Event) -> Void)?
    private var sending: Sending?
    private var receiving: Receiving?
    private static let chunksPerTurn = 64

    func beginSending(transfer: String, source: FileByteSource, link: FileChannelLink, chunk: Int, highWater: UInt64,
                      pacer: FilePacer) {
        queue.async {
            self.sending = Sending(transfer: transfer, source: source, link: link, chunk: chunk, highWater: highWater, pacer: pacer)
            self.pump()
        }
    }

    func stopSending(transfer: String) {
        queue.async {
            guard self.sending?.transfer == transfer else { return }
            self.sending = nil
        }
    }

    func wake() {
        queue.async { self.pump() }
    }

    private func pump() {
        guard let sending else { return }
        sending.pumpScheduled = false
        let total = sending.source.byteCount
        var turns = 0
        while sending.sent < total {
            guard let buffered = sending.link.fileBufferedAmount else { fail(sending, .connectionLost); return }
            if buffered >= sending.highWater { schedule(sending, after: 0.005); return }
            let size = Int(min(Int64(sending.chunk), total - sending.sent))
            guard sending.pacer.allows(size, at: ProcessInfo.processInfo.systemUptime) else {
                schedule(sending, after: 0.01)
                return
            }
            let payload: Data
            do { payload = try sending.source.read(upTo: size) } catch { fail(sending, .unreadable); return }
            guard payload.count == size,
                  let message = FileChunk.encode(transfer: sending.transfer, offset: sending.sent, payload: payload)
            else { fail(sending, .unreadable); return }
            guard sending.link.sendFile(message) else { fail(sending, .connectionLost); return }
            sending.hasher.update(data: payload)
            sending.sent += Int64(size)
            turns += 1
            if turns >= Self.chunksPerTurn, sending.sent < total { schedule(sending, after: 0); return }
        }
        self.sending = nil
        events?(.sent(sending.transfer, FileDigest.hex(sending.hasher.finalize())))
    }

    private func schedule(_ sending: Sending, after delay: TimeInterval) {
        guard !sending.pumpScheduled else { return }
        sending.pumpScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak sending] in
            guard let sending, self.sending === sending else { return }
            self.pump()
        }
    }

    private func fail(_ sending: Sending, _ status: FileTransferStatus) {
        self.sending = nil
        events?(.sendFailed(sending.transfer, status))
    }

    func beginReceiving(transfer: String, bytes: Int64, sink: FileByteSink) {
        queue.async {
            self.receiving?.sink.discard()
            self.receiving = Receiving(assembler: FileAssembler(transfer: transfer, expectedBytes: bytes), sink: sink)
            self.events?(.receiverReady(transfer))
        }
    }

    func stopReceiving(transfer: String) {
        queue.async {
            guard let receiving = self.receiving, receiving.assembler.transfer == transfer else { return }
            receiving.sink.discard()
            self.receiving = nil
        }
    }

    func receive(_ data: Data) {
        queue.async {
            guard var receiving = self.receiving else { return }
            guard let chunk = FileChunk.decode(data) else { self.settle(receiving, .invalid); return }
            guard chunk.transfer == receiving.assembler.transfer else { return }
            let outcome = receiving.assembler.accept(chunk)
            if outcome != .failed {
                do { try receiving.sink.write(chunk.payload) } catch {
                    self.settle(receiving, FolderFileSink.status(for: error))
                    return
                }
            }
            self.receiving = receiving
            self.apply(outcome, receiving)
        }
    }

    func receiveDigest(transfer: String, digest: String) {
        queue.async {
            guard var receiving = self.receiving, receiving.assembler.transfer == transfer else { return }
            let outcome = receiving.assembler.receiveDigest(digest)
            self.receiving = receiving
            self.apply(outcome, receiving)
        }
    }

    private func apply(_ outcome: FileAssembler.Outcome, _ receiving: Receiving) {
        let transfer = receiving.assembler.transfer
        switch outcome {
        case .progress(let bytes):
            let now = ProcessInfo.processInfo.systemUptime
            if now - receiving.lastReport >= FileTransferLimits.progressInterval / 2 {
                self.receiving?.lastReport = now
                events?(.received(transfer, bytes))
            }
        case .awaitingDigest:
            events?(.received(transfer, receiving.assembler.receivedBytes))
        case .verified:
            events?(.received(transfer, receiving.assembler.receivedBytes))
            self.receiving = nil
            do {
                let url = try receiving.sink.commit()
                events?(.receivedFile(transfer, .stored, url))
            } catch {
                events?(.receivedFile(transfer, FolderFileSink.status(for: error), nil))
            }
        case .failed:
            settle(receiving, .invalid)
        }
    }

    private func settle(_ receiving: Receiving, _ status: FileTransferStatus) {
        receiving.sink.discard()
        self.receiving = nil
        events?(.receivedFile(receiving.assembler.transfer, status, nil))
    }
}
