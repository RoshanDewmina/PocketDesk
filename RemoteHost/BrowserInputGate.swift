import Foundation

/// The token exists only in the encoded pixels. A status packet cannot renew it.
final class BrowserInputGate {
    private struct Frame { let token: String; let revision: UInt64; let time: Double; let ordinal: UInt64 }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var ordinal: UInt64 = 0
    private var lastFrame: UInt64 = 0
    private var lastInput: UInt64 = 0
    private var session = ""
    private var revision: UInt64 = 1
    var maximumAge: Double = 0.6

    func begin(session: String, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.session = session; self.revision = revision; frames.removeAll(); ordinal = 0; lastFrame = 0; lastInput = 0
    }
    func invalidateFrames() { lock.lock(); defer { lock.unlock() }; frames.removeAll() }
    func record(token: String, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !session.isEmpty, Self.validToken(token), time.isFinite else { return }
        ordinal += 1; frames.append(Frame(token: token, revision: revision, time: time, ordinal: ordinal))
        if frames.count > 128 { frames.removeFirst(frames.count - 128) }
    }
    static func validToken(_ value: String) -> Bool { value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    func accept(_ data: Data, at time: Double, healthy: Bool, control: Bool) throws -> RemoteAction {
        struct Packet: Decodable { var type: String; var session: String; var sequence: String; var revision: String; var frameToken: String; var action: RemoteAction }
        guard data.count <= 16384 else { throw RemoteError.invalidMessage }
        let packet = try JSONDecoder().decode(Packet.self, from: data)
        try packet.action.validate()
        lock.lock(); defer { lock.unlock() }
        guard packet.type == "input", !session.isEmpty, packet.session == session,
              let sequence = UInt64(packet.sequence), String(sequence) == packet.sequence, sequence > lastInput, sequence <= 9007199254740991 else { throw RemoteError.stale }
        lastInput = sequence
        if packet.action.action == "release" { return packet.action }
        guard ["move", "click", "right", "double", "dragDown", "dragUp", "scroll", "text", "key"].contains(packet.action.action),
              packet.revision == String(revision), packet.action.epoch == revision, healthy, control,
              let frame = frames.last(where: { $0.token == packet.frameToken }), frame.revision == revision,
              time.isFinite, time >= frame.time, time - frame.time <= maximumAge, frame.ordinal >= lastFrame else { throw RemoteError.stale }
        lastFrame = frame.ordinal
        return packet.action
    }
}
