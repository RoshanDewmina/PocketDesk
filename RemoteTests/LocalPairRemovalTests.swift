import XCTest

private final class RemovalTrust: PairPersistence {
    var data: Data?
    var refuseDeletion = false
    var leaveRecordAfterDeletion = false
    var refuseRead = false
    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        if refuseRead { throw RemoteError.keychain(-25308) }
        return try data.map { try JSONDecoder().decode(type, from: $0) }
    }
    func delete() throws {
        if refuseDeletion { throw RemoteError.keychain(-25308) }
        if !leaveRecordAfterDeletion { data = nil }
    }
}

@MainActor
final class LocalPairRemovalTests: XCTestCase {
    private func makeHost(_ trust: RemovalTrust) throws -> RemoteCoordinator {
        let pair = try HostPair.create(server: "wss://signal-staging.getfarside.com/signal", name: "Fixture").rotated()
        try trust.save(pair)
        let host = RemoteCoordinator(isHost: true, store: trust, signaling: ScriptedSignaling())
        host.restore()
        return host
    }

    func testFailedDeletionStopsConnectionRetainsTrustAndSupportsRetry() throws {
        let trust = RemovalTrust(), host = try makeHost(trust)
        let original = host.hostPair?.invitation
        trust.refuseDeletion = true
        host.start()
        XCTAssertTrue(host.isRunning)
        host.revoke()
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(host.hostPair?.invitation, original)
        XCTAssertEqual(host.pairingRemovalFailure, "delete:-25308")
        XCTAssertNotNil(try trust.read(HostPair.self))
        trust.refuseDeletion = false
        host.revoke()
        XCTAssertNil(host.hostPair)
        XCTAssertNil(host.invitation)
        XCTAssertNil(host.pairingRemovalFailure)
        XCTAssertNil(try trust.read(HostPair.self))
        let relaunched = RemoteCoordinator(isHost: true, store: trust, signaling: ScriptedSignaling())
        relaunched.restore()
        XCTAssertNil(relaunched.hostPair)
    }

    func testDeletionMustConfirmAuthoritativeAbsenceBeforeClearingHostTrust() throws {
        let trust = RemovalTrust(), host = try makeHost(trust)
        trust.leaveRecordAfterDeletion = true
        host.revoke()
        XCTAssertNotNil(host.hostPair, "A retained persistent record cannot be reported as removed")
        XCTAssertNotNil(host.invitation)
        XCTAssertFalse(host.isRunning)
        XCTAssertTrue(host.status.contains("could not be removed"))
        XCTAssertEqual(host.pairingRemovalFailure, "verify:record-remains")
    }

    func testReadFailureAfterDeletionRemainsRetryable() throws {
        let trust = RemovalTrust(), host = try makeHost(trust)
        trust.refuseRead = true
        host.revoke()
        XCTAssertNotNil(host.hostPair)
        XCTAssertNotNil(host.invitation)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(host.pairingRemovalFailure, "verify:-25308")
        trust.refuseRead = false
        host.revoke()
        XCTAssertNil(host.hostPair)
        XCTAssertNil(host.invitation)
        XCTAssertNil(host.pairingRemovalFailure)
    }

    func testPhoneRemovalAlsoConfirmsPersistentAbsence() throws {
        let trust = RemovalTrust()
        let invitation = try HostPair.create(server: "wss://signal-staging.getfarside.com/signal", name: "Fixture").invitation
        try trust.save(invitation)
        let phone = RemoteCoordinator(isHost: false, store: trust, signaling: ScriptedSignaling())
        phone.restore()
        trust.leaveRecordAfterDeletion = true
        phone.revoke()
        XCTAssertEqual(phone.invitation, invitation)
        trust.leaveRecordAfterDeletion = false
        phone.revoke()
        XCTAssertNil(phone.invitation)
    }
}
