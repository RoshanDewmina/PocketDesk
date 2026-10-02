import XCTest
#if canImport(TrustFoundation)
@testable import TrustFoundation
#endif

private final class TrustFixturePersistence: PairPersistence {
    var data: Data?
    var reads = 0
    var refuseRead = false
    var refuseWrite = false
    var refuseDelete = false
    var retainAfterDelete = false
    func save<T: Encodable>(_ value: T) throws {
        if refuseWrite { throw RemoteError.keychain(-25308) }
        data = try JSONEncoder().encode(value)
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        reads += 1
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
        invitation.expires = Date().addingTimeInterval(120)
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
    func testSnapshotIsReadFromTheKeychainOnceAndRefreshedByEveryCommit() throws {
        let legacy = TrustFixturePersistence(), records = TrustFixturePersistence()
        let trust = PhoneTrustStore(records: records, legacy: legacy, cachesSnapshot: true)
        try trust.saveApproved(pair(identified: true))
        let first = try trust.snapshot()
        let reads = records.reads
        for _ in 0..<60 { XCTAssertEqual(try trust.snapshot(), first) }
        XCTAssertEqual(records.reads, reads, "Sixty reads on the main thread cost no Keychain round trip")
        XCTAssertEqual(legacy.reads, 1, "The legacy backup is consulted once, on the first load")

        let second = try pair(identified: true)
        try trust.saveApproved(second)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, second, "A commit refreshes what readers see")
        let afterCommit = records.reads
        XCTAssertEqual(try trust.snapshot().selected?.invitation, second)
        XCTAssertEqual(records.reads, afterCommit)

        records.refuseWrite = true
        XCTAssertThrowsError(try trust.select(hostID: XCTUnwrap(first.selectedHostID)))
        records.refuseWrite = false
        let beforeReread = records.reads
        XCTAssertEqual(try trust.snapshot().selected?.invitation, second)
        XCTAssertEqual(records.reads, beforeReread + 1, "A failed commit sends the next read back to the Keychain")

        try trust.forget(hostID: XCTUnwrap(first.selectedHostID))
        XCTAssertEqual(try trust.snapshot().hosts.count, 1, "Forgetting refreshes the copy")
        let adapter = PhonePairPersistence(trust: trust)
        XCTAssertEqual(try adapter.read(PairInvitation.self), second)
        try adapter.delete()
        XCTAssertEqual(try trust.snapshot().hosts.count, 0, "The adapter's delete refreshes the copy")
        XCTAssertNil(try adapter.read(PairInvitation.self))

        let uncached = PhoneTrustStore(records: records, legacy: legacy, cachesSnapshot: false)
        let start = records.reads
        _ = try uncached.snapshot(); _ = try uncached.snapshot()
        XCTAssertEqual(records.reads, start + 2, "The kill switch reads every time, as before")
        XCTAssertEqual(PhoneTrustStore.cacheKey, "trust.cacheSnapshot")
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
        XCTAssertThrowsError(try trust.saveApproved(a))
        let request = try XCTUnwrap(trust.replacementRequest(for: a))
        try trust.saveApproved(a, scannedEnrollment: a, replacementApproval: PhoneTrustReplacementApproval(request: request, enrollment: a))
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
        let upgrade = try XCTUnwrap(trust.replacementRequest(for: old))
        try trust.saveApproved(old, scannedEnrollment: old, replacementApproval: PhoneTrustReplacementApproval(request: upgrade, enrollment: old))
        old.room = try SecureRandom.token(); old.key = try SecureRandom.bytes(); old.token = try SecureRandom.token()
        let replacement = try XCTUnwrap(trust.replacementRequest(for: old))
        try trust.saveApproved(old, scannedEnrollment: old, replacementApproval: PhoneTrustReplacementApproval(request: replacement, enrollment: old))
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
    func testReplacementApprovalBindsOldRecordAndExactScannedQRWhileAllowingAcceptedRotation() throws {
        let records = TrustFixturePersistence(), legacy = TrustFixturePersistence()
        let trust = PhoneTrustStore(records: records, legacy: legacy)
        let old = try pair(identified: true)
        try trust.saveApproved(old)
        let initial = try trust.snapshot()
        var qr = old
        qr.room = try SecureRandom.token()
        qr.ownerPairID = try SecureRandom.token()
        let approval = PhoneTrustReplacementApproval(request: try XCTUnwrap(trust.replacementRequest(for: qr)), enrollment: qr)
        var accepted = qr
        accepted.key = try SecureRandom.bytes()
        accepted.token = try SecureRandom.token()
        XCTAssertThrowsError(try trust.saveApproved(accepted, scannedEnrollment: qr))
        XCTAssertEqual(try trust.snapshot(), initial)
        var hostile = accepted
        hostile.ownerPairID = try SecureRandom.token()
        XCTAssertThrowsError(try trust.saveApproved(hostile, scannedEnrollment: qr, replacementApproval: approval))
        XCTAssertEqual(try trust.snapshot(), initial)
        var changedQR = qr
        changedQR.key = try SecureRandom.bytes()
        let mismatched = PhoneTrustReplacementApproval(request: approval.request, enrollment: changedQR)
        XCTAssertThrowsError(try trust.saveApproved(accepted, scannedEnrollment: qr, replacementApproval: mismatched))
        XCTAssertEqual(try trust.snapshot(), initial)
        try trust.saveApproved(accepted, scannedEnrollment: qr, replacementApproval: approval)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, accepted)
        XCTAssertThrowsError(try trust.saveApproved(accepted, scannedEnrollment: qr, replacementApproval: approval), "approval cannot replay")
    }

