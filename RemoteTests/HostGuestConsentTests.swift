import XCTest
import CryptoKit

final class HostGuestConsentTests: XCTestCase {
    @MainActor
    func testRetiredCaptureSourceCannotFenceReplacementGuestFanout() {
        let source = CaptureScopeLease(validUntil: 10, clock: { 1 })
        let fanout = HostGuestController.Fanout()
        let lease = GuestCaptureLease(grantID: String(repeating: "a", count: 64), ownerSessionID: String(repeating: "b", count: 64), scopeEpoch: "2", geometryEpoch: "2", expiresAt: 10, clock: { 1 })
        let replacement = GuestMediaPeer(servers: [], lease: lease)
        defer { replacement.close() }
        source.invalidate() // Stop's actual source fence happens before replacing its guest peers.
        fanout.replace([replacement]); lease.permit(until: 10)
        XCTAssertFalse(source.performIfValid { fanout.fence() })
        XCTAssertTrue(lease.deliver {}, "Delayed old-source callback cannot retire a new peer")
        fanout.fence()
        XCTAssertFalse(lease.deliver {}, "Current source/filter change fences guest media synchronously")
    }
    @MainActor
    func testOwnerApprovalRequiresExactCurrentScopeAndRecipientRequest() throws {
        let controller = HostGuestController()
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        var context: HostGuestContext? = HostGuestContext(room: a, hostID: b, origin: "https://fixture.invalid", ownerSessionID: a, scopeEpoch: "1", geometryEpoch: "2", scopeKind: "window", deadline: Date().addingTimeInterval(900))
        controller.context = { context }
        var outgoing: [GuestRelayFrame] = []
        controller.send = { outgoing.append($0); return true }
        controller.create()
        let invite = try XCTUnwrap(outgoing.first), id = try XCTUnwrap(invite.grantID)
        XCTAssertEqual(invite.mode, "view"); XCTAssertEqual(invite.scopeKind, "window")
        controller.receive(GuestRelayFrame(operation: "created", grantID: id, expiresAt: invite.expiresAt))
        let recipient = P256.Signing.PrivateKey(), agreement = P256.KeyAgreement.PrivateKey()
        let key = recipient.publicKey.x963Representation.base64EncodedString(), other = agreement.publicKey.x963Representation.base64EncodedString()
        let signature = try GuestCrypto.sign(["request", "https://fixture.invalid", a, id, key, other, b], key: recipient)
        controller.receive(GuestRelayFrame(operation: "pending", grantID: id, publicKey: key, requestID: a, agreementKey: other, nonce: b, signature: signature))
        XCTAssertEqual(controller.rows.first?.fingerprint, GuestCrypto.hash(recipient.publicKey.x963Representation)); XCTAssertEqual(controller.rows.first?.pending, true)
        XCTAssertFalse(outgoing.contains(where: { $0.operation == "approve" }))
        // Explicit action creates only the recipient-bound grant; no peer or media before service ready.
        controller.approve(id)
        let approval = try XCTUnwrap(outgoing.last), grant = try XCTUnwrap(approval.grant)
        XCTAssertEqual(approval.operation, "approve"); XCTAssertEqual(grant.requestID, a); XCTAssertEqual(grant.recipientPublicKey, key)
        XCTAssertEqual(grant.recipientAgreementKey, other); XCTAssertEqual(grant.scopeEpoch, "1"); XCTAssertEqual(grant.geometryEpoch, "2")
        XCTAssertTrue(GuestCrypto.verify(grant.signedFields, signature: try XCTUnwrap(approval.signature), publicKey: try XCTUnwrap(invite.publicKey)))
        controller.endAll(); XCTAssertTrue(controller.rows.isEmpty); XCTAssertEqual(outgoing.last?.operation, "revoke")
        context = nil; controller.approve(id); XCTAssertEqual(outgoing.last?.operation, "revoke")
    }
    @MainActor
    func testChangingContextBeforeExplicitApprovalAndForgedRequestCannotAllocatePeer() throws {
        let controller = HostGuestController(), a = String(repeating: "a", count: 64)
        var current: HostGuestContext? = HostGuestContext(room: a, hostID: a, origin: "https://fixture.invalid", ownerSessionID: a, scopeEpoch: "1", geometryEpoch: "1", scopeKind: "display", deadline: Date().addingTimeInterval(900))
        controller.context = { current }; var outgoing: [GuestRelayFrame] = []; controller.send = { outgoing.append($0); return true }
        controller.create(); let id = try XCTUnwrap(outgoing.first?.grantID)
        current = HostGuestContext(room: a, hostID: a, origin: "https://fixture.invalid", ownerSessionID: a, scopeEpoch: "2", geometryEpoch: "2", scopeKind: "window", deadline: Date().addingTimeInterval(900))
        controller.approve(id); XCTAssertEqual(outgoing.count, 1)
        controller.endAll(); controller.create(); let invite = try XCTUnwrap(outgoing.last)
        controller.receive(GuestRelayFrame(operation: "created", grantID: invite.grantID, expiresAt: invite.expiresAt))
        controller.receive(GuestRelayFrame(operation: "pending", grantID: invite.grantID, publicKey: "forged", requestID: a, agreementKey: "forged", nonce: a, signature: "forged"))
        XCTAssertTrue(controller.rows.isEmpty); XCTAssertFalse(outgoing.contains(where: { $0.operation == "approve" }))
    }
    func testServiceResetRequiresCurrentRouteExactVariantAndRejectsReplay() {
        var gate = GuestServiceResetGate()
        let epoch = String(repeating: "a", count: 32), nonce = String(repeating: "b", count: 64)
        let reset = GuestRelayFrame(operation: "serviceReset", nonce: nonce, code: epoch)
        XCTAssertFalse(gate.accept(reset, currentEpoch: nil))
        XCTAssertFalse(gate.accept(reset, currentEpoch: "other"))
        var mutated = reset; mutated.grantID = nonce
        XCTAssertFalse(gate.accept(mutated, currentEpoch: epoch))
        XCTAssertTrue(gate.accept(reset, currentEpoch: epoch))
        XCTAssertFalse(gate.accept(reset, currentEpoch: epoch))
    }
    private final class FixtureClock: @unchecked Sendable {
        let lock = NSLock(); private var value: Double = 1
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ next: Double) { lock.lock(); value = next; lock.unlock() }
    }
    @MainActor
    private func activeFixture() throws -> (HostGuestController, FixtureClock, GuestCaptureLease, () -> [GuestRelayFrame], GuestGrant, String) {
        let clock = FixtureClock(); var retained: GuestCaptureLease?
        let controller = HostGuestController(clock: { clock.now() }, makePeer: { servers, lease in
            retained = lease; return GuestMediaPeer(servers: servers, lease: lease)
        })
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let context = HostGuestContext(room: a, hostID: b, origin: "https://fixture.invalid", ownerSessionID: a, scopeEpoch: "1", geometryEpoch: "2", scopeKind: "window", deadline: Date().addingTimeInterval(900))
        controller.context = { context }; var outgoing: [GuestRelayFrame] = []
        controller.send = { outgoing.append($0); return true }; controller.create()
        let invite = try XCTUnwrap(outgoing.first), id = try XCTUnwrap(invite.grantID)
        controller.receive(GuestRelayFrame(operation: "created", grantID: id, expiresAt: invite.expiresAt))
        let recipient = P256.Signing.PrivateKey(), agreement = P256.KeyAgreement.PrivateKey()
        let key = recipient.publicKey.x963Representation.base64EncodedString(), other = agreement.publicKey.x963Representation.base64EncodedString()
        let signature = try GuestCrypto.sign(["request", context.origin, a, id, key, other, b], key: recipient)
        controller.receive(GuestRelayFrame(operation: "pending", grantID: id, publicKey: key, requestID: a, agreementKey: other, nonce: b, signature: signature))
        controller.approve(id); let grant = try XCTUnwrap(outgoing.last?.grant)
        let session = GuestCrypto.hash(GuestCrypto.canonical(grant.signedFields))
        controller.receive(GuestRelayFrame(operation: "ready", grantID: id, expiresAt: grant.expiresAt, sessionID: session, servers: [ICEServerConfiguration(urls: ["stun:127.0.0.1:9"])]))
        return (controller, clock, try XCTUnwrap(retained), { outgoing }, grant, session)
    }
    @MainActor
    func testMissingServiceProofClosesActualNativeLeaseAndCannotReenable() throws {
        E2EMedia.loopbackOnly = true; defer { E2EMedia.loopbackOnly = false }
        let (controller, clock, lease, outgoing, grant, session) = try activeFixture()
        defer { controller.endAll() }
        for _ in 0..<4 { controller.refreshAuthority() }
        let check = try XCTUnwrap(outgoing().last(where: { $0.operation == "check" }))
        clock.set(1.5)
        controller.receive(GuestRelayFrame(operation: "alive", grantID: grant.grantID, expiresAt: grant.expiresAt, nonce: check.nonce, sessionID: session))
        // Replaying the accepted nonce cannot extend the current deadline again.
        clock.set(3.4)
        controller.receive(GuestRelayFrame(operation: "alive", grantID: grant.grantID, expiresAt: grant.expiresAt, nonce: check.nonce, sessionID: session))
        lease.permit(until: 10); XCTAssertTrue(lease.deliver {})
        clock.set(3.5); controller.refreshAuthority()
        XCTAssertTrue(controller.rows.isEmpty); XCTAssertFalse(lease.deliver {})
        lease.permit(until: 10); XCTAssertFalse(lease.deliver {})
        XCTAssertEqual(outgoing().last?.operation, "revoke")
    }
    @MainActor
    func testServiceRestartClosesActualLeaseAndMalformedVariantCannotRetireIt() throws {
        E2EMedia.loopbackOnly = true; defer { E2EMedia.loopbackOnly = false }
        let (controller, _, lease, _, grant, _) = try activeFixture()
        defer { controller.endAll() }
        lease.permit(until: 10)
        controller.receive(GuestRelayFrame(operation: "serviceReset", grantID: grant.grantID, nonce: String(repeating: "b", count: 64), code: String(repeating: "a", count: 32)))
        XCTAssertTrue(lease.deliver {}); XCTAssertEqual(controller.rows.count, 1)
        controller.receive(GuestRelayFrame(operation: "serviceReset", nonce: String(repeating: "b", count: 64), code: String(repeating: "a", count: 32)))
        XCTAssertTrue(controller.rows.isEmpty); XCTAssertFalse(lease.deliver {})
    }

}
