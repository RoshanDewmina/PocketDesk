import Foundation
import WebRTC

/// The `backdrop.1` channel. The Mac opens it at session start only for a phone that asked (its data
/// channels need no renegotiation once `control` exists); the phone adopts it only when it asked, and
/// otherwise closes it like any unknown label. Unordered but reliable: an idle screen sends one
/// snapshot and nothing after it, so a lost one would never be replaced. Newest wins at both ends.
final class BackdropLink {
    static let label = "backdrop.1"
    static let maximumBufferedBytes = UInt64(BackdropSnapshot.maximumMessageBytes)

    static var configuration: RTCDataChannelConfiguration {
        let config = RTCDataChannelConfiguration(); config.isOrdered = false
        return config
    }

    enum Readiness: Equatable { case waiting, ready, closed }

    /// Phone: the newest decoded snapshot, on the main queue.
    var onImage: ((BackdropImage) -> Void)?
    var sent: Int { lock.withLock { sentCount } }
    private var sentCount = 0
    private var lastSequence: UInt32 = 0

    private let lock = NSLock()
    private var channel: RTCDataChannel?
    private var ended = false
    private var pending: Data?
    private var draining = false
    private var newestSequence: UInt32?
    private let decodeQueue = DispatchQueue(label: "farside.backdrop.decode", qos: .utility)

    /// Host: takes the channel it created.
    @discardableResult
    func attach(_ created: RTCDataChannel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, channel == nil else { return false }
        channel = created
        return true
    }

    /// Phone: adopts the Mac's channel synchronously, so no early snapshot finds it unowned.
    func adopt(_ offered: RTCDataChannel) -> Bool {
        guard offered.label == Self.label, !offered.isOrdered else { return false }
        return attach(offered)
    }

    func owns(_ candidate: RTCDataChannel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return channel === candidate
    }

    /// Host: false while the channel is not open or the previous snapshot is still queued.
    func send(_ message: Data) -> Bool {
        guard message.count <= BackdropSnapshot.maximumMessageBytes else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !ended, let channel, channel.readyState == .open,
              channel.bufferedAmount + UInt64(message.count) <= Self.maximumBufferedBytes,
              channel.sendData(RTCDataBuffer(data: message, isBinary: true)) else { return false }
        sentCount += 1
        return true
    }

    /// Host: one counter per peer, so a capture restart never sends numbers the phone already passed.
    func nextSequence() -> UInt32 {
        lock.withLock { lastSequence &+= 1; return lastSequence }
    }

    /// Host: whether a snapshot could go now; `closed` once the phone refused or the session ended.
    var readiness: Readiness {
        lock.lock(); defer { lock.unlock() }
        guard !ended, let channel else { return .closed }
        switch channel.readyState {
        case .open: return channel.bufferedAmount < Self.maximumBufferedBytes / 2 ? .ready : .waiting
        case .connecting: return .waiting
        default: return .closed
        }
    }

    /// Phone, on WebRTC's thread: keeps only the newest message and decodes off the main queue.
    /// `admitted` is re-checked on the main queue before delivery.
    func receive(_ message: Data, admitted: @escaping () -> Bool = { true }) {
        guard message.count <= BackdropSnapshot.maximumMessageBytes else { return }
        lock.lock()
        guard !ended else { lock.unlock(); return }
        pending = message
        let start = !draining
        draining = true
        lock.unlock()
        if start { decodeQueue.async { [weak self] in self?.drain(admitted: admitted) } }
    }

    private func drain(admitted: @escaping () -> Bool) {
        while true {
            lock.lock()
            guard !ended, let message = pending else { draining = false; lock.unlock(); return }
            pending = nil
            let newest = newestSequence
            lock.unlock()
            guard let snapshot = BackdropSnapshot.decode(message), newest.map({ snapshot.sequence > $0 }) ?? true,
                  let image = BackdropSnapshot.decodeImage(snapshot.image) else { continue }
            lock.lock()
            guard !ended, newestSequence.map({ snapshot.sequence > $0 }) ?? true else { lock.unlock(); continue }
            newestSequence = snapshot.sequence
            lock.unlock()
            let decoded = BackdropImage(image: image, sequence: snapshot.sequence, displaySize: snapshot.displaySize)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isEnded, admitted() else { return }
                self.onImage?(decoded)
            }
        }
    }

    private var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    /// Retires the link; the caller detaches and closes the returned channel.
    func end() -> RTCDataChannel? {
        lock.lock(); defer { lock.unlock() }
        ended = true; pending = nil
        let retired = channel; channel = nil
        return retired
    }
}
