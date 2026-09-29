import Foundation
import Security
import XCTest

#if os(macOS)
private final class MockPairSecurity {
    var present = true
    var reference = Data([0x11, 0x22])
    var lookupStatus: OSStatus?
    var malformedLookup = false
    var deleteStatus = errSecSuccess
    var afterDelete: (() -> Void)?
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func store() -> PairStore {
        PairStore(account: "host", security: PairStoreSecurityCalls(
            copyMatching: { [self] search in
                copyQueries.append(search)
                if search[kSecReturnPersistentRef as String] != nil {
                    if let lookupStatus { return (lookupStatus, nil) }
                    if !present { return (errSecItemNotFound, nil) }
                    if malformedLookup { return (errSecSuccess, "not a reference") }
                    return (errSecSuccess, reference)
                }
                return (present ? errSecSuccess : errSecItemNotFound, nil)
            },
            delete: { [self] search in
                deleteQueries.append(search)
                if deleteStatus == errSecSuccess { present = false }
                afterDelete?()
                return deleteStatus
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
