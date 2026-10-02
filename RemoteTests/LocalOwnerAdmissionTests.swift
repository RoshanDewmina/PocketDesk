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

    private func fixture(timeout: UInt64 = 1_000_000_000, legacyDeadline: Bool = false,
                         additionalDevices: Int = 0) async throws
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
        if additionalDevices > 0 {
            host.hostInvitations = [invitation]
            for _ in 0..<additionalDevices {
                var extra = invitation
                extra.key = try SecureRandom.bytes()
                extra.ownerPairID = try SecureRandom.token()
                extra.localServiceName = "farside-test-" + UUID().uuidString.lowercased()
                host.hostInvitations.append(extra)
            }
        }
        let ready = expectation(description: "Local listener registered")
        ready.assertForOverFulfill = true
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

    private func devicePort(_ invitation: PairInvitation, host: LocalSignalingTransport) async throws -> NWEndpoint.Port {
        let identifier = try XCTUnwrap(invitation.ownerPairID)
        for _ in 0..<150 {
            if let port = host.listeningPortForTesting(ownerPairID: identifier) { return port }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(host.listeningPortForTesting(ownerPairID: identifier))
    }

    private func prove(_ challenge: LocalOwnerChallenge, invitation: PairInvitation,
                       on connection: NWConnection) async throws {
        let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let proof = try LocalOwnerResponse.make(challenge: challenge, invitation: invitation)
        let payload = Data(try cipher.seal(ProtectedMessage(kind: "localProof", request: challenge.hostID,
            session: challenge.nonce, sequence: 0, body: JSONEncoder().encode(proof)), sender: "client").utf8)
        await send(try LocalSignalFraming.header(length: payload.count) + payload, to: connection)
    }

    private func expectClosed(_ connection: NWConnection) async {
        let rejected = expectation(description: "Rejected local attempt closes its TCP connection")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4) { data, _, complete, error in
            XCTAssertTrue(complete || error != nil)
            XCTAssertTrue(data?.isEmpty ?? true)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 3)
    }

    func testCatalogRejectsMoreThanFiveDevicesConflictingKeysForeignHostAndDuplicateServices() async throws {
        let (host, invitation, _) = try await fixture()
        defer { host.close() }
        host.hostInvitations = Array(repeating: invitation, count: 6)
        XCTAssertThrowsError(try host.connect(invitation: invitation, hostToken: "fixture-host", features: []))
        var conflicting = invitation; conflicting.key = try SecureRandom.bytes()
        host.hostInvitations = [invitation, conflicting]
        XCTAssertThrowsError(try host.connect(invitation: invitation, hostToken: "fixture-host", features: []))
        var foreign = invitation; foreign.durableHostID = try SecureRandom.token()
        foreign.ownerPairID = try SecureRandom.token()
        host.hostInvitations = [invitation, foreign]
        XCTAssertThrowsError(try host.connect(invitation: invitation, hostToken: "fixture-host", features: []))
        var duplicateService = invitation; duplicateService.ownerPairID = try SecureRandom.token()
        duplicateService.key = try SecureRandom.bytes()
        host.hostInvitations = [invitation, duplicateService]
        XCTAssertThrowsError(try host.connect(invitation: invitation, hostToken: "fixture-host", features: []))
        duplicateService.localServiceName = invitation.localServiceName?.uppercased()
        host.hostInvitations = [invitation, duplicateService]
        XCTAssertThrowsError(try host.connect(invitation: invitation, hostToken: "fixture-host", features: []))
        var foreignRoom = duplicateService; foreignRoom.room = try SecureRandom.token()
        foreignRoom.localServiceName = "farside-test-" + UUID().uuidString.lowercased()
        host.hostInvitations = [invitation, foreignRoom]
        XCTAssertThrowsError(try host.connect(invitation: invitation, hostToken: "fixture-host", features: []))
        XCTAssertNil(host.listeningPortForTesting)
    }

    func testFiveDeviceServicesGiveMatchingLegacyChallengesAndAllCloseTogether() async throws {
        let (host, _, _) = try await fixture(timeout: 3_000_000_000, additionalDevices: 4)
        defer { host.close() }
        let devices = host.hostInvitations
        XCTAssertEqual(devices.count, 5)
        var ports: Set<NWEndpoint.Port> = []
        for invitation in devices {
            let port = try await devicePort(invitation, host: host)
            ports.insert(port)
            let phone = await peer(port: port)
            defer { phone.cancel() }
            let challenge = try await challenge(from: phone, invitation: invitation)
            XCTAssertEqual(challenge.ownerPairID, invitation.ownerPairID)
        }
        XCTAssertEqual(ports.count, 5)
        host.close()
        XCTAssertNil(host.listeningPortForTesting)
        for invitation in devices {
            XCTAssertNil(host.listeningPortForTesting(ownerPairID: try XCTUnwrap(invitation.ownerPairID)))
        }
    }

    func testNewSecondaryPhoneAuthenticatesSelectedPairBeforeCallbacksAndExchangesSignal() async throws {
        let (host, _, _) = try await fixture(timeout: 3_000_000_000, additionalDevices: 1)
        defer { host.close() }
        let selected = try XCTUnwrap(host.hostInvitations.last)
        let port = try await devicePort(selected, host: host)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "farside.local.phone." + UUID().uuidString))
        let parameters = NWParameters.tcp; parameters.requiredInterfaceType = .loopback
        let phone = LocalSignalingTransport(defaults: defaults, hostAuthenticationTimeoutNanoseconds: 3_000_000_000,
            parameters: parameters, endpoint: .hostPort(host: "127.0.0.1", port: port))
        defer { phone.close() }
        var callbacks: [String] = []
        let hostAuthenticated = expectation(description: "Secondary host authenticated")
        let phoneAuthenticated = expectation(description: "Secondary phone authenticated")
        host.onSelectedHostInvitation = { invitation in
            XCTAssertEqual(invitation, selected); callbacks.append("selected")
        }
        host.onAuthenticatedLocalSignaling = { challenge in
            XCTAssertEqual(challenge.ownerPairID, selected.ownerPairID)
            callbacks.append("authenticated"); hostAuthenticated.fulfill()
        }
        host.onMessage = { if $0.type == "peer" { callbacks.append("peer") } }
        phone.onAuthenticatedLocalSignaling = { challenge in
            XCTAssertEqual(challenge.ownerPairID, selected.ownerPairID); phoneAuthenticated.fulfill()
        }
        try phone.connect(invitation: selected, hostToken: nil, features: [])
        await fulfillment(of: [hostAuthenticated, phoneAuthenticated], timeout: 3)
        XCTAssertEqual(callbacks, ["selected", "authenticated", "peer"])
        let delivered = expectation(description: "Secondary encrypted signal delivered")
        host.onMessage = { if $0.type == "signal" { XCTAssertEqual($0.payload, "secondary"); delivered.fulfill() } }
        phone.send(RelayMessage(type: "signal", payload: "secondary"))
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertNil(host.lastCloseReason); XCTAssertNil(phone.lastCloseReason)
    }

    func testLegacyPrimaryPhoneUsesSingleChallengeAndEncryptedProofWithMultipleDevices() async throws {
        let (host, primary, port) = try await fixture(additionalDevices: 1)
        defer { host.close() }
        let authenticated = expectation(description: "Legacy primary proof accepted")
        var callbacks: [String] = []
        host.onSelectedHostInvitation = { XCTAssertEqual($0, primary); callbacks.append("selected") }
        host.onAuthenticatedLocalSignaling = { _ in callbacks.append("authenticated"); authenticated.fulfill() }
        let legacyPhone = await peer(port: port)
        defer { legacyPhone.cancel() }
        let challenge = try await challenge(from: legacyPhone, invitation: primary)
        try await prove(challenge, invitation: primary, on: legacyPhone)
        await fulfillment(of: [authenticated], timeout: 3)
        let header = try await read(4, from: legacyPhone)
        let payload = try await read(LocalSignalFraming.length(header), from: legacyPhone)
        let cipher = try SignalCipher(key: primary.key, room: primary.room)
        let ack = try cipher.open(XCTUnwrap(String(data: payload, encoding: .utf8)), sender: "host")
        XCTAssertEqual(ack.kind, "localAck", "Legacy phone receives no alternate-key challenges")
        XCTAssertEqual(callbacks, ["selected", "authenticated"])
    }

    func testNewPrimaryPhoneUsesLegacyHostChallengeAndProof() async throws {
        var invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Legacy Mac").invitation
        invitation.durableHostID = try SecureRandom.token()
        invitation.ownerPairID = try SecureRandom.token()
        invitation.localServiceName = "farside-test-" + UUID().uuidString.lowercased()
        let parameters = NWParameters.tcp; parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let listening = expectation(description: "Raw legacy host listening")
        let connected = expectation(description: "Raw legacy host accepted new phone")
        var legacyConnection: NWConnection?
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                legacyConnection = connection
                connection.stateUpdateHandler = { if case .ready = $0 { connected.fulfill() } }
                connection.start(queue: self.queue)
            }
        }
        listener.start(queue: queue)
        await fulfillment(of: [listening], timeout: 3)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "farside.local.legacy-phone." + UUID().uuidString))
        let phone = LocalSignalingTransport(defaults: defaults, hostAuthenticationTimeoutNanoseconds: 3_000_000_000,
            parameters: parameters, endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)))
        defer { phone.close(); legacyConnection?.cancel() }
        let authenticated = expectation(description: "New phone accepted legacy host ack")
        phone.onAuthenticatedLocalSignaling = { _ in authenticated.fulfill() }
        try phone.connect(invitation: invitation, hostToken: nil, features: [])
        await fulfillment(of: [connected], timeout: 3)
        let connection = try XCTUnwrap(legacyConnection)
        let challenge = try LocalOwnerChallenge.make(invitation: invitation)
        let cipher = try SignalCipher(key: invitation.key, room: invitation.room)
        let challengePayload = Data(try cipher.seal(ProtectedMessage(kind: "localChallenge", request: challenge.hostID,
            session: challenge.nonce, sequence: 0, body: JSONEncoder().encode(challenge)), sender: "host").utf8)
        await send(try LocalSignalFraming.header(length: challengePayload.count) + challengePayload, to: connection)
        let header = try await read(4, from: connection)
        let payload = try await read(LocalSignalFraming.length(header), from: connection)
        let packet = try cipher.open(XCTUnwrap(String(data: payload, encoding: .utf8)), sender: "client")
        XCTAssertEqual(packet.kind, "localProof")
        let proof = try JSONDecoder().decode(LocalOwnerResponse.self, from: XCTUnwrap(packet.body))
        try proof.validate(expected: challenge, invitation: invitation)
        let ack = Data(try cipher.seal(ProtectedMessage(kind: "localAck", request: challenge.hostID,
            session: challenge.nonce, sequence: 0, body: JSONEncoder().encode(proof)), sender: "host").utf8)
        await send(try LocalSignalFraming.header(length: ack.count) + ack, to: connection)
        await fulfillment(of: [authenticated], timeout: 3)
        XCTAssertNil(phone.lastCloseReason)
    }

    func testLegacySecondaryPhoneUsesMatchingChallengeAndCannotBeTakenOverAcrossServices() async throws {
        let (host, primary, primaryPort) = try await fixture(timeout: 3_000_000_000, additionalDevices: 1)
        defer { host.close() }
        let secondary = try XCTUnwrap(host.hostInvitations.last)
        let secondaryPort = try await devicePort(secondary, host: host)
        XCTAssertNotEqual(primaryPort, secondaryPort)
        let owner = await peer(port: secondaryPort)
        defer { owner.cancel() }
        let challenge = try await challenge(from: owner, invitation: secondary)
        let authenticated = expectation(description: "Legacy secondary proof accepted")
        var callbacks: [String] = []
        host.onSelectedHostInvitation = { XCTAssertEqual($0, secondary); callbacks.append("selected") }
        host.onAuthenticatedLocalSignaling = { _ in callbacks.append("authenticated"); authenticated.fulfill() }
        try await prove(challenge, invitation: secondary, on: owner)
        await fulfillment(of: [authenticated], timeout: 3)
        XCTAssertEqual(callbacks, ["selected", "authenticated"])
        let primaryIntruder = await peer(port: primaryPort)
        defer { primaryIntruder.cancel() }
        await expectClosed(primaryIntruder)
        let secondaryIntruder = await peer(port: secondaryPort)
        defer { secondaryIntruder.cancel() }
        await expectClosed(secondaryIntruder)
        let delivered = expectation(description: "Legacy secondary retains global ownership")
        host.onMessage = { if $0.type == "signal" { delivered.fulfill() } }
        let cipher = try SignalCipher(key: secondary.key, room: secondary.room)
        let signal = Data(try cipher.seal(ProtectedMessage(kind: "localSignal", request: challenge.hostID,
            session: challenge.nonce, sequence: 1, body: JSONEncoder().encode(RelayMessage(type: "signal", payload: "secondary"))), sender: "client").utf8)
        await send(try LocalSignalFraming.header(length: signal.count) + signal, to: owner)
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(callbacks, ["selected", "authenticated"])
        XCTAssertEqual(host.listeningPortForTesting, primaryPort)
        XCTAssertEqual(host.listeningPortForTesting(ownerPairID: try XCTUnwrap(primary.ownerPairID)), primaryPort)
        host.close()
        XCTAssertNil(host.listeningPortForTesting(ownerPairID: try XCTUnwrap(secondary.ownerPairID)))
    }

    func testSecondaryServiceWrongKeyCannotAuthenticateAndPrimaryStillServes() async throws {
        let (host, primary, port) = try await fixture(additionalDevices: 1)
        defer { host.close() }
        var callbacks = 0
        host.onSelectedHostInvitation = { _ in callbacks += 1 }
        host.onAuthenticatedLocalSignaling = { _ in callbacks += 1 }
        let secondary = try XCTUnwrap(host.hostInvitations.last)
        let secondaryPort = try await devicePort(secondary, host: host)
        let attacker = await peer(port: secondaryPort)
        defer { attacker.cancel() }
        let selectedChallenge = try await challenge(from: attacker, invitation: secondary)
        var wrongKey = secondary; wrongKey.key = try SecureRandom.bytes()
        try await prove(selectedChallenge, invitation: wrongKey, on: attacker)
        try await waitForReason("Local signaling authentication failed", host: host)
        let fresh = await peer(port: port)
        defer { fresh.cancel() }
        _ = try await challenge(from: fresh, invitation: primary)
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(host.listeningPortForTesting, port)
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
