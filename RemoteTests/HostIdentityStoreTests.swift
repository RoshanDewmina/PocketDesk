import XCTest

final class HostIdentityStoreTests: XCTestCase {
    private final class Memory: PairPersistence {
        var data: Data?
        var failRead = false
        var failSave = false
        func read<T: Decodable>(_ type: T.Type) throws -> T? {
            if failRead { throw RemoteError.keychain(-1) }
            return try data.map { try JSONDecoder().decode(type, from: $0) }
        }
        func save<T: Encodable>(_ value: T) throws {
            if failSave { throw RemoteError.keychain(-1) }
            data = try JSONEncoder().encode(value)
        }
        func delete() throws { data = nil }
    }

    func testNewPairAndRotationPreserveHostIdentityButNotOwnerPairIdentity() throws {
        let memory = Memory(), store = HostIdentityStore(persistence: Memory())
        let identity = try HostIdentityStore(persistence: memory).loadOrCreate()
        XCTAssertEqual(try HostIdentityStore(persistence: memory).loadOrCreate(), identity)
        let first = try HostPair.create(server: "wss://example.com/signal", name: "Mac", identity: identity)
        let second = try HostPair.create(server: "wss://example.com/signal", name: "Mac", identity: identity)
        XCTAssertEqual(first.invitation.durableHostID, second.invitation.durableHostID)
        XCTAssertNotEqual(first.invitation.ownerPairID, second.invitation.ownerPairID)
        XCTAssertEqual(try first.rotated().invitation.ownerPairID, first.invitation.ownerPairID)
        XCTAssertNotEqual(try store.loadOrCreate().hostID, identity.hostID)
    }

    func testCorruptionOrReadFailureNeverSilentlyReplacesIdentity() throws {
        let memory = Memory()
        memory.data = Data("{}".utf8)
        let corrupt = memory.data
        XCTAssertThrowsError(try HostIdentityStore(persistence: memory).loadOrCreate())
        XCTAssertEqual(memory.data, corrupt)
        memory.failRead = true
        XCTAssertThrowsError(try HostIdentityStore(persistence: memory).loadOrCreate())
        XCTAssertEqual(memory.data, corrupt)
        memory.data = nil; memory.failRead = false; memory.failSave = true
        XCTAssertThrowsError(try HostIdentityStore(persistence: memory).loadOrCreate())
        XCTAssertNil(memory.data)
    }
}