    func testStaleApprovalCannotReplaceRotatedOrRemovedRecord() throws {
        let trust = PhoneTrustStore(records: TrustFixturePersistence(), legacy: TrustFixturePersistence())
        var old = try pair(identified: true)
        try trust.saveApproved(old)
        var qr = old; qr.ownerPairID = try SecureRandom.token()
        let approval = PhoneTrustReplacementApproval(request: try XCTUnwrap(trust.replacementRequest(for: qr)), enrollment: qr)
        old.token = try SecureRandom.token()
        try trust.saveApproved(old)
        XCTAssertThrowsError(try trust.saveApproved(qr, scannedEnrollment: qr, replacementApproval: approval))
        XCTAssertEqual(try trust.snapshot().selected?.invitation, old)
        try trust.forget(hostID: XCTUnwrap(trust.snapshot().selectedHostID))
        XCTAssertThrowsError(try trust.saveApproved(qr, scannedEnrollment: qr, replacementApproval: approval))
        XCTAssertNil(try trust.snapshot().selected)
    }

    func testOrdinaryOwnerKeyRotationRetainsHostWithoutReplacementApproval() throws {
        let trust = PhoneTrustStore(records: TrustFixturePersistence(), legacy: TrustFixturePersistence())
        var invitation = try pair(identified: true)
        try trust.saveApproved(invitation)
        let id = try XCTUnwrap(trust.snapshot().selectedHostID)
        invitation.token = try SecureRandom.token(); invitation.key = try SecureRandom.bytes()
        XCTAssertNotNil(try trust.replacementRequest(for: invitation), "a fresh explicit QR still asks before replacing credentials")
        try trust.saveApproved(invitation)
        XCTAssertEqual(try trust.snapshot().selectedHostID, id)
        XCTAssertEqual(try trust.snapshot().selected?.invitation, invitation)
    }

    func testExplicitSameIdentityQRKeyOrTokenChangesRequireExactReplacementApproval() throws {
        for changeKey in [true, false] {
            let trust = PhoneTrustStore(records: TrustFixturePersistence(), legacy: TrustFixturePersistence())
            let old = try pair(identified: true)
            try trust.saveApproved(old)
            let initial = try trust.snapshot()
            var qr = old
            if changeKey { qr.key = try SecureRandom.bytes() } else { qr.token = try SecureRandom.token() }
            let approval = PhoneTrustReplacementApproval(request: try XCTUnwrap(trust.replacementRequest(for: qr)), enrollment: qr)
            var accepted = qr
            accepted.key = try SecureRandom.bytes(); accepted.token = try SecureRandom.token()
            XCTAssertThrowsError(try trust.saveApproved(accepted, scannedEnrollment: qr))
            XCTAssertEqual(try trust.snapshot(), initial)
            try trust.saveApproved(accepted, scannedEnrollment: qr, replacementApproval: approval)
            XCTAssertEqual(try trust.snapshot().selected?.invitation, accepted)
        }
    }

