import XCTest
import Network
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
    func testRealDateWireRoundTripPreservesAuthenticatedTranscript() throws {
        let invitation = try pair()
        let challenge = try LocalOwnerChallenge.make(invitation: invitation)
        let encodedChallenge = try JSONEncoder().encode(challenge)
        let decodedChallenge = try JSONDecoder().decode(LocalOwnerChallenge.self, from: encodedChallenge)
        XCTAssertEqual(decodedChallenge, challenge)
        let proof = try LocalOwnerResponse.make(challenge: decodedChallenge, invitation: invitation)
        let decodedProof = try JSONDecoder().decode(LocalOwnerResponse.self, from: JSONEncoder().encode(proof))
        var admission = LocalOwnerAdmission(challenge: challenge)
        try admission.accept(decodedProof, invitation: invitation)
        XCTAssertTrue(admission.consumed)
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

/// Real TCP frames exercise the transport's admission, recovery and callback fencing.
@MainActor
final class LocalSignalingLifecycleTests: XCTestCase {
    private let queue = DispatchQueue(label: "farside.test.local-signaling")

    private func fixture(timeout: UInt64 = 1_000_000_000, legacyDeadline: Bool = false) async throws
        -> (LocalSignalingTransport, PairInvitation, NWEndpoint.Port) {
        var invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Fixture").invitation
        invitation.durableHostID = try SecureRandom.token()
        invitation.ownerPairID = try SecureRandom.token()
        invitation.localServiceName = "farside-test-" + UUID().uuidString.lowercased()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "farside.local.test." + UUID().uuidString))
        defaults.set(legacyDeadline, forKey: LocalSignalingTransport.legacyAuthenticationTimeoutKey)
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let host = LocalSignalingTransport(defaults: defaults,
            hostAuthenticationTimeoutNanoseconds: timeout, parameters: parameters)
        let ready = expectation(description: "Local listener registered")
        host.onMessage = { if $0.type == "registered" { ready.fulfill() } }
        try host.connect(invitation: invitation, hostToken: "fixture-host", features: [])
        await fulfillment(of: [ready], timeout: 3)
        return (host, invitation, try XCTUnwrap(host.listeningPortForTesting))
    }

    private func peer(port: NWEndpoint.Port) async -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let ready = expectation(description: "Raw TCP peer ready")
        connection.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        connection.start(queue: queue)
        await fulfillment(of: [ready], timeout: 3)
        return connection
    }

    private func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        let received = expectation(description: "TCP frame bytes")
        var result: Data?
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            Task { @MainActor in result = data; received.fulfill() }
        }
        await fulfillment(of: [received], timeout: 3)
        let data = try XCTUnwrap(result)
        XCTAssertEqual(data.count, count)
        return data
    }

    private func challenge(from connection: NWConnection, invitation: PairInvitation) async throws -> LocalOwnerChallenge {
        let header = try await read(4, from: connection)
        let body = try await read(LocalSignalFraming.length(header), from: connection)
        let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let packet = try cipher.open(try XCTUnwrap(String(data: body, encoding: .utf8)), sender: "host")
        XCTAssertEqual(packet.kind, "localChallenge")
        return try JSONDecoder().decode(LocalOwnerChallenge.self, from: XCTUnwrap(packet.body))
    }

    private func send(_ data: Data, to connection: NWConnection) async {
        let sent = expectation(description: "TCP write completed")
        connection.send(content: data, completion: .contentProcessed { _ in sent.fulfill() })
        await fulfillment(of: [sent], timeout: 3)
    }

    private func waitForReason(_ reason: String, host: LocalSignalingTransport) async throws {
        for _ in 0..<150 {
            if host.lastCloseReason == reason { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Expected local attempt failure: \(reason), received \(host.lastCloseReason ?? "none")")
    }

    func testUnauthenticatedTimeoutKeepsListenerAndAcceptsFreshAttempt() async throws {
        let (host, invitation, port) = try await fixture(timeout: 150_000_000)
        defer { host.close() }
        var closes = 0, authentications = 0
        host.onClose = { closes += 1 }
        host.onAuthenticatedLocalSignaling = { _ in authentications += 1 }
        let stalled = await peer(port: port)
        defer { stalled.cancel() }
        let oldChallenge = try await challenge(from: stalled, invitation: invitation)
        try await waitForReason("Local authentication timed out", host: host)
        XCTAssertEqual(host.listeningPortForTesting, port)
        let fresh = await peer(port: port)
        defer { fresh.cancel() }
        let newChallenge = try await challenge(from: fresh, invitation: invitation)
        XCTAssertNotEqual(oldChallenge.nonce, newChallenge.nonce)
        XCTAssertEqual(closes, 0); XCTAssertEqual(authentications, 0)
    }

    func testMalformedAndWrongKeyAttemptsKeepListenerServingWithoutAuthority() async throws {
        let (host, invitation, port) = try await fixture()
        defer { host.close() }
        var closes = 0, authentications = 0
        host.onClose = { closes += 1 }
        host.onAuthenticatedLocalSignaling = { _ in authentications += 1 }
        let malformed = await peer(port: port)
        defer { malformed.cancel() }
        _ = try await challenge(from: malformed, invitation: invitation)
        await send(Data([0, 0, 0, 0]), to: malformed)
        try await waitForReason("Invalid local signaling frame", host: host)
        let wrongKey = await peer(port: port)
        defer { wrongKey.cancel() }
        let challenge = try await challenge(from: wrongKey, invitation: invitation)
        var attacker = invitation; attacker.key = try SecureRandom.bytes()
        let cipher = try SignalCipher(key: attacker.key, room: invitation.room)
        let proof = try LocalOwnerResponse.make(challenge: challenge, invitation: attacker)
        let payload = Data(try cipher.seal(ProtectedMessage(kind: "localProof", request: challenge.hostID,
            session: challenge.nonce, sequence: 0, body: JSONEncoder().encode(proof)), sender: "client").utf8)
        await send(try LocalSignalFraming.header(length: payload.count) + payload, to: wrongKey)
        try await waitForReason("Local signaling authentication failed", host: host)
        let fresh = await peer(port: port)
        defer { fresh.cancel() }
        _ = try await self.challenge(from: fresh, invitation: invitation)
        XCTAssertEqual(host.listeningPortForTesting, port)
        XCTAssertEqual(closes, 0); XCTAssertEqual(authentications, 0)
    }

    func testPendingReplacementFencesOldReadAndDeadlineAndPreservesAuthenticatedOwner() async throws {
        let (host, invitation, port) = try await fixture(timeout: 600_000_000)
        defer { host.close() }
        var closes = 0, authentications = 0
        host.onClose = { closes += 1 }
        let authenticated = expectation(description: "Fresh owner authenticated")
        host.onAuthenticatedLocalSignaling = { _ in authentications += 1; authenticated.fulfill() }
        let old = await peer(port: port)
        defer { old.cancel() }
        let oldChallenge = try await challenge(from: old, invitation: invitation)
        try await Task.sleep(nanoseconds: 350_000_000)
        let owner = await peer(port: port)
        defer { owner.cancel() }
        let current = try await challenge(from: owner, invitation: invitation)
        XCTAssertNotEqual(oldChallenge.nonce, current.nonce)
        // Cancellation of the old peer leaves an outstanding production read completion.
        old.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(closes, 0)
        let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let proof = try LocalOwnerResponse.make(challenge: current, invitation: invitation)
        let payload = Data(try cipher.seal(ProtectedMessage(kind: "localProof", request: current.hostID,
            session: current.nonce, sequence: 0, body: JSONEncoder().encode(proof)), sender: "client").utf8)
        await send(try LocalSignalFraming.header(length: payload.count) + payload, to: owner)
        await fulfillment(of: [authenticated], timeout: 3)
        let intruder = await peer(port: port)
        defer { intruder.cancel() }
        let rejected = expectation(description: "Authenticated ownership rejects incoming connection")
        intruder.receive(minimumIncompleteLength: 1, maximumLength: 4) { data, _, complete, error in
            XCTAssertTrue(complete || error != nil); XCTAssertTrue(data?.isEmpty ?? true)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 3)
        var signals = 0
        let delivered = expectation(description: "Authenticated owner's signal remains usable")
        host.onMessage = { if $0.type == "signal" { signals += 1; delivered.fulfill() } }
        let signal = Data(try cipher.seal(ProtectedMessage(kind: "localSignal", request: current.hostID,
            session: current.nonce, sequence: 1, body: JSONEncoder().encode(RelayMessage(type: "signal", payload: "fixture"))), sender: "client").utf8)
        await send(try LocalSignalFraming.header(length: signal.count) + signal, to: owner)
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(signals, 1); XCTAssertEqual(authentications, 1); XCTAssertEqual(closes, 0)
    }

    func testLegacyDeadlineSwitchKeepsRecoveryAndAuthenticationRequired() async throws {
        let (host, invitation, port) = try await fixture(timeout: 50_000_000, legacyDeadline: true)
        defer { host.close() }
        var closes = 0, authentications = 0
        host.onClose = { closes += 1 }
        host.onAuthenticatedLocalSignaling = { _ in authentications += 1 }
        let stalled = await peer(port: port)
        defer { stalled.cancel() }
        _ = try await challenge(from: stalled, invitation: invitation)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(host.lastCloseReason, "Kill switch restores the old deadline")
        let replacement = await peer(port: port)
        defer { replacement.cancel() }
        _ = try await challenge(from: replacement, invitation: invitation)
        await send(Data([0, 0, 0, 0]), to: replacement)
        try await waitForReason("Invalid local signaling frame", host: host)
        XCTAssertEqual(host.listeningPortForTesting, port)
        XCTAssertEqual(closes, 0); XCTAssertEqual(authentications, 0)
    }
}
