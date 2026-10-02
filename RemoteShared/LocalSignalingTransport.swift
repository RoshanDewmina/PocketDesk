import Foundation
import Network

/// Real local TCP signaling, mutually authenticated with the scanned/saved owner-pair secret.
/// Frames remain encrypted; discovery is never authority. The coordinator MUST independently
/// prove the attached one-hop route with LocalLinkProof before permitting any media/control.
/// No cloud DNS/rendezvous, ICE/TURN service or purchase token is consulted by this transport.
@MainActor
protocol OwnerLocalSignalingTransport: SignalingTransport {
    var onAuthenticatedLocalSignaling: ((LocalOwnerChallenge) -> Void)? { get set }
}

@MainActor
protocol MultiDeviceLocalSignalingTransport: OwnerLocalSignalingTransport {
    var hostInvitations: [PairInvitation] { get set }
    var onSelectedHostInvitation: ((PairInvitation) -> Void)? { get set }
}

@MainActor
final class LocalSignalingTransport: MultiDeviceLocalSignalingTransport {
    /// Internal rollback of the shorter deadline only; admission/recovery still fail closed.
    static let legacyAuthenticationTimeoutKey = "FarsideLocalSignalingLegacyAuthenticationTimeout"
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    /// Host/owner/session binding authenticated; NOT a free-route grant. Root-owned coordinator
    /// wiring uses this separate callback rather than accepting network-supplied route messages.
    var onAuthenticatedLocalSignaling: ((LocalOwnerChallenge) -> Void)?
    /// Empty preserves single-pair behavior. The coordinator owns the internal multi-device gate.
    var hostInvitations: [PairInvitation] = []
    /// Called after encrypted proof succeeds, before the local authentication/peer callbacks.
    var onSelectedHostInvitation: ((PairInvitation) -> Void)?
    private(set) var lastCloseReason: String?
    private let queue = DispatchQueue(label: "farside.local-signaling")
    private var generation = UUID()
    private var connectionGeneration = UUID()
    private var listener: NWListener?
    private var hostListeners: [String: NWListener] = [:]
    private var hostRegistrationAnnounced = false
    private var connection: NWConnection?
    private var invitation: PairInvitation?
    private var hostInvitationSnapshot: [PairInvitation] = []
    private var cipher: SignalCipher?
    private var isHost = false
    private var admission: LocalOwnerAdmission?
    private var response: LocalOwnerResponse?
    private var authenticated = false
    private var receivedSequence: UInt64 = 0
    private var sentSequence: UInt64 = 0
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var sending = false
    private var timeout: Task<Void, Never>?
    private let hostAuthenticationTimeoutNanoseconds: UInt64
    private let parametersOverride: NWParameters?
    private let endpointOverride: NWEndpoint?

    init(defaults: UserDefaults = .standard) {
        hostAuthenticationTimeoutNanoseconds = defaults.bool(forKey: Self.legacyAuthenticationTimeoutKey)
            ? 20_000_000_000 : 3_000_000_000
        parametersOverride = nil
        endpointOverride = nil
    }

