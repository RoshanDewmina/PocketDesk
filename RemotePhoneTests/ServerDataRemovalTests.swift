import XCTest
@testable import PocketDeskRemote

@MainActor
final class ServerDataRemovalTests: XCTestCase {
    private final class Source: AnywhereEntitlementSource {
        var entitlement = AnywhereEntitlement(phase: .active)
        func signedTransaction() async -> String? { "signed" }
    }
    private final class Remover: ServerDataRemoving {
        var requests: [ServerDataRemovalRequest] = []
        var fail = false
        func remove(_ request: ServerDataRemovalRequest) async throws {
            requests.append(request)
            if fail { throw ServerDataRemovalError.unavailable }
        }
    }
    private final class Verifier: EntitlementVerifying {
        var calls = 0
        func verify(_ request: EntitlementVerifyRequest) async throws -> EntitlementGrant {
            calls += 1
            throw EntitlementServiceError.unreachable
        }
    }
    private func make(_ tokenStore: MemoryStore, _ removalStore: MemoryStore, _ verifier: Verifier) -> AnywhereAccess {
        let access = AnywhereAccess(source: Source(), makeClient: { _ in verifier },
                                   deviceID: { String(repeating: "a", count: 64) }, persistence: tokenStore,
                                   removalPersistence: removalStore)
        access.serviceURL = { URL(string: "https://signal.example") }
        return access
    }
    private func seed(_ store: MemoryStore) throws {
        try store.save(EntitlementGrant(entitled: true, token: "fe1.valid.proof",
                                       tokenExpiresAt: Date().addingTimeInterval(3600), issuedAt: Date(),
                                       serviceOrigin: "https://signal.example"))
    }

    func testFailureRetainsProofAndSuppressesRefreshAcrossRelaunch() async throws {
        let tokens = MemoryStore(), pending = MemoryStore(), verifier = Verifier(), remover = Remover()
        try seed(tokens)
        let access = make(tokens, pending, verifier)
        remover.fail = true
        do { try await access.unlinkDevice(using: remover); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(access.removalPending)
        XCTAssertNotNil(try tokens.read(EntitlementGrant.self))
        XCTAssertNil(access.currentToken())
        let relaunched = make(tokens, pending, verifier)
        XCTAssertTrue(relaunched.removalPending)
        let refreshed = await relaunched.refresh(force: true)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(verifier.calls, 0)
        remover.fail = false
        try await relaunched.unlinkDevice(using: remover)
        XCTAssertEqual(remover.requests.count, 2)
        XCTAssertEqual(remover.requests.first, remover.requests.last)
        XCTAssertFalse(relaunched.removalPending)
        XCTAssertNil(try tokens.read(EntitlementGrant.self))
        let afterSuccess = make(tokens, pending, verifier)
        let autoRefresh = await afterSuccess.refresh(force: true)
        XCTAssertFalse(autoRefresh, "Background observers must not immediately relink a removed device")
        XCTAssertEqual(verifier.calls, 0)
    }

    func testUnreadableRemovalRecordNeverRelinksOrResumesConnect() async throws {
        struct UnreadableStore: PairPersistence {
            func save<T: Encodable>(_ value: T) throws {}
            func read<T: Decodable>(_ type: T.Type) throws -> T? { throw RemoteError.keychain(-25308) }
            func delete() throws { throw RemoteError.keychain(-25308) }
        }
        let tokens = MemoryStore(), verifier = Verifier()
        try seed(tokens)
        let access = AnywhereAccess(source: Source(), makeClient: { _ in verifier },
                                    persistence: tokens, removalPersistence: UnreadableStore())
        access.serviceURL = { URL(string: "https://signal.example") }
        XCTAssertTrue(access.removalPending)
        XCTAssertTrue(access.removalRecoveryRequired)
        await access.prepareForConnection(timeout: 0.01)
        let refreshed = await access.refresh(force: true)
        XCTAssertFalse(refreshed)
        XCTAssertNil(access.currentToken())
        XCTAssertEqual(verifier.calls, 0)
        XCTAssertThrowsError(try access.cancelRemoval())
        XCTAssertTrue(access.removalPending)
    }

    func testWrongOriginCannotReceiveSavedProof() async throws {
        let tokens = MemoryStore(), pending = MemoryStore(), verifier = Verifier(), remover = Remover()
        try seed(tokens)
        let access = make(tokens, pending, verifier)
        access.serviceURL = { URL(string: "https://different.example") }
        do { try await access.unlinkDevice(using: remover); XCTFail("Origin must match") }
        catch { XCTAssertEqual(error as? ServerDataRemovalError, .invalidProof) }
        XCTAssertTrue(remover.requests.isEmpty)
        XCTAssertNotNil(try tokens.read(EntitlementGrant.self))
    }

    func testWireRestrictsOriginAndContainsNoScreenKey() throws {
        let request = ServerDataRemovalRequest(kind: .room, serviceOrigin: "https://signal.example",
                                              identifier: String(repeating: "a", count: 64), proof: String(repeating: "b", count: 64))
        let http = try request.httpRequest()
        XCTAssertEqual(http.url?.absoluteString, "https://signal.example/v1/rooms/forget")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(http.httpBody)) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["room", "token"])
        for bad in ["http://signal.example", "https://user@signal.example", "https://signal.example/path", "https://signal.example?x=1"] {
            var changed = request; changed.serviceOrigin = bad
            XCTAssertThrowsError(try changed.httpRequest())
        }
    }

    func testOnly204ConfirmsRemovalAndRedirectIsNotSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemovalProtocol.self]
        let remover = HTTPServerDataRemover(configuration: config)
        let request = ServerDataRemovalRequest(kind: .device, serviceOrigin: "https://signal.example",
                                              identifier: String(repeating: "a", count: 64), proof: "fe1.valid.proof")
        for (status, expected) in [(301, ServerDataRemovalError.invalidResponse), (200, .invalidResponse),
                                   (401, .unauthorized), (403, .blocked), (429, .rateLimited), (503, .unavailable)] {
            RemovalProtocol.code = status
            do { try await remover.remove(request); XCTFail("Should reject \(status)") }
            catch { XCTAssertEqual(error as? ServerDataRemovalError, expected) }
        }
        RemovalProtocol.code = 204
        try await remover.remove(request)
    }
}

private final class RemovalProtocol: URLProtocol {
    nonisolated(unsafe) static var code = 204
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
