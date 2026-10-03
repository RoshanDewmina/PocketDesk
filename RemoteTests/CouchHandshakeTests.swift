import XCTest
import Foundation

@MainActor
private struct Peer {
    let cipher: SignalCipher
    let role: String

    init(invitation: PairInvitation, plays role: String) throws {
        cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        self.role = role
    }

    func seal(_ kind: String, request: String, session: String = "", sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
        RelayMessage(type: "signal", payload: try cipher.seal(
            ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: role))
    }

    func open(_ message: RelayMessage) throws -> ProtectedMessage {
        try cipher.open(try XCTUnwrap(message.payload), sender: role == "client" ? "host" : "client")
    }
}

@MainActor
private final class RecordingSignaling: SignalingTransport {
    struct Connect { let features: [String]; let entitlement: String? }
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    private(set) var connects: [Connect] = []
    private(set) var sent: [RelayMessage] = []
    var lastCloseReason: String? { nil }

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        try connect(invitation: invitation, hostToken: hostToken, features: features, entitlement: nil)
    }
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws {
        connects.append(Connect(features: features, entitlement: entitlement))
    }
    func send(_ message: RelayMessage) { sent.append(message) }
    func close() {}
    func checkLiveness() {}
    func deliver(_ message: RelayMessage) { onMessage?(message) }
}

private func routeMessage(room: String, access: String) throws -> RelayMessage {
    let deadline = Int64((Date().timeIntervalSince1970 + 60) * 1000)
    let json = """
    {"type":"route","version":1,"room":"\(room)","epoch":"\(String(repeating: "c", count: 32))","revision":1,"access":"\(access)","expiresAt":\(deadline)}
    """
    return try JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
}

@MainActor
private final class HostRig {
    let signaling = RecordingSignaling()
    let host: RemoteCoordinator
    let phone: Peer
    let invitation: PairInvitation

    init() throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        invitation = pair.invitation
        host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                 registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                 renewalScheduler: ManualScheduler())
        host.allowLegacyPrivateRoute = true
        phone = try Peer(invitation: pair.invitation, plays: "client")
        host.restore()
        host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
    }

    /// Request, challenge and proof; returns (request, session). The paired Mac then sends `accepted`.
    func authenticate() throws -> (String, String) {
        let request = try SecureRandom.token()
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(try phone.seal("request", request: request))
        let challenge = try phone.open(try XCTUnwrap(signaling.sent.last))
        signaling.deliver(try phone.seal("proof", request: request, session: challenge.session))
        XCTAssertEqual(host.status, "Connecting live desktop…")
        return (request, challenge.session)
    }
}