    func testExpiredScannedEnrollmentCannotUseApprovalAtAcceptedSave() throws {
        let trust = PhoneTrustStore(records: TrustFixturePersistence(), legacy: TrustFixturePersistence())
        let old = try pair(identified: true)
        try trust.saveApproved(old)
        let initial = try trust.snapshot()
        var qr = old; qr.key = try SecureRandom.bytes()
        let approvedRequest = try XCTUnwrap(trust.replacementRequest(for: qr))
        qr.expires = Date().addingTimeInterval(-1)
        let expired = PhoneTrustReplacementApproval(request: approvedRequest, enrollment: qr)
        var accepted = qr; accepted.expires = .distantFuture
        XCTAssertThrowsError(try trust.saveApproved(accepted, scannedEnrollment: qr, replacementApproval: expired))
        XCTAssertEqual(try trust.snapshot(), initial)
    }

    func testUnscannedAuthenticatedRotationCannotChangeRoutingIdentityOrConsumeEnrollmentApproval() throws {
        let trust = PhoneTrustStore(records: TrustFixturePersistence(), legacy: TrustFixturePersistence())
        let old = try pair(identified: true)
        try trust.saveApproved(old)
        let initial = try trust.snapshot()
        var different = old; different.room = try SecureRandom.token()
        XCTAssertThrowsError(try trust.saveApproved(different))
        let approval = PhoneTrustReplacementApproval(request: try XCTUnwrap(trust.replacementRequest(for: different)), enrollment: different)
        XCTAssertThrowsError(try trust.saveApproved(different, replacementApproval: approval))
        XCTAssertEqual(try trust.snapshot(), initial)
    }

}

@MainActor
final class HostMultiDeviceTests: XCTestCase {
    func testAddingInvitationKeepsExistingRoomAndHostProof() throws {
        let store = MemoryPairStore()
        var original = try HostPair.create(server: "wss://example.com/signal", name: "Mac")
        original = try original.rotated()
        try store.save(original)
        let host = RemoteCoordinator(isHost: true, store: store)
        host.restore()
        let added = try host.createPair(server: original.invitation.server, name: "Mac")
        XCTAssertEqual(added.room, original.invitation.room)
        XCTAssertEqual(host.hostPair?.hostToken, original.hostToken)
        XCTAssertNotEqual(added.token, original.invitation.token)
        XCTAssertNotEqual(added.key, original.invitation.key)
    }
}


extension HostMultiDeviceTests {
    /// Exercise the actual v2 commitment, reveal and reciprocal confirmation before Mac consent.
    private func comparisonEnrollment(_ invitation: PairInvitation, host: RemoteCoordinator,
                                      transport: ScriptedSignaling) throws -> (cipher: SignalCipher, keys: PairEnrollment.Keys) {
        XCTAssertEqual(invitation.version, PairEnrollment.version)
        let qrCipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let ephemeral = try PairEnrollment.Ephemeral(), requestID = try SecureRandom.token()
        let handshake = MacShareBlocker.Handshake.phone
        let name = "Fixture iPad"
        let enrollment = PairEnrollment.Request(commitment: try PairEnrollment.commitment(
            invitation: invitation, requestID: requestID, reveal: ephemeral.reveal,
            handshake: handshake, phoneName: name), handshake: handshake, phoneName: name)
        let request = ProtectedMessage(kind: "enrollmentRequest", request: requestID, session: "", sequence: 0,
                                       body: try PairEnrollment.encoded(enrollment))
        transport.deliver(RelayMessage(type: "signal", payload: try qrCipher.seal(request, sender: "client")))
        let challengeMessage = try qrCipher.open(XCTUnwrap(transport.sent.last?.payload), sender: "host")
        XCTAssertEqual(challengeMessage.kind, "enrollmentChallenge")
        XCTAssertEqual(challengeMessage.request, requestID)
        XCTAssertEqual(challengeMessage.sequence, 0)
        let challenge = try PairEnrollment.decode(PairEnrollment.Challenge.self, body: challengeMessage.body)
        let keys = try PairEnrollment.derive(invitation: invitation, requestID: requestID,
            sessionID: challengeMessage.session, request: enrollment, challenge: challenge,
            phone: ephemeral.reveal, ephemeral: ephemeral, isHost: false)
        let proof = ProtectedMessage(kind: "enrollmentProof", request: requestID,
            session: challengeMessage.session, sequence: 0,
            body: try PairEnrollment.encoded(PairEnrollment.Proof(reveal: ephemeral.reveal,
                                                                 confirmation: keys.confirmation(role: "phone"))))
        transport.deliver(RelayMessage(type: "signal", payload: try qrCipher.seal(proof, sender: "client")))
        let sessionCipher = try SignalCipher(key: keys.sessionKey, room: invitation.room)
        let ready = try sessionCipher.open(XCTUnwrap(transport.sent.last?.payload), sender: "host")
        XCTAssertEqual(ready.kind, "enrollmentReady")
        XCTAssertEqual(ready.request, requestID)
        XCTAssertEqual(ready.session, challengeMessage.session)
        XCTAssertTrue(keys.confirms(try XCTUnwrap(ready.body), role: "host"))
        XCTAssertEqual(host.pairingComparisonCode, keys.comparisonCode)
        XCTAssertTrue(host.awaitingApproval)
        return (sessionCipher, keys)
    }

