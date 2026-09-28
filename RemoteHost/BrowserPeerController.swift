import Combine
import CryptoKit
import Foundation

struct BrowserEnrollmentOffer: Codable, Equatable {
    var version = 1
    var url: String
    var hostID: String
    var hostKey: String
    var secret: String
    var expires: String
}

struct BrowserControlBind: Codable, Equatable {
    var type: String
    var session: String
    var challengeHash: String
}

struct BrowserEnrollmentProposal: Equatable {
    var peerID: String
    var publicKey: String

    static func open(
        body: [String: Any],
        secret: String,
        hostID: String,
        origin: String
    ) throws -> Self {
        guard body.count == 2,
              Set(body.keys) == Set(["nonce", "payload"]),
              let nonce = body["nonce"] as? String,
              let payload = body["payload"] as? String else {
            throw BrowserControllerError.invalidMessage
        }
        let plaintext = try BrowserCrypto.openEnrollment(
            secret: secret,
            hostID: hostID,
            origin: origin,
            nonce: nonce,
            payload: payload
        )
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              object.count == 2,
              Set(object.keys) == Set(["peerID", "publicKey"]),
              let peerID = object["peerID"] as? String,
              let publicKey = object["publicKey"] as? String,
              BrowserPeerValidation.isToken(peerID),
              BrowserPeerValidation.isPublicSigningKey(publicKey) else {
            throw BrowserControllerError.invalidMessage
        }
        return Self(peerID: peerID, publicKey: publicKey)
    }
}

struct BrowserPendingEnrollment: Equatable {
    var requestID: String
    var peerID: String
    var publicKey: String
    var expiresAt: Date

    func isLive(at date: Date) -> Bool { expiresAt > date }
    func matchesCancellation(_ requestID: String) -> Bool { self.requestID == requestID }
}

struct BrowserLeaseOwnership {
    private(set) var isOwned = false

    mutating func acquire(using canAcquire: () -> Bool) -> Bool {
        guard !isOwned, canAcquire() else { return false }
        isOwned = true
        return true
    }

    @discardableResult
    mutating func release(using release: () -> Void) -> Bool {
        guard isOwned else { return false }
        isOwned = false
        release()
        return true
    }
}

