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
    private func fixture(builder: (@Sendable (String, String, String, Data) -> LocalLinkProof?)? = nil) throws -> (RemoteCoordinator, ScriptedSignaling, OwnerLocalFixtureTransport, PairInvitation) {
        let identity = HostIdentityRecord(hostID: String(repeating: "a", count: 64),
            localServiceName: "farside-" + String(repeating: "b", count: 32))
        let invitation = try HostPair.create(server: "wss://example.com/signal", name: "Mac", identity: identity).rotated().invitation
        let store = MemoryPairStore(); try store.save(invitation)
        let cloud = ScriptedSignaling(), local = OwnerLocalFixtureTransport()
        let phone = RemoteCoordinator(isHost: false, store: store, signaling: cloud, localSignaling: local, localProofBuilder: builder)
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
    func testAcceptedRotationCannotMutateScannedHostGrantOrDiscoveryIdentity() throws {
        for field in 0..<3 {
            let (phone, cloud, _, invitation) = try fixture()
            defer { phone.stop() }
            phone.allowLegacyPrivateRoute = true
            phone.start()
            cloud.deliver(RelayMessage(type: "peer", online: true))
            let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
            let request = try cipher.open(try XCTUnwrap(cloud.sent.last?.payload), sender: "client")
            let session = String(repeating: "d", count: 64)
            func incoming(_ kind: String, body: Data? = nil, sequence: UInt64) throws -> RelayMessage {
                RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: kind,
                    request: request.request, session: session, sequence: sequence, body: body), sender: "host"))
            }
            cloud.deliver(try incoming("challenge", sequence: 0))
            var hostile = invitation
            if field == 0 { hostile.durableHostID = String(repeating: "f", count: 64) }
            if field == 1 { hostile.ownerPairID = String(repeating: "e", count: 64) }
            if field == 2 { hostile.localServiceName = "other-mac" }
            cloud.deliver(try incoming("accepted", body: JSONEncoder().encode(hostile), sequence: 1))
            XCTAssertEqual(phone.invitation, invitation, "Rejected identity mutation must not persist trust")
            XCTAssertFalse(phone.isRunning); XCTAssertNil(phone.media)
        }
    }

    func testDuplicateAcceptedCannotStartConcurrentLocalProofPreparation() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(), release = DispatchSemaphore(value: 0)
            var count = 0
            func begin() { lock.lock(); count += 1; lock.unlock() }
            func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let counter = Counter(), started = expectation(description: "Injected proof preparation started")
        let (phone, _, local, invitation) = try fixture { _, _, _, _ in
            counter.begin(); started.fulfill()
            _ = counter.release.wait(timeout: .now() + 5)
            return nil // Never consult interfaces or start a real local listener in this fixture.
        }
        defer { counter.release.signal(); phone.stop() }
        phone.setLocalOnly(true); phone.start()
        local.onAuthenticatedLocalSignaling?(try LocalOwnerChallenge.make(invitation: invitation))
        local.onMessage?(RelayMessage(type: "peer", online: true))
        let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let request = try cipher.open(try XCTUnwrap(local.sent.last?.payload), sender: "client")
        let session = String(repeating: "d", count: 64)
        func incoming(_ kind: String, sequence: UInt64) throws -> RelayMessage {
            RelayMessage(type: "signal", payload: try cipher.seal(ProtectedMessage(kind: kind,
                request: request.request, session: session, sequence: sequence), sender: "host"))
        }
        local.onMessage?(try incoming("challenge", sequence: 0))
        local.onMessage?(try incoming("accepted", sequence: 1))
        await fulfillment(of: [started], timeout: 2)
        local.onMessage?(try incoming("accepted", sequence: 2))
        await Task.yield()
        XCTAssertEqual(counter.read(), 1)
        XCTAssertNil(phone.media); XCTAssertFalse(phone.connected)
        phone.stop(); counter.release.signal()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(phone.isRunning); XCTAssertNil(phone.media)
    }

}
