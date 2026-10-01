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
    private(set) var controlArrivedFrames: Int?
    private(set) var controlArrivedAt: TimeInterval?
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
    @Published private(set) var localOnly = false
    /// Changing transport retires the whole old session before a new route can be authorized.
    func setLocalOnly(_ enabled: Bool) {
        guard localOnly != enabled else { return }
        stop()
        localOnly = enabled
        status = enabled ? "Ready to connect on this local network" : "Ready to connect"
    }
    var routeIsLocal: Bool {
        if localOnly { return ownerLocalEpoch != nil && !stopped }
        guard routeArmed, let routePolicy, routePolicy.expiresAt > Date() else { return false }
        return routePolicy.access == .local
    }
    var provenLocalLinkActive: Bool { media?.provenLocalLinkActive == true }
    /// Phone: what the service allowed this registration, "remote" or "local"; nil when it did not say.
    @Published private(set) var serviceAccess: String?
    /// Phone: the service asked for Farside Anywhere during this attempt. The session continues on
    /// the routes permitted by the service and clients; empty ICE alone is not a LAN boundary.
    @Published private(set) var entitlementRequired = false
    /// Host: a missing grant that stops this Mac accepting any session (see `MacShareBlocker`).
    var shareBlocker: (() -> MacShareBlocker?)?
    /// Host: what the current phone listed in its handshake request.
    private(set) var peerFeatures: Set<String> = []
    /// Phone: the grant the Mac said it is missing when it refused this attempt.
    @Published private(set) var macBlocker: MacShareBlocker?
    /// Host: the paired phone's display name as it last reported it, if it ever did (D39).
    @Published private(set) var peerName: String?
    /// Phone: the name this device sends its Mac inside the sealed `acceptedAck`.
    var localDisplayName: String?
    var media: PeerMedia?
    /// Receives the `file` channel's chunks and buffer changes for every session's peer.
    weak var fileTransfer: FileTransferEngine?
    private(set) var hostPair: HostPair?
    private(set) var invitation: PairInvitation?
    /// Sanitized mutation phase and Security status only; never pairing data.
    private(set) var pairingRemovalFailure: String?
    // Exact scanned QR context survives only this enrollment attempt. It must never
    // be reclassified as an authenticated credential rotation after a retry or End.
    private var scannedEnrollment: PairInvitation?
    private var pendingPhoneReplacementApproval: PhoneTrustReplacementApproval?
    private let isHost: Bool
    private let store: any PairPersistence
    private let hostIdentityStore: HostIdentityStore?
    private let cloudRelay: any SignalingTransport
    private let localRelay: any OwnerLocalSignalingTransport
    private var relay: any SignalingTransport { localOnly ? localRelay : cloudRelay }
    private var signalingRun = UUID()
    // A local owner handshake is distinct from a cloud route lease. It still requires
    // continuous physical one-hop proof and never supplies an ActivityKit server epoch.
    private var ownerLocalEpoch: String?
    /// Correlation only; route/grant authorization below remains the authority.
    /// Read only the trust store that admitted this coordinator, including injected tests.
    var presentationHostTrust: PhoneHostTrust? {
        guard !isHost, let phone = store as? PhonePairPersistence,
              let host = try? phone.trust.snapshot().selected, host.invitation == invitation else { return nil }
        return host
    }
    var onPresentationInvalidated: (() -> Void)?
    private(set) var presentationSessionID = UUID()
    private(set) var presentationTrackID = UUID()
    /// Current monotonic media lease; local media requires continuous physical proof.
    func presentationDeadline(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard !stopped, connected, media != nil, cipher != nil, (!isHost || proofReceived), guardState != nil, routeAuthorized else { return nil }
        if localOnly || routePolicy?.access == .local {
            guard provenLocalLinkActive else { return nil }
        }
        let seconds = localOnly || allowLegacyPrivateRoute ? 2 : min(2, max(0, routePolicy?.expiresAt.timeIntervalSinceNow ?? 0))
        guard seconds > 0 else { return nil }
        return now + seconds
    }
    private var routeAuthorized: Bool {
        if localOnly { return !stopped && ownerLocalEpoch != nil }
        return (routeArmed && (routePolicy?.expiresAt ?? .distantPast) > Date()) || allowLegacyPrivateRoute
    }
    private var localRouteEpoch: String? {
        if localOnly { return routeAuthorized ? ownerLocalEpoch : nil }
        guard routeArmed, routePolicy?.access == .local,
              (routePolicy?.expiresAt ?? .distantPast) > Date() else { return nil }
        return routePolicy?.epoch
    }
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
    var onGuestAuthorityEnded: (() -> Void)?
    var onGuest: ((GuestRelayFrame) -> Void)?
    private var guestServiceAvailable = false
    private var guestResetGate = GuestServiceResetGate()
    var guestOwnerContext: (session: String, deadline: Date)? {
        guard isHost, guestServiceAvailable, !localOnly, !stopped, connected, routeArmed, let routePolicy, routePolicy.access == .remote,
              routePolicy.expiresAt > Date(), SecureRandom.isToken(session) else { return nil }
        return (session, routePolicy.expiresAt)
    }
    @discardableResult
    func sendGuest(_ guest: GuestRelayFrame) -> Bool {
        guard guestOwnerContext != nil else { return false }
        return (cloudRelay as? SignalingClient)?.sendGuest(RelayMessage(type: "guest", guest: guest, version: 1)) ?? false
    }
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
    private var localProofPreparation: Task<Void, Never>?
    private var localProofPreparationID: UUID?
    private var pendingLocalEndpoint: LocalProbeEndpoint?
    private var localProofTimeout: Task<Void, Never>?
    private let localProofTimeoutNanoseconds: UInt64
    private let localProofBuilder: @Sendable (String, String, String, Data) -> LocalLinkProof?
    /// Host: why the most recent phone session attempt ended without stopping sharing.
    @Published private(set) var lastSessionFailure: String?
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
    var allowsCausalInput = true
    var onCausalInput: ((InputCausalEnvelope, RemoteAction?) -> Void)?
    var onCausalContext: ((InputCausalEnvelope) -> Void)?
    var onCausalRejected: ((RemoteAction) -> Void)?
    /// Exact-current-context cleanup before publishing a recovery anchor.
    var onCausalRecovery: (() -> Void)?
    private var hostInputEpoch: UInt64 = 0
    private var hostInputAnchor = InputCausalEnvelope.identity()
    private var causalContext: InputCausalEnvelope?
    private var offeredInputNonce: String?
    private var offeredInputEpoch: UInt64 = 0
    private var inputNegotiationTimeout: Task<Void, Never>?
    private var motionPrefix = InputMotionPrefix()
    private var motionSequence: UInt64 = 0
    private var motionReplay = InputMotionReplay()
    private var deferredInput: [RemoteAction] = []
    private var deferredInputSizes: [Int] = []
    private var deferredInputBytes = 0
    private var reliableMotionOrdinal: UInt64?
    private var reliableCheckpointRetransmit: Task<Void, Never>?
    private var reliableCheckpointRetransmits = 0
    /// The host can drop a checkpoint batch without an ACK or anchor (its executor generation
    /// moved mid-batch). The ledger makes a resent prefix idempotent, so resend instead of stalling.
    static let reliableCheckpointRetransmitNanoseconds: UInt64 = 250_000_000
    private var inputRecoveryPending = false
    private var inputRecoveryTimeout: Task<Void, Never>?
    private static let maximumDeferredActions = 512
    private static let maximumDeferredSemantics = 64
    var causalInputNegotiated: Bool { causalContext != nil }
    #if DEBUG
    // Input-only fixture seam: no sockets, pairing store mutations or authorization bypass in release.
    var inputPacketSenderForTesting: ((ControlPacket) -> Bool)?
    func startInputFixtureForTesting(session: String) {
        self.session = session; connected = true; stopped = false; hostRegistered = isHost
        peerFeatures = [SessionFeature.extendedFeatureList, SessionFeature.causalInput]
    }
    func receiveInputFixtureForTesting(_ packet: ControlPacket, motion: Bool = false) throws {
        if motion {
            guard packet.session == session, packet.version == 1 else { throw RemoteError.stale }
            try packet.action.validate(); try receiveCausal(packet, motion: true)
        } else { try deliverControlPacket(packet) }
    }
    #endif
    private static let causalSemantics: Set<String> = ["click", "double", "right", "middle", "auxClick", "dragDown", "dragUp", "holdRenew", "scroll", "text", "key", "release"]
    private var moveCoalescer = PointerMoveCoalescer()
    private var moveFlush: Task<Void, Never>?
    /// Mach ms when the control message being delivered through `onControl` reached the data channel,
    /// before its main-actor hop; nil outside that call.
    private(set) var currentControlArrivalMs: Double?
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
        handshakeTimeoutNanoseconds: UInt64 = 20_000_000_000,
        localProofTimeoutNanoseconds: UInt64 = 8_000_000_000,
        hostIdentityStore: HostIdentityStore? = nil,
        localSignaling: (any OwnerLocalSignalingTransport)? = nil,
        localProofBuilder: (@Sendable (String, String, String, Data) -> LocalLinkProof?)? = nil
    ) {
        self.localProofTimeoutNanoseconds = localProofTimeoutNanoseconds
        self.localProofBuilder = localProofBuilder ?? { LocalLinkProof.make(room: $0, epoch: $1, session: $2, pairingKey: $3) }
        // Injected pair stores (including isolated tests) must not touch the owner's identity.
        self.hostIdentityStore = hostIdentityStore ?? (isHost && store == nil ? HostIdentityStore() : nil)
        self.isHost = isHost
        self.store = store ?? (isHost ? PairStore(account: "host") as any PairPersistence : PhonePairPersistence())
        self.cloudRelay = signaling ?? SignalingClient()
        self.localRelay = localSignaling ?? LocalSignalingTransport()
        self.renewalScheduler = renewalScheduler
        self.advertisesRenewal = advertisesRenewal
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.retryLimit = max(0, retryLimit)
        self.retryBaseNanoseconds = retryBaseNanoseconds
        self.sessionLossRetryLimit = sessionLossRetryLimit.map { max(0, $0) }
        self.maximumRetryDelayNanoseconds = maximumRetryDelayNanoseconds
        self.retriesIndefinitely = retriesIndefinitely
        self.registrationStableNanoseconds = registrationStableNanoseconds
        wireSignalingCallbacks()
    }
    private func wireSignalingCallbacks() {
        signalingRun = UUID()
        let run = signalingRun, local = localOnly
        let transport = relay
        transport.onMessage = { [weak self] message in
            guard let self, !self.stopped, self.signalingRun == run, self.localOnly == local else { return }
            // Owner-local transport only exposes its authenticated signal and own lifecycle;
            // cloud policy/entitlement/renewal cannot be supplied by a local peer.
            if local && !["registered", "ice", "peer", "signal"].contains(message.type) {
                self.sessionFailed("Unexpected local signaling message."); return
            }
            self.receive(message)
        }
        transport.onClose = { [weak self] in
            guard let self, self.signalingRun == run, self.localOnly == local else { return }
            self.connectionLost()
        }
        localRelay.onAuthenticatedLocalSignaling = { [weak self] challenge in
            guard let self, !self.stopped, local, self.localOnly, self.signalingRun == run,
                  let invitation = self.invitation else { return }
            do {
                try challenge.validate(invitation: invitation)
                guard self.ownerLocalEpoch == nil, !self.routeEpochsSeen.contains(challenge.epoch) else { throw RemoteError.stale }
                self.ownerLocalEpoch = challenge.epoch
                self.routeEpochsSeen.insert(challenge.epoch)
                self.serviceAccess = "local"
            } catch { self.sessionFailed("Local owner authentication failed.") }
        }
    }
    func setHostInputEpoch(_ epoch: UInt64) {
        guard isHost, hostInputEpoch != epoch else { return }
        hostInputEpoch = epoch; hostInputAnchor = InputCausalEnvelope.identity()
        if var context = causalContext {
            context.kind = "anchor"; context.epoch = epoch; context.anchor = hostInputAnchor; context.applied = 0; context.segments = []
            causalContext = context; motionReplay = InputMotionReplay()
            onCausalContext?(context)
            _ = transmit(RemoteAction(action: "heartbeat", epoch: epoch), input: context)
        }
    }

    func rebaseCausalInput() {
        guard isHost, var context = causalContext else { return }
        context.kind = "anchor"; context.anchor = InputCausalEnvelope.identity(); context.applied = 0; context.segments = []
        hostInputAnchor = context.anchor; causalContext = context; motionReplay = InputMotionReplay()
        onCausalContext?(context)
        _ = transmit(RemoteAction(action: "heartbeat", epoch: context.epoch), input: context)
    }

    @discardableResult
    func recoverCausalInput(_ context: InputCausalEnvelope) -> Bool {
        guard isHost, connected, let current = causalContext, context.nonce == current.nonce,
              context.anchor == current.anchor, context.epoch == current.epoch else { return false }
        onCausalRecovery?()
        guard let after = causalContext, after.nonce == current.nonce, after.anchor == current.anchor,
              after.epoch == current.epoch else { return false }
        rebaseCausalInput()
        return true
    }

    /// Legacy invalid input ends this peer attempt; it never suspends Mac sharing.
    func endPhoneInputSession(_ message: String) {
        guard isHost else { return }
        sessionFailed(message)
    }

    private func clearDeferredInput() {
        deferredInput.removeAll(); deferredInputSizes.removeAll(); deferredInputBytes = 0
    }
    private func enqueueDeferredInput(_ action: RemoteAction) -> Bool {
        if let last = deferredInput.last, let merged = PointerMoveCoalescer.coalescedUnsentMove(last, action),
           let oldSize = deferredInputSizes.last, let size = try? JSONEncoder().encode(merged).count {
            guard deferredInputBytes - oldSize + size <= 256 * 1024 else { return false }
            deferredInput[deferredInput.count - 1] = merged
            deferredInputSizes[deferredInputSizes.count - 1] = size
            deferredInputBytes += size - oldSize
            return true
        }
        guard deferredInput.count < Self.maximumDeferredActions,
              let size = try? JSONEncoder().encode(action).count,
              deferredInputBytes + size <= 256 * 1024 else { return false }
        if Self.causalSemantics.contains(action.action),
           deferredInput.filter({ Self.causalSemantics.contains($0.action) }).count >= Self.maximumDeferredSemantics { return false }
        deferredInput.append(action); deferredInputSizes.append(size); deferredInputBytes += size
        return true
    }

    /// A bounded queue can expire without expiring the connection. Discard unsent
    /// semantics, ask the authenticated host to release/rebase, then await its anchor.
    private func requestInputRecovery() -> Bool {
        guard !isHost, connected, var context = causalContext else { return false }
        if inputRecoveryPending { return false }
        inputRecoveryPending = true; clearDeferredInput(); clearReliableCheckpoint()
        context.kind = "rebase"; context.applied = 0; context.segments = []
        guard transmit(RemoteAction(action: "heartbeat", epoch: context.epoch), input: context) else { return false }
        inputRecoveryTimeout?.cancel()
        inputRecoveryTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.inputRecoveryPending else { return }
            self.peerDisconnected() // Preserve the normal reconnect budget.
        }
        return false
    }

    func requestCausalInput(epoch: UInt64) {
        guard !isHost, connected, epoch > 0,
              causalContext?.epoch != epoch,
              offeredInputNonce == nil || offeredInputEpoch != epoch else { return }
        if let held = moveCoalescer.flush(backlogged: false, now: ProcessInfo.processInfo.systemUptime) {
            guard transmit(held) else { return }
        }
        moveFlush?.cancel(); moveFlush = nil
        media?.allowPointerChannel()
        let nonce = InputCausalEnvelope.identity()
        clearDeferredInput() // A replacement offer cannot carry queued work from retired geometry.
        offeredInputNonce = nonce; offeredInputEpoch = epoch
        let offer = InputCausalEnvelope(kind: "offer", nonce: nonce, anchor: String(repeating: "0", count: 32), epoch: epoch)
        _ = transmit(RemoteAction(action: "heartbeat", epoch: epoch), input: offer)
        inputNegotiationTimeout?.cancel()
        inputNegotiationTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.offeredInputNonce == nonce else { return }
            self.sessionFailed("Input negotiation expired. Reconnect from the phone.")
        }
    }

    func sendInputMoves(_ actions: [RemoteAction]) -> Bool {
        guard !isHost, connected, !inputRecoveryPending else { return false }
        guard causalContext != nil else {
            if offeredInputNonce != nil {
                guard actions.allSatisfy({ $0.epoch == offeredInputEpoch }) else { return false }
                do {
                    for action in actions {
                        try action.validate()
                        guard ["move", "moveTo"].contains(action.action), action.epoch == offeredInputEpoch, enqueueDeferredInput(action) else { throw RemoteError.stale }
                    }
                    return true
                } catch { peerDisconnected(); return false }
            }
            return actions.allSatisfy { sendControl($0) }
        }
        // A geometry notification may follow its anchor on reliable control. Refuse
        // old-scope work locally without treating that normal transition as corruption.
        guard let context = causalContext, actions.allSatisfy({ $0.epoch == context.epoch }) else { return false }
        do {
            for action in actions {
                try action.validate()
                if !deferredInput.isEmpty || !motionPrefix.canAppend(action) {
                    guard enqueueDeferredInput(action) else { return requestInputRecovery() }
                } else { try motionPrefix.append(action) }
            }
            return sendMotionPrefix(reliable: !deferredInput.isEmpty)
        } catch { return requestInputRecovery() }
    }

    private func envelope(kind: String) -> InputCausalEnvelope? {
        guard var value = causalContext else { return nil }
        value.kind = kind; value.applied = motionPrefix.next; value.segments = motionPrefix.segments
        return value
    }
    private func sendMotionPrefix(reliable: Bool) -> Bool {
        guard let envelope = envelope(kind: reliable ? "barrier" : "motion") else { return false }
        if reliable {
            guard !envelope.segments.isEmpty else { return true }
            // One reliable checkpoint per ACK round-trip, even at 240 Hz. The
            // immutable on-wire prefix stays intact; only its unsent tail merges.
            if reliableMotionOrdinal != nil { return true }
            reliableMotionOrdinal = envelope.applied
            let sent = transmit(RemoteAction(action: "heartbeat", epoch: envelope.epoch), input: envelope)
            armReliableCheckpointRetransmit(ordinal: envelope.applied, context: envelope)
            return sent
        }
        motionSequence &+= 1
        let packet = ControlPacket(session: session, sequence: motionSequence,
                                   action: RemoteAction(action: "heartbeat", epoch: envelope.epoch), input: envelope)
        guard let data = try? JSONEncoder().encode(packet), data.count <= 16384 else { return false }
        if media?.sendPointer(data) == true { return true }
        // Opening/congestion/channel loss falls back to the same checkpoint on reliable control.
        return sendMotionPrefix(reliable: true)
    }
    private func armReliableCheckpointRetransmit(ordinal: UInt64, context: InputCausalEnvelope) {
        reliableCheckpointRetransmit?.cancel()
        let delay = Self.reliableCheckpointRetransmitNanoseconds << UInt64(min(reliableCheckpointRetransmits, 2))
        reliableCheckpointRetransmit = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.connected, !self.inputRecoveryPending,
                  self.reliableMotionOrdinal == ordinal, let current = self.causalContext,
                  current.nonce == context.nonce, current.anchor == context.anchor, current.epoch == context.epoch else { return }
            self.reliableCheckpointRetransmits += 1
            self.reliableMotionOrdinal = nil
            _ = self.sendMotionPrefix(reliable: true)
        }
    }
    private func clearReliableCheckpoint() {
        reliableMotionOrdinal = nil; reliableCheckpointRetransmits = 0
        reliableCheckpointRetransmit?.cancel(); reliableCheckpointRetransmit = nil
    }
    func acknowledgeCausalInput(_ context: InputCausalEnvelope, applied: UInt64) {
        guard isHost, let current = causalContext, context.nonce == current.nonce,
              context.anchor == current.anchor, context.epoch == current.epoch else { return }
        var ack = current; ack.kind = "ack"; ack.applied = applied; ack.segments = []
        _ = transmit(RemoteAction(action: "heartbeat", epoch: ack.epoch), input: ack)
    }
    private func drainDeferredInput() throws {
        while !deferredInput.isEmpty {
            let action = deferredInput[0]
            if ["move", "moveTo"].contains(action.action) {
                guard motionPrefix.canAppend(action) else { break }
                try motionPrefix.append(action)
            } else {
                guard let barrier = envelope(kind: "barrier"), transmit(action, input: barrier) else { throw RemoteError.stale }
            }
            deferredInput.removeFirst(); deferredInputBytes -= deferredInputSizes.removeFirst()
        }
        if !motionPrefix.segments.isEmpty { _ = sendMotionPrefix(reliable: !deferredInput.isEmpty) }
    }
    private func receiveCausal(_ packet: ControlPacket, motion: Bool) throws {
        guard let input = packet.input else { throw RemoteError.invalidMessage }
        try input.validate()
        guard packet.action.epoch == input.epoch else { throw RemoteError.invalidMessage }
        if motion {
            guard isHost, input.kind == "motion", packet.action.action == "heartbeat",
                  let current = causalContext, input.nonce == current.nonce,
                  input.anchor == current.anchor, input.epoch == current.epoch else { return }
            guard motionReplay.accepts(packet.sequence) else { return }
            onCausalInput?(input, nil)
            return
        }
        switch input.kind {
        case "offer":
            guard isHost, allowsCausalInput, peerFeatures.contains(SessionFeature.causalInput),
                  hostInputEpoch > 0, packet.action.action == "heartbeat" else { throw RemoteError.stale }
            if let current = causalContext, current.nonce == input.nonce { return }
            // Geometry may advance while an initial offer is in flight. The authenticated
            // host accepts its nonce at CURRENT geometry; old queued input is never posted.
            let context = InputCausalEnvelope(kind: "accept", nonce: input.nonce, anchor: hostInputAnchor, epoch: hostInputEpoch)
            causalContext = context; motionReplay = InputMotionReplay(); onCausalContext?(context)
            media?.openPointerChannel()
            _ = transmit(RemoteAction(action: "heartbeat", epoch: context.epoch), input: context)
        case "accept":
            guard !isHost, packet.action.action == "heartbeat" else { throw RemoteError.stale }
            guard input.nonce == offeredInputNonce else { return } // A newer correlated offer supersedes this response.
            let changedGeometry = input.epoch != offeredInputEpoch
            inputNegotiationTimeout?.cancel(); inputNegotiationTimeout = nil
            offeredInputNonce = nil; causalContext = input; motionPrefix = InputMotionPrefix(); clearReliableCheckpoint()
            if changedGeometry { clearDeferredInput(); onCausalContext?(input) }
            try drainDeferredInput()
        case "anchor":
            guard !isHost, packet.action.action == "heartbeat" else { throw RemoteError.stale }
            guard let current = causalContext, input.nonce == current.nonce else { return }
            guard input.anchor != current.anchor || input.epoch != current.epoch else { return }
            causalContext = input; motionPrefix = InputMotionPrefix(); clearDeferredInput()
            clearReliableCheckpoint(); inputRecoveryPending = false
            inputRecoveryTimeout?.cancel(); inputRecoveryTimeout = nil
            onCausalContext?(input)
        case "ack":
            guard !isHost, let current = causalContext, input.nonce == current.nonce,
                  input.anchor == current.anchor, input.epoch == current.epoch,
                  packet.action.action == "heartbeat" else { return }
            guard !inputRecoveryPending else { return }
            try motionPrefix.acknowledge(input.applied)
            if let ordinal = reliableMotionOrdinal, input.applied >= ordinal { clearReliableCheckpoint() }
            try drainDeferredInput()
        case "rebase":
            guard isHost, let current = causalContext, input.nonce == current.nonce,
                  packet.action.action == "heartbeat" else { throw RemoteError.stale }
            if !recoverCausalInput(input) {
                var anchor = current; anchor.kind = "anchor"; anchor.applied = 0; anchor.segments = []
                _ = transmit(RemoteAction(action: "heartbeat", epoch: anchor.epoch), input: anchor)
            }
        case "barrier":
            guard isHost, let current = causalContext, input.nonce == current.nonce,
                  packet.action.action == "heartbeat" || Self.causalSemantics.contains(packet.action.action) else { throw RemoteError.stale }
            // Reliable input already in flight can belong to the retired geometry.
            // Never let its cleanup affect a newer hold, or end a healthy session.
            guard input.epoch == current.epoch else {
                onCausalRejected?(packet.action)
                var anchor = current; anchor.kind = "anchor"; anchor.applied = 0; anchor.segments = []
                _ = transmit(RemoteAction(action: "heartbeat", epoch: anchor.epoch), input: anchor)
                return
            }
            if input.anchor != current.anchor {
                onCausalRejected?(packet.action)
                var anchor = current; anchor.kind = "anchor"; anchor.applied = 0; anchor.segments = []
                _ = transmit(RemoteAction(action: "heartbeat", epoch: anchor.epoch), input: anchor)
                return
            }
            onCausalInput?(input, packet.action.action == "heartbeat" ? nil : packet.action)
        default: throw RemoteError.invalidMessage
        }
    }

    private func deliverControlPacket(_ packet: ControlPacket) throws {
        guard packet.version == 1, packet.session == session, packet.sequence > receivedControl else { throw RemoteError.stale }
        try packet.action.validate()
        receivedControl = packet.sequence
        if packet.input != nil { try receiveCausal(packet, motion: false) }
        else {
            if isHost, causalContext != nil,
               Self.causalSemantics.contains(packet.action.action) || ["move", "moveTo"].contains(packet.action.action) { throw RemoteError.stale }
            onControl?(try JSONEncoder().encode(packet.action))
        }
    }

    func sendControl(_ action: RemoteAction) -> Bool {
        guard connected, !session.isEmpty else {
            moveCoalescer.discard()
            controlNotConnectedRefusals += 1
            if InputLog.sampled(controlNotConnectedRefusals) {
                InputLog.log.error("\(self.isHost ? "host" : "phone", privacy: .public) send refused: not connected (\(action.action, privacy: .public)) count=\(self.controlNotConnectedRefusals, privacy: .public)")
            }
            return false
        }
        do { try action.validate() } catch { connectionLost(); return false }
        if !isHost, inputRecoveryPending, Self.causalSemantics.contains(action.action) { return false }
        if !isHost, offeredInputNonce != nil, Self.causalSemantics.contains(action.action) {
            guard action.epoch == offeredInputEpoch else { return false }
            if action.action == "release" { clearDeferredInput() }
            guard enqueueDeferredInput(action) else { peerDisconnected(); return false }
            return true
        }
        if !isHost, let context = causalContext, Self.causalSemantics.contains(action.action) {
            guard action.epoch == context.epoch else { return false }
            if action.action == "release" { clearDeferredInput() }
            if !deferredInput.isEmpty {
                guard enqueueDeferredInput(action) else { return requestInputRecovery() }
                return sendMotionPrefix(reliable: true)
            }
            guard let barrier = envelope(kind: "barrier") else { return false }
            return transmit(action, input: barrier)
        }
        guard StreamTuning.current.mergePointerMoves || moveCoalescer.pending != nil else { return transmit(action) }
        let outgoing = moveCoalescer.offer(action, backlogged: controlBacklogged,
                                           now: ProcessInfo.processInfo.systemUptime)
        for _ in 0..<moveCoalescer.takeMerged() { media?.counters.coalescedMove() }
        if moveCoalescer.pending != nil { scheduleMoveFlush() }
        for message in outgoing {
            guard transmit(message) else { return false }
        }
        return true
    }

    private var controlBacklogged: Bool {
        (media?.controlBufferedAmount ?? 0) >= PointerMoveCoalescer.backlogBytes
    }

    private func transmit(_ action: RemoteAction, input: InputCausalEnvelope? = nil) -> Bool {
        do {
            sentControl += 1
            #if DEBUG
            if let sender = inputPacketSenderForTesting {
                return sender(ControlPacket(session: session, sequence: sentControl, action: action, input: input))
            }
            #endif
            let data = try JSONEncoder().encode(ControlPacket(session: session, sequence: sentControl, action: action, input: input))
            guard media?.sendControl(data) == true else {
                InputLog.log.error("\(self.isHost ? "host" : "phone", privacy: .public) control send failed (\(action.action, privacy: .public)); ending session")
                peerDisconnected(); return false
            }
            return true
        } catch { connectionLost(); return false }
    }

    /// Sends a held move once the backlog clears, or after `PointerMoveCoalescer.flushInterval`.
    private func scheduleMoveFlush() {
        guard moveFlush == nil else { return }
        moveFlush = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.connected, !self.session.isEmpty, self.moveCoalescer.pending != nil else {
                    self.moveCoalescer.discard()
                    break
                }
                if let held = self.moveCoalescer.flush(backlogged: self.controlBacklogged,
                                                       now: ProcessInfo.processInfo.systemUptime) {
                    _ = self.transmit(held)
                    break
                }
            }
            // A cancelled task's handle was already cleared by the reset that cancelled it.
            if !Task.isCancelled { self?.moveFlush = nil }
        }
    }
    func restore() {
        do {
            if isHost { hostPair = try store.read(HostPair.self); invitation = hostPair?.invitation; peerName = hostPair?.phoneName }
            else { invitation = try store.read(PairInvitation.self) }
            status = invitation == nil ? "Pair with your Mac to get started" : "Ready to connect"
        } catch { status = error.localizedDescription }
    }
    func createPair(server: String, name: String) throws -> PairInvitation {
        stop()
        let pair = try HostPair.create(server: server, name: name, identity: hostIdentityStore?.loadOrCreate())
        try pair.invitation.validate()
        try store.save(pair)
        hostPair = pair; invitation = pair.invitation; peerName = nil
        return pair.invitation
    }
    func enroll(_ code: String, replacementApproval: PhoneTrustReplacementApproval? = nil) throws {
        guard !isHost else { throw RemoteError.invalidPairing }
        let parsed = try PairInvitation.parse(code)
        if let phone = store as? PhonePairPersistence {
            let required = try phone.trust.replacementRequest(for: parsed)
            guard required == replacementApproval?.request,
                  replacementApproval == nil || replacementApproval?.enrollment == parsed else {
                throw PhoneTrustMutationError.replacementRequiresApproval
            }
        } else if replacementApproval != nil { throw RemoteError.invalidPairing }
        try prepareForEnrollment?()
        stop()
        scannedEnrollment = parsed
        pendingPhoneReplacementApproval = replacementApproval
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
            if let scannedEnrollment { try scannedEnrollment.validate(enrollment: true) }
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
            onGuestAuthorityEnded?(); routePolicy = nil; routeArmed = false; ownerLocalEpoch = nil
            routeEpochsSeen.removeAll()
            serviceAccess = nil; guestServiceAvailable = false; guestResetGate = GuestServiceResetGate()
            entitlementRequired = false
            macBlocker = nil
            var features = advertisesRenewal ? [SignalingFeature.renewal] : []
            features.append(SignalingFeature.route)
            if isHost && !localOnly { features.append("guest-v1") }
            if !isHost && advertisesRemoteAccess && sessionModeRequest != .couch {
                features.append(SignalingFeature.remoteAccess)
            }
            wireSignalingCallbacks()
            if localOnly && !invitation.hasOwnerLocalIdentity {
                throw RemoteError.localPairingRefreshRequired
            }
            try relay.connect(invitation: invitation, hostToken: hostPair?.hostToken, features: features,
                              entitlement: isHost || localOnly || sessionModeRequest == .couch ? nil : entitlementToken?())
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
    func revoke(expectedInvitation: PairInvitation? = nil) -> Bool {
        pairingRemovalFailure = nil
        if let expectedInvitation {
            do {
                guard invitation == expectedInvitation,
                      try store.read(PairInvitation.self) == expectedInvitation else {
                    status = "Selected Mac changed. Choose the Mac to forget again."
                    return false
                }
            } catch { status = error.localizedDescription; return false }
        }
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
            hostPair = nil; invitation = nil; peerName = nil
            status = isHost ? "Pairing removed. Old credentials no longer work." : "Mac forgotten on this phone. Revoke the phone on the Mac to remove its grant."
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
    private func cancelEnrollment() {
        if scannedEnrollment != nil { invitation = try? store.read(PairInvitation.self) }
        scannedEnrollment = nil
        pendingPhoneReplacementApproval = nil
        #if DEBUG
        e2eEnrolling = false
        #endif
    }
    func stop() {
        cancelEnrollment()
        stopped = true; retry?.cancel(); retry = nil; retryCount = 0; recoveringLiveSession = false
        reconnecting = false
        routeExpiry?.cancel(); routeExpiry = nil; onGuestAuthorityEnded?(); routePolicy = nil; routeArmed = false; ownerLocalEpoch = nil
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
        onGuestAuthorityEnded?()
        onPresentationInvalidated?()
        presentationSessionID = UUID(); presentationTrackID = UUID()
        timeout?.cancel(); timeout = nil
        localProofTimeout?.cancel(); localProofTimeout = nil
        localProofPreparation?.cancel(); localProofPreparation = nil; localProofPreparationID = nil
        if let proof = localLinkProof { localProofSummary = proof.stageSummary() }
        localLinkProof?.close(); localLinkProof = nil
        pendingMediaSignals.removeAll()
        pendingLocalEndpoint = nil
        registrationStability?.cancel(); registrationStability = nil
        media?.close(); media = nil
        remoteVideo = nil; connected = false; awaitingApproval = false; hostRegistered = false
        diagnostics = "Route not measured"
        sentControl = 0; receivedControl = 0
        moveCoalescer.discard(); moveFlush?.cancel(); moveFlush = nil
        inputNegotiationTimeout?.cancel(); inputNegotiationTimeout = nil
        causalContext = nil; offeredInputNonce = nil; offeredInputEpoch = 0; hostInputEpoch = 0
        hostInputAnchor = InputCausalEnvelope.identity(); motionPrefix = InputMotionPrefix()
        motionSequence = 0; motionReplay = InputMotionReplay(); clearDeferredInput()
        clearReliableCheckpoint(); inputRecoveryPending = false
        inputRecoveryTimeout?.cancel(); inputRecoveryTimeout = nil
        request = ""; session = ""; sequence = 0; guardState = nil; proofReceived = false
        peerFeatures = []
        peerRequestedMode = .picture
        onEnded?()
    }
    private func receive(_ message: RelayMessage) {
        do {
            switch message.type {
            case "guest":
                guard isHost, message.version == 1, guestOwnerContext != nil, let guest = message.guest else { return }
                if guest.operation == "serviceReset" {
                    guard guestResetGate.accept(guest, currentEpoch: routePolicy?.epoch) else { return }
                }
                onGuest?(guest)
            case "route":
                if routePolicy == nil, routeEpochsSeen.contains(message.epoch ?? "") {
                    throw RemoteError.stale
                }
                guard let room = invitation?.room,
                      let policy = ServerRoutePolicy.accept(message, room: room, previous: routePolicy) else {
                    throw RemoteError.invalidMessage
                }
                if let old = routePolicy, old.access != policy.access, media != nil {
                    sessionFailed("Route access changed. Reconnect to verify the new route.")
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
                    self.sessionFailed("Route authorization expired. Reconnect to renew access.")
                }
            case "registered":
                if isHost {
                    guestServiceAvailable = message.features?.contains("guest-v1") == true
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
                    guard routeAuthorized else {
                        sessionFailed("The connection service did not authorize this route. Update Farside and retry.")
                        return
                    }
                    if !isHost {
                        resetSession(); request = try SecureRandom.token()
                        send(kind: "request", body: try? JSONEncoder().encode(MacShareBlocker.Handshake(features: MacShareBlocker.Handshake.phone.features, mode: sessionModeRequest == .couch ? SessionMode.couch.rawValue : nil)), handshake: true)
                        status = "Authenticating your Mac…"; setTimeout()
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
        } catch { sessionFailed("Secure connection failed. Reconnect or pair again on your Mac.") }
    }
    private func receiveProtected(_ message: ProtectedMessage) throws {
        if isHost, message.kind == "request" {
            guard request.isEmpty, message.session.isEmpty, message.sequence == 0,
                  let pair = hostPair, pair.paired || pair.invitation.expires > Date() else { throw RemoteError.stale }
            request = message.request; session = try SecureRandom.token()
            guardState = SessionReplayGuard(request: request, session: session)
            peerFeatures = MacShareBlocker.Handshake.features(in: message.body)
            peerRequestedMode = MacShareBlocker.Handshake.requestedMode(in: message.body)
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
            if peerRequestedMode != .couch, let blocker = shareBlocker?() {
                refuseSession(blocker)
                return
            }
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
            guard localRouteEpoch != nil, let body = message.body else { throw RemoteError.invalidMessage }
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
                guard next.room == invitation?.room, next.server == invitation?.server,
                      next.durableHostID == invitation?.durableHostID,
                      next.ownerPairID == invitation?.ownerPairID,
                      next.localServiceName == invitation?.localServiceName else { throw RemoteError.invalidMessage }
                try persistAcceptedInvitation(next)
            } else if let scannedEnrollment {
                // A paired host may accept without rotating credentials. The scanned
                // QR still needs the same explicit replacement admission and expiry.
                try persistAcceptedInvitation(scannedEnrollment)
            }
            prepareMedia()
            send(kind: "acceptedAck", body: SessionModeRequest.body(for: sessionModeRequest, name: localDisplayName))
        case MacShareBlocker.refusalKind where !isHost:
            guard media == nil, let body = message.body else { throw RemoteError.invalidMessage }
            let refusal = try JSONDecoder().decode(MacShareBlocker.Refusal.self, from: body)
            macBlocker = refusal.reason
            fail("Mac unavailable: \(refusal.reason.rawValue)")
        case "acceptedAck" where isHost:
            guard proofReceived, media == nil, !awaitingApproval else { throw RemoteError.stale }
            recordPeerName(PhoneIdentity.decode(message.body))
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
    private func persistAcceptedInvitation(_ next: PairInvitation) throws {
        if let phone = store as? PhonePairPersistence {
            try phone.trust.saveApproved(next, scannedEnrollment: scannedEnrollment,
                                         replacementApproval: pendingPhoneReplacementApproval)
        } else { try store.save(next) }
        invitation = next
        scannedEnrollment = nil
        pendingPhoneReplacementApproval = nil
        #if DEBUG
        e2eEnrolling = false
        #endif
    }
    /// Keeps the name a paired phone reports; a phone that sends none keeps the stored one.
    private func recordPeerName(_ name: String?) {
        guard let name, var pair = hostPair, pair.paired, pair.phoneName != name else { return }
        pair.phoneName = name
        do { try store.save(pair); hostPair = pair; peerName = name }
        catch { peerName = name }
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
    /// An authenticated phone is never accepted while a grant is missing. One that understands blockers
    /// is told which; an older phone just times out, as it did when the Mac was not listening.
    private func refuseSession(_ blocker: MacShareBlocker) {
        if let reason = blocker.told(to: peerFeatures),
           let body = try? JSONEncoder().encode(MacShareBlocker.Refusal(reason: reason)) {
            send(kind: MacShareBlocker.refusalKind, body: body)
        }
        peerDisconnected()
    }

    private func prepareMedia() {
        guard routeAuthorized else {
            sessionFailed("The connection route is no longer authorized.")
            return
        }
        if !isHost, sessionModeRequest == .couch, !routeIsLocal {
            fail(CouchCopy.phoneRefusedStatus)
            return
        }
        if let epoch = localRouteEpoch, let room = invitation?.room {
            beginLocalProof(room: room, epoch: epoch)
            return
        }
        finishMedia(localLink: nil)
    }

    private func beginLocalProof(room: String, epoch: String) {
        guard localProofPreparation == nil, localLinkProof == nil else { return }
        guard let key = invitation?.key, !session.isEmpty else { sessionFailed("Local link proof could not start."); return }
        let session = self.session
        let isHost = self.isHost, buildProof = localProofBuilder
        let preparation = UUID(); localProofPreparationID = preparation
        localProofPreparation = Task { [weak self] in
            // TN3179: a backgrounded attempt is denied silently and never prompts. Wait for the foreground.
            if !isHost, !(await LocalNetworkAccess.waitUntilForeground()) {
                guard let self, !Task.isCancelled, !self.stopped, self.session == session,
                      self.localProofPreparationID == preparation else { return }
                self.sessionFailed("Open Farside to finish connecting on this Wi-Fi."); return
            }
            let proof = await Task.detached(priority: .userInitiated) {
                buildProof(room, epoch, session, key)
            }.value
            guard let self, !Task.isCancelled, !self.stopped, self.session == session,
                  self.localProofPreparationID == preparation, self.localRouteEpoch == epoch else {
                proof?.close(); return
            }
            self.localProofPreparation = nil
            guard let proof else {
                self.localProofSummary = "not started: no single directly attached Wi-Fi or Ethernet path"
                self.sessionFailed("No directly attached Wi-Fi or Ethernet link is available."); return
            }
            self.localLinkProof = proof
            self.localProofSummary = nil
            proof.onInvalidated = { [weak self, weak proof] in
                guard let self, let proof, self.localLinkProof === proof else { return }
                self.sessionFailed("The local network changed. Reconnect to verify the route again.")
            }
            proof.onLocalNetworkDenied = { [weak self, weak proof] in
                // With the alert still up, iOS denies first and retries after Allow; only an active app's denial is final.
                guard let self, let proof, self.localLinkProof === proof, LocalNetworkAccess.appIsActive else { return }
                self.localProofSummary = proof.stageSummary()
                self.sessionFailed(LocalNetworkAccess.deniedStatus)
            }
            proof.onProven = { [weak self, weak proof] link in
                guard let self, let proof, self.localLinkProof === proof,
                      self.localRouteEpoch == epoch else { return }
                self.localProofTimeout?.cancel(); self.localProofTimeout = nil
                self.localProofSummary = proof.stageSummary()
                self.finishMedia(localLink: link)
            }
            self.localProofTimeout = Task { [weak self, weak proof] in
                try? await Task.sleep(nanoseconds: self?.localProofTimeoutNanoseconds ?? 8_000_000_000)
                guard !Task.isCancelled, let self, let proof, self.localLinkProof === proof,
                      self.session == session, self.localRouteEpoch == epoch else { return }
                if let proof = self.localLinkProof {
                    LocalLinkProof.log.error("timed out after 8 s: \(proof.stageSummary(), privacy: .public)")
                    if proof.isLocalNetworkDenied { self.sessionFailed(LocalNetworkAccess.deniedStatus); return }
                }
                self.sessionFailed("The devices could not verify a directly attached local link.")
            }
            if let pending = self.pendingLocalEndpoint {
                LocalLinkProof.log.info("applying peer endpoint received before the proof existed")
                proof.setPeer(pending)
            }
            guard let data = try? JSONEncoder().encode(proof.endpoint) else { self.sessionFailed("Local link proof could not start."); return }
            self.send(kind: "localEndpoint", body: data)
        }
    }

    private func finishMedia(localLink: ProvenLocalLink?) {
        guard !stopped, media == nil else { return }
        let relayOnly: Bool
        let decision = NativeRelayPolicy.decide(servers: servers, policy: relayPolicy, localForce: forceRelay)
        SessionLog.log.info("media start: relay decision=\(String(describing: decision), privacy: .public) policy=\(self.relayPolicy ?? "nil", privacy: .public) hasRelay=\(NativeRelayPolicy.hasRelay(self.servers), privacy: .public) localLink=\(localLink != nil, privacy: .public) access=\(self.routePolicy?.access.rawValue ?? "nil", privacy: .public)")
        switch decision {
        case .proceed(let force):
            relayOnly = force
        case .relayRequiredUnavailable(let serverRequired):
            sessionFailed(serverRequired ? "The connection service requires a relay, but none was provided." : "Relay-only test requires a configured TURN service.")
            return
        }
        let peer = PeerMedia(isHost: isHost, servers: servers, forceRelay: relayOnly, localLink: localLink, fileChannel: true, videoLTR: isHost && peerFeatures.contains(SessionFeature.videoLTR))
        media = peer
        if let engine = fileTransfer {
            peer.onFileMessage = { [weak engine] data in engine?.receiveChunk(data) }
            peer.onFileBufferedAmountChange = { [weak engine] in engine?.fileBufferedAmountChanged() }
        }
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
        peer.onRemoteVideo = { [weak self, weak peer] track in Task { @MainActor in if let self, let peer, self.media === peer {
            if self.remoteVideo !== track { self.onPresentationInvalidated?(); self.presentationTrackID = UUID() }
            self.remoteVideo = track
        } } }
        peer.onPointerMessage = { [weak self, weak peer] data in
            MainActor.assumeIsolated {
                guard let self, let peer, self.media === peer else { return }
                do {
                    let packet = try JSONDecoder().decode(ControlPacket.self, from: data)
                    guard packet.version == 1, packet.session == self.session else { return }
                    try packet.action.validate()
                    try self.receiveCausal(packet, motion: true)
                } catch { self.sessionFailed("Invalid pointer checkpoint. Session ended safely.") }
            }
        }
        peer.onControl = { [weak self, weak peer] data in
            let arrivedMs = MachClock.nowMs()
            let arrivedFrames = peer?.lastControlArrivedFrames
            let arrivedAt = peer?.lastControlArrivedAt
            MainActor.assumeIsolated {
                guard let self, let peer, self.media === peer, data.count <= 16384 else { return }
                do {
                    let packet = try JSONDecoder().decode(ControlPacket.self, from: data)
                    guard packet.version == 1, packet.session == self.session, packet.sequence > self.receivedControl else {
                        self.controlRejected["stale", default: 0] += 1
                        InputLog.log.error("control rejected: stale version/session/sequence (seq \(packet.sequence, privacy: .public) after \(self.receivedControl, privacy: .public))")
                        throw RemoteError.stale
                    }
                    self.currentControlArrivalMs = arrivedMs
                    self.controlArrivedFrames = arrivedFrames
                    self.controlArrivedAt = arrivedAt
                    defer { self.currentControlArrivalMs = nil; self.controlArrivedFrames = nil; self.controlArrivedAt = nil }
                    try self.deliverControlPacket(packet)
                } catch {
                    self.controlRejected["parse-or-validate", default: 0] += 1
                    InputLog.log.error("control rejected: \(String(describing: error), privacy: .public); ending session")
                    self.sessionFailed("Invalid control message. Session ended safely.")
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
        routeExpiry?.cancel(); routeExpiry = nil; onGuestAuthorityEnded?(); routePolicy = nil; routeArmed = false; ownerLocalEpoch = nil
        if localOnly { connectionLost(); return }
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
        if scannedEnrollment != nil {
            fail("Pairing was interrupted. Scan a fresh QR to try again.")
            return
        }
        // A media and signaling failure can report the same outage independently.
        // The first event already closed the old transport and scheduled a retry.
        guard retry == nil else { return }
        if connected && sessionLossRetryLimit != nil { recoveringLiveSession = true }
        cancelRenewal()
        routeExpiry?.cancel(); routeExpiry = nil; onGuestAuthorityEnded?(); routePolicy = nil; routeArmed = false; ownerLocalEpoch = nil
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
    /// A failure that belongs to one phone session attempt: a local proof that timed out or was
    /// invalidated, a route that expired or changed, a relay the policy needs but lacks, or an invalid
    /// control message. A sharing Mac ends only that attempt and stays registered (same path as a phone
    /// leaving); if it is not registered at that moment it re-registers. A phone fails as before.
    /// Registration stops only through `stop()` or a fatal `fail` (update required, pairing, keychain).
    private func sessionFailed(_ message: String) {
        guard isHost, !stopped else { fail(message); return }
        SessionLog.log.error("host session ended, sharing continues: \(message, privacy: .public)")
        lastSessionFailure = message
        if hostRegistered { peerDisconnected() } else { connectionLost(finalStatus: message) }
    }

    private func fail(_ message: String) {
        cancelEnrollment()
        SessionLog.log.error("fail: \(message, privacy: .public)")
        stopped = true; retry?.cancel(); retry = nil; recoveringLiveSession = false
        reconnecting = false
        cancelRenewal()
        routeExpiry?.cancel(); routeExpiry = nil; onGuestAuthorityEnded?(); routePolicy = nil; routeArmed = false; ownerLocalEpoch = nil
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
    var localLinkProofForTesting: LocalLinkProof? { localLinkProof }
    var isStoppedForTesting: Bool { stopped }
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
