import AppKit
import CryptoKit
import CoreVideo

struct HostGuestContext: Equatable {
    let room: String
    let hostID: String
    let origin: String
    let ownerSessionID: String
    let scopeEpoch: String
    let geometryEpoch: String
    let scopeKind: String
    let deadline: Date
}

/// Main-thread consent and signaling. Capture obtains only retained peers under the separate fanout lock.
@MainActor
final class HostGuestController {
    private final class Entry {
        let context: HostGuestContext, secret: String, signing = P256.Signing.PrivateKey()
        let id: String
        var expires: Int64
        var monotonicDeadline: TimeInterval
        var created = false
        var request: GuestRelayFrame?
        var agreement: P256.KeyAgreement.PrivateKey?
        var grant: GuestGrant?
        var key: SymmetricKey?
        var sessionID: String?
        var peer: GuestMediaPeer?
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var transport: GuestTransportObservation?
        var serviceDeadline: TimeInterval = 0
        var proofNonce: String?
        var handshakeDeadline: TimeInterval?
        init(context: HostGuestContext, id: String, secret: String, expires: Int64, now: TimeInterval) {
            self.context = context; self.id = id; self.secret = secret; self.expires = expires
            monotonicDeadline = now + max(0, min(120, Double(expires) / 1000 - Date().timeIntervalSince1970))
        }
    }
    nonisolated final class Fanout: @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [GuestMediaPeer] = []
        func replace(_ next: [GuestMediaPeer]) { lock.lock(); peers = next; lock.unlock() }
        func fence() {
            lock.lock(); let snapshot = peers; lock.unlock()
            for peer in snapshot { peer.lease.close() }
        }
        func deliver(_ buffer: CVPixelBuffer, at now: Double) {
            lock.lock(); let snapshot = peers; lock.unlock()
            for peer in snapshot { peer.pushFrame(buffer, at: now) }
        }
    }
    private let clock: () -> TimeInterval
    private let makePeer: ([ICEServerConfiguration], GuestCaptureLease) -> GuestMediaPeer
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makePeer: @escaping ([ICEServerConfiguration], GuestCaptureLease) -> GuestMediaPeer = { GuestMediaPeer(servers: $0, lease: $1) }) {
        self.clock = clock; self.makePeer = makePeer
    }
    nonisolated let fanout = Fanout()
    var context: () -> HostGuestContext? = { nil }
    var send: (GuestRelayFrame) -> Bool = { _ in false }
    var ownerPeer: () -> PeerMedia? = { nil }
    var changed: () -> Void = {}
    private var entries: [String: Entry] = [:]
    private weak var observedPeer: PeerMedia?
    private var ownerTransport: GuestTransportObservation?
    private var timer: Timer?
    private var samplingTick = 0
    private(set) var message: String?
    var available: Bool { context() != nil && entries.count < 2 }
    var rows: [HostGuestRow] {
        entries.values.sorted { $0.id < $1.id }.map { entry in
            let publicKey = entry.request?.publicKey ?? entry.signing.publicKey.x963Representation.base64EncodedString()
            let fingerprint = GuestCrypto.hash(Data(base64Encoded: publicKey) ?? Data())
            return HostGuestRow(id: entry.id, fingerprint: fingerprint, status: entry.peer != nil ? "Viewing · video only" : entry.grant != nil ? "Approved · connecting" : entry.request != nil ? "Recipient requests viewing" : "Link expires in two minutes",
                pending: entry.request != nil && entry.grant == nil, linkReady: entry.created && entry.request == nil,
                remainingSeconds: max(0, Int(ceil(min(entry.monotonicDeadline-clock(), Double(entry.expires)/1000-Date().timeIntervalSince1970)))))
        }
    }
    deinit { timer?.invalidate() }
    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAuthority() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func create() {
        guard available, let context = context(), GuestValidation.origin(context.origin) else { message = "Guest viewing requires a live paid remote session."; changed(); return }
        do {
            let id = try SecureRandom.token(), secret = try SecureRandom.token()
            let expires = min(Self.milliseconds(Date().addingTimeInterval(120)), Self.milliseconds(context.deadline))
            let entry = Entry(context: context, id: id, secret: secret, expires: expires, now: clock())
            entries[id] = entry
            guard send(GuestRelayFrame(operation: "invite", grantID: id, inviteHash: GuestCrypto.hash(Data(secret.utf8)),
                publicKey: entry.signing.publicKey.x963Representation.base64EncodedString(), hostID: context.hostID,
                ownerSessionID: context.ownerSessionID, scopeEpoch: context.scopeEpoch, geometryEpoch: context.geometryEpoch,
                scopeKind: context.scopeKind, origin: context.origin, mode: "view", expiresAt: expires)) else {
                end(id, notify: false); throw GuestValidation.Failure.closed
            }
            message = "Copy the guest link, then verify the recipient's full key fingerprint before approving."
        } catch { message = "Guest link could not be created." }
        changed()
    }
    func copyLink(_ id: String) {
        guard let entry = entries[id], live(entry), entry.created, entry.request == nil else { return }
        do {
            let link = GuestInviteLink(version: 1, room: entry.context.room, grantID: id, secret: entry.secret,
                publicKey: entry.signing.publicKey.x963Representation.base64EncodedString(), expiresAt: entry.expires)
            let url = try link.url(origin: entry.context.origin)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
            message = "Guest link copied. Each recipient still needs your approval."; changed()
        } catch { end(id) }
    }
    func approve(_ id: String) {
        guard let entry = entries[id], live(entry), entry.grant == nil, let request = entry.request,
              let requestID = request.requestID, let publicKey = request.publicKey,
              let agreementKey = request.agreementKey, let nonce = request.nonce else { return }
        do {
            let agreement = P256.KeyAgreement.PrivateKey(), ticket = try SecureRandom.token(), hostNonce = try SecureRandom.token()
            let now = Self.milliseconds(Date())
            let grant = GuestGrant(hostID: entry.context.hostID, grantID: id, ownerSessionID: entry.context.ownerSessionID,
                scopeEpoch: entry.context.scopeEpoch, geometryEpoch: entry.context.geometryEpoch, scopeKind: entry.context.scopeKind,
                requestID: requestID, recipientPublicKey: publicKey, recipientAgreementKey: agreementKey,
                hostAgreementKey: agreement.publicKey.x963Representation.base64EncodedString(), recipientNonce: nonce,
                hostNonce: hostNonce, origin: entry.context.origin, issuedAt: now,
                expiresAt: min(now + 600_000, Self.milliseconds(entry.context.deadline)), ticketHash: GuestCrypto.hash(Data(ticket.utf8)))
            try grant.validate(at: now)
            entry.agreement = agreement; entry.grant = grant; entry.expires = grant.expiresAt
            entry.monotonicDeadline = clock() + Double(grant.expiresAt - now) / 1000
            entry.handshakeDeadline = clock() + 30
            entry.sessionID = GuestCrypto.hash(GuestCrypto.canonical(grant.signedFields))
            entry.key = try GuestCrypto.sharedKey(privateKey: agreement, publicKey: agreementKey, grant: grant)
            let signature = try GuestCrypto.sign(grant.signedFields, key: entry.signing)
            guard send(GuestRelayFrame(operation: "approve", grantID: id, requestID: requestID, signature: signature, grant: grant, ticket: ticket)) else { throw GuestValidation.Failure.closed }
            changed()
        } catch { end(id) }
    }
    func end(_ id: String, notify: Bool = true) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        // Terminal media fence before detaching refs or waiting on signaling/provider revocation.
        entry.peer?.close(); fanout.replace(entries.values.compactMap(\.peer))
        if notify { _ = send(GuestRelayFrame(operation: "revoke", grantID: id)) }
        updateBudget(); changed()
    }
    func endAll() {
        for id in Array(entries.keys) { end(id) }
        ownerTransport = nil
    }
    private func live(_ entry: Entry) -> Bool {
        entries[entry.id] === entry && context() == entry.context && entry.expires > Self.milliseconds(Date()) && clock() < min(entry.monotonicDeadline, entry.handshakeDeadline ?? .infinity)
    }
    func receive(_ frame: GuestRelayFrame) {
        if frame.operation == "serviceReset" {
            guard frame.hasOnlyFields(["operation", "code", "nonce"]), let nonce = frame.nonce, GuestValidation.token(nonce), frame.code != nil else { return }
            // Coordinator binds route epoch + current signaling generation and rejects nonce replay.
            endAll(); message = "Guest service restarted. Create a fresh link and approve each recipient again."; changed(); return
        }
        guard let id = frame.grantID, let entry = entries[id], live(entry) else { return }
        switch frame.operation {
        case "created":
            guard let expires = frame.expiresAt, expires <= entry.expires, expires > Self.milliseconds(Date()) else { end(id); return }
            entry.expires = expires
            entry.monotonicDeadline = min(entry.monotonicDeadline, clock() + Double(expires - Self.milliseconds(Date())) / 1000)
            entry.created = true; changed()
        case "pending":
            guard entry.created, entry.request == nil, entry.grant == nil,
                  let requestID = frame.requestID, GuestValidation.token(requestID), let key = frame.publicKey,
                  let agreement = frame.agreementKey, GuestValidation.publicKey(agreement), let nonce = frame.nonce,
                  GuestValidation.token(nonce), let signature = frame.signature,
                  GuestCrypto.verify(["request", entry.context.origin, entry.context.room, id, key, agreement, nonce], signature: signature, publicKey: key)
            else { end(id); return }
            entry.request = frame; changed()
        case "ready":
            guard frame.sessionID == entry.sessionID, let grant = entry.grant, frame.expiresAt == grant.expiresAt,
                  entry.peer == nil, let servers = frame.servers, !servers.isEmpty, servers.count <= 8,
                  servers.allSatisfy({ !$0.urls.isEmpty && $0.urls.count <= 8 && $0.urls.allSatisfy { $0.utf8.count <= 2048 && ($0.hasPrefix("stun:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:")) } }) else { end(id); return }
            let lease = GuestCaptureLease(grantID: id, ownerSessionID: grant.ownerSessionID, scopeEpoch: grant.scopeEpoch,
                geometryEpoch: grant.geometryEpoch, expiresAt: entry.monotonicDeadline, clock: clock)
            let peer = makePeer(servers, lease)
            entry.handshakeDeadline = nil
            entry.serviceDeadline = clock() + 2
            entry.peer = peer
            peer.onSignal = { [weak self, weak entry] signal in guard let self, let entry, self.live(entry) else { return }; self.signal(signal, entry: entry) }
            peer.onEnded = { [weak self] in self?.end(id) }
            fanout.replace(entries.values.compactMap(\.peer)); updateBudget(); peer.offer(); changed()
        case "alive":
            guard frame.hasOnlyFields(["operation", "grantID", "sessionID", "nonce", "expiresAt"]),
                  frame.sessionID == entry.sessionID, frame.expiresAt == entry.grant?.expiresAt,
                  frame.nonce != nil, frame.nonce == entry.proofNonce,
                  clock() < entry.serviceDeadline else { return }
            entry.proofNonce = nil; entry.serviceDeadline = clock() + 2
            updateBudget()
        case "signal":
            guard frame.sessionID == entry.sessionID, let session = entry.sessionID, let key = entry.key,
                  let envelope = frame.envelope, let sequence = UInt64(envelope.sequence), sequence > entry.received,
                  let bytes = try? GuestCrypto.open(envelope, key: key, grantID: id, sessionID: session, direction: "guest"),
                  let signal = try? JSONDecoder().decode(MediaSignal.self, from: bytes), let peer = entry.peer else { end(id); return }
            entry.received = sequence; peer.receive(signal)
        case "ended": end(id, notify: false)
        default: end(id)
        }
    }
    private func signal(_ signal: MediaSignal, entry: Entry) {
        do {
            guard let session = entry.sessionID, let key = entry.key, entry.sent < GuestCrypto.maximumSequence else { throw GuestValidation.Failure.closed }
            entry.sent += 1
            let envelope = try GuestCrypto.seal(JSONEncoder().encode(signal), key: key, grantID: entry.id,
                sessionID: session, direction: "host", sequence: entry.sent)
            guard send(GuestRelayFrame(operation: "signal", grantID: entry.id, sessionID: session, envelope: envelope)) else { throw GuestValidation.Failure.closed }
        } catch { end(entry.id) }
    }
    func refreshAuthority() {
        let now = clock()
        for entry in Array(entries.values) where !live(entry) || (entry.peer != nil && now >= entry.serviceDeadline) { end(entry.id) }
        if let peer = ownerPeer(), observedPeer !== peer {
            observedPeer?.onGuestTransportStatistics = nil; observedPeer = peer; ownerTransport = nil
            peer.onGuestTransportStatistics = { [weak self, weak peer] stats in
                guard let self, let peer, self.ownerPeer() === peer else { return }; self.ownerTransport = stats; self.updateBudget()
            }
        }
        samplingTick += 1
        if samplingTick % 4 == 0 {
            if !entries.isEmpty { changed() }
            for entry in Array(entries.values) {
                if entry.peer != nil, entry.proofNonce == nil, let session = entry.sessionID {
                    guard let nonce = try? SecureRandom.token() else { end(entry.id); continue }
                    entry.proofNonce = nonce
                    guard send(GuestRelayFrame(operation: "check", grantID: entry.id, nonce: nonce, sessionID: session)) else { end(entry.id); continue }
                }
                entry.peer?.sampleTransport { [weak self, weak entry] stats in
                    guard let self, let entry, self.live(entry) else { return }; entry.transport = stats; self.updateBudget()
                }
            }
        }
        updateBudget()
    }
    private func updateBudget() {
        let now = clock(), active = entries.values.filter { $0.peer != nil }
        let rates = active.compactMap { entry -> (String, Double)? in
            guard let stats = entry.transport, now >= stats.at, now - stats.at < 2, let rate = stats.totalKbps else { return nil }
            return (entry.id, rate)
        }
        let allKnown = rates.count == active.count
        ownerPeer()?.observeReplicatedGuestLoad(count: active.count, kbps: allKnown ? rates.reduce(0) { $0 + $1.1 } : nil, at: now)
        guard let owner = ownerTransport, let total = owner.totalKbps, allKnown else { for entry in active { entry.peer?.lease.pause() }; return }
        let observation = GuestBudgetObservation(at: owner.at, capacityKbps: owner.capacityKbps, ownerMediaKbps: total,
            fileKbps: 0, fecKbps: 0, guestKbps: Dictionary(uniqueKeysWithValues: rates), controlBufferedBytes: owner.controlBufferedBytes,
            rttMs: owner.rttMs, baselineRTTMs: owner.baselineRTTMs, pacerDelayMs: owner.pacerDelayMs)
        for entry in active {
            let ownerCeiling = GuestBudgetPolicy.ceilingKbps(for: entry.id, observation: observation, at: now)
            if now < entry.serviceDeadline,
               let ceiling = GuestBudgetPolicy.boundedCeilingKbps(ownerCeiling: ownerCeiling, guest: entry.transport, at: now),
               let stats = entry.transport {
                // Separate paths may have separate bottlenecks; estimates are never added.
                entry.peer?.setCeiling(kbps: ceiling)
                entry.peer?.lease.permit(until: min(owner.at + 2, stats.at + 2, entry.serviceDeadline, now + 0.5))
            } else { entry.peer?.lease.pause() }
        }
    }
    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
