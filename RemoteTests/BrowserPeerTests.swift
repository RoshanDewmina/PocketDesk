import CryptoKit
import XCTest

private final class BrowserPeerMemoryBackend {
    var records: [String: Data] = [:]
    var writes: [String] = []
    var deletes: [String] = []

    var backend: BrowserPeerStoreBackend {
        BrowserPeerStoreBackend(
            read: { [weak self] account in self?.records[account] },
            write: { [weak self] account, data in
                self?.records[account] = data
                self?.writes.append(account)
            },
            delete: { [weak self] account in
                self?.records[account] = nil
                self?.deletes.append(account)
            }
        )
    }
}

private func encryptedEnrollmentBody(
    secretByte: UInt8,
    hostID: String,
    origin: String,
    proposal: [String: Any]
) throws -> [String: Any] {
    let nonceData = Data(repeating: 7, count: 12)
    let nonce = try AES.GCM.Nonce(data: nonceData)
    let plaintext = try JSONSerialization.data(withJSONObject: proposal)
    let box = try AES.GCM.seal(
        plaintext,
        using: SymmetricKey(data: Data(repeating: secretByte, count: 32)),
        nonce: nonce,
        authenticating: BrowserCrypto.canonical(["enroll", hostID, origin])
    )
    return [
        "nonce": nonceData.base64EncodedString(),
        "payload": (box.ciphertext + box.tag).base64EncodedString()
    ]
}

final class BrowserPeerTests: XCTestCase {
    func testEnrollmentProposalIsEncryptedAndBoundToOfferAuthority() throws {
        let hostID = String(repeating: "a", count: 64)
        let peerID = String(repeating: "b", count: 64)
        let origin = "https://desk.example"
        let signingKey = P256.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.x963Representation.base64EncodedString()
        let body = try encryptedEnrollmentBody(
            secretByte: 0x11,
            hostID: hostID,
            origin: origin,
            proposal: ["peerID": peerID, "publicKey": publicKey]
        )

        XCTAssertEqual(
            try BrowserEnrollmentProposal.open(
                body: body,
                secret: String(repeating: "11", count: 32),
                hostID: hostID,
                origin: origin
            ),
            BrowserEnrollmentProposal(peerID: peerID, publicKey: publicKey)
        )
        XCTAssertThrowsError(try BrowserEnrollmentProposal.open(
            body: ["secret": String(repeating: "11", count: 32), "peerID": peerID, "publicKey": publicKey],
            secret: String(repeating: "11", count: 32),
            hostID: hostID,
            origin: origin
        ))
        XCTAssertThrowsError(try BrowserEnrollmentProposal.open(
            body: body,
            secret: String(repeating: "22", count: 32),
            hostID: hostID,
            origin: origin
        ))
        XCTAssertThrowsError(try BrowserEnrollmentProposal.open(
            body: body,
            secret: String(repeating: "11", count: 32),
            hostID: String(repeating: "c", count: 64),
            origin: origin
        ))
        XCTAssertThrowsError(try BrowserEnrollmentProposal.open(
            body: body,
            secret: String(repeating: "11", count: 32),
            hostID: hostID,
            origin: "https://substitute.example"
        ))
    }

    func testEnrollmentProposalRequiresExactDecryptedFields() throws {
        let hostID = String(repeating: "a", count: 64)
        let peerID = String(repeating: "b", count: 64)
        let origin = "https://desk.example"
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let body = try encryptedEnrollmentBody(
            secretByte: 0x11,
            hostID: hostID,
            origin: origin,
            proposal: ["peerID": peerID, "publicKey": publicKey, "mode": "interactive"]
        )

        XCTAssertThrowsError(try BrowserEnrollmentProposal.open(
            body: body,
            secret: String(repeating: "11", count: 32),
            hostID: hostID,
            origin: origin
        ))
    }

    func testPendingEnrollmentDeadlineAndCancellationIdentity() {
        let deadline = Date(timeIntervalSince1970: 100)
        let pending = BrowserPendingEnrollment(
            requestID: String(repeating: "1", count: 64),
            peerID: String(repeating: "2", count: 64),
            publicKey: "fixture",
            expiresAt: deadline
        )

        XCTAssertTrue(pending.isLive(at: deadline.addingTimeInterval(-0.001)))
        XCTAssertFalse(pending.isLive(at: deadline))
        XCTAssertTrue(pending.matchesCancellation(String(repeating: "1", count: 64)))
        XCTAssertFalse(pending.matchesCancellation(String(repeating: "3", count: 64)))
    }

    func testIdentityAndApprovedPeerUseSeparateBrowserRecords() throws {
        let memory = BrowserPeerMemoryBackend()
        let store = BrowserPeerStore(backend: memory.backend)
        let identity = try store.loadOrCreateIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let peer = BrowserPeerRecord(
            peerID: String(repeating: "1", count: 64),
            publicKey: signingKey.publicKey.x963Representation.base64EncodedString(),
            origin: "https://desk.example",
            maximumMode: "interactive",
            display: "Test Mac",
            approvedAt: "1789320000000"
        )

        try store.savePeer(peer)

        XCTAssertEqual(try store.loadPeer(), peer)
        XCTAssertEqual(try store.loadOrCreateIdentity(), identity)
        XCTAssertEqual(Set(memory.records.keys), [BrowserPeerStore.identityAccount, BrowserPeerStore.peerAccount])
        XCTAssertEqual(BrowserPeerStore.service, "PocketDesk.Browser.Trust.v1")
        XCTAssertEqual(memory.writes, [BrowserPeerStore.identityAccount, BrowserPeerStore.peerAccount])

        try store.deletePeer()

        XCTAssertNil(try store.loadPeer())
        XCTAssertEqual(try store.loadOrCreateIdentity(), identity)
        XCTAssertEqual(memory.deletes, [BrowserPeerStore.peerAccount])
    }

