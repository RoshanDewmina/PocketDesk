import Foundation

/// Reliable independent channel; each encoded message (header included) fits the shared 16 KiB credit.
struct VideoRefinementChunk: Codable {
    let version: Int
    let id: String
    let identity: VideoRefinementIdentity
    let total: Int
    let offset: Int
    let body: Data
    let ack: Bool
    func validate() throws {
        try identity.validate()
        guard version == 1, InputCausalEnvelope.validID(id), total > 0, total <= VideoRefinementPNG.maximumBytes,
              offset >= 0, offset <= total, body.count <= 9000,
              ack ? body.isEmpty : (!body.isEmpty && body.count <= total - offset) else { throw RemoteError.invalidMessage }
    }
}

/// One sender and one assembly, one chunk outstanding, bounded lifetime. Call only on its owner queue.
final class VideoRefinementChannel {
    private struct Outgoing { let id: String; let image: VideoRefinementImage; let started: Double; var offset = 0; var awaiting: Int? }
    private struct Incoming { let id: String; let identity: VideoRefinementIdentity; let total: Int; let started: Double; var data = Data() }
    private var outgoing: Outgoing?
    private var incoming: Incoming?
    private var pendingAck: (Data, Double)?
    private var geometry: UInt64 = 0, scope: UInt64 = 0
    private var enabled = false, ended = false
    private var lastReceivedID: String?
    var send: ((Data, Bool) -> Bool)? // Bool marks an ACK; no independent image credit pool.
    var image: ((VideoRefinementImage) -> Void)?
    #if DEBUG
    var retainedIncomingBytesForTesting: Int { incoming?.data.count ?? 0 }
    #endif
    func configure(enabled: Bool, geometry: UInt64, scope: UInt64) {
        guard !ended else { return }
        if self.enabled != enabled || self.geometry != geometry || self.scope != scope {
            outgoing = nil; incoming = nil; pendingAck = nil; lastReceivedID = nil
        }
        self.enabled = enabled; self.geometry = geometry; self.scope = scope
    }
    func end() { ended = true; enabled = false; outgoing = nil; incoming = nil; pendingAck = nil; send = nil; image = nil }
    func offer(_ image: VideoRefinementImage, at now: Double) {
        guard enabled, !ended, now.isFinite, image.identity.geometryEpoch == geometry, image.identity.scopeEpoch == scope,
              (try? image.identity.validate()) != nil, !image.png.isEmpty, image.png.count <= VideoRefinementPNG.maximumBytes else { return }
        if let outgoing, now >= outgoing.started && now - outgoing.started <= 2 { return }
        outgoing = Outgoing(id: VideoFeedbackContext.id(), image: image, started: now)
        pump(at: now)
    }
    func pump(at now: Double) {
        guard enabled, !ended, now.isFinite else { return }
        if let incoming, now < incoming.started || now - incoming.started > 2 { self.incoming = nil }
        if let ack = pendingAck {
            if now < ack.1 || now - ack.1 > 2 { pendingAck = nil }
            else if send?(ack.0, true) == true { pendingAck = nil }
            else { return }
        }
        guard var next = outgoing else { return }
        guard now >= next.started, now - next.started <= 2 else { outgoing = nil; return }
        guard next.awaiting == nil, next.offset < next.image.png.count else { return }
        let end = min(next.offset + 9000, next.image.png.count)
        let packet = VideoRefinementChunk(version: 1, id: next.id, identity: next.image.identity,
            total: next.image.png.count, offset: next.offset, body: next.image.png.subdata(in: next.offset..<end), ack: false)
        guard let data = try? JSONEncoder().encode(packet), data.count <= BulkAdmissionPolicy.maximumMessageBytes else { outgoing = nil; return }
        // Install the outstanding boundary before send: fixture/loopback callbacks may be synchronous.
        next.awaiting = end; outgoing = next
        if send?(data, false) != true, outgoing?.id == next.id { outgoing?.awaiting = nil }
    }
    func receive(_ data: Data, at now: Double) {
        guard enabled, !ended, now.isFinite, data.count <= BulkAdmissionPolicy.maximumMessageBytes,
              let packet = try? JSONDecoder().decode(VideoRefinementChunk.self, from: data), (try? packet.validate()) != nil,
              packet.identity.geometryEpoch == geometry, packet.identity.scopeEpoch == scope else { return }
        if packet.ack {
            guard var next = outgoing, packet.id == next.id, packet.identity == next.image.identity,
                  packet.total == next.image.png.count, packet.offset == next.awaiting,
                  now >= next.started, now - next.started <= 2 else { return }
            next.offset = packet.offset; next.awaiting = nil
            outgoing = next.offset == next.image.png.count ? nil : next
            return // Timer/next owner turn sends; never recursive ACK drain.
        }
        guard pendingAck == nil else { return }
        if incoming == nil || incoming?.id != packet.id {
            guard packet.offset == 0, packet.id != lastReceivedID else { return }
            if let incoming, now >= incoming.started && now - incoming.started <= 2 { return }
            incoming = Incoming(id: packet.id, identity: packet.identity, total: packet.total, started: now)
        }
        guard var next = incoming, packet.id == next.id, packet.identity == next.identity, packet.total == next.total,
              packet.offset == next.data.count, now >= next.started, now - next.started <= 2 else { incoming = nil; return }
        next.data.append(packet.body)
        incoming = next
        let ack = VideoRefinementChunk(version: 1, id: next.id, identity: next.identity, total: next.total,
            offset: next.data.count, body: Data(), ack: true)
        if let ackData = try? JSONEncoder().encode(ack), ackData.count <= BulkAdmissionPolicy.maximumMessageBytes { pendingAck = (ackData, now); pump(at: now) }
        if next.data.count == next.total {
            lastReceivedID = next.id; incoming = nil
            image?(VideoRefinementImage(identity: next.identity, png: next.data))
        }
    }
}
