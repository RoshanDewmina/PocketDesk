import XCTest

@MainActor
final class EnrollmentCoordinatorTests: XCTestCase {
    private func fixture() throws -> (RemoteCoordinator, ScriptedSignaling, PhoneTrustStore, PairInvitation) {
        var old = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac",
            identity: HostIdentityRecord(hostID: String(repeating: "a", count: 64), localServiceName: "fixture")).rotated().invitation
        old.expires = Date().addingTimeInterval(120)
        let trust = PhoneTrustStore(records: MemoryPairStore(), legacy: MemoryPairStore())
        try trust.saveApproved(old)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: PhonePairPersistence(trust: trust), signaling: signaling)
        phone.restore()
        return (phone, signaling, trust, old)
    }

    func testSameHostAndGrantChangedQRRequiresApprovalBeforeRetiringCurrentSession() throws {
        let (phone, signaling, trust, old) = try fixture()
        defer { phone.stop() }
        phone.start()
        var scanned = old; scanned.key = try SecureRandom.bytes(); scanned.token = try SecureRandom.token()
        XCTAssertThrowsError(try phone.enroll(scanned.code()))
        XCTAssertEqual(phone.invitation, old)
        XCTAssertEqual(signaling.connects.count, 1)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old)
        let request = try XCTUnwrap(trust.replacementRequest(for: scanned))
        try phone.enroll(scanned.code(), replacementApproval: PhoneTrustReplacementApproval(request: request, enrollment: scanned))
        XCTAssertEqual(phone.invitation, scanned)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old, "Enrollment is not saved before the host accepts")
        phone.stop()
        XCTAssertEqual(phone.invitation, old, "End must retire scanned authority and restore the persisted selection")
    }

    func testInterruptedEnrollmentDoesNotRetryAsUnscannedRotation() throws {
        let (phone, signaling, trust, old) = try fixture()
        defer { phone.stop() }
        var scanned = old; scanned.key = try SecureRandom.bytes()
        let request = try XCTUnwrap(trust.replacementRequest(for: scanned))
        try phone.enroll(scanned.code(), replacementApproval: PhoneTrustReplacementApproval(request: request, enrollment: scanned))
        signaling.onClose?()
        XCTAssertFalse(phone.isRunning)
        XCTAssertFalse(phone.reconnecting)
        XCTAssertEqual(phone.invitation, old)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old)
        phone.start()
        XCTAssertEqual(signaling.connects.last?.invitation, old)
    }

    func testForgetCapturedMacCannotDeleteLaterPersistentSelection() throws {
        let (phone, _, trust, old) = try fixture()
        defer { phone.stop() }
        let other = try HostPair.create(server: "wss://offline.invalid/signal", name: "Other Mac").rotated().invitation
        try trust.saveApproved(other)
        XCTAssertEqual(phone.invitation, old, "Simulate a persistent selection change while the owner prompt is pending")
        XCTAssertFalse(phone.revoke(expectedInvitation: old))
        XCTAssertEqual(try trust.snapshot().selected?.invitation, other)
        XCTAssertEqual(try trust.snapshot().hosts.count, 2)
    }
}