    func testStoredHostIdentitySignsBrowserDomainMessages() throws {
        let memory = BrowserPeerMemoryBackend()
        let identity = try BrowserPeerStore(backend: memory.backend).loadOrCreateIdentity()
        let fields = ["challenge", try identity.hostID(), "view", "17"]
        let signature = try BrowserCrypto.sign(fields, key: identity.signingKey())

        XCTAssertEqual(identity.token.count, 64)
        XCTAssertEqual(try identity.hostID(), BrowserCrypto.hash(Data(identity.token.utf8)))
        XCTAssertTrue(BrowserCrypto.verify(fields, signature: signature, publicKey: try identity.publicKey()))
        XCTAssertFalse(BrowserCrypto.verify(fields + ["changed"], signature: signature, publicKey: try identity.publicKey()))
    }

    func testInvalidOrRevokedPeerNeverPersists() throws {
        let memory = BrowserPeerMemoryBackend()
        let store = BrowserPeerStore(backend: memory.backend)
        let peer = BrowserPeerRecord(
            peerID: String(repeating: "2", count: 64),
            publicKey: P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            origin: "https://desk.example",
            maximumMode: "view",
            display: "Test Mac",
            approvedAt: "1789320000000",
            revoked: true
        )

        XCTAssertThrowsError(try store.savePeer(peer))
        XCTAssertNil(memory.records[BrowserPeerStore.peerAccount])

        memory.records[BrowserPeerStore.peerAccount] = Data("not-json".utf8)
        XCTAssertThrowsError(try store.loadPeer())
    }

    func testLeaseOwnershipRejectsRacingAcquireAndReleasesExactlyOnce() {
        var lease = BrowserLeaseOwnership()
        var acquireCalls = 0
        var releaseCalls = 0

        XCTAssertTrue(lease.acquire {
            acquireCalls += 1
            return true
        })
        XCTAssertFalse(lease.acquire {
            acquireCalls += 1
            return true
        })
        XCTAssertEqual(acquireCalls, 1)
        XCTAssertTrue(lease.isOwned)

        XCTAssertTrue(lease.release { releaseCalls += 1 })
        XCTAssertFalse(lease.release { releaseCalls += 1 })
        XCTAssertEqual(releaseCalls, 1)
        XCTAssertFalse(lease.isOwned)

        XCTAssertFalse(lease.acquire { false })
        XCTAssertFalse(lease.isOwned)
    }

    func testBrowserEndpointAndCapabilityValidation() {
        XCTAssertTrue(BrowserPeerValidation.isBrowserHostURL("wss://desk.example/browser-host"))
        XCTAssertTrue(BrowserPeerValidation.isBrowserHostURL("ws://127.0.0.1:8788/browser-host"))
        XCTAssertFalse(BrowserPeerValidation.isBrowserHostURL("ws://desk.example/browser-host"))
        XCTAssertFalse(BrowserPeerValidation.isBrowserHostURL("wss://desk.example/signal"))
        XCTAssertFalse(BrowserPeerValidation.isBrowserHostURL("wss://user:pass@desk.example/browser-host"))
        XCTAssertEqual(
            BrowserPeerValidation.origin(forBrowserHostURL: "wss://desk.example:9443/browser-host"),
            "https://desk.example:9443"
        )
        XCTAssertTrue(BrowserPeerValidation.mode("view", isAllowedBy: "view"))
        XCTAssertTrue(BrowserPeerValidation.mode("view", isAllowedBy: "interactive"))
        XCTAssertTrue(BrowserPeerValidation.mode("interactive", isAllowedBy: "interactive"))
        XCTAssertFalse(BrowserPeerValidation.mode("interactive", isAllowedBy: "view"))
        XCTAssertTrue(BrowserPeerValidation.isDecimal("9007199254740991"))
        XCTAssertFalse(BrowserPeerValidation.isDecimal("9007199254740992"))
        XCTAssertFalse(BrowserPeerValidation.isDecimal("01"))
    }

    @MainActor
    func testInvalidConfigurationDoesNotEnterBrowserMode() {
        let memory = BrowserPeerMemoryBackend()
        var releaseCalls = 0
        let controller = BrowserPeerController(
            store: BrowserPeerStore(backend: memory.backend),
            canAcquire: { true },
            release: { releaseCalls += 1 },
            autoApproveSyntheticEnrollment: true
        )

        controller.start(serverURL: "ws://desk.example/browser-host", display: "Test Mac", revision: 1, maximumMode: "view")

        XCTAssertFalse(controller.running)
        XCTAssertFalse(controller.connected)
        XCTAssertEqual(controller.sessionID, "")
        XCTAssertEqual(controller.revision, 0)
        XCTAssertEqual(controller.status, "Browser host configuration is invalid")
        XCTAssertEqual(releaseCalls, 0)
        XCTAssertTrue(memory.records.isEmpty)
    }
}