    private func catalog(count: Int = 2) throws -> HostPair {
        var root = try HostPair.create(server: "wss://example.com/signal", name: "Mac").rotated()
        root.devices = []
        root.phoneName = "iPhone"
        try root.rememberCurrentDevice(at: Date(timeIntervalSince1970: 10))
        for index in 1..<count {
            var next = try HostPair.create(server: root.invitation.server, name: "Mac").rotated()
            next.hostToken = root.hostToken; next.invitation.room = root.invitation.room
            next.devices = root.devices; next.phoneName = "iPad \(index)"
            try next.rememberCurrentDevice(at: Date(timeIntervalSince1970: Double(10 + index)))
            root = next
        }
        return root
    }

    func testLegacyMigrationPreservesExactSecretsAndName() throws {
        let store = MemoryPairStore()
        var original = try HostPair.create(server: "wss://example.com/signal", name: "Mac").rotated()
        original.phoneName = "Original iPhone"
        try store.save(original)
        let host = RemoteCoordinator(isHost: true, store: store)
        host.restore()
        XCTAssertEqual(host.invitation, original.invitation)
        XCTAssertEqual(host.pairedDevices.count, 1)
        XCTAssertEqual(host.pairedDevices.first?.phoneName, original.phoneName)
        let migrated = try XCTUnwrap(store.read(HostPair.self))
        XCTAssertEqual(migrated.hostToken, original.hostToken)
        XCTAssertEqual(migrated.devices?.first?.invitation, original.invitation)
        host.restore()
        XCTAssertEqual(host.pairedDevices.count, 1)
    }

    func testSixthInvitationFailsWithoutChangingTrustOrRoom() throws {
        let store = MemoryPairStore(), saved = try catalog(count: 5)
        try store.save(saved)
        let before = store.data
        let host = RemoteCoordinator(isHost: true, store: store)
        host.restore()
        XCTAssertThrowsError(try host.createPair(server: saved.invitation.server, name: "Mac")) { error in
            XCTAssertTrue(error.localizedDescription.contains("five devices"))
        }
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(host.pairedDevices.count, 5)
        XCTAssertEqual(host.invitation?.room, saved.invitation.room)
    }

    func testRemoveOneKeepsOtherKeysAndRemovingLastNeverResurrectsLegacyTrust() throws {
        let store = MemoryPairStore(), saved = try catalog()
        try store.save(saved)
        let host = RemoteCoordinator(isHost: true, store: store)
        host.restore()
        let first = saved.approvedDevices[0], second = saved.approvedDevices[1]
        XCTAssertTrue(host.removePairedDevice(second.id))
        host.restore()
        XCTAssertEqual(host.pairedDevices, [first])
        XCTAssertEqual(host.invitation, first.invitation)
        XCTAssertTrue(host.removePairedDevice(first.id))
        host.restore()
        XCTAssertTrue(host.pairedDevices.isEmpty)
        XCTAssertNil(host.invitation)
        let next = try host.createPair(server: saved.invitation.server, name: "Mac")
        XCTAssertEqual(next.room, saved.invitation.room)
        XCTAssertNotEqual(next.key, first.invitation.key)
        XCTAssertTrue(host.pairedDevices.isEmpty)
    }