@MainActor
final class CouchHandshakeTests: XCTestCase {
    /// Connect awaits the codec capability snapshot (PocketDeskAsyncCapabilitySnapshot) before
    /// creating media; a bounded wait replaces the former synchronous assertion.
    private func mediaCreated(_ host: RemoteCoordinator) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while host.media == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return host.media != nil
    }

    func testTheMacRecordsTheCouchRequestFromTheAcceptedAckAndForgetsItWithTheSession() async throws {
        let rig = try HostRig()
        let (request, session) = try rig.authenticate()
        XCTAssertEqual(rig.host.peerRequestedMode, .picture)
        rig.signaling.deliver(try rig.phone.seal("acceptedAck", request: request, session: session, sequence: 1,
                                                 body: SessionModeRequest.body(for: .couch)))
        XCTAssertEqual(rig.host.peerRequestedMode, .couch)
        let created = await mediaCreated(rig.host)
        XCTAssertTrue(created, "the Mac still prepares media exactly as before")
        rig.signaling.deliver(RelayMessage(type: "peer", online: false))
        XCTAssertEqual(rig.host.peerRequestedMode, .picture)
        rig.host.stop()
    }

    func testAnAcceptedAckWithoutOrWithAnUnknownBodyIsAPictureSession() async throws {
        let bodies: [Data?] = [nil, Data(#"{"mode":"hologram"}"#.utf8), Data("garbage".utf8)]
        for body in bodies {
            let rig = try HostRig()
            let (request, session) = try rig.authenticate()
            rig.signaling.deliver(try rig.phone.seal("acceptedAck", request: request, session: session, sequence: 1, body: body))
            XCTAssertEqual(rig.host.peerRequestedMode, .picture)
            let created = await mediaCreated(rig.host)
            XCTAssertTrue(created)
            XCTAssertTrue(rig.host.isRunning, "an unreadable body never ends the session")
            rig.host.stop()
        }
    }

    func testRouteIsLocalOnlyWhileTheServerPublishedALocalRoute() throws {
        let rig = try HostRig()
        XCTAssertFalse(rig.host.routeIsLocal)
        rig.signaling.deliver(try routeMessage(room: rig.invitation.room, access: "local"))
        XCTAssertTrue(rig.host.routeIsLocal)
        XCTAssertFalse(rig.host.provenLocalLinkActive, "a route alone is not a proven link")
        rig.signaling.deliver(RelayMessage(type: "peer", online: false))
        XCTAssertFalse(rig.host.routeIsLocal)
        rig.host.stop()

        let remote = try HostRig()
        remote.signaling.deliver(try routeMessage(room: remote.invitation.room, access: "remote"))
        XCTAssertFalse(remote.host.routeIsLocal)
        remote.host.stop()
    }

    func testAPeerWithoutAProvenLinkIsNeverLocal() {
        XCTAssertFalse(PeerMedia(isHost: true, servers: []).provenLocalLinkActive)
    }

    private func pairedPhone(_ signaling: RecordingSignaling) throws -> (RemoteCoordinator, PairInvitation) {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 0, signaling: signaling,
                                      renewalScheduler: ManualScheduler())
        phone.restore()
        return (phone, pair.invitation)
    }

    func testACouchRegistrationListsNoRemoteAccessAndSendsNoEntitlement() throws {
        for mode in SessionMode.allCases {
            let signaling = RecordingSignaling()
            let (phone, _) = try pairedPhone(signaling)
            phone.advertisesRemoteAccess = true
            phone.entitlementToken = { "paid-token" }
            phone.sessionModeRequest = mode
            phone.start()
            let connect = try XCTUnwrap(signaling.connects.last)
            XCTAssertTrue(connect.features.contains(SignalingFeature.route))
            if mode == .couch {
                XCTAssertFalse(connect.features.contains(SignalingFeature.remoteAccess))
                XCTAssertNil(connect.entitlement)
            } else {
                XCTAssertTrue(connect.features.contains(SignalingFeature.remoteAccess))
                XCTAssertEqual(connect.entitlement, "paid-token")
            }
            phone.stop()
        }
    }

    /// Plays the Mac up to `accepted`; returns the counterpart so the caller can read what the phone sent.
    private func acceptPhone(_ phone: RemoteCoordinator, _ signaling: RecordingSignaling,
                             invitation: PairInvitation, access: String) throws -> Peer {
        let mac = try Peer(invitation: invitation, plays: "host")
        phone.start()
        signaling.deliver(try routeMessage(room: invitation.room, access: access))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let request = try mac.open(try XCTUnwrap(signaling.sent.last))
        XCTAssertEqual(request.kind, "request")
        let session = try SecureRandom.token()
        signaling.deliver(try mac.seal("challenge", request: request.request, session: session))
        XCTAssertEqual(try mac.open(try XCTUnwrap(signaling.sent.last)).kind, "proof")
        signaling.deliver(try mac.seal("accepted", request: request.request, session: session, sequence: 1))
        return mac
    }

    func testThePhonePutsItsModeInTheAcceptedAck() throws {
        for mode in SessionMode.allCases {
            let signaling = RecordingSignaling()
            let (phone, invitation) = try pairedPhone(signaling)
            phone.sessionModeRequest = mode
            let mac = try acceptPhone(phone, signaling, invitation: invitation, access: "local")
            let ack = try mac.open(try XCTUnwrap(signaling.sent.last))
            XCTAssertEqual(ack.kind, "acceptedAck")
            XCTAssertEqual(ack.body == nil, mode == .picture, "Picture sends no body, exactly as before")
            XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: ack.body), mode)
            phone.stop()
        }
    }

    func testACouchRequestOnARemoteRouteStopsBeforeTheAcceptedAck() throws {
        let signaling = RecordingSignaling()
        let (phone, invitation) = try pairedPhone(signaling)
        phone.sessionModeRequest = .couch
        let mac = try acceptPhone(phone, signaling, invitation: invitation, access: "remote")
        let kinds = signaling.sent.compactMap { try? mac.open($0).kind }
        XCTAssertFalse(kinds.contains("acceptedAck"))
        XCTAssertEqual(phone.status, CouchCopy.phoneRefusedStatus)
        XCTAssertFalse(phone.isRunning)
    }
    func testModeAndPhoneNameShareTheAcceptedAckWithoutLosingEither() throws {
        let body = try XCTUnwrap(SessionModeRequest.body(for: .couch, name: "Test phone"))
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: body), .couch)
        XCTAssertEqual(PhoneIdentity.decode(body), "Test phone")
        let picture = try XCTUnwrap(SessionModeRequest.body(for: .picture, name: "Test phone"))
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: picture), .picture)
        XCTAssertEqual(PhoneIdentity.decode(picture), "Test phone")
    }

    func testCouchIntentIsBoundedAndAvailableBeforeCaptureAdmission() throws {
        let request = MacShareBlocker.Handshake(features: MacShareBlocker.Handshake.phone.features, mode: "couch")
        let body = try JSONEncoder().encode(request)
        XCTAssertEqual(MacShareBlocker.Handshake.requestedMode(in: body), .couch)
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: body), Set(request.features))
        XCTAssertEqual(MacShareBlocker.Handshake.requestedMode(in: nil), .picture)
        XCTAssertEqual(MacShareBlocker.Handshake.requestedMode(in: Data(repeating: 0, count: 1025)), .picture)
    }

    func testAnOversizedDisplayNameNeverChangesCouchToPicture() throws {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 40)
        let body = try XCTUnwrap(SessionModeRequest.body(for: .couch, name: name))
        XCTAssertLessThanOrEqual(body.count, SessionModeRequest.maximumBodyBytes)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: body), .couch)
    }

}
