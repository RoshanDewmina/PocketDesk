import Foundation
import Security
import XCTest

#if os(macOS)
private final class MockPairSecurity {
    var present = true
    var reference = Data([0x11, 0x22])
    var lookupStatus: OSStatus?
    var malformedLookup = false
    var nilLookup = false
    var verificationStatus: OSStatus?
    var deleteStatus = errSecSuccess
    var afterDelete: (() -> Void)?
    var updateStatus: OSStatus = errSecInvalidOwnerEdit
    var storedData: Data?
    var afterUpdate: (() -> Void)?
    var verificationValues: [Data]?
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func store(account: String = "host") -> PairStore {
        PairStore(account: account, security: PairStoreSecurityCalls(
            copyMatching: { [self] search in
                copyQueries.append(search)
                if search[kSecReturnPersistentRef as String] != nil {
                    if let lookupStatus { return (lookupStatus, nil) }
                    if !present { return (errSecItemNotFound, nil) }
                    if malformedLookup { return (errSecSuccess, "not a reference") }
                    if nilLookup { return (errSecSuccess, nil) }
                    return (errSecSuccess, reference)
                }
                if let verificationStatus { return (verificationStatus, nil) }
                if !present { return (errSecItemNotFound, nil) }
                if search[kSecReturnData as String] != nil {
                    if search[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                        return (errSecSuccess, verificationValues ?? storedData.map { [$0] } ?? [])
                    }
                    return (errSecSuccess, storedData)
                }
                return (errSecSuccess, nil)
            },
            delete: { [self] search in
                deleteQueries.append(search)
                if deleteStatus == errSecSuccess { present = false }
                afterDelete?()
                return deleteStatus
            },
            update: { [self] query, attributes in
                updateQueries.append(query); updateAttributes.append(attributes)
                if updateStatus == errSecSuccess { storedData = attributes[kSecValueData as String] as? Data }
                afterUpdate?()
                return updateStatus
            }
        ))
    }
}

