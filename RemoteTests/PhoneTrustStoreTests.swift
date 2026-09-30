import XCTest
#if canImport(TrustFoundation)
@testable import TrustFoundation
#endif

private final class TrustFixturePersistence: PairPersistence {
    var data: Data?
    var refuseRead = false
    var refuseWrite = false
    var refuseDelete = false
    var retainAfterDelete = false
    func save<T: Encodable>(_ value: T) throws {
        if refuseWrite { throw RemoteError.keychain(-25308) }
        data = try JSONEncoder().encode(value)
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        if refuseRead { throw RemoteError.keychain(-25308) }
        return try data.map { try JSONDecoder().decode(type, from: $0) }
    }
    func delete() throws {
        if refuseDelete { throw RemoteError.keychain(-25308) }
        if !retainAfterDelete { data = nil }
    }
}

final class PhoneTrustStoreTests: XCTestCase {
    private func pair(name: String = "Mac", identified: Bool = false) throws -> PairInvitation {
        var invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: name).rotated().invitation
        if identified {
            invitation.durableHostID = try SecureRandom.token()
            invitation.ownerPairID = try SecureRandom.token()
            invitation.localServiceName = "fixture"
        }
        return invitation
    }
    func testLegacyMigrationRetainsExactBackupAndStableSelectionAcrossRelaunch() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence(), old = try pair()
        try legacy.save(old)
        let backup = legacy.data
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        let first = try trust.snapshot()
        XCTAssertEqual(first.selected?.invitation, old)
        XCTAssertNil(first.selected?.durableHostID, "Legacy room alias is not durable host evidence")
        XCTAssertEqual(first.selected?.legacyAliases, [PhoneTrustStore.legacyAlias(room: old.room)])
        XCTAssertEqual(legacy.data, backup)
        XCTAssertEqual(try PhoneTrustStore(records: records, legacy: legacy).snapshot(), first)
    }
    func testMigrationWriteFailurePreservesLegacyAndCanRetry() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence(), old = try pair()
        try legacy.save(old); records.refuseWrite = true
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        XCTAssertThrowsError(try trust.snapshot())
        XCTAssertNil(records.data)
        XCTAssertEqual(try legacy.read(PairInvitation.self), old)
        records.refuseWrite = false
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old)
    }
    func testExistingCorruptOrUnknownV2NeverFallsBackToLegacy() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence()
        try legacy.save(pair())
        records.data = Data("broken".utf8)
        let corrupt = records.data
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        XCTAssertThrowsError(try trust.snapshot())
        XCTAssertEqual(records.data, corrupt)
        var unknown = PhoneTrustSnapshot(); unknown.version = 999
        try records.save(unknown)
        XCTAssertThrowsError(try trust.snapshot())
        records.refuseRead = true
        XCTAssertThrowsError(try trust.snapshot())
    }
    func testHostIdentitySurvivesRoomAndOwnerReplacementWhileOtherHostCannotCross() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence()
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        var a = try pair(name: "A", identified: true), b = try pair(name: "B", identified: true)
        try trust.saveApproved(a); let aID = try XCTUnwrap(trust.snapshot().selectedHostID)
        try trust.saveApproved(b); let bID = try XCTUnwrap(trust.snapshot().selectedHostID)
        XCTAssertNotEqual(aID, bID)
        a.room = try SecureRandom.token(); a.token = try SecureRandom.token(); a.ownerPairID = try SecureRandom.token()
        try trust.saveApproved(a)
        XCTAssertEqual(try trust.snapshot().selectedHostID, aID)
        XCTAssertEqual(try trust.snapshot().hosts.count, 2)
        try trust.select(hostID: bID)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, b)
        var spoof = b; spoof.durableHostID = a.durableHostID
        XCTAssertThrowsError(try trust.saveApproved(spoof))
        XCTAssertEqual(try trust.snapshot().selected?.invitation, b)
        spoof = b; spoof.durableHostID = nil
        XCTAssertThrowsError(try trust.saveApproved(spoof))
    }
    func testFailedSelectionAndUnknownDestinationDoNotMutateSelection() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence()
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        try trust.saveApproved(pair(identified: true)); let first = try trust.snapshot()
        try trust.saveApproved(pair(identified: true)); let selected = try trust.snapshot()
        records.refuseWrite = true
        XCTAssertThrowsError(try trust.select(hostID: XCTUnwrap(first.selectedHostID)))
        XCTAssertEqual(try trust.snapshot(), selected)
        records.refuseWrite = false
        XCTAssertThrowsError(try trust.select(hostID: SecureRandom.token()))
        XCTAssertEqual(try trust.snapshot(), selected)
    }
    func testForgetOneHostDoesNotAutoSelectAnotherOrResurrectLegacy() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence(), old = try pair()
        try legacy.save(old)
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        let oldID = try XCTUnwrap(trust.snapshot().selectedHostID)
        let other = try pair(identified: true)
        try trust.saveApproved(other)
        let otherID = try XCTUnwrap(trust.snapshot().selectedHostID)
        try trust.forget(hostID: otherID)
        let adapter = PhonePairPersistence(trust: trust)
        XCTAssertNil(try adapter.read(PairInvitation.self))
        XCTAssertEqual(try trust.snapshot().hosts.count, 1)
        try trust.select(hostID: oldID)
        try adapter.delete()
        XCTAssertNil(legacy.data)
        XCTAssertEqual(try trust.snapshot().hosts.count, 0)
        // Even a restored obsolete backup cannot reactivate authority after the v2 tombstone.
        try legacy.save(old)
        XCTAssertNil(try PhoneTrustStore(records: records, legacy: legacy).snapshot().selected)
    }
    func testForgetBackupDeletionFailureRetainsActiveTrustAndRetryIsSafe() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence(), old = try pair()
        try legacy.save(old)
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        let selected = try trust.snapshot()
        legacy.refuseDelete = true
        XCTAssertThrowsError(try trust.forget(hostID: XCTUnwrap(selected.selectedHostID)))
        XCTAssertEqual(try trust.snapshot(), selected)
        legacy.refuseDelete = false; legacy.retainAfterDelete = true
        XCTAssertThrowsError(try trust.forget(hostID: XCTUnwrap(selected.selectedHostID)))
        XCTAssertEqual(try trust.snapshot(), selected)
        legacy.retainAfterDelete = false; records.refuseWrite = true
        XCTAssertThrowsError(try trust.forget(hostID: XCTUnwrap(selected.selectedHostID)))
        XCTAssertEqual(try trust.snapshot(), selected, "v2 authority remains safe if commit fails after backup deletion")
        records.refuseWrite = false
        try trust.forget(hostID: XCTUnwrap(selected.selectedHostID))
        XCTAssertNil(try trust.snapshot().selected)
    }
    func testForgetDeletesHistoricalBackupAfterDurableHostChangesRoom() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence()
        var old = try pair()
        try legacy.save(old)
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        let legacyID = try XCTUnwrap(trust.snapshot().selectedHostID)
        old.durableHostID = try SecureRandom.token(); old.ownerPairID = try SecureRandom.token()
        try trust.saveApproved(old)
        old.room = try SecureRandom.token(); old.key = try SecureRandom.bytes(); old.token = try SecureRandom.token()
        try trust.saveApproved(old)
        XCTAssertEqual(try trust.snapshot().selectedHostID, legacyID)
        XCTAssertNotNil(legacy.data)
        try trust.forget(hostID: legacyID)
        XCTAssertNil(legacy.data, "A historical rollback credential must be removed with its host")
        XCTAssertNil(try trust.snapshot().selected)
    }
    func testAtomicSnapshotRejectsDuplicateHostsAndMissingSelection() throws {
        let invitation = try pair(identified: true)
        let host = PhoneHostTrust(id: try SecureRandom.token(), durableHostID: invitation.durableHostID,
                                  ownerPairID: invitation.ownerPairID, invitation: invitation, legacyAliases: [])
        XCTAssertThrowsError(try PhoneTrustSnapshot(hosts: [host, host], selectedHostID: host.id).validate())
        XCTAssertThrowsError(try PhoneTrustSnapshot(hosts: [host], selectedHostID: SecureRandom.token()).validate())
    }
    func testLegacyInvitationDecodesWithoutNewOptionalIdentityAndInvalidIDsFailClosed() throws {
        let invitation = try pair()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(invitation)) as? [String: Any])
        object.removeValue(forKey: "durableHostID"); object.removeValue(forKey: "ownerPairID"); object.removeValue(forKey: "localServiceName")
        let decoded = try JSONDecoder().decode(PairInvitation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, invitation)
        var invalid = invitation; invalid.durableHostID = "room"
        XCTAssertThrowsError(try invalid.validate(enrollment: false))
        invalid = invitation; invalid.ownerPairID = "purchase-restored"
        XCTAssertThrowsError(try invalid.validate(enrollment: false))
        invalid = invitation; invalid.localServiceName = "bad\nname"
        XCTAssertThrowsError(try invalid.validate(enrollment: false))
    }
}