    func testPrimaryLegacyRequestAndSecondaryRequestSelectOnlyTheirOwnCipher() throws {
        let store = MemoryPairStore(), saved = try catalog()
        try store.save(saved)
        let transport = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, signaling: transport)
        host.allowLegacyPrivateRoute = true
        host.restore(); host.start()
        defer { host.stop() }
        transport.deliver(RelayMessage(type: "registered", features: [SignalingFeature.devices]))
        XCTAssertEqual(transport.connects.first?.invitation, saved.approvedDevices[0].invitation)
        XCTAssertEqual(transport.clientTokenHashes, saved.approvedDevices.map { SecureRandom.digest($0.invitation.token) })
        for device in saved.approvedDevices {
            let cipher = try SignalCipher(key: device.invitation.key, room: device.invitation.room)
            let request = ProtectedMessage(kind: "request", request: try SecureRandom.token(), session: "", sequence: 0)
            transport.deliver(RelayMessage(type: "signal", payload: try cipher.seal(request, sender: "client")))
            let challenge = try XCTUnwrap(transport.sent.last?.payload)
            let opened = try cipher.open(challenge, sender: "host")
            XCTAssertEqual(opened.kind, "challenge")
            XCTAssertEqual(opened.request, request.request)
            XCTAssertEqual(host.invitation, device.invitation)
            XCTAssertThrowsError(try host.createPair(server: saved.invitation.server, name: "Mac"))
            let count = transport.sent.count
            let other = saved.approvedDevices.first { $0.id != device.id }!
            let wrongCipher = try SignalCipher(key: other.invitation.key, room: other.invitation.room)
            transport.deliver(RelayMessage(type: "signal", payload: try wrongCipher.seal(request, sender: "client")))
            XCTAssertEqual(transport.sent.count, count, "A second key cannot replace an active handshake/consent")
            XCTAssertEqual(host.invitation, device.invitation)
            transport.deliver(RelayMessage(type: "peer", online: false))
            XCTAssertTrue(host.hostRegistered)
        }
    }

    func testPendingEnrollmentSurvivesAnExistingPhoneRequest() throws {
        let store = MemoryPairStore(), saved = try catalog(count: 1)
        try store.save(saved)
        let transport = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, signaling: transport)
        host.allowLegacyPrivateRoute = true
        host.restore()
        let pending = try host.createPair(server: saved.invitation.server, name: "Mac")
        host.start(); defer { host.stop() }
        transport.deliver(RelayMessage(type: "registered", features: [SignalingFeature.devices]))
        let original = saved.approvedDevices[0].invitation
        let cipher = try SignalCipher(key: original.key, room: original.room)
        let request = ProtectedMessage(kind: "request", request: try SecureRandom.token(), session: "", sequence: 0)
        transport.deliver(RelayMessage(type: "signal", payload: try cipher.seal(request, sender: "client")))
        XCTAssertEqual(host.invitation, original)
        XCTAssertEqual(host.pendingPairInvitation, pending)
        transport.deliver(RelayMessage(type: "peer", online: false))
        XCTAssertTrue(host.hostRegistered)
        XCTAssertEqual(host.pendingPairInvitation, pending)
        // Complete a second enrollment through the public encrypted handshake/approval path.
        let enrollment = try comparisonEnrollment(pending, host: host, transport: transport)
        host.approve()
        let acceptedPayload = try XCTUnwrap(transport.sent.last?.payload)
        let accepted = try enrollment.cipher.open(acceptedPayload, sender: "host")
        XCTAssertEqual(accepted.kind, "accepted")
        let published = try JSONDecoder().decode(PairInvitation.self, from: XCTUnwrap(accepted.body))
        XCTAssertEqual(published.key, enrollment.keys.trustKey)
        XCTAssertEqual(published.token, enrollment.keys.trustToken)
        XCTAssertThrowsError(try SignalCipher(key: pending.key, room: pending.room).open(acceptedPayload, sender: "host"))
        XCTAssertNotEqual(published.key, pending.key)
        XCTAssertNotEqual(published.token, pending.token)
        XCTAssertEqual(published.room, original.room)
        XCTAssertEqual(host.pairedDevices.count, 2)
        XCTAssertEqual(host.pairedDevices[0], saved.approvedDevices[0])
        XCTAssertEqual(host.pairedDevices[1].invitation, published)
        XCTAssertNil(host.pendingPairInvitation)
        XCTAssertEqual(try store.read(HostPair.self)?.approvedDevices, host.pairedDevices)
    }

    func testFailedAdditionalApprovalRetirementPreservesCatalogAndRequiresFreshQR() throws {
        let store = MemoryPairStore(), saved = try catalog(count: 1)
        try store.save(saved)
        let transport = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, signaling: transport)
        host.allowLegacyPrivateRoute = true
        host.restore()
        let exposed = try host.createPair(server: saved.invitation.server, name: "Mac")
        host.start(); defer { host.stop() }
        transport.deliver(RelayMessage(type: "registered", features: [SignalingFeature.devices]))
        _ = try comparisonEnrollment(exposed, host: host, transport: transport)
        store.refuseSave = true
        host.approve()
        XCTAssertFalse(host.isRunning)
        XCTAssertNil(host.pendingPairInvitation)
        XCTAssertEqual(try store.read(HostPair.self)?.approvedDevices, saved.approvedDevices)
        let registrations = transport.connects.count
        store.refuseSave = false
        host.restore(); host.start()
        XCTAssertEqual(transport.connects.count, registrations)
        XCTAssertFalse(host.isRunning)
        let fresh = try host.createPair(server: saved.invitation.server, name: "Mac")
        XCTAssertEqual(fresh.room, exposed.room)
        XCTAssertNotEqual(fresh.key, exposed.key)
        XCTAssertNotEqual(fresh.token, exposed.token)
        host.start()
        transport.deliver(RelayMessage(type: "registered", features: [SignalingFeature.devices]))
        _ = try comparisonEnrollment(fresh, host: host, transport: transport)
        host.approve()
        XCTAssertEqual(host.pairedDevices.count, 2)
        XCTAssertEqual(host.pairedDevices.first, saved.approvedDevices.first)
        XCTAssertNil(host.pendingPairInvitation)
    }

    func testKillSwitchAdvertisesOnlyOneDeviceWithoutDeletingCatalog() throws {
        let store = MemoryPairStore(), saved = try catalog()
        try store.save(saved)
        let transport = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, signaling: transport, multiDeviceEnabled: false)
        host.allowLegacyPrivateRoute = true
        host.restore(); host.start(); defer { host.stop() }
        XCTAssertFalse(transport.connects.first?.features.contains(SignalingFeature.devices) ?? true)
        XCTAssertNil(transport.clientTokenHashes)
        XCTAssertEqual(transport.connects.first?.invitation, saved.approvedDevices[0].invitation)
        XCTAssertThrowsError(try host.createPair(server: saved.invitation.server, name: "Mac"))
        XCTAssertEqual(try store.read(HostPair.self)?.approvedDevices, saved.approvedDevices)
        transport.deliver(RelayMessage(type: "registered"))
        let primary = saved.approvedDevices[0].invitation
        let cipher = try SignalCipher(key: primary.key, room: primary.room)
        let request = ProtectedMessage(kind: "request", request: try SecureRandom.token(), session: "", sequence: 0)
        transport.deliver(RelayMessage(type: "signal", payload: try cipher.seal(request, sender: "client")))
        let challenge = try cipher.open(XCTUnwrap(transport.sent.last?.payload), sender: "host")
        XCTAssertEqual(challenge.kind, "challenge")
    }

    func testInvalidCatalogFailsClosedRatherThanDroppingAnotherDevicesTrust() throws {
        let store = MemoryPairStore()
        var saved = try catalog()
        let duplicate = saved.approvedDevices[0]
        saved.devices?.append(duplicate)
        try store.save(saved)
        let host = RemoteCoordinator(isHost: true, store: store)
        host.restore()
        XCTAssertNil(host.invitation)
        XCTAssertTrue(host.pairedDevices.isEmpty)
        XCTAssertThrowsError(try host.createPair(server: saved.invitation.server, name: "Mac"))
        XCTAssertEqual(try store.read(HostPair.self)?.devices?.count, 3)
    }

    func testLastUsedAndNameUpdateOnlySelectedDevice() throws {
        var saved = try catalog()
        let first = saved.approvedDevices[0]
        saved.phoneName = "Renamed iPad"
        try saved.rememberCurrentDevice(at: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(saved.approvedDevices[0], first)
        XCTAssertEqual(saved.approvedDevices[1].phoneName, "Renamed iPad")
        XCTAssertEqual(saved.approvedDevices[1].lastUsed, Date(timeIntervalSince1970: 99))
    }
}