final class PairStoreDeletionTests: XCTestCase {
    private func assertKeychainStatus(_ expected: OSStatus, _ body: () throws -> Void,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case RemoteError.keychain(let status) = error else {
                return XCTFail("Expected the original Keychain status", file: file, line: line)
            }
            XCTAssertEqual(status, expected, file: file, line: line)
        }
    }

    func testExactReferenceDeleteUsesMetadataOnlyAndChecksOriginalQuery() throws {
        let mock = MockPairSecurity()
        try mock.store().delete()

        XCTAssertEqual(mock.copyQueries.count, 2)
        XCTAssertEqual(Set(mock.copyQueries[0].keys), Set([
            kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
            kSecReturnPersistentRef as String, kSecMatchLimit as String
        ]))
        XCTAssertEqual(mock.copyQueries[0][kSecAttrService as String] as? String, "PocketDesk.Remote.Trust.v1")
        XCTAssertEqual(mock.copyQueries[0][kSecAttrAccount as String] as? String, "host")
        XCTAssertEqual(mock.copyQueries[0][kSecReturnPersistentRef as String] as? Bool, true)
        XCTAssertEqual(mock.copyQueries[0][kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(Set(mock.copyQueries[1].keys), Set([
            kSecClass as String, kSecAttrService as String, kSecAttrAccount as String
        ]))
        XCTAssertEqual(mock.deleteQueries.count, 1)
        XCTAssertEqual(Set(mock.deleteQueries[0].keys), Set([kSecClass as String, kSecMatchItemList as String]))
        XCTAssertEqual(mock.deleteQueries[0][kSecMatchItemList as String] as? [Data], [mock.reference])
    }

    func testMissingLookupSucceedsOnlyAfterOriginalQueryAlsoFindsNothing() throws {
        let missing = MockPairSecurity()
        missing.present = false
        try missing.store().delete()
        XCTAssertEqual(missing.copyQueries.count, 2)
        XCTAssertTrue(missing.deleteQueries.isEmpty)

        let inconsistent = MockPairSecurity()
        inconsistent.lookupStatus = errSecItemNotFound
        XCTAssertThrowsError(try inconsistent.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .recordRemains)
        }
        XCTAssertTrue(inconsistent.deleteQueries.isEmpty)
    }

    func testLookupErrorAndMalformedReferenceFailWithoutDeleting() {
        let denied = MockPairSecurity()
        denied.lookupStatus = -25244
        assertKeychainStatus(-25244) { try denied.store().delete() }
        XCTAssertTrue(denied.deleteQueries.isEmpty)

        let malformed = MockPairSecurity()
        malformed.malformedLookup = true
        XCTAssertThrowsError(try malformed.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .invalidPersistentReference)
        }
        XCTAssertTrue(malformed.deleteQueries.isEmpty)

        let nilOutput = MockPairSecurity()
        nilOutput.nilLookup = true
        XCTAssertThrowsError(try nilOutput.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .invalidPersistentReference)
        }
        XCTAssertTrue(nilOutput.deleteQueries.isEmpty)

        let empty = MockPairSecurity()
        empty.reference = Data()
        XCTAssertThrowsError(try empty.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .invalidPersistentReference)
        }
        XCTAssertTrue(empty.deleteQueries.isEmpty)

        let oversized = MockPairSecurity()
        oversized.reference = Data(repeating: 0x11, count: 4_097)
        XCTAssertThrowsError(try oversized.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .invalidPersistentReference)
        }
        XCTAssertTrue(oversized.deleteQueries.isEmpty)
    }

    func testDeleteErrorPreservesOriginalStatus() {
        let mock = MockPairSecurity()
        mock.deleteStatus = -25244
        assertKeychainStatus(-25244) { try mock.store().delete() }
        XCTAssertTrue(mock.present)
    }

    func testOwnerEditDeleteFailureOverwritesOnlySelectedAccountAndSurvivesRelaunch() throws {
        let mock = MockPairSecurity()
        mock.deleteStatus = errSecInvalidOwnerEdit; mock.updateStatus = errSecSuccess
        let store = mock.store()
        try store.delete()
        XCTAssertEqual(mock.updateQueries.count, 1)
        XCTAssertEqual(Set(mock.updateQueries[0].keys), [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])
        XCTAssertEqual(mock.updateQueries[0][kSecAttrAccount as String] as? String, "host")
        XCTAssertEqual(Set(mock.updateAttributes[0].keys), [kSecValueData as String], "No ownership/accessibility edits")
        XCTAssertEqual(mock.copyQueries.last?[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertTrue(mock.present, "Logical revocation may retain an inert Keychain item")
        XCTAssertNil(try store.read(HostPair.self))
        XCTAssertNil(try mock.store().read(HostPair.self), "A relaunched reader cannot resurrect revoked credentials")
    }

    func testOwnerEditLookupFailureUsesSameScopedVerifiedFallback() throws {
        let mock = MockPairSecurity()
        mock.lookupStatus = errSecInvalidOwnerEdit; mock.updateStatus = errSecSuccess
        try mock.store().delete()
        XCTAssertTrue(mock.deleteQueries.isEmpty)
        XCTAssertEqual(mock.updateQueries.count, 1)
        XCTAssertNil(try mock.store().read(HostPair.self))
    }

    func testOtherSecurityErrorsNeverOverwriteCredentials() {
        let lookup = MockPairSecurity(); lookup.lookupStatus = errSecInteractionNotAllowed
        assertKeychainStatus(errSecInteractionNotAllowed) { try lookup.store().delete() }
        XCTAssertTrue(lookup.updateQueries.isEmpty)
        let deletion = MockPairSecurity(); deletion.deleteStatus = errSecAuthFailed
        assertKeychainStatus(errSecAuthFailed) { try deletion.store().delete() }
        XCTAssertTrue(deletion.updateQueries.isEmpty)
    }

    func testFailedMarkerUpdateRetainsPriorRecordAndFailsRemoval() {
        let mock = MockPairSecurity()
        mock.deleteStatus = errSecInvalidOwnerEdit; mock.updateStatus = errSecInteractionNotAllowed
        let before = Data("fixture-prior-record".utf8); mock.storedData = before
        assertKeychainStatus(errSecInteractionNotAllowed) { try mock.store().delete() }
        XCTAssertEqual(mock.storedData, before); XCTAssertTrue(mock.present)
    }

    func testMarkerUpdateMustActuallyPersistAndCoverEveryMatchingRecord() {
        let unchanged = MockPairSecurity()
        unchanged.deleteStatus = errSecInvalidOwnerEdit; unchanged.updateStatus = errSecSuccess
        unchanged.afterUpdate = { unchanged.storedData = Data("fixture-retained-record".utf8) }
        XCTAssertThrowsError(try unchanged.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .recordRemains)
        }
        let duplicate = MockPairSecurity()
        duplicate.deleteStatus = errSecInvalidOwnerEdit; duplicate.updateStatus = errSecSuccess
        duplicate.afterUpdate = { duplicate.verificationValues = [duplicate.storedData!, Data("fixture-other-record".utf8)] }
        XCTAssertThrowsError(try duplicate.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .recordRemains)
        }
    }

    func testMarkerReadbackErrorNeverReportsConfirmedRemoval() {
        let mock = MockPairSecurity()
        mock.deleteStatus = errSecInvalidOwnerEdit; mock.updateStatus = errSecSuccess
        mock.verificationStatus = errSecInteractionNotAllowed
        assertKeychainStatus(errSecInteractionNotAllowed) { try mock.store().delete() }
    }

    func testUnknownWrongAccountAndMalformedMarkerNeverCountAsAbsence() throws {
        let mock = MockPairSecurity()
        let markers: [[String: Any]] = [
            ["pairStoreRemoval": "revoked.v1", "version": 2, "account": "host"],
            ["pairStoreRemoval": "revoked.v1", "version": 1, "account": "other"],
            ["pairStoreRemoval": "unknown", "version": 1, "account": "host"],
            ["pairStoreRemoval": "revoked.v1", "version": 1, "account": "host", "extra": true]
        ]
        for object in markers {
            mock.storedData = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try mock.store().read(HostPair.self))
        }
    }

    func testExplicitFreshPairCanReplaceAnInertMarker() throws {
        let mock = MockPairSecurity()
        mock.deleteStatus = errSecInvalidOwnerEdit; mock.updateStatus = errSecSuccess
        try mock.store().delete()
        let fresh = try HostPair.create(server: "wss://fixture.invalid/signal", name: "Fixture")
        try mock.store().save(fresh)
        XCTAssertEqual(try mock.store().read(HostPair.self)?.invitation, fresh.invitation)
    }

    func testSuccessfulDeleteCannotMaskVerificationError() {
        let mock = MockPairSecurity()
        mock.verificationStatus = -25308
        assertKeychainStatus(-25308) { try mock.store().delete() }
        XCTAssertEqual(mock.deleteQueries.count, 1)
        XCTAssertEqual(mock.copyQueries.count, 2)
        XCTAssertFalse(mock.present)
    }

    func testStaleReferenceOnlySucceedsWhenOriginalRecordIsGone() throws {
        let gone = MockPairSecurity()
        gone.deleteStatus = errSecItemNotFound
        gone.afterDelete = { gone.present = false }
        try gone.store().delete()

        let replaced = MockPairSecurity()
        replaced.deleteStatus = errSecItemNotFound
        replaced.afterDelete = { replaced.reference = Data([0x33, 0x44]); replaced.present = true }
        XCTAssertThrowsError(try replaced.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .recordRemains)
        }
        XCTAssertEqual(replaced.deleteQueries.count, 1)
        XCTAssertEqual(replaced.deleteQueries[0][kSecMatchItemList as String] as? [Data], [Data([0x11, 0x22])])
        XCTAssertEqual(replaced.reference, Data([0x33, 0x44]))
    }

    func testSuccessfulDeleteWithDuplicateLeftoverFailsClosed() {
        let mock = MockPairSecurity()
        mock.afterDelete = { mock.present = true }
        XCTAssertThrowsError(try mock.store().delete()) { error in
            XCTAssertEqual(error as? PairStoreDeletionError, .recordRemains)
        }
        XCTAssertEqual(mock.deleteQueries.count, 1)
    }
}
#endif