@MainActor
final class BrowserPeerController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Browser access is stopped"
    @Published private(set) var enrollmentCode = ""
    @Published private(set) var pendingApproval = false
    @Published private(set) var connected = false
    @Published private(set) var mode = "view"
    @Published private(set) var peer: PeerMedia?
    @Published private(set) var sessionID = ""
    @Published private(set) var revision: UInt64 = 0

    var onAuthenticated: ((_ peer: PeerMedia, _ mode: String) -> Void)?
    var onEnded: (() -> Void)?
    var onControl: ((Data) -> Void)?

    private struct EnrollmentState {
        var offer: BrowserEnrollmentOffer
        var expiresAt: Date
    }

    private struct PendingChallenge {
        var requestID: String
        var fields: [String]
        var session: String
        var mode: String
        var expiresAt: Date
        var ephemeralKey: P256.KeyAgreement.PrivateKey
    }

    private struct PendingTicket {
        var requestID: String
        var session: String
        var mode: String
        var challengeHash: String
        var key: SymmetricKey
        var expiresAt: Date
        var sessionExpiresAt: Date
    }

    private struct ActiveSession {
        var session: String
        var mode: String
        var challengeHash: String
        var key: SymmetricKey
        var expiresAt: Date
        var receivedSequence: UInt64 = 0
        var sentSequence: UInt64 = 0
        var receivedKeyConfirmation = false
        var mediaConnected = false
        var channelBound = false
        var authenticatedDelivered = false
    }

    private let store: BrowserPeerStore
    private let canAcquire: () -> Bool
    private let releaseAcquired: () -> Void
    private let autoApproveSyntheticEnrollment: Bool
    private let now: () -> Date

    private var identity: BrowserHostIdentity?
    private var approvedPeer: BrowserPeerRecord?
    private var browserHostURL = ""
    private var origin = ""
    private var display = ""
    private var maximumMode = "view"
    private var enrollment: EnrollmentState?
    private var pendingEnrollment: BrowserPendingEnrollment?
    private var challenge: PendingChallenge?
    private var ticket: PendingTicket?
    private var session: ActiveSession?
    private var lease = BrowserLeaseOwnership()
    private var iceServers: [ICEServerConfiguration] = []
    private var icePolicy = "all"
    private var iceWaitSession: String?
    private var iceReceivedSession: String?

    private var socket: URLSessionWebSocketTask?
    private var socketGeneration = UUID()
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var pendingWrites: [String] = []
    private var enrollmentTimeout: Task<Void, Never>?
    private var authorityTimeout: Task<Void, Never>?
    private var sessionTimeout: Task<Void, Never>?
    private var iceTimeout: Task<Void, Never>?

    init(
        store: BrowserPeerStore = BrowserPeerStore(),
        canAcquire: @escaping () -> Bool,
        release: @escaping () -> Void,
        autoApproveSyntheticEnrollment: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.canAcquire = canAcquire
        self.releaseAcquired = release
        self.autoApproveSyntheticEnrollment = autoApproveSyntheticEnrollment
        self.now = now
    }

    func start(serverURL: String, display: String, revision: UInt64, maximumMode: String) {
        stop()
        guard BrowserPeerValidation.isBrowserHostURL(serverURL),
              let origin = BrowserPeerValidation.origin(forBrowserHostURL: serverURL),
              !display.isEmpty,
              display.utf8.count <= 256,
              revision <= BrowserPeerValidation.maximumSafeInteger,
              BrowserPeerValidation.isMode(maximumMode),
              let url = URL(string: serverURL) else {
            status = "Browser host configuration is invalid"
            return
        }

        do {
            let identity = try store.loadOrCreateIdentity()
            self.identity = identity
            approvedPeer = try store.loadPeer()
            browserHostURL = serverURL
            self.origin = origin
            self.display = display
            self.revision = revision
            self.maximumMode = maximumMode
            mode = "view"

            let socket = URLSession.shared.webSocketTask(with: url)
            socket.maximumMessageSize = 256 * 1024
            self.socket = socket
            running = true
            let generation = socketGeneration
            socket.resume()
            send([
                "type": "host",
                "hostID": try identity.hostID(),
                "token": identity.token
            ])
            read(from: socket, generation: generation)
            status = "Connecting browser access service…"
        } catch {
            stopSocket()
            status = error.localizedDescription
        }
    }

    func makeEnrollment() {
        expireStaleAuthority()
        guard approvedPeer == nil else {
            status = "Revoke existing browser trust before enrolling a different browser or access scope"
            return
        }
        guard socket != nil, let identity else {
            status = "Start browser access before creating an enrollment offer"
            return
        }
        guard pendingEnrollment == nil else {
            status = "Finish or reject the pending browser enrollment first"
            return
        }
        do {
            let expiresAt = now().addingTimeInterval(120)
            let offer = BrowserEnrollmentOffer(
                url: origin,
                hostID: try identity.hostID(),
                hostKey: try identity.publicKey(),
                secret: try BrowserCrypto.random(),
                expires: Self.milliseconds(expiresAt)
            )
            let data = try JSONEncoder().encode(offer)
            enrollment = EnrollmentState(offer: offer, expiresAt: expiresAt)
            enrollmentCode = "pocketdesk-browser:" + data.base64EncodedString()
            status = "Enrollment offer created. It expires in two minutes."
        } catch {
            enrollment = nil
            enrollmentCode = ""
            status = error.localizedDescription
        }
    }

    func approveEnrollment() {
        guard let pending = pendingEnrollment,
              let identity else {
            status = "No browser enrollment is waiting for approval"
            return
        }
        guard pending.isLive(at: now()) else {
            expirePendingEnrollment(requestID: pending.requestID, respond: true)
            return
        }
        clearPendingEnrollment()
        do {
            let approvedAt = Self.milliseconds(now())
            let record = BrowserPeerRecord(
                peerID: pending.peerID,
                publicKey: pending.publicKey,
                origin: origin,
                maximumMode: maximumMode,
                display: display,
                approvedAt: approvedAt
            )
            try store.savePeer(record)
            approvedPeer = record
            let fields = ["enrolled", try identity.hostID(), record.peerID, record.publicKey, origin, maximumMode, display]
            respond(
                to: pending.requestID,
                body: [
                    "receipt": fields,
                    "signature": try BrowserCrypto.sign(fields, key: identity.signingKey())
                ]
            )
            status = "Browser enrolled for \(maximumMode) access"
        } catch {
            respond(to: pending.requestID, error: "enrollment_failed")
            status = error.localizedDescription
        }
    }

    func rejectEnrollment() {
        guard let pending = pendingEnrollment else { return }
        clearPendingEnrollment()
        respond(to: pending.requestID, error: "enrollment_rejected")
        status = "Browser enrollment rejected"
    }

    func stop() {
        if let sessionID = session?.session ?? ticket?.session ?? challenge?.session {
            send(["type": "end", "session": sessionID])
        }
        endAuthority(notifyEnded: true)
        enrollment = nil
        enrollmentCode = ""
        if let pendingEnrollment {
            respond(to: pendingEnrollment.requestID, error: "host_stopped")
        }
        clearPendingEnrollment()
        stopSocket()
        identity = nil
        approvedPeer = nil
        browserHostURL = ""
        origin = ""
        display = ""
        revision = 0
        maximumMode = "view"
        mode = "view"
        status = "Browser access is stopped"
    }

    func revoke() {
        stop()
        do {
            try store.deletePeer()
            approvedPeer = nil
            status = "Browser trust revoked"
        } catch {
            status = error.localizedDescription
        }
    }

    @discardableResult
    func sendStatus(_ data: Data) -> Bool {
        guard connected, session?.channelBound == true else { return false }
        return peer?.sendControl(data) == true
    }

    private func read(from socket: URLSessionWebSocketTask, generation: UUID) {
        reader = Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.socketGeneration == generation else { return }
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let string): data = Data(string.utf8)
                    @unknown default: throw BrowserControllerError.invalidMessage
                    }
                    guard data.count <= 256 * 1024 else { throw BrowserControllerError.invalidMessage }
                    try self.receive(data)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.socketGeneration == generation else { return }
                self.endAuthority(notifyEnded: true)
                self.stopSocket()
                self.status = "Browser access service disconnected"
            }
        }
    }

    private func receive(_ data: Data) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else {
            throw BrowserControllerError.invalidMessage
        }
        expireStaleAuthority()
        switch type {
        case "registered":
            status = "Browser access service is ready"
        case "ice":
            try handleIce(message)
        case "request":
            try handleRequest(message)
        case "cancel":
            handleCancellation(message)
        case "joined":
            try handleJoined(message)
        case "signal":
            try handleSignal(message)
        case "end":
            guard let sessionID = message["session"] as? String,
                  sessionID == session?.session || sessionID == ticket?.session else {
                throw BrowserControllerError.invalidMessage
            }
            endAuthority(notifyEnded: true)
            status = "Browser session ended"
        case "error":
            endAuthority(notifyEnded: true)
            status = "Browser service rejected the request"
        default:
            throw BrowserControllerError.invalidMessage
        }
    }

    private func handleRequest(_ message: [String: Any]) throws {
        guard let requestID = message["id"] as? String,
              !requestID.isEmpty,
              requestID.utf8.count <= 128,
              let operation = message["operation"] as? String,
              let body = message["body"] as? [String: Any] else {
            throw BrowserControllerError.invalidMessage
        }
        switch operation {
        case "enroll": try handleEnrollment(requestID: requestID, body: body)
        case "challenge": try handleChallenge(requestID: requestID, body: body)
        case "proof": try handleProof(requestID: requestID, body: body)
        default: respond(to: requestID, error: "unsupported_operation")
        }
    }

    private func handleEnrollment(requestID: String, body: [String: Any]) throws {
        guard pendingEnrollment == nil,
              approvedPeer == nil,
              let enrollment,
              enrollment.expiresAt > now(),
              let identity else {
            respond(to: requestID, error: "invalid_enrollment")
            return
        }
        let proposal: BrowserEnrollmentProposal
        do {
            proposal = try BrowserEnrollmentProposal.open(
                body: body,
                secret: enrollment.offer.secret,
                hostID: identity.hostID(),
                origin: origin
            )
        } catch {
            respond(to: requestID, error: "invalid_enrollment")
            return
        }
        self.enrollment = nil
        enrollmentCode = ""
        pendingEnrollment = BrowserPendingEnrollment(
            requestID: requestID,
            peerID: proposal.peerID,
            publicKey: proposal.publicKey,
            expiresAt: enrollment.expiresAt
        )
        pendingApproval = true
        status = "Approve this browser on your Mac"
        scheduleEnrollmentTimeout(until: enrollment.expiresAt, requestID: requestID)
        if autoApproveSyntheticEnrollment {
            approveEnrollment()
        }
    }

    private func handleCancellation(_ message: [String: Any]) {
        guard message.count == 2,
              Set(message.keys) == Set(["type", "id"]),
              let requestID = message["id"] as? String,
              BrowserPeerValidation.isToken(requestID) else { return }
        if pendingEnrollment?.matchesCancellation(requestID) == true {
            clearPendingEnrollment()
            enrollment = nil
            enrollmentCode = ""
            status = "Browser enrollment request expired"
            return
        }
        if challenge?.requestID == requestID || ticket?.requestID == requestID {
            // Cancel service-side tickets too; this branch cannot match a live session.
            send(["type": "stop"])
            endAuthority(notifyEnded: true)
            status = "Browser authorization request was cancelled"
        }
    }

    private func handleChallenge(requestID: String, body: [String: Any]) throws {
        guard challenge == nil, ticket == nil, session == nil, peer == nil,
              let identity,
              let approvedPeer,
              !approvedPeer.revoked,
              approvedPeer.origin == origin,
              approvedPeer.display == display,
              let peerID = body["peerID"] as? String,
              let nonce = body["nonce"] as? String,
              let requestedMode = body["mode"] as? String,
              peerID == approvedPeer.peerID,
              BrowserPeerValidation.isToken(nonce),
              BrowserPeerValidation.mode(requestedMode, isAllowedBy: approvedPeer.maximumMode),
              BrowserPeerValidation.mode(requestedMode, isAllowedBy: maximumMode) else {
            respond(to: requestID, error: "invalid_challenge")
            return
        }
        guard lease.acquire(using: canAcquire) else {
            respond(to: requestID, error: "busy")
            status = "Another viewer or controller is active"
            return
        }
        do {
            let sessionID = try BrowserCrypto.random()
            let hostNonce = try BrowserCrypto.random()
            let expiresAt = now().addingTimeInterval(30)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let fields = [
                "challenge",
                try identity.hostID(),
                approvedPeer.peerID,
                origin,
                requestedMode,
                display,
                String(revision),
                sessionID,
                Self.milliseconds(expiresAt),
                nonce,
                hostNonce,
                ephemeral.publicKey.x963Representation.base64EncodedString()
            ]
            challenge = PendingChallenge(
                requestID: requestID,
                fields: fields,
                session: sessionID,
                mode: requestedMode,
                expiresAt: expiresAt,
                ephemeralKey: ephemeral
            )
            self.sessionID = sessionID
            respond(to: requestID, body: [
                "fields": fields,
                "signature": try BrowserCrypto.sign(fields, key: identity.signingKey())
            ])
            status = "Waiting for browser proof"
            scheduleAuthorityTimeout(until: expiresAt, session: sessionID)
        } catch {
            endAuthority(notifyEnded: false)
            respond(to: requestID, error: "challenge_failed")
            status = error.localizedDescription
        }
    }

    private func handleProof(requestID: String, body: [String: Any]) throws {
        // Consume first. Every failure below requires a fresh challenge.
        guard let pending = challenge else {
            respond(to: requestID, error: "invalid_proof")
            return
        }
        challenge = nil
        authorityTimeout?.cancel()
        authorityTimeout = nil

        guard pending.expiresAt > now(),
              let identity,
              let approvedPeer,
              let sessionID = body["session"] as? String,
              let publicKey = body["publicKey"] as? String,
              let signature = body["signature"] as? String,
              sessionID == pending.session,
              BrowserPeerValidation.isPublicAgreementKey(publicKey) else {
            finishRejectedProof(requestID: requestID)
            return
        }
        let challengeHash = BrowserCrypto.hash(BrowserCrypto.canonical(pending.fields))
        guard BrowserCrypto.verify(
            ["proof", challengeHash, publicKey],
            signature: signature,
            publicKey: approvedPeer.publicKey
        ) else {
            finishRejectedProof(requestID: requestID)
            return
        }
        do {
            let key = try BrowserCrypto.sharedKey(
                privateKey: pending.ephemeralKey,
                publicKey: publicKey,
                challenge: pending.fields
            )
            let ticketValue = try BrowserCrypto.random()
            let ticketExpiresAt = now().addingTimeInterval(15)
            let sessionExpiresAt = now().addingTimeInterval(10 * 60)
            let expires = Self.milliseconds(ticketExpiresAt)
            let ticketFields = ["ticket", sessionID, ticketValue, expires, challengeHash]
            let ticketSignature = try BrowserCrypto.sign(ticketFields, key: identity.signingKey())
            ticket = PendingTicket(
                requestID: requestID,
                session: sessionID,
                mode: pending.mode,
                challengeHash: challengeHash,
                key: key,
                expiresAt: ticketExpiresAt,
                sessionExpiresAt: sessionExpiresAt
            )
            // ICE for this session must land before the ticket admission window
            // closes; a separate timer survives past `joined` so a contract
            // violation (joined arriving without ice) still fails closed.
            iceWaitSession = sessionID
            scheduleIceTimeout(until: ticketExpiresAt, session: sessionID)

            // The authenticated host socket is ordered: install transport authority
            // before returning it to the browser.
            send([
                "type": "ticket",
                "ticket": ticketValue,
                "session": sessionID,
                "expires": expires,
                "peerID": approvedPeer.peerID
            ])
            respond(to: requestID, body: [
                "ticket": ticketValue,
                "session": sessionID,
                "expires": expires,
                "signature": ticketSignature
            ])
            status = "Waiting for the browser transport"
            scheduleAuthorityTimeout(until: ticketExpiresAt, session: sessionID)
        } catch {
            finishRejectedProof(requestID: requestID)
        }
    }

    private func finishRejectedProof(requestID: String) {
        endAuthority(notifyEnded: false)
        respond(to: requestID, error: "invalid_proof")
        status = "Browser proof rejected"
    }

    private func handleJoined(_ message: [String: Any]) throws {
        guard let sessionID = message["session"] as? String,
              let pending = ticket,
              pending.session == sessionID,
              pending.expiresAt > now(),
              session == nil,
              peer == nil,
              lease.isOwned else {
            throw BrowserControllerError.invalidMessage
        }
        ticket = nil
        authorityTimeout?.cancel()
        authorityTimeout = nil
        mode = pending.mode
        session = ActiveSession(
            session: pending.session,
            mode: pending.mode,
            challengeHash: pending.challengeHash,
            key: pending.key,
            expiresAt: pending.sessionExpiresAt
        )
        status = "Confirming the browser session key…"
        scheduleSessionTimeout(until: pending.sessionExpiresAt, session: pending.session)
    }

    private func handleSignal(_ message: [String: Any]) throws {
        guard let sessionID = message["session"] as? String,
              sessionID == session?.session,
              let envelopeObject = message["envelope"] else {
            throw BrowserControllerError.invalidMessage
        }
        let envelope: BrowserEnvelope = try decode(envelopeObject)
        guard envelope.direction == "browser",
              BrowserPeerValidation.isDecimal(envelope.sequence),
              let sequence = UInt64(envelope.sequence),
              sequence > 0,
              var current = session,
              sequence > current.receivedSequence,
              current.expiresAt > now() else {
            throw BrowserControllerError.invalidMessage
        }
        let signal = try BrowserCrypto.open(
            envelope,
            key: current.key,
            session: current.session,
            direction: "browser",
            challengeHash: current.challengeHash
        )
        current.receivedSequence = sequence
        if !current.receivedKeyConfirmation {
            guard sequence == 1, signal.kind == "ready",
                  signal.sdp == nil, signal.candidate == nil,
                  signal.mid == nil, signal.line == nil else {
                throw BrowserControllerError.invalidMessage
            }
            current.receivedKeyConfirmation = true
            session = current
            preparePeer(for: current.session)
            peer?.offer()
            status = "Negotiating browser video…"
            return
        }
        guard signal.kind != "ready", let peer else { throw BrowserControllerError.invalidMessage }
        session = current
        peer.receive(signal)
    }

    private func handleIce(_ message: [String: Any]) throws {
        guard message.count == 4,
              Set(message.keys) == Set(["type", "session", "servers", "policy"]),
              let sessionID = message["session"] as? String,
              let policy = message["policy"] as? String,
              ["all", "relay"].contains(policy),
              let waitingSession = iceWaitSession,
              sessionID == waitingSession,
              iceReceivedSession == nil else {
            throw BrowserControllerError.invalidMessage
        }
        let servers = try decodeICEServers(message["servers"])
        iceServers = servers
        icePolicy = policy
        iceReceivedSession = sessionID
        iceTimeout?.cancel()
        iceTimeout = nil
    }

    private func scheduleIceTimeout(until deadline: Date, session sessionID: String) {
        iceTimeout?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        iceTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.iceWaitSession == sessionID else { return }
            self.terminateLiveSession(status: "Browser ICE delivery timed out (ice_timeout)")
        }
    }

    private func preparePeer(for sessionID: String) {
        guard peer == nil, let current = session,
              current.session == sessionID,
              current.receivedKeyConfirmation,
              lease.isOwned,
              iceReceivedSession == sessionID else { return }
        let forceRelay: Bool
        switch BrowserRelayPolicy.relayDecision(servers: iceServers, policy: icePolicy) {
        case .relayRequiredUnavailable:
            terminateLiveSession(status: "Browser session requires relay but no TURN server was issued (relay_required_unavailable)")
            return
        case .proceed(let decided):
            forceRelay = decided
        }
        let next = PeerMedia(isHost: true, servers: iceServers, forceRelay: forceRelay, nativeDesktopCodecs: false)
        peer = next
        next.onSignal = { [weak self, weak next] signal in
            Task { @MainActor in
                guard let self, let next, self.peer === next else { return }
                self.sendEncrypted(signal)
            }
        }
        next.onControl = { [weak self, weak next] data in
            Task { @MainActor in
                guard let self, let next, self.peer === next else { return }
                self.receiveControl(data)
            }
        }
        next.onState = { [weak self, weak next] state in
            Task { @MainActor in
                guard let self, let next, self.peer === next else { return }
                if state == "connected" {
                    self.session?.mediaConnected = true
                    self.deliverAuthenticationIfReady()
                } else if state == "failed" || state == "disconnected" || state == "closed" {
                    self.terminateLiveSession(status: "Browser media disconnected")
                }
            }
        }
    }

    private func sendEncrypted(_ signal: MediaSignal) {
        guard var current = session,
              current.receivedKeyConfirmation,
              current.sentSequence < BrowserPeerValidation.maximumSafeInteger else {
            terminateLiveSession(status: "Browser signaling sequence exhausted")
            return
        }
        current.sentSequence += 1
        do {
            let envelope = try BrowserCrypto.seal(
                signal,
                key: current.key,
                session: current.session,
                direction: "host",
                sequence: current.sentSequence,
                challengeHash: current.challengeHash
            )
            session = current
            send([
                "type": "signal",
                "session": current.session,
                "envelope": try dictionary(envelope)
            ])
        } catch {
            terminateLiveSession(status: "Browser signaling encryption failed")
        }
    }

    private func receiveControl(_ data: Data) {
        guard data.count <= 16_384, var current = session else {
            terminateLiveSession(status: "Browser control message rejected")
            return
        }
        if !current.channelBound {
            guard let bind = try? JSONDecoder().decode(BrowserControlBind.self, from: data),
                  bind.type == "bind",
                  bind.session == current.session,
                  bind.challengeHash == current.challengeHash else {
                terminateLiveSession(status: "Browser media binding failed")
                return
            }
            current.channelBound = true
            session = current
            deliverAuthenticationIfReady()
            return
        }
        if let duplicate = try? JSONDecoder().decode(BrowserControlBind.self, from: data), duplicate.type == "bind" {
            terminateLiveSession(status: "Duplicate browser media binding rejected")
            return
        }
        guard connected else { return }
        onControl?(data)
    }

    private func deliverAuthenticationIfReady() {
        guard var current = session,
              current.mediaConnected,
              current.channelBound,
              !current.authenticatedDelivered,
              let peer else { return }
        current.authenticatedDelivered = true
        session = current
        connected = true
        mode = current.mode
        status = current.mode == "interactive" ? "Browser connected for control" : "Browser connected for viewing"
        onAuthenticated?(peer, current.mode)
    }

    private func terminateLiveSession(status message: String) {
        if let sessionID = session?.session ?? ticket?.session {
            send(["type": "end", "session": sessionID])
        }
        endAuthority(notifyEnded: true)
        status = message
    }

    private func expireStaleAuthority() {
        let date = now()
        if let enrollment, enrollment.expiresAt <= date {
            self.enrollment = nil
            enrollmentCode = ""
        }
        if let pendingEnrollment, !pendingEnrollment.isLive(at: date) {
            expirePendingEnrollment(requestID: pendingEnrollment.requestID, respond: true)
        }
        let challengeExpired = challenge.map { $0.expiresAt <= date } ?? false
        let ticketExpired = ticket.map { $0.expiresAt <= date } ?? false
        let sessionExpired = session.map { $0.expiresAt <= date } ?? false
        if challengeExpired || ticketExpired {
            endAuthority(notifyEnded: true)
            status = "Browser authorization expired"
        } else if sessionExpired {
            endAuthority(notifyEnded: true)
            status = "Browser session expired"
        }
    }

    private func scheduleEnrollmentTimeout(until deadline: Date, requestID: String) {
        enrollmentTimeout?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        enrollmentTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.pendingEnrollment?.matchesCancellation(requestID) == true else { return }
            self.expirePendingEnrollment(requestID: requestID, respond: true)
        }
    }

    private func expirePendingEnrollment(requestID: String, respond shouldRespond: Bool) {
        guard pendingEnrollment?.matchesCancellation(requestID) == true else { return }
        clearPendingEnrollment()
        enrollment = nil
        enrollmentCode = ""
        if shouldRespond { respond(to: requestID, error: "enrollment_expired") }
        status = "Browser enrollment approval expired"
    }

    private func clearPendingEnrollment() {
        enrollmentTimeout?.cancel()
        enrollmentTimeout = nil
        pendingEnrollment = nil
        pendingApproval = false
    }

    private func scheduleAuthorityTimeout(until deadline: Date, session sessionID: String) {
        authorityTimeout?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        authorityTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.challenge?.session == sessionID || self.ticket?.session == sessionID else { return }
            self.endAuthority(notifyEnded: true)
            self.status = "Browser authorization expired"
        }
    }

    private func scheduleSessionTimeout(until deadline: Date, session sessionID: String) {
        sessionTimeout?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        sessionTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session?.session == sessionID else { return }
            self.send(["type": "end", "session": sessionID])
            self.endAuthority(notifyEnded: true)
            self.status = "Browser session reached its ten-minute limit"
        }
    }

    private func endAuthority(notifyEnded: Bool) {
        authorityTimeout?.cancel()
        authorityTimeout = nil
        sessionTimeout?.cancel()
        sessionTimeout = nil
        iceTimeout?.cancel()
        iceTimeout = nil
        challenge = nil
        ticket = nil
        session = nil
        sessionID = ""
        connected = false
        peer?.close()
        peer = nil
        iceServers = []
        icePolicy = "all"
        iceWaitSession = nil
        iceReceivedSession = nil
        let released = lease.release(using: releaseAcquired)
        if notifyEnded && released { onEnded?() }
    }

    private func send(_ object: [String: Any]) {
        guard socket != nil,
              pendingWrites.count < 64,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= 256 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            endAuthority(notifyEnded: true)
            status = "Browser service send failed"
            return
        }
        pendingWrites.append(text)
        guard writer == nil else { return }
        let generation = socketGeneration
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled,
                      self.socketGeneration == generation,
                      !self.pendingWrites.isEmpty {
                    guard let socket = self.socket else { return }
                    let next = self.pendingWrites.removeFirst()
                    try await socket.send(.string(next))
                }
                if self.socketGeneration == generation { self.writer = nil }
            } catch {
                guard self.socketGeneration == generation else { return }
                self.endAuthority(notifyEnded: true)
                self.stopSocket()
                self.status = "Browser access service disconnected"
            }
        }
    }

    private func respond(to requestID: String, body: [String: Any]) {
        send(["type": "response", "id": requestID, "body": body])
    }

    private func respond(to requestID: String, error: String) {
        send(["type": "response", "id": requestID, "error": error])
    }

    private func stopSocket() {
        running = false
        socketGeneration = UUID()
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pendingWrites.removeAll()
        iceServers.removeAll()
        icePolicy = "all"
        iceWaitSession = nil
        iceReceivedSession = nil
        iceTimeout?.cancel()
        iceTimeout = nil
    }

    private func decodeICEServers(_ object: Any?) throws -> [ICEServerConfiguration] {
        guard let object else { return [] }
        let servers: [ICEServerConfiguration] = try decode(object)
        guard servers.count <= 8,
              servers.allSatisfy({ $0.urls.count <= 8 && $0.urls.allSatisfy({ $0.utf8.count <= 2048 }) }) else {
            throw BrowserControllerError.invalidMessage
        }
        return servers
    }

    private func decode<T: Decodable>(_ object: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(object) else { throw BrowserControllerError.invalidMessage }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserControllerError.invalidMessage
        }
        return result
    }

    private static func milliseconds(_ date: Date) -> String {
        String(UInt64(max(0, date.timeIntervalSince1970 * 1_000)))
    }
}

private enum BrowserControllerError: Error {
    case invalidMessage
}

enum BrowserRelayDecision: Equatable {
    case proceed(forceRelay: Bool)
    case relayRequiredUnavailable
}

enum BrowserRelayPolicy {
    static func relayDecision(servers: [ICEServerConfiguration], policy: String) -> BrowserRelayDecision {
        guard policy == "relay" else { return .proceed(forceRelay: false) }
        let hasRelay = servers.contains { server in
            server.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        }
        return hasRelay ? .proceed(forceRelay: true) : .relayRequiredUnavailable
    }
}
