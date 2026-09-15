import Foundation
import Combine
import WebRTC

@MainActor
final class RemoteCoordinator: ObservableObject {
    @Published var status = "Not connected"
    @Published var awaitingApproval = false
    @Published var connected = false
    @Published private(set) var hostRegistered = false
    @Published var remoteVideo: RTCVideoTrack?
    @Published var hasRelay = false
    @Published var diagnostics = "Route not measured"
    var forceRelay = false
    var onAuthenticated: (() -> Void)?
    var onControl: ((Data) -> Void)?
    var onEnded: (() -> Void)?
    var media: PeerMedia?
    private(set) var hostPair: HostPair?
    private(set) var invitation: PairInvitation?
    private let isHost: Bool
    private let store: any PairPersistence
    private let relay = SignalingClient()
    private var cipher: SignalCipher?
    private var request = ""
    private var session = ""
    private var sequence: UInt64 = 0
    private var guardState: SessionReplayGuard?
        private var servers: [ICEServerConfiguration] = []
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryCount = 0
    private let retryLimit: Int
    private let retryBaseNanoseconds: UInt64
    private var stopped = true
    private var proofReceived = false
    private var sentControl: UInt64 = 0
    private var receivedControl: UInt64 = 0

    init(
        isHost: Bool,
        store: (any PairPersistence)? = nil,
        retryLimit: Int = 5,
        retryBaseNanoseconds: UInt64 = 500_000_000
    ) {
        self.isHost = isHost
        self.store = store ?? PairStore(account: isHost ? "host" : "phone")
        self.retryLimit = max(0, retryLimit)
        self.retryBaseNanoseconds = retryBaseNanoseconds
        relay.onMessage = { [weak self] message in self?.receive(message) }
        relay.onClose = { [weak self] in self?.connectionLost() }
    }
    func sendControl(_ action: RemoteAction) -> Bool {
        guard connected, !session.isEmpty else { return false }
        do {
            try action.validate()
            sentControl += 1
            let data = try JSONEncoder().encode(ControlPacket(session: session, sequence: sentControl, action: action))
            guard media?.sendControl(data) == true else { connectionLost(); return false }
            return true
        } catch { connectionLost(); return false }
    }
    func restore() {
        do {
            if isHost { hostPair = try store.read(HostPair.self); invitation = hostPair?.invitation }
            else { invitation = try store.read(PairInvitation.self) }
            status = invitation == nil ? "Pair with your Mac to get started" : "Ready to connect"
        } catch { status = error.localizedDescription }
    }
    func createPair(server: String, name: String) throws -> PairInvitation {
        stop()
        let pair = try HostPair.create(server: server, name: name)
        try pair.invitation.validate()
        try store.save(pair)
        hostPair = pair; invitation = pair.invitation
        return pair.invitation
    }
    func enroll(_ code: String) throws {
        stop()
        invitation = try PairInvitation.parse(code)
        start()
    }
    func start() {
        start(resetRetryBudget: true)
    }
    private func start(resetRetryBudget: Bool) {
        guard let invitation else { status = "Pair with your Mac first"; return }
        do {
            if isHost, let pair = hostPair, !pair.paired { try invitation.validate() }
            else { try invitation.validate(enrollment: false) }
            if resetRetryBudget { retryCount = 0 }
            stopped = false
            retry?.cancel(); retry = nil
            resetSession()
            cipher = try SignalCipher(key: invitation.key, room: invitation.room)
            status = "Connecting securely…"
            try relay.connect(invitation: invitation, hostToken: hostPair?.hostToken)
            setTimeout()
        } catch { fail(error.localizedDescription) }
    }
    func approve() {
        guard isHost, awaitingApproval, proofReceived, (hostPair?.invitation.expires ?? .distantPast) > Date() else { fail("Pairing expired. Create a fresh code."); return }
        awaitingApproval = false
        acceptSession()
    }
    func reject() { fail("Pairing was declined on the Mac") }
    func revoke() {
        stop()
        do { try store.delete(); hostPair = nil; invitation = nil; status = "Pairing removed. Old credentials no longer work." }
        catch { status = error.localizedDescription }
    }
    func stop() {
        stopped = true; retry?.cancel(); retry = nil; retryCount = 0
        relay.close(); resetSession(); status = "Disconnected"
    }
    private func resetSession() {
        timeout?.cancel(); timeout = nil
        media?.close(); media = nil
        remoteVideo = nil; connected = false; awaitingApproval = false; hostRegistered = false
        diagnostics = "Route not measured"
        sentControl = 0; receivedControl = 0
        request = ""; session = ""; sequence = 0; guardState = nil; proofReceived = false
        onEnded?()
    }
    private func receive(_ message: RelayMessage) {
        do {
            switch message.type {
            case "registered":
                if isHost { hostRegistered = true; timeout?.cancel(); status = "Ready for your paired phone" }
            case "ice":
                servers = message.servers ?? []
                guard servers.count <= 8, servers.allSatisfy({ $0.urls.count <= 8 }) else { throw RemoteError.invalidMessage }
                hasRelay = servers.contains { $0.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
            case "peer":
                if message.online == true {
                    if !isHost {
                        resetSession(); request = try SecureRandom.token()
                        send(kind: "request", handshake: true); status = "Authenticating your Mac…"; setTimeout()
                    }
                } else {
                    resetSession()
                    if isHost { connectionLost() }
                    else { connectionLost() }
                }
            case "signal":
                guard let cipher, let payload = message.payload else { throw RemoteError.invalidMessage }
                try receiveProtected(cipher.open(payload, sender: isHost ? "client" : "host"))
            case "error":
                let code = message.code ?? "unavailable"
                let serviceError = "Connection service: \(code). Check the Mac and retry."
                if !isHost, code == "host_unavailable_or_unauthorized" {
                    connectionLost(finalStatus: serviceError)
                } else {
                    fail(serviceError)
                }
            default: throw RemoteError.invalidMessage
            }
        } catch { fail("Secure connection failed. Reconnect or pair again on your Mac.") }
    }
    private func receiveProtected(_ message: ProtectedMessage) throws {
        if isHost, message.kind == "request" {
            guard request.isEmpty, message.session.isEmpty, message.sequence == 0,
                  let pair = hostPair, pair.paired || pair.invitation.expires > Date() else { throw RemoteError.stale }
            request = message.request; session = try SecureRandom.token()
            guardState = SessionReplayGuard(request: request, session: session)
            send(kind: "challenge", handshake: true); setTimeout(); return
        }
        if !isHost, message.kind == "challenge" {
            guard message.request == request, session.isEmpty, !message.session.isEmpty, message.sequence == 0 else { throw RemoteError.stale }
            session = message.session; guardState = SessionReplayGuard(request: request, session: session)
            send(kind: "proof", handshake: true); return
        }
        if isHost, message.kind == "proof" {
            guard message.request == request, message.session == session, !session.isEmpty,
                  message.sequence == 0, !proofReceived else { throw RemoteError.stale }
            proofReceived = true
            if hostPair?.paired == true { acceptSession() }
            else { awaitingApproval = true; status = "Approve this phone on your Mac"; setTimeout(seconds: 60) }
            return
        }
        guard guardState != nil else { throw RemoteError.stale }
        try guardState?.accept(message)
        switch message.kind {
        case "accepted" where !isHost:
            guard media == nil else { throw RemoteError.stale }
            if let body = message.body {
                let next = try JSONDecoder().decode(PairInvitation.self, from: body)
                try next.validate(enrollment: false)
                guard next.room == invitation?.room, next.server == invitation?.server else { throw RemoteError.invalidMessage }
                try store.save(next); invitation = next
            }
            prepareMedia()
            send(kind: "acceptedAck")
        case "acceptedAck" where isHost:
            guard proofReceived, media == nil, !awaitingApproval else { throw RemoteError.stale }
            prepareMedia(); media?.offer()
        case "media":
            guard let body = message.body, let media else { throw RemoteError.invalidMessage }
            media.receive(try JSONDecoder().decode(MediaSignal.self, from: body))
        default: throw RemoteError.invalidMessage
        }
    }
    private func acceptSession() {
        do {
            guard let hostPair else { throw RemoteError.invalidPairing }
            if !hostPair.paired {
                // Persist before publishing new trust. An interrupted enrollment may require
                // a fresh QR, but can never reconnect using the exposed enrollment key.
                let next = try hostPair.rotated()
                try store.save(next)
                self.hostPair = next; invitation = next.invitation
                send(kind: "accepted", body: try JSONEncoder().encode(next.invitation))
            } else { send(kind: "accepted") }
            status = "Connecting live desktop…"; setTimeout()
        } catch { fail(error.localizedDescription) }
    }
    private func prepareMedia() {
        guard !forceRelay || hasRelay else { fail("Relay-only test requires a configured TURN service."); return }
        let peer = PeerMedia(isHost: isHost, servers: servers, forceRelay: forceRelay)
        media = peer
        peer.onDiagnostics = { [weak self, weak peer] value in
            Task { @MainActor in if let self, let peer, self.media === peer { self.diagnostics = value } }
        }
        peer.onSignal = { [weak self, weak peer] signal in
            Task { @MainActor in
                guard let self, let peer, self.media === peer, let data = try? JSONEncoder().encode(signal) else { return }
                self.send(kind: "media", body: data)
            }
        }
        peer.onRemoteVideo = { [weak self, weak peer] track in Task { @MainActor in if let self, let peer, self.media === peer { self.remoteVideo = track } } }
        peer.onControl = { [weak self, weak peer] data in
            Task { @MainActor in
                guard let self, let peer, self.media === peer, data.count <= 16384 else { return }
                do {
                    let packet = try JSONDecoder().decode(ControlPacket.self, from: data)
                    guard packet.version == 1, packet.session == self.session, packet.sequence > self.receivedControl else { throw RemoteError.stale }
                    try packet.action.validate()
                    self.receivedControl = packet.sequence
                    self.onControl?(try JSONEncoder().encode(packet.action))
                } catch { self.fail("Invalid control message. Session ended safely.") }
            }
        }
        peer.onState = { [weak self, weak peer] state in
            Task { @MainActor in
                guard let self, let peer, self.media === peer else { return }
                self.status = state
                if state == "connected" {
                    guard !self.connected else { return }
                    self.connected = true; self.retryCount = 0; self.timeout?.cancel(); self.onAuthenticated?()
                } else if state == "failed" || state == "disconnected" || state == "closed" { self.connectionLost() }
            }
        }
    }
    private func send(kind: String, body: Data? = nil, handshake: Bool = false) {
        guard let cipher else { fail("Pairing is not ready"); return }
        do {
            if !handshake { sequence += 1 }
            let message = ProtectedMessage(kind: kind, request: request, session: session, sequence: handshake ? 0 : sequence, body: body)
            relay.send(RelayMessage(type: "signal", payload: try cipher.seal(message, sender: isHost ? "host" : "client")))
        } catch { fail(error.localizedDescription) }
    }
    private func setTimeout(seconds: UInt64 = 20) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fail("Connection timed out. Check that the Mac is awake and the service is reachable.")
        }
    }
    private func connectionLost(finalStatus: String = "Connection lost. Tap Connect to try again.") {
        guard !stopped else { return }
        relay.close(); resetSession()
        guard retry == nil, retryCount < retryLimit else {
            stopped = true
            status = finalStatus
            return
        }
        retryCount += 1
        let delay = UInt64(1 << (retryCount - 1))
        status = "Connection interrupted · retrying…"
        retry = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay * self.retryBaseNanoseconds)
            guard !Task.isCancelled, !self.stopped else { return }
            self.retry = nil; self.start(resetRetryBudget: false)
        }
    }
    private func fail(_ message: String) {
        stopped = true; retry?.cancel(); retry = nil
        relay.close(); resetSession(); status = message
    }
}
