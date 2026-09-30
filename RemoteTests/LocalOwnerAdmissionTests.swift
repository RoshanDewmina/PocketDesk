import XCTest
#if canImport(TrustFoundation)
@testable import TrustFoundation
#endif

final class LocalOwnerAdmissionTests: XCTestCase {
    private func pair() throws -> PairInvitation {
        var invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Fixture").invitation
        invitation.durableHostID = try SecureRandom.token()
        invitation.ownerPairID = try SecureRandom.token()
        invitation.localServiceName = "opaque-locator"
        return invitation
    }
    func testFreshApprovedBootstrapAndSavedTrustUseIndependentFreshConnections() throws {
        let invitation = try pair(), now = Date(timeIntervalSince1970: 1000)
        let bootstrap = try LocalOwnerChallenge.make(invitation: invitation, now: now)
        let proof = try LocalOwnerResponse.make(challenge: bootstrap, invitation: invitation, now: now)
        var admission = LocalOwnerAdmission(challenge: bootstrap)
        try admission.accept(proof, invitation: invitation, now: now)
        XCTAssertTrue(admission.consumed)
        XCTAssertThrowsError(try admission.accept(proof, invitation: invitation, now: now))
        let reconnect = try LocalOwnerChallenge.make(invitation: invitation, now: now)
        XCTAssertNotEqual(bootstrap.nonce, reconnect.nonce)
        XCTAssertNotEqual(bootstrap.epoch, reconnect.epoch)
        var newAdmission = LocalOwnerAdmission(challenge: reconnect)
        XCTAssertThrowsError(try newAdmission.accept(proof, invitation: invitation, now: now))
        XCTAssertFalse(newAdmission.consumed)
        try newAdmission.accept(LocalOwnerResponse.make(challenge: reconnect, invitation: invitation, now: now),
                                invitation: invitation, now: now)
        XCTAssertTrue(newAdmission.consumed)
    }
    func testSpoofedHostOwnerPairOrExpiredChallengeCannotAuthenticate() throws {
        let invitation = try pair(), now = Date(timeIntervalSince1970: 2000)
        let challenge = try LocalOwnerChallenge.make(invitation: invitation, now: now)
        var otherHost = invitation; otherHost.durableHostID = try SecureRandom.token()
        XCTAssertThrowsError(try LocalOwnerResponse.make(challenge: challenge, invitation: otherHost, now: now))
        var revoked = invitation; revoked.ownerPairID = try SecureRandom.token()
        let response = try LocalOwnerResponse.make(challenge: challenge, invitation: invitation, now: now)
        XCTAssertThrowsError(try response.validate(expected: challenge, invitation: revoked, now: now))
        XCTAssertThrowsError(try response.validate(expected: challenge, invitation: invitation, now: now.addingTimeInterval(20)))
        XCTAssertThrowsError(try challenge.validate(invitation: invitation, now: now.addingTimeInterval(-30)))
    }
    func testDiscoveredLocatorNameAndPurchaseRestorationNeverProvideKeyAuthority() throws {
        let invitation = try pair(), now = Date(timeIntervalSince1970: 3000)
        let challenge = try LocalOwnerChallenge.make(invitation: invitation, now: now)
        let proof = try LocalOwnerResponse.make(challenge: challenge, invitation: invitation, now: now)
        var attacker = invitation // Same host ID, service locator and all public identifiers.
        attacker.key = try SecureRandom.bytes()
        XCTAssertThrowsError(try proof.validate(expected: challenge, invitation: attacker, now: now))
        let fake = try LocalOwnerResponse.make(challenge: challenge, invitation: attacker, now: now)
        XCTAssertThrowsError(try fake.validate(expected: challenge, invitation: invitation, now: now))
        attacker = invitation; attacker.token = "restored-purchase"
        XCTAssertThrowsError(try attacker.validate(enrollment: false))
    }
    func testTranscriptTamperingAndOldSessionOrNonceFailClosed() throws {
        let invitation = try pair(), now = Date(timeIntervalSince1970: 4000)
        let challenge = try LocalOwnerChallenge.make(invitation: invitation, now: now)
        let proof = try LocalOwnerResponse.make(challenge: challenge, invitation: invitation, now: now)
        let altered = LocalOwnerResponse(challenge: challenge, clientNonce: try SecureRandom.token(), authentication: proof.authentication)
        XCTAssertThrowsError(try altered.validate(expected: challenge, invitation: invitation, now: now))
        let epochChanged = LocalOwnerChallenge(hostID: challenge.hostID, ownerPairID: challenge.ownerPairID,
            epoch: String(try SecureRandom.token().prefix(32)), nonce: challenge.nonce, expires: challenge.expires)
        XCTAssertThrowsError(try proof.validate(expected: epochChanged, invitation: invitation, now: now))
        let invalid = LocalOwnerResponse(challenge: challenge, clientNonce: "bad", authentication: proof.authentication)
        XCTAssertThrowsError(try invalid.validate(expected: challenge, invitation: invitation, now: now))
    }
    func testAllLocalWireContentIsEncryptedRoleBoundAndRequiresFreshSequence() throws {
        let invitation = try pair(), wrongPair = try pair()
        let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let wrongCipher = try SignalCipher(key: wrongPair.key, room: invitation.room)
        let request = try SecureRandom.token(), session = try SecureRandom.token()
        let clear = Data("private-fixture-only".utf8)
        let sealed = try cipher.seal(ProtectedMessage(kind: "localSignal", request: request, session: session,
                                                     sequence: 1, body: clear), sender: "host")
        XCTAssertFalse(sealed.contains("private-fixture-only"))
        XCTAssertThrowsError(try wrongCipher.open(sealed, sender: "host"))
        XCTAssertThrowsError(try cipher.open(sealed, sender: "client"))
        let opened = try cipher.open(sealed, sender: "host")
        var guardState = SessionReplayGuard(request: request, session: session)
        try guardState.accept(opened)
        XCTAssertThrowsError(try guardState.accept(opened))
        var changedSession = SessionReplayGuard(request: request, session: try SecureRandom.token())
        XCTAssertThrowsError(try changedSession.accept(opened))
    }
    func testFrameBoundsRejectZeroOversizeTruncatedAndMalformedInput() throws {
        for length in [1, 127, 65536, LocalSignalFraming.maximumPayload] {
            XCTAssertEqual(try LocalSignalFraming.length(LocalSignalFraming.header(length: length)), length)
        }
        XCTAssertThrowsError(try LocalSignalFraming.header(length: 0))
        XCTAssertThrowsError(try LocalSignalFraming.header(length: -1))
        XCTAssertThrowsError(try LocalSignalFraming.header(length: LocalSignalFraming.maximumPayload + 1))
        XCTAssertThrowsError(try LocalSignalFraming.length(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try LocalSignalFraming.length(Data([255, 255, 255, 255])))
        XCTAssertThrowsError(try LocalSignalFraming.length(Data([0, 1, 0])))
    }
    func testLegacyPairHasNoUnprovenDurableLocalAdmission() throws {
        let invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Legacy").invitation
        XCTAssertThrowsError(try LocalOwnerChallenge.make(invitation: invitation))
    }
}