    #if DEBUG
    init(defaults: UserDefaults, hostAuthenticationTimeoutNanoseconds: UInt64,
         parameters: NWParameters? = nil, endpoint: NWEndpoint? = nil) {
        self.hostAuthenticationTimeoutNanoseconds = defaults.bool(forKey: Self.legacyAuthenticationTimeoutKey)
            ? 20_000_000_000 : hostAuthenticationTimeoutNanoseconds
        parametersOverride = parameters
        endpointOverride = endpoint
    }
    var listeningPortForTesting: NWEndpoint.Port? { listener?.port }
    func listeningPortForTesting(ownerPairID: String) -> NWEndpoint.Port? {
        guard let listener = hostListeners[ownerPairID], case .ready = listener.state else { return nil }
        return listener.port
    }
    #endif

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        close()
        try invitation.validate(enrollment: false)
        guard invitation.durableHostID != nil, invitation.ownerPairID != nil,
              let serviceName = invitation.localServiceName else { throw RemoteError.invalidPairing }
        self.invitation = invitation; isHost = hostToken != nil
        cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        if isHost {
            guard hostInvitations.count <= 5 else { throw RemoteError.invalidPairing }
            hostInvitationSnapshot = [invitation]
            for candidate in hostInvitations {
                try candidate.validate(enrollment: false)
                guard candidate.durableHostID == invitation.durableHostID,
                      candidate.server == invitation.server, candidate.room == invitation.room,
                      candidate.localServiceName != nil, candidate.ownerPairID != nil else {
                    throw RemoteError.invalidPairing
                }
                if let existing = hostInvitationSnapshot.first(where: { $0.ownerPairID == candidate.ownerPairID }) {
                    guard existing == candidate else { throw RemoteError.invalidPairing }
                } else {
                    guard !hostInvitationSnapshot.contains(where: {
                        $0.localServiceName?.lowercased() == candidate.localServiceName?.lowercased()
                    }) else {
                        throw RemoteError.invalidPairing
                    }
                    hostInvitationSnapshot.append(candidate)
                }
            }
            guard hostInvitationSnapshot.count <= 5 else { throw RemoteError.invalidPairing }
        }
        let run = generation
        let parameters = parametersOverride ?? NWParameters.tcp
        if parametersOverride == nil {
            parameters.includePeerToPeer = false
            // No routed/cellular signaling can earn free media. The actual link proof remains mandatory.
            parameters.prohibitedInterfaceTypes = [.cellular, .loopback, .other]
        }
        if isHost {
            do {
                for (index, candidate) in hostInvitationSnapshot.enumerated() {
                    guard let pairID = candidate.ownerPairID, let name = candidate.localServiceName else {
                        throw RemoteError.invalidPairing
                    }
                    let listener = try NWListener(using: parameters)
                    hostListeners[pairID] = listener
                    if index == 0 { self.listener = listener }
                    listener.service = NWListener.Service(name: name, type: LocalMacDiscovery.serviceType, domain: "local.")
                    listener.newConnectionHandler = { [weak self] incoming in
                        Task { @MainActor in
                            guard let self, self.generation == run, self.hostRegistrationAnnounced, !self.authenticated else { incoming.cancel(); return }
                            // All device services share one connection slot. Pending TCP is not authority.
                            self.resetConnection()
                            self.attach(incoming, run: run, hostInvitation: candidate)
                        }
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.generation == run else { return }
                            switch state {
                            case .ready:
                                if index == 0 && !self.hostRegistrationAnnounced {
                                    self.hostRegistrationAnnounced = true
                                    self.onMessage?(RelayMessage(type: "registered", version: 1))
                                }
                            case .failed: self.lost("Local listener unavailable")
                            default: break
                            }
                        }
                    }
                }
                // Construct every listener before starting any; partial setup failures close all.
                for listener in hostListeners.values { listener.start(queue: queue) }
            } catch {
                close()
                throw error
            }
        } else {
            let endpoint = endpointOverride ?? NWEndpoint.service(name: serviceName, type: LocalMacDiscovery.serviceType, domain: "local.", interface: nil)
            attach(NWConnection(to: endpoint, using: parameters), run: run)
        }
    }

    private func attach(_ connection: NWConnection, run: UUID, hostInvitation: PairInvitation? = nil) {
        self.connection = connection
        let connectionRun = connectionGeneration
        timeout = Task { [weak self] in
            guard let self else { return }
            let deadline = self.isHost ? self.hostAuthenticationTimeoutNanoseconds : 20_000_000_000
            try? await Task.sleep(nanoseconds: deadline)
            guard !Task.isCancelled, self.generation == run,
                  self.isCurrentConnection(connectionRun), !self.authenticated else { return }
            self.lostConnection("Local authentication timed out")
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, self.generation == run, self.isCurrentConnection(connectionRun),
                      let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.receiveHeader(run: connectionRun)
                    if self.isHost {
                        do {
                            guard let invitation = hostInvitation else { throw RemoteError.invalidPairing }
                            try self.challengeHostInvitation(invitation)
                        } catch { self.lostConnection("Local challenge failed") }
                    }
                case .failed, .cancelled: self.lostConnection("Local connection closed")
                default: break
                }
            }
        }
        // Unsafe interface changes stop signaling immediately. LocalLinkProof separately pins the
        // exact physical interface/address and stops media on any change of that admitted route.
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            Task { @MainActor in
                guard let self, self.generation == run, self.isCurrentConnection(connectionRun),
                      let connection, self.connection === connection else { return }
                if self.authenticated && (path.status != .satisfied || path.usesInterfaceType(.other)
                    || path.usesInterfaceType(.cellular) || path.usesInterfaceType(.loopback)) {
                    self.lostConnection("Local route changed")
                }
            }
        }
        connection.start(queue: queue)
    }

    private func challengeHostInvitation(_ invitation: PairInvitation) throws {
        self.invitation = invitation
        cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let challenge = try LocalOwnerChallenge.make(invitation: invitation)
        admission = LocalOwnerAdmission(challenge: challenge)
        try write(kind: "localChallenge", body: JSONEncoder().encode(challenge), challenge: challenge, sequence: 0)
    }

    func send(_ message: RelayMessage) {
        guard authenticated, message.type == "signal", let challenge = admission?.challenge ?? response?.challenge else {
            lost("Local signaling send refused"); return
        }
        do {
            guard sentSequence < UInt64.max else { throw RemoteError.stale }
            sentSequence += 1
            try write(kind: "localSignal", body: JSONEncoder().encode(message), challenge: challenge, sequence: sentSequence)
        } catch { lost("Local signaling send failed") }
    }

    private func write(kind: String, body: Data, challenge: LocalOwnerChallenge, sequence: UInt64) throws {
        guard let cipher, connection != nil else { throw RemoteError.invalidMessage }
        let message = ProtectedMessage(kind: kind, request: challenge.hostID, session: challenge.nonce, sequence: sequence, body: body)
        let payload = Data(try cipher.seal(message, sender: isHost ? "host" : "client").utf8)
        let frame = try LocalSignalFraming.header(length: payload.count) + payload
        guard pending.count < 64, pendingBytes + frame.count <= 1024 * 1024 else { throw RemoteError.backpressure }
        pending.append(frame); pendingBytes += frame.count
        flush(run: connectionGeneration)
    }

    private func flush(run: UUID) {
        guard !sending, let connection, let next = pending.first else { return }
        sending = true
        connection.send(content: next, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.isCurrentConnection(run) else { return }
                self.sending = false
                guard error == nil else { self.lostConnection("Local signaling write failed"); return }
                self.pending.removeFirst(); self.pendingBytes -= next.count
                self.flush(run: run)
            }
        })
    }

    private func receiveHeader(run: UUID) {
        readExactly(4, run: run) { [weak self] header in
            guard let self else { return }
            do {
                let length = try LocalSignalFraming.length(header)
                self.readExactly(length, run: run) { [weak self] data in
                    guard let self else { return }
                    do { try self.receive(data); if self.isCurrentConnection(run) { self.receiveHeader(run: run) } }
                    catch { self.lostConnection("Local signaling authentication failed") }
                }
            } catch { self.lostConnection("Invalid local signaling frame") }
        }
    }

    private func readExactly(_ count: Int, run: UUID, done: @escaping (Data) -> Void) {
        connection?.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.isCurrentConnection(run) else { return }
                guard error == nil, !complete, let data, data.count == count else {
                    self.lostConnection("Local signaling read failed"); return
                }
                done(data)
            }
        }
    }

    private func receive(_ data: Data) throws {
        guard let cipher, let invitation, let text = String(data: data, encoding: .utf8) else { throw RemoteError.invalidMessage }
        let packet = try cipher.open(text, sender: isHost ? "client" : "host")
        guard packet.request == invitation.durableHostID, let body = packet.body else { throw RemoteError.invalidMessage }
        if !authenticated {
            guard packet.sequence == 0 else { throw RemoteError.stale }
            switch packet.kind {
            case "localChallenge" where !isHost && response == nil:
                let challenge = try JSONDecoder().decode(LocalOwnerChallenge.self, from: body)
                try challenge.validate(invitation: invitation)
                guard packet.session == challenge.nonce else { throw RemoteError.stale }
                let response = try LocalOwnerResponse.make(challenge: challenge, invitation: invitation)
                self.response = response
                try write(kind: "localProof", body: JSONEncoder().encode(response), challenge: challenge, sequence: 0)
            case "localProof" where isHost:
                let proof = try JSONDecoder().decode(LocalOwnerResponse.self, from: body)
                guard packet.session == admission?.challenge.nonce else { throw RemoteError.stale }
                try admission?.accept(proof, invitation: invitation)
                guard admission?.consumed == true else { throw RemoteError.stale }
                try write(kind: "localAck", body: JSONEncoder().encode(proof), challenge: proof.challenge, sequence: 0)
                didAuthenticate(proof.challenge)
            case "localAck" where !isHost:
                let proof = try JSONDecoder().decode(LocalOwnerResponse.self, from: body)
                guard let response, proof == response, packet.session == response.challenge.nonce else { throw RemoteError.stale }
                try proof.validate(expected: response.challenge, invitation: invitation)
                didAuthenticate(proof.challenge)
            default: throw RemoteError.invalidMessage
            }
            return
        }
        guard let challenge = admission?.challenge ?? response?.challenge,
              packet.session == challenge.nonce, packet.kind == "localSignal",
              packet.sequence > receivedSequence else { throw RemoteError.stale }
        let message = try JSONDecoder().decode(RelayMessage.self, from: body)
        // No peer can impersonate cloud policy, ICE, entitlement, registration or revocation.
        guard message.type == "signal", message.payload != nil else { throw RemoteError.invalidMessage }
        receivedSequence = packet.sequence
        onMessage?(message)
    }

    private func didAuthenticate(_ challenge: LocalOwnerChallenge) {
        authenticated = true; timeout?.cancel(); timeout = nil
        let run = connectionGeneration
        if isHost, let invitation { onSelectedHostInvitation?(invitation) }
        guard isCurrentConnection(run), authenticated else { return }
        // Callback runs before `peer`; coordinator must arm ONLY its local-proof requirement here.
        onAuthenticatedLocalSignaling?(challenge)
        guard isCurrentConnection(run), authenticated else { return }
        if !isHost { onMessage?(RelayMessage(type: "registered", version: 1)) }
        onMessage?(RelayMessage(type: "ice", servers: [], policy: "all"))
        onMessage?(RelayMessage(type: "peer", online: true))
    }

    private func lost(_ reason: String) {
        lastCloseReason = reason; close(); onClose?()
    }
    private func isCurrentConnection(_ run: UUID) -> Bool {
        connectionGeneration == run && connection != nil
    }
    private func lostConnection(_ reason: String) {
        if isHost && !authenticated && listener != nil {
            lastCloseReason = reason
            resetConnection()
        } else {
            lost(reason)
        }
    }
    private func resetConnection() {
        // Retire callbacks before cancellation can enqueue a final read/write/state completion.
        connectionGeneration = UUID(); timeout?.cancel(); timeout = nil
        connection?.cancel(); connection = nil
        admission = nil; response = nil; authenticated = false
        receivedSequence = 0; sentSequence = 0; pending.removeAll(); pendingBytes = 0; sending = false
    }
    func close() {
        generation = UUID()
        for listener in hostListeners.values { listener.cancel() }
        hostListeners.removeAll(); hostRegistrationAnnounced = false; listener = nil
        resetConnection()
        cipher = nil; invitation = nil
        hostInvitationSnapshot.removeAll()
    }
}