extension HostMultiDeviceTests {
    func testExpiredAddDeviceCodeStillListensAfterRestartWithoutRepair() throws {
        let store = MemoryPairStore(), saved = try catalog(count: 1)
        try store.save(saved)
        let creator = RemoteCoordinator(isHost: true, store: store)
        creator.restore()
        _ = try creator.createPair(server: saved.invitation.server, name: "Mac")
        var expired = try XCTUnwrap(store.read(HostPair.self))
        expired.pendingInvitation?.expires = .distantPast
        try store.save(expired)
        let transport = ScriptedSignaling()
        let restarted = RemoteCoordinator(isHost: true, store: store, signaling: transport)
        restarted.restore(); restarted.start(); defer { restarted.stop() }
        XCTAssertEqual(restarted.invitation, saved.approvedDevices[0].invitation)
        XCTAssertNil(restarted.pendingPairInvitation)
        XCTAssertEqual(restarted.pairedDevices, saved.approvedDevices)
        XCTAssertEqual(transport.connects.first?.invitation, saved.approvedDevices[0].invitation)
        XCTAssertEqual(transport.clientTokenHashes?.count, 1)
    }

    func testCancelAndDeclineAddDeviceKeepExistingGrantAndResumeAdmission() throws {
        for decline in [false, true] {
            let store = MemoryPairStore(), saved = try catalog(count: 1)
            try store.save(saved)
            let transport = ScriptedSignaling()
            let host = RemoteCoordinator(isHost: true, store: store, signaling: transport)
            host.allowLegacyPrivateRoute = true
            host.restore()
            let pending = try host.createPair(server: saved.invitation.server, name: "Mac")
            host.start(); defer { host.stop() }
            transport.deliver(RelayMessage(type: "registered", features: [SignalingFeature.devices]))
            if decline {
                let enrollment = try comparisonEnrollment(pending, host: host, transport: transport)
                host.reject()
                let declined = try enrollment.cipher.open(XCTUnwrap(transport.sent.last?.payload), sender: "host")
                XCTAssertEqual(declined.kind, "enrollmentDeclined")
                XCTAssertEqual(transport.connects.count, 2)
            } else {
                XCTAssertTrue(host.cancelPendingPairing())
                host.start()
            }
            XCTAssertNil(host.pendingPairInvitation)
            XCTAssertFalse(host.awaitingApproval)
            XCTAssertEqual(host.pairedDevices, saved.approvedDevices)
            XCTAssertEqual(host.invitation, saved.approvedDevices[0].invitation)
            XCTAssertEqual(transport.clientTokenHashes, [SecureRandom.digest(saved.approvedDevices[0].invitation.token)])
            XCTAssertNil(try store.read(HostPair.self)?.pendingInvitation)
            let registrations = transport.connects.count
            host.approve() // A queued Allow from the retired candidate must not stop the listener.
            host.reject() // The retired Decline action also cannot affect established trust.
            XCTAssertTrue(host.isRunning)
            XCTAssertEqual(transport.connects.count, registrations)
            XCTAssertEqual(host.invitation, saved.approvedDevices[0].invitation)
            XCTAssertEqual(host.pairedDevices, saved.approvedDevices)
        }
    }

