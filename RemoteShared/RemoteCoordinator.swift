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
    private let relay: any SignalingTransport
    private let renewalScheduler: any RenewalScheduler
    private let advertisesRenewal: Bool
    private let handshakeTimeoutNanoseconds: UInt64
    private var renewalPlan: RenewalPlan?
    private var renewalTask: Task<Void, Never>?
    /// Renewal replies accepted, refreshed credentials applied, and ICE restarts started (host only)
    /// since this coordinator was created. Diagnostics and tests read them.
    private(set) var renewalCount = 0
    private(set) var credentialRefreshCount = 0
    private(set) var iceRestartCount = 0
    /// Inbound signaling that belonged to no current session and was dropped instead of acted on.
    private(set) var staleMessagesIgnored = 0
    private var cipher: SignalCipher?
    private var registeredInvitation: PairInvitation?
    private var request = ""
    private var session = ""
    private var sequence: UInt64 = 0
    private var guardState: SessionReplayGuard?
    private var servers: [ICEServerConfiguration] = []
    private var relayPolicy: String?
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryCount = 0
    private let retryLimit: Int
    private let retryBaseNanoseconds: UInt64
    private let sessionLossRetryLimit: Int?
    private let maximumRetryDelayNanoseconds: UInt64?
    /// An established session dropped (for example, the Mac app crashed and is being relaunched);
    /// retries use the longer session-loss budget until a connection succeeds or is stopped.
    private var recoveringLiveSession = false
    private let registrationStableNanoseconds: UInt64
    private var registrationStability: Task<Void, Never>?
    private var stopped = true
    private var proofReceived = false
    private var sentControl: UInt64 = 0
    private var receivedControl: UInt64 = 0
    #if DEBUG
    /// E2E harness only (see script/e2e/README.md). Host: approves an unpaired phone whose
    /// encrypted proof carries the harness's one-time token; nil keeps human approval.
    var e2eProofApprover: ((Data?) -> Bool)?
    /// E2E harness only. Phone: token sent inside the encrypted proof while enrolling.
    var e2eEnrollmentProof: Data?
    private var e2eEnrolling = false
    #endif

    init(
        isHost: Bool,
        store: (any PairPersistence)? = nil,
        retryLimit: Int = 5,
        retryBaseNanoseconds: UInt64 = 500_000_000,
        sessionLossRetryLimit: Int? = nil,
        maximumRetryDelayNanoseconds: UInt64? = nil,
        registrationStableNanoseconds: UInt64 = 5_000_000_000,
        signaling: (any SignalingTransport)? = nil,
        renewalScheduler: any RenewalScheduler = SystemRenewalScheduler(),
        advertisesRenewal: Bool = true,
        handshakeTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) {
        self.isHost = isHost
        self.store = store ?? PairStore(account: isHost ? "host" : "phone")
        self.relay = signaling ?? SignalingClient()
        self.renewalScheduler = renewalScheduler
        self.advertisesRenewal = advertisesRenewal
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.retryLimit = max(0, retryLimit)
        self.retryBaseNanoseconds = retryBaseNanoseconds
        self.sessionLossRetryLimit = sessionLossRetryLimit.map { max(0, $0) }
        self.maximumRetryDelayNanoseconds = maximumRetryDelayNanoseconds
        self.registrationStableNanoseconds = registrationStableNanoseconds
        relay.onMessage = { [weak self] message in self?.receive(message) }
        relay.onClose = { [weak self] in self?.connectionLost() }
    }
    func sendControl(_ action: RemoteAction) -> Bool {
        guard connected, !session.isEmpty else { return false }
        do {
            try action.validate()
            sentControl += 1
            let data = try JSONEncoder().encode(ControlPacket(session: session, sequence: sentControl, action: action))
            guard media?.sendControl(data) == true else { peerDisconnected(); return false }
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
        #if DEBUG
        e2eEnrolling = true
        #endif
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
            if resetRetryBudget { retryCount = 0; recoveringLiveSession = false }
            stopped = false
            retry?.cancel(); retry = nil
            cancelRenewal()
            resetSession()
            cipher = try SignalCipher(key: invitation.key, room: invitation.room)
            status = "Connecting securely…"
            registeredInvitation = invitation
            try relay.connect(invitation: invitation, hostToken: hostPair?.hostToken,
                              features: advertisesRenewal ? [SignalingFeature.renewal] : [])
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
        stopped = true; retry?.cancel(); retry = nil; retryCount = 0; recoveringLiveSession = false
        cancelRenewal()
        relay.close(); registeredInvitation = nil; resetSession(); status = "Disconnected"
    }
    /// Connected, connecting, or waiting to retry.
    var isRunning: Bool { !stopped }
    /// Ends only the current phone session. A registered host keeps listening for its paired phone.
    func dropPeerSession() {
        guard isHost, connected || media != nil else { return }
        peerDisconnected()
    }
    private func resetSession() {
        timeout?.cancel(); timeout = nil
        registrationStability?.cancel(); registrationStability = nil
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
                if isHost {
                    hostRegistered = true; timeout?.cancel(); status = "Ready for your paired phone"
                    resetRetryBudgetAfterStableRegistration()
                }
                beginRenewal(message.renew)
            case "renewed":
                receiveRenewal(message)
            case "ice":
                servers = message.servers ?? []
                guard servers.count <= 8, servers.allSatisfy({ $0.urls.count <= 8 }),
                      NativeRelayPolicy.isValid(message.policy) else { throw RemoteError.invalidMessage }
                relayPolicy = message.policy
                hasRelay = NativeRelayPolicy.hasRelay(servers)
            case "peer":
                if message.online == true {
                    if !isHost {
                        resetSession(); request = try SecureRandom.token()
                        send(kind: "request", handshake: true); status = "Authenticating your Mac…"; setTimeout()
                    }
                } else {
                    peerDisconnected()
                }
            case "signal":
                guard let cipher, let payload = message.payload else { throw RemoteError.invalidMessage }
                let opened: ProtectedMessage
                do { opened = try cipher.open(payload, sender: isHost ? "client" : "host") }
                catch { throw RemoteError.stale }
                do { try receiveProtected(opened) }
                catch RemoteError.stale { throw RemoteError.stale }
                // A registered Mac's job is to keep listening: a current message that breaks the protocol
                // ends this phone's session, not the registration. A phone still fails closed.
                catch where isHost && hostRegistered && !stopped { peerDisconnected() }
            case "error":
                let code = message.code ?? "unavailable"
                // The service answers a signal for a peer that already left with a non-closing
                // error. It is a late message from a session that is over, not a service failure.
                if code == "peer_unavailable" { staleMessagesIgnored += 1; return }
                let serviceError = "Connection service: \(code). Check the Mac and retry."
                // A freshly stopped phone may still occupy the server's client slot
                // for a moment. Retry within the existing bound; never evict it.
                if !isHost, code == "host_unavailable_or_unauthorized" || code == "already_connected" {
                    connectionLost(finalStatus: serviceError)
                } else if isHost, code == "already_connected" {
                    // A relaunched host can race the service noticing that its crashed
                    // predecessor's socket closed. Wait it out within the retry bound.
                    connectionLost(finalStatus: serviceError)
                } else {
                    fail(serviceError)
                }
            default: throw RemoteError.invalidMessage
            }
        } catch RemoteError.stale {
            // Not from the current pairing, session or handshake: a trailing candidate from a phone
            // session that already ended, a replay, or a message sealed with another key. Rejecting
            // it means not acting on it, never tearing down the connection it was aimed at.
            staleMessagesIgnored += 1
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
            #if DEBUG
            send(kind: "proof", body: e2eEnrolling ? e2eEnrollmentProof : nil, handshake: true); return
            #else
            send(kind: "proof", handshake: true); return
            #endif
        }
        if isHost, message.kind == "proof" {
            guard message.request == request, message.session == session, !session.isEmpty,
                  message.sequence == 0, !proofReceived else { throw RemoteError.stale }
            proofReceived = true
            if hostPair?.paired == true { acceptSession() }
            else {
                #if DEBUG
                if let approver = e2eProofApprover, (hostPair?.invitation.expires ?? .distantPast) > Date(),
                   approver(message.body) {
                    acceptSession()
                    return
                }
                #endif
                awaitingApproval = true; status = "Approve this phone on your Mac"; setTimeout(nanoseconds: 60_000_000_000)
            }
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
                #if DEBUG
                e2eEnrolling = false
                #endif
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
        let relayOnly: Bool
        switch NativeRelayPolicy.decide(servers: servers, policy: relayPolicy, localForce: forceRelay) {
        case .proceed(let force):
            relayOnly = force
        case .relayRequiredUnavailable(let serverRequired):
            fail(serverRequired ? "The connection service requires a relay, but none was provided." : "Relay-only test requires a configured TURN service.")
            return
        }
        let peer = PeerMedia(isHost: isHost, servers: servers, forceRelay: relayOnly)
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
                    self.connected = true; self.retryCount = 0; self.recoveringLiveSession = false
                    self.timeout?.cancel(); self.onAuthenticated?()
                } else if state == "failed" || state == "disconnected" || state == "closed" { self.peerDisconnected() }
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
    private func setTimeout(nanoseconds: UInt64? = nil) {
        timeout?.cancel()
        let wait = nanoseconds ?? handshakeTimeoutNanoseconds
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self else { return }
            // A registered Mac keeps listening when one phone's attempt stalls; only a Mac that never
            // reached the service, or a phone, reports the timeout as a failure.
            if self.isHost, self.hostRegistered, !self.stopped { self.peerDisconnected() }
            else { self.fail("Connection timed out. Check that the Mac is awake and the service is reachable.") }
        }
    }

    private func peerDisconnected() {
        // The relay keeps the host's registered room open when its phone leaves.
        // Keep listening there; tearing down the host socket can exhaust its retry
        // budget while the phone independently reconnects.
        // First approval rotates the saved phone credential. The currently
        // registered relay room and cipher still use the enrollment invitation,
        // so that one session must re-register before accepting the saved phone.
        guard isHost, hostRegistered, !stopped, registeredInvitation == invitation else {
            connectionLost(); return
        }
        resetSession()
        hostRegistered = true
        status = "Ready for your paired phone"
        resetRetryBudgetAfterStableRegistration()
    }

    private func resetRetryBudgetAfterStableRegistration() {
        guard isHost else { return }
        registrationStability?.cancel()
        registrationStability = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.registrationStableNanoseconds)
            guard !Task.isCancelled, self.hostRegistered, !self.stopped else { return }
            self.retryCount = 0
            self.registrationStability = nil
        }
    }

    private func connectionLost(finalStatus: String = "Connection lost. Tap Connect to try again.") {
        guard !stopped else { return }
        // A media and signaling failure can report the same outage independently.
        // The first event already closed the old transport and scheduled a retry.
        guard retry == nil else { return }
        if connected && sessionLossRetryLimit != nil { recoveringLiveSession = true }
        cancelRenewal()
        relay.close(); registeredInvitation = nil; resetSession()
        let limit = recoveringLiveSession ? max(retryLimit, sessionLossRetryLimit ?? retryLimit) : retryLimit
        guard retryCount < limit else {
            stopped = true
            recoveringLiveSession = false
            status = finalStatus
            return
        }
        retryCount += 1
        let delay = RetrySchedule.delay(attempt: retryCount, base: retryBaseNanoseconds,
                                        maximum: maximumRetryDelayNanoseconds)
        status = "Connection interrupted · retrying…"
        retry = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, !self.stopped else { return }
            self.retry = nil; self.start(resetRetryBudget: false)
        }
    }
    private func fail(_ message: String) {
        stopped = true; retry?.cancel(); retry = nil; recoveringLiveSession = false
        cancelRenewal()
        relay.close(); registeredInvitation = nil; resetSession(); status = message
    }

    // MARK: Lease and credential renewal
    //
    // The signaling service ends a room that is not renewed, and ends a relay allocation whose
    // credentials expire. When the service offers renewal, this keeps both alive for as long as the
    // session is connected: it sends `renew` on the schedule the service asks for, applies fresh relay
    // credentials to the live connection, and, on a relayed route, restarts ICE so the media moves to
    // a new allocation while the old one keeps carrying it. Everything here is best effort. If the
    // service stops answering, the room ends as it always did and the reconnect logic takes over.

    private func beginRenewal(_ offer: RenewalOffer?) {
        cancelRenewal()
        guard advertisesRenewal, let offer, offer.version == 1, offer.renewAfterSeconds.isFinite,
              offer.renewAfterSeconds > 0 else { return }
        renewalPlan = RenewalPlan(offer: offer, now: renewalScheduler.now())
        scheduleRenewal()
    }

    private func cancelRenewal() {
        renewalTask?.cancel(); renewalTask = nil
        renewalPlan = nil
    }

    private func scheduleRenewal() {
        renewalTask?.cancel(); renewalTask = nil
        guard let plan = renewalPlan else { return }
        let scheduler = renewalScheduler
        let delay = plan.delay(from: scheduler.now())
        renewalTask = Task { [weak self] in
            do { try await scheduler.sleep(seconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.sendRenewal()
        }
    }

    private func sendRenewal() {
        guard var plan = renewalPlan, !stopped else { return }
        plan.attemptStarted(at: renewalScheduler.now())
        renewalPlan = plan
        scheduleRenewal()
        relay.send(RelayMessage(type: "renew"))
    }

    private func receiveRenewal(_ message: RelayMessage) {
        guard var plan = renewalPlan, let renewAfter = message.renewAfterSeconds, renewAfter.isFinite else { return }
        let now = renewalScheduler.now()
        var fresh: [ICEServerConfiguration]?
        if let servers = message.servers {
            guard servers.count <= 8, servers.allSatisfy({ $0.urls.count <= 8 }), NativeRelayPolicy.hasRelay(servers) else {
                plan.attemptFailed(at: now)
                renewalPlan = plan
                scheduleRenewal()
                return
            }
            fresh = servers
        }
        plan.renewed(RenewalOutcome(leaseSeconds: message.leaseSeconds, renewAfterSeconds: renewAfter,
                                    credentialSeconds: fresh == nil ? nil : message.credentialSeconds,
                                    softFailure: message.code), at: now)
        renewalPlan = plan
        renewalCount += 1
        if let fresh { applyRefreshedServers(fresh) }
        scheduleRenewal()
    }

    private func applyRefreshedServers(_ fresh: [ICEServerConfiguration]) {
        servers = fresh
        hasRelay = true
        credentialRefreshCount += 1
        guard let media, media.updateICEServers(fresh) else { return }
        if isHost, connected, media.needsRelayRefresh, media.restartICE() { iceRestartCount += 1 }
    }

    #if DEBUG
    func simulateTransportLossForTesting() { connectionLost() }
    var iceServersForTesting: [ICEServerConfiguration] { servers }
    var renewalPlanForTesting: RenewalPlan? { renewalPlan }
    #endif
}

enum RetrySchedule {
    /// Exponential backoff of 1×, 2×, 4×… the base delay, optionally capped.
    static func delay(attempt: Int, base: UInt64, maximum: UInt64?) -> UInt64 {
        let exponent = UInt64(min(max(attempt - 1, 0), 32))
        let (value, overflow) = base.multipliedReportingOverflow(by: UInt64(1) << exponent)
        let delay = overflow ? UInt64.max : value
        return maximum.map { min(delay, $0) } ?? delay
    }
}
