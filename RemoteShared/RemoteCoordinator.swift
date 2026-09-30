import Foundation
import Combine
import os
import WebRTC

@MainActor
final class RemoteCoordinator: ObservableObject {
    @Published var status = "Not connected" {
        didSet {
            guard status != oldValue else { return }
            SessionLog.log.info("\(self.isHost ? "host" : "phone", privacy: .public) status: \(self.status, privacy: .public)")
        }
    }
    @Published var awaitingApproval = false
    @Published var connected = false
    @Published private(set) var hostRegistered = false
    /// The signaling connection dropped and a retry is pending or in flight; cleared once the
    /// service registers this device again, a session connects, or the coordinator stops.
    @Published private(set) var reconnecting = false
    /// Why the signaling connection last dropped, for diagnostics.
    private(set) var signalingLossReason: String?
    @Published var remoteVideo: RTCVideoTrack?
    @Published var hasRelay = false
    @Published var diagnostics = "Route not measured"
    /// Stage counters from the most recent local-link proof; no keys, nonces or addresses.
    @Published private(set) var localProofSummary: String?
    var forceRelay = false
    var onAuthenticated: (() -> Void)?
    var onControl: ((Data) -> Void)?
    var onEnded: (() -> Void)?
    /// Phone only: the current Farside Anywhere token, read at each registration. Nil (no plan, or
    /// not verified) still registers; the service decides what the room may use.
    var entitlementToken: (() -> String?)?
    /// Phone owner may suspend new sessions while server-data removal is pending.
    var startAllowed: (() -> Bool)?
    /// An explicit pairing action may resume after fully completed server removal.
    /// Pending cleanup must throw before the invitation or connection changes.
    var prepareForEnrollment: (() throws -> Void)?
    /// Phone only: list `remote.1`, so the service reports `access` and answers a missing or refused
    /// token with a non-closing `entitlement_required` (Backend/ENTITLEMENT-CONTRACT.md §4).
    var advertisesRemoteAccess = false
    /// Set only for an explicitly allowlisted private legacy service. Public services must send route.1.
    var allowLegacyPrivateRoute = false
    /// Phone: the mode this connection asks for. Couch lists no `remote.1` and sends no entitlement,
    /// so the service publishes a local route and both peers run the one-hop proof.
    var sessionModeRequest: SessionMode = .picture
    /// Host: the mode the phone asked for in this session's `acceptedAck`.
    private(set) var peerRequestedMode: SessionMode = .picture
    var routeIsLocal: Bool {
        guard routeArmed, let routePolicy, routePolicy.expiresAt > Date() else { return false }
        return routePolicy.access == .local
    }
    var provenLocalLinkActive: Bool { media?.provenLocalLinkActive == true }
    /// Phone: what the service allowed this registration, "remote" or "local"; nil when it did not say.
    @Published private(set) var serviceAccess: String?
    /// Phone: the service asked for Farside Anywhere during this attempt. The session continues on
    /// the routes permitted by the service and clients; empty ICE alone is not a LAN boundary.
    @Published private(set) var entitlementRequired = false
    var media: PeerMedia?
    private(set) var hostPair: HostPair?
    private(set) var invitation: PairInvitation?
    /// Sanitized mutation phase and Security status only; never pairing data.
    private(set) var pairingRemovalFailure: String?
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
    private var routePolicy: ServerRoutePolicy?
    private var routeArmed = false
    /// Epochs retired on this signaling connection cannot be replayed after a peer leaves.
    private var routeEpochsSeen: Set<String> = []
    /// Current server-authenticated room epoch for ActivityKit registration; nil before policy
    /// admission, after peer departure, or after its deadline.
    var routePolicyEpoch: String? {
        guard routeArmed, let routePolicy, routePolicy.expiresAt > Date() else { return nil }
        return routePolicy.epoch
    }
    private var routeExpiry: Task<Void, Never>?
    private var localLinkProof: LocalLinkProof?
    private var pendingLocalEndpoint: LocalProbeEndpoint?
    private var localProofTimeout: Task<Void, Never>?
    /// Media signals that arrive after this side's proof started but before it finished; the faster
    /// side can prove first and send its offer. Bounded and dropped with the session.
    private var pendingMediaSignals: [MediaSignal] = []
    private var controlNotConnectedRefusals = 0
    private(set) var controlRejected: [String: Int] = [:]
    /// Control-channel counts for Copy Diagnostics; no content.
    var inputSummary: String {
        let rejected = controlRejected.keys.sorted().map { "\($0)=\(controlRejected[$0] ?? 0)" }.joined(separator: " ")
        return (media?.controlCounters.summary ?? "no media") + " notConnected=\(controlNotConnectedRefusals) rejected=[\(rejected)]"
    }
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryCount = 0
    private let retryLimit: Int
    private let retryBaseNanoseconds: UInt64
    private let sessionLossRetryLimit: Int?
    private let maximumRetryDelayNanoseconds: UInt64?
    /// A sharing Mac never gives up on the service by itself; only a phone has a retry budget.
    private let retriesIndefinitely: Bool
    static let hostRetryBaseNanoseconds: UInt64 = 500_000_000
    static let hostMaximumRetryDelayNanoseconds: UInt64 = 60_000_000_000
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
        retriesIndefinitely: Bool = false,
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
        self.retriesIndefinitely = retriesIndefinitely
        self.registrationStableNanoseconds = registrationStableNanoseconds
        relay.onMessage = { [weak self] message in self?.receive(message) }
        relay.onClose = { [weak self] in self?.connectionLost() }
    }
    func sendControl(_ action: RemoteAction) -> Bool {
        guard connected, !session.isEmpty else {
            controlNotConnectedRefusals += 1
            if InputLog.sampled(controlNotConnectedRefusals) {
                InputLog.log.error("\(self.isHost ? "host" : "phone", privacy: .public) send refused: not connected (\(action.action, privacy: .public)) count=\(self.controlNotConnectedRefusals, privacy: .public)")
            }
            return false
        }
        do {
            try action.validate()
            sentControl += 1
            let data = try JSONEncoder().encode(ControlPacket(session: session, sequence: sentControl, action: action))
            guard media?.sendControl(data) == true else {
                InputLog.log.error("\(self.isHost ? "host" : "phone", privacy: .public) control send failed (\(action.action, privacy: .public)); ending session")
                peerDisconnected(); return false
            }
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
        let parsed = try PairInvitation.parse(code)
        try prepareForEnrollment?()
        stop()
        invitation = parsed
        #if DEBUG
        e2eEnrolling = true
        #endif
        start()
    }
    func start() {
        start(resetRetryBudget: true)
    }
    private func start(resetRetryBudget: Bool) {
        guard startAllowed?() != false else {
            status = "Server removal is pending. Retry or cancel removal first."
            return
        }
        guard let invitation else { status = "Pair with your Mac first"; return }
        do {
            if isHost, let pair = hostPair, !pair.paired { try invitation.validate() }
            else { try invitation.validate(enrollment: false) }
            if resetRetryBudget { retryCount = 0; recoveringLiveSession = false; reconnecting = false }
            stopped = false
            retry?.cancel(); retry = nil
            cancelRenewal()
            resetSession()
            cipher = try SignalCipher(key: invitation.key, room: invitation.room)
            status = "Connecting securely…"
            registeredInvitation = invitation
            routeExpiry?.cancel(); routeExpiry = nil
            routePolicy = nil; routeArmed = false
            routeEpochsSeen.removeAll()
            serviceAccess = nil
            entitlementRequired = false
            var features = advertisesRenewal ? [SignalingFeature.renewal] : []
            features.append(SignalingFeature.route)
            if !isHost && advertisesRemoteAccess && sessionModeRequest != .couch {
                features.append(SignalingFeature.remoteAccess)
            }
            try relay.connect(invitation: invitation, hostToken: hostPair?.hostToken, features: features,
                              entitlement: isHost || sessionModeRequest == .couch ? nil : entitlementToken?())
            setTimeout()
        } catch { fail(error.localizedDescription) }
    }
    func approve() {
        guard isHost, awaitingApproval, proofReceived, (hostPair?.invitation.expires ?? .distantPast) > Date() else { fail("Pairing expired. Create a fresh code."); return }
        awaitingApproval = false
        acceptSession()
    }
    func reject() { fail("Pairing was declined on the Mac") }
    @discardableResult
    func revoke() -> Bool {
        pairingRemovalFailure = nil
        stop()
        var phase = "delete"
        do {
            try store.delete()
            phase = "verify"
            let pairingRemains: Bool
            if isHost { pairingRemains = try store.read(HostPair.self) != nil }
            else { pairingRemains = try store.read(PairInvitation.self) != nil }
            guard !pairingRemains else {
                pairingRemovalFailure = "verify:record-remains"
                status = "Pairing could not be removed. Try removing it again."
                return false
            }
            hostPair = nil; invitation = nil
            status = "Pairing removed. Old credentials no longer work."
            return true
        } catch {
            if let remoteError = error as? RemoteError, case let .keychain(code) = remoteError {
                pairingRemovalFailure = "\(phase):\(code)"
            } else { pairingRemovalFailure = "\(phase):failed" }
            status = error.localizedDescription
            return false
        }
    }
    /// Completes an already confirmed phone unlink without deleting a replacement pairing.
    /// The persistent read is authoritative: a locked Keychain must remain retryable.
    func phonePairingForRemoval() throws -> PairInvitation? {
        guard !isHost else { return nil }
        return try store.read(PairInvitation.self) ?? invitation
    }

    func removePhonePairingIfMatching(room: String, server: String, tokenDigest: String) throws -> Bool {
        guard !isHost else { return false }
        func matches(_ pair: PairInvitation) -> Bool {
            pair.room == room && pair.server == server && SecureRandom.digest(pair.token) == tokenDigest
        }
        if let saved = try store.read(PairInvitation.self) {
            guard matches(saved) else {
                // A different persisted pairing won during the server request. Retire stale RAM
                // authority for the removed Mac without interrupting a newer enrollment.
                if invitation == nil || invitation.map(matches) == true {
                    stop()
                    invitation = saved
                    status = "Ready to connect to your paired Mac"
                }
                return false
            }
            try store.delete()
        }
        if let current = invitation, matches(current) {
            stop()
            invitation = nil
            status = "Pairing removed. Pair again to connect."
        }
        return invitation == nil
    }
    func stop() {
        stopped = true; retry?.cancel(); retry = nil; retryCount = 0; recoveringLiveSession = false
        reconnecting = false
        routeExpiry?.cancel(); routeExpiry = nil; routePolicy = nil; routeArmed = false
        routeEpochsSeen.removeAll()
        cancelRenewal()
        relay.close(); registeredInvitation = nil; resetSession(); status = "Disconnected"
    }
    /// Connected, connecting, or waiting to retry.
    var isRunning: Bool { !stopped }
    /// Retries attempted since the last stable registration or connection.
    var retryAttempt: Int { retryCount }

    /// Asks the signaling connection to prove it is alive; a dead one closes and retries.
    func checkSignalingLiveness() {
        guard !stopped else { return }
        relay.checkLiveness()
    }

    /// The network path changed. A registration may be riding a path that no longer exists, so
    /// check it; a retry waiting out its backoff tries the new path at once.
    func networkPathChanged() {
        guard !stopped else { return }
        guard let pending = retry else { relay.checkLiveness(); return }
        pending.cancel(); retry = nil
        start(resetRetryBudget: false)
    }
    /// Ends only the current phone session. A registered host keeps listening for its paired phone.
    func dropPeerSession() {
        guard isHost, connected || media != nil else { return }
        peerDisconnected()
    }
    private func resetSession() {
        timeout?.cancel(); timeout = nil
        localProofTimeout?.cancel(); localProofTimeout = nil
        if let proof = localLinkProof { localProofSummary = proof.stageSummary() }
        localLinkProof?.close(); localLinkProof = nil
        pendingMediaSignals.removeAll()
        pendingLocalEndpoint = nil
        registrationStability?.cancel(); registrationStability = nil
        media?.close(); media = nil
        remoteVideo = nil; connected = false; awaitingApproval = false; hostRegistered = false
        diagnostics = "Route not measured"
        sentControl = 0; receivedControl = 0
        request = ""; session = ""; sequence = 0; guardState = nil; proofReceived = false
        peerRequestedMode = .picture
        onEnded?()
    }
    private func receive(_ message: RelayMessage) {
        do {
            switch message.type {
            case "route":
                if routePolicy == nil, routeEpochsSeen.contains(message.epoch ?? "") {
                    throw RemoteError.stale
                }
                guard let room = invitation?.room,
                      let policy = ServerRoutePolicy.accept(message, room: room, previous: routePolicy) else {
                    throw RemoteError.invalidMessage
                }
                if let old = routePolicy, old.access != policy.access, media != nil {
                    fail("Route access changed. Reconnect to verify the new route.")
                    return
                }
                routePolicy = policy; routeArmed = true; routeEpochsSeen.insert(policy.epoch)
                serviceAccess = policy.access.rawValue
                SessionLog.log.info("route policy access=\(policy.access.rawValue, privacy: .public) expiresIn=\(Int(policy.expiresAt.timeIntervalSinceNow), privacy: .public)s revision=\(policy.revision, privacy: .public)")
                routeExpiry?.cancel()
                routeExpiry = Task { [weak self] in
                    let delay = max(0, policy.expiresAt.timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, let self, self.routePolicy == policy else { return }
                    SessionLog.log.error("route policy expired")
                    self.fail("Route authorization expired. Reconnect to renew access.")
                }
            case "registered":
                if isHost {
                    hostRegistered = true; reconnecting = false; timeout?.cancel(); status = "Ready for your paired phone"
                    resetRetryBudgetAfterStableRegistration()
                }
                // The legacy access hint is advisory; only `route` authorizes media.
                if allowLegacyPrivateRoute, !isHost, let access = message.access { serviceAccess = access }
                beginRenewal(message.renew)
            case "renewed":
                // The lease is still extended; without fresh servers the relay ends when its credentials do.
                if !isHost, message.code == "entitlement_required" { entitlementRequired = true }
                receiveRenewal(message)
            case "ice":
                servers = message.servers ?? []
                guard servers.count <= 8, servers.allSatisfy({ $0.urls.count <= 8 }),
                      NativeRelayPolicy.isValid(message.policy) else { throw RemoteError.invalidMessage }
                relayPolicy = message.policy
                hasRelay = NativeRelayPolicy.hasRelay(servers)
            case "peer":
                if message.online == true {
                    guard (routeArmed && (routePolicy?.expiresAt ?? .distantPast) > Date()) || allowLegacyPrivateRoute else {
                        fail("The connection service did not authorize this route. Update Farside and retry.")
                        return
                    }
                    if !isHost {
                        resetSession(); request = try SecureRandom.token()
                        send(kind: "request", handshake: true); status = "Authenticating your Mac…"; setTimeout()
                    }
                } else { peerDisconnected() }
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
                if code == "upgrade_required" {
                    fail("Update Farside on both your Mac and phone to connect to this service.")
                    return
                }
                // Non-closing: `registered` (access "local") and an empty `ice` follow.
                if !isHost, code == "entitlement_required" { entitlementRequired = true; return }
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
        case "localEndpoint":
            guard routePolicy?.access == .local, let body = message.body else { throw RemoteError.invalidMessage }
            let endpoint = try JSONDecoder().decode(LocalProbeEndpoint.self, from: body)
            guard pendingLocalEndpoint == nil else { throw RemoteError.stale }
            pendingLocalEndpoint = endpoint
            LocalLinkProof.log.info("peer endpoint received; proof exists=\(self.localLinkProof != nil, privacy: .public)")
            localLinkProof?.setPeer(endpoint)
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
            guard !stopped else { return }
            send(kind: "acceptedAck", body: SessionModeRequest.body(for: sessionModeRequest))
        case "acceptedAck" where isHost:
            guard proofReceived, media == nil, !awaitingApproval else { throw RemoteError.stale }
            peerRequestedMode = SessionModeRequest.mode(fromAcceptedAckBody: message.body)
            prepareMedia()
        case "media":
            guard let body = message.body else { throw RemoteError.invalidMessage }
            let signal = try JSONDecoder().decode(MediaSignal.self, from: body)
            if let media { media.receive(signal); return }
            guard localLinkProof != nil, pendingMediaSignals.count < 64 else { throw RemoteError.invalidMessage }
            SessionLog.log.info("media \(signal.kind, privacy: .public) held until the local proof finishes")
            pendingMediaSignals.append(signal)
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
        guard (routeArmed && (routePolicy?.expiresAt ?? .distantPast) > Date()) || allowLegacyPrivateRoute else {
            fail("The connection route is no longer authorized.")
            return
        }
        if !isHost, sessionModeRequest == .couch, routePolicy?.access != .local {
            fail(CouchCopy.phoneRefusedStatus)
            return
        }
        if let routePolicy, routePolicy.access == .local {
            beginLocalProof(routePolicy)
            return
        }
        finishMedia(localLink: nil)
    }

    private func beginLocalProof(_ policy: ServerRoutePolicy) {
        guard let key = invitation?.key, !session.isEmpty else { fail("Local link proof could not start."); return }
        let room = policy.room, epoch = policy.epoch, session = self.session
        Task { [weak self] in
            let proof = await Task.detached(priority: .userInitiated) {
                LocalLinkProof.make(room: room, epoch: epoch, session: session, pairingKey: key)
            }.value
            guard let self, !self.stopped, self.session == session,
                  self.routePolicy?.epoch == policy.epoch, self.routePolicy?.access == .local else {
                proof?.close(); return
            }
            guard let proof else {
                self.localProofSummary = "not started: no single directly attached Wi-Fi or Ethernet path"
                self.fail("No directly attached Wi-Fi or Ethernet link is available."); return
            }
            self.localLinkProof = proof
            self.localProofSummary = nil
            proof.onInvalidated = { [weak self, weak proof] in
                guard let self, let proof, self.localLinkProof === proof else { return }
                self.fail("The local network changed. Reconnect to verify the route again.")
            }
            proof.onProven = { [weak self, weak proof] link in
                guard let self, let proof, self.localLinkProof === proof,
                      self.routePolicy?.epoch == policy.epoch, self.routePolicy?.access == .local,
                      (self.routePolicy?.expiresAt ?? .distantPast) > Date() else { return }
                self.localProofTimeout?.cancel(); self.localProofTimeout = nil
                self.localProofSummary = proof.stageSummary()
                self.finishMedia(localLink: link)
            }
            self.localProofTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if let proof = self.localLinkProof {
                    LocalLinkProof.log.error("timed out after 8 s: \(proof.stageSummary(), privacy: .public)")
                }
                self.fail("The devices could not verify a directly attached local link.")
            }
            if let pending = self.pendingLocalEndpoint {
                LocalLinkProof.log.info("applying peer endpoint received before the proof existed")
                proof.setPeer(pending)
            }
            guard let data = try? JSONEncoder().encode(proof.endpoint) else { self.fail("Local link proof could not start."); return }
            self.send(kind: "localEndpoint", body: data)
        }
    }

    private func finishMedia(localLink: ProvenLocalLink?) {
        let relayOnly: Bool
        let decision = NativeRelayPolicy.decide(servers: servers, policy: relayPolicy, localForce: forceRelay)
        SessionLog.log.info("media start: relay decision=\(String(describing: decision), privacy: .public) policy=\(self.relayPolicy ?? "nil", privacy: .public) hasRelay=\(NativeRelayPolicy.hasRelay(self.servers), privacy: .public) localLink=\(localLink != nil, privacy: .public) access=\(self.routePolicy?.access.rawValue ?? "nil", privacy: .public)")
        switch decision {
        case .proceed(let force):
            relayOnly = force
        case .relayRequiredUnavailable(let serverRequired):
            fail(serverRequired ? "The connection service requires a relay, but none was provided." : "Relay-only test requires a configured TURN service.")
            return
        }
        let peer = PeerMedia(isHost: isHost, servers: servers, forceRelay: relayOnly, localLink: localLink)
        media = peer
        if isHost { peer.offer() }
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
                    guard packet.version == 1, packet.session == self.session, packet.sequence > self.receivedControl else {
                        self.controlRejected["stale", default: 0] += 1
                        InputLog.log.error("control rejected: stale version/session/sequence (seq \(packet.sequence, privacy: .public) after \(self.receivedControl, privacy: .public))")
                        throw RemoteError.stale
                    }
                    try packet.action.validate()
                    self.receivedControl = packet.sequence
                    self.onControl?(try JSONEncoder().encode(packet.action))
                } catch {
                    self.controlRejected["parse-or-validate", default: 0] += 1
                    InputLog.log.error("control rejected: \(String(describing: error), privacy: .public); ending session")
                    self.fail("Invalid control message. Session ended safely.")
                }
            }
        }
        peer.onState = { [weak self, weak peer] state in
            Task { @MainActor in
                guard let self, let peer, self.media === peer else { return }
                self.status = state
                if state == "connected" {
                    guard !self.connected else { return }
                    self.connected = true; self.retryCount = 0; self.recoveringLiveSession = false
                    self.reconnecting = false
                    self.timeout?.cancel(); self.onAuthenticated?()
                } else if state == "failed" || state == "disconnected" || state == "closed" {
                    SessionLog.log.error("media state \(state, privacy: .public); ending session")
                    self.peerDisconnected()
                }
            }
        }
        let held = pendingMediaSignals
        pendingMediaSignals.removeAll()
        for signal in held { peer.receive(signal) }
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
        SessionLog.log.error("peerDisconnected (connected=\(self.connected, privacy: .public))")
        routeExpiry?.cancel(); routeExpiry = nil; routePolicy = nil; routeArmed = false
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
        SessionLog.log.error("connectionLost: \(finalStatus, privacy: .public) signaling=\(self.relay.lastCloseReason ?? "nil", privacy: .public) stopped=\(self.stopped, privacy: .public) retry=\(self.retryCount, privacy: .public)")
        guard !stopped else { return }
        // A media and signaling failure can report the same outage independently.
        // The first event already closed the old transport and scheduled a retry.
        guard retry == nil else { return }
        if connected && sessionLossRetryLimit != nil { recoveringLiveSession = true }
        cancelRenewal()
        routeExpiry?.cancel(); routeExpiry = nil; routePolicy = nil; routeArmed = false
        routeEpochsSeen.removeAll()
        signalingLossReason = relay.lastCloseReason ?? "connection ended"
        relay.close(); registeredInvitation = nil; resetSession()
        let limit = recoveringLiveSession ? max(retryLimit, sessionLossRetryLimit ?? retryLimit) : retryLimit
        guard retriesIndefinitely || retryCount < limit else {
            stopped = true
            recoveringLiveSession = false
            reconnecting = false
            status = finalStatus
            return
        }
        retryCount += 1
        reconnecting = true
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
        SessionLog.log.error("fail: \(message, privacy: .public)")
        stopped = true; retry?.cancel(); retry = nil; recoveringLiveSession = false
        reconnecting = false
        cancelRenewal()
        routeExpiry?.cancel(); routeExpiry = nil; routePolicy = nil; routeArmed = false
        routeEpochsSeen.removeAll()
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