    func testBigTextIsSeparateOnTwoDevicesForTheSameStableMacRoom() throws {
        let room = try catalog().invitation.room
        let firstSuite = "HostMultiDeviceBigTextPhone-" + UUID().uuidString
        let secondSuite = "HostMultiDeviceBigTextIPad-" + UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer { first.removePersistentDomain(forName: firstSuite); second.removePersistentDomain(forName: secondSuite) }
        let display = DisplayDescriptor(id: 1, name: "Mac display", width: 1470, height: 956)
        BigTextMemory(defaults: first).remember(1280, forRoom: room, display: display, among: [display])
        BigTextMemory(defaults: second).remember(1440, forRoom: room, display: display, among: [display])
        XCTAssertEqual(BigTextMemory(defaults: first).width(forRoom: room, display: display, among: [display]), 1280)
        XCTAssertEqual(BigTextMemory(defaults: second).width(forRoom: room, display: display, among: [display]), 1440)
    }
}


extension HostMultiDeviceTests {
    func testKeychainSaveFailurePreservesCatalogAndStopsUnconfirmedRemoval() throws {
        let store = MemoryPairStore(), saved = try catalog()
        try store.save(saved)
        let host = RemoteCoordinator(isHost: true, store: store, signaling: ScriptedSignaling())
        host.restore()
        store.refuseSave = true
        XCTAssertThrowsError(try host.createPair(server: saved.invitation.server, name: "Mac"))
        XCTAssertEqual(host.pairedDevices, saved.approvedDevices)
        XCTAssertEqual(try store.read(HostPair.self)?.approvedDevices, saved.approvedDevices)
        host.start()
        XCTAssertFalse(host.removePairedDevice(saved.approvedDevices[0].id))
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(try store.read(HostPair.self)?.approvedDevices, saved.approvedDevices)
        store.refuseSave = false
        XCTAssertTrue(host.removePairedDevice(saved.approvedDevices[0].id))
        XCTAssertEqual(host.pairedDevices, [saved.approvedDevices[1]])
    }
}


