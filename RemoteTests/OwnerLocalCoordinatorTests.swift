import XCTest

@MainActor
private final class OwnerLocalFixtureTransport: OwnerLocalSignalingTransport {
    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    var onAuthenticatedLocalSignaling: ((LocalOwnerChallenge) -> Void)?
    var connects = 0
    var closes = 0
    var sent: [RelayMessage] = []
    var entitlementReceived: String?
    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws { connects += 1 }
    func connect(invitation: PairInvitation, hostToken: String?, features: [String], entitlement: String?) throws {
        entitlementReceived = entitlement
        try connect(invitation: invitation, hostToken: hostToken, features: features)
    }
    func send(_ message: RelayMessage) { sent.append(message) }
    func close() { closes += 1 }
}

@MainActor
final class OwnerLocalCoordinatorTests: XCTestCase {
    private func fixture() throws -> (RemoteCoordinator, ScriptedSignaling, OwnerLocalFixtureTransport, PairInvitation) {
        let identity = HostIdentityRecord(hostID: String(repeating: "a", count: 64),
            localServiceName: "farside-" + String(repeating: "b", count: 32))
        let invitation = try HostPair.create(server: "wss://example.com/signal", name: "Mac", identity: identity).rotated().invitation
        let store = MemoryPairStore(); try store.save(invitation)
        let cloud = ScriptedSignaling(), local = OwnerLocalFixtureTransport()
        let phone = RemoteCoordinator(isHost: false, store: store, signaling: cloud, localSignaling: local)
        phone.restore()
        return (phone, cloud, local, invitation)
    }

    func testOfflineAdmissionNeverConnectsCloudOrConsultsPurchaseAndStillRequiresMediaProof() throws {
        let (phone, cloud, local, invitation) = try fixture()
        defer { phone.stop() }
        var purchaseReads = 0
        phone.entitlementToken = { purchaseReads += 1; return "purchase-fixture" }
        phone.advertisesRemoteAccess = true
        phone.setLocalOnly(true); phone.start()
        XCTAssertEqual(local.connects, 1); XCTAssertEqual(cloud.connects.count, 0)
        XCTAssertEqual(purchaseReads, 0); XCTAssertNil(local.entitlementReceived)
        XCTAssertFalse(phone.routeIsLocal)
        local.onAuthenticatedLocalSignaling?(try LocalOwnerChallenge.make(invitation: invitation))
        XCTAssertTrue(phone.routeIsLocal)
        XCTAssertNil(phone.routePolicyEpoch, "Owner-local authority must never impersonate a server epoch")
        local.onMessage?(RelayMessage(type: "peer", online: true))
        XCTAssertEqual(local.sent.count, 1, "Only the sealed pairing request may start here")
        XCTAssertNil(phone.media); XCTAssertFalse(phone.connected); XCTAssertFalse(phone.provenLocalLinkActive)
        phone.stop(); XCTAssertFalse(phone.routeIsLocal)
    }

    func testModeSwitchRejectsTrailingOldTransportCallbacks() throws {
        let (phone, cloud, local, invitation) = try fixture()
        defer { phone.stop() }
        phone.setLocalOnly(true); phone.start()
        let oldAuth = local.onAuthenticatedLocalSignaling, oldMessage = local.onMessage
        phone.setLocalOnly(false); phone.start()
        oldAuth?(try LocalOwnerChallenge.make(invitation: invitation))
        oldMessage?(RelayMessage(type: "peer", online: true))
        XCTAssertFalse(phone.routeIsLocal); XCTAssertNil(phone.media)
        XCTAssertEqual(cloud.connects.count, 1); XCTAssertTrue(cloud.sent.isEmpty)
        XCTAssertTrue(local.sent.isEmpty)
    }

    func testWrongOwnerChallengeCannotAuthorizeLocalRoute() throws {
        let (phone, _, local, invitation) = try fixture()
        defer { phone.stop() }
        phone.setLocalOnly(true); phone.start()
        let challenge = try LocalOwnerChallenge.make(invitation: invitation)
        let wrong = LocalOwnerChallenge(hostID: String(repeating: "c", count: 64), ownerPairID: challenge.ownerPairID,
            epoch: challenge.epoch, nonce: challenge.nonce, expires: challenge.expires)
        local.onAuthenticatedLocalSignaling?(wrong)
        XCTAssertFalse(phone.isRunning); XCTAssertFalse(phone.routeIsLocal)
        XCTAssertNil(phone.media); XCTAssertTrue(local.sent.isEmpty)
    }

    func testUnauthenticatedPeerAndPeerSuppliedCloudRouteFailClosed() throws {
        let (phone, _, local, _) = try fixture()
        defer { phone.stop() }
        phone.setLocalOnly(true); phone.start()
        local.onMessage?(RelayMessage(type: "peer", online: true))
        XCTAssertFalse(phone.isRunning); XCTAssertNil(phone.media); XCTAssertTrue(local.sent.isEmpty)
        phone.start()
        local.onMessage?(RelayMessage(type: "route", version: 1))
        XCTAssertFalse(phone.isRunning); XCTAssertFalse(phone.routeIsLocal); XCTAssertNil(phone.routePolicyEpoch)
    }
}