extension HostMultiDeviceTests {
    private func expireConsentWithoutRunningItsTimeout(_ invitation: PairInvitation) {
        // Keep the Allow/disconnect expiry regression distinct from the v2 timer-expiry path.
        // A synchronous wait lets the owner action run before the MainActor timeout resumes.
        Thread.sleep(forTimeInterval: max(0, invitation.expires.timeIntervalSinceNow) + 0.05)
    }

    func testExpiryDuringAuthenticatedConsentRecoversOriginalAdmissionWithoutRelaunch() async throws {
        for approveExpired in [true, false] {
            let store = MemoryPairStore(), saved = try catalog(count: 1)
            try store.save(saved)
            let creator = RemoteCoordinator(isHost: true, store: store)
            creator.restore()
            _ = try creator.createPair(server: saved.invitation.server, name: "Mac")
            var record = try XCTUnwrap(store.read(HostPair.self))
            record.pendingInvitation?.expires = Date().addingTimeInterval(2)
            let pending = try XCTUnwrap(record.pendingInvitation)
            try store.save(record)
            let transport = ScriptedSignaling()
            let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 1,
                                         retryBaseNanoseconds: 1_000_000, signaling: transport)
            host.allowLegacyPrivateRoute = true
            host.restore(); host.start(); defer { host.stop() }
            transport.deliver(RelayMessage(type: "registered", features: [SignalingFeature.devices]))
            _ = try comparisonEnrollment(pending, host: host, transport: transport)
            expireConsentWithoutRunningItsTimeout(pending)
            XCTAssertTrue(host.awaitingApproval, "Expiry must be exercised at consent, before automatic retirement")
            if approveExpired { host.approve() }
            else { transport.deliver(RelayMessage(type: "peer", online: false)) }
            let deadline = Date().addingTimeInterval(2)
            while transport.connects.count < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(transport.connects.count, 2)
            XCTAssertEqual(host.invitation, saved.approvedDevices[0].invitation)
            XCTAssertEqual(host.pairedDevices, saved.approvedDevices)
            XCTAssertNil(host.pendingPairInvitation)
            XCTAssertTrue(host.isRunning)
            XCTAssertEqual(transport.clientTokenHashes, [SecureRandom.digest(saved.approvedDevices[0].invitation.token)])
        }
    }
}
