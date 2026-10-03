import XCTest
import Foundation

/// The other end of the conversation, played by the test: it seals what a phone (or a Mac) would
/// send and opens what the coordinator under test sent.
@MainActor
private struct Counterpart {
    let cipher: SignalCipher
    let role: String

    init(cipher: SignalCipher, plays role: String) {
        self.cipher = cipher
        self.role = role
    }

    init(invitation: PairInvitation, plays role: String) throws {
        self.init(cipher: try SignalCipher(key: invitation.key, room: invitation.room), plays: role)
    }

    func seal(_ kind: String, request: String, session: String = "", sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
        RelayMessage(type: "signal", payload: try cipher.seal(
            ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: role))
    }

    func open(_ message: RelayMessage) throws -> ProtectedMessage {
        let payload = try XCTUnwrap(message.payload)
        return try cipher.open(payload, sender: role == "client" ? "host" : "client")
    }
}

private let candidateBody: Data = {
    let signal = MediaSignal(kind: "candidate", candidate: "candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host", mid: "0", line: 0)
    return try! JSONEncoder().encode(signal)
}()

@MainActor
private final class HostFixture {
    let signaling = ScriptedSignaling()
    let scheduler = ManualScheduler()
    let host: RemoteCoordinator
    let phone: Counterpart
    let invitation: PairInvitation

    init(handshakeTimeoutNanoseconds: UInt64 = 20_000_000_000, defaults: UserDefaults = .standard) throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        invitation = pair.invitation
        host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                 registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                 renewalScheduler: scheduler, defaults: defaults,
                                 handshakeTimeoutNanoseconds: handshakeTimeoutNanoseconds)
        host.allowLegacyPrivateRoute = true
        phone = try Counterpart(invitation: pair.invitation, plays: "client")
        host.restore()
    }

    func startRegistered(offer: RenewalOffer? = nil) {
        host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host", renew: offer))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
    }

    /// A phone joins and sends its request; returns the session the Mac challenged it with.
    func handshake(request: String) throws -> String {
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(try phone.seal("request", request: request))
        let challenge = try phone.open(try XCTUnwrap(signaling.sent.last))
        XCTAssertEqual(challenge.kind, "challenge")
        XCTAssertEqual(challenge.request, request)
        return challenge.session
    }

    func prove(request: String, session: String) throws {
        signaling.deliver(try phone.seal("proof", request: request, session: session))
    }

    func phoneLeaves() { signaling.deliver(RelayMessage(type: "peer", online: false)) }

    func assertStillListening(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(host.hostRegistered, file: file, line: line)
        XCTAssertEqual(host.status, "Ready for your paired phone", file: file, line: line)
        XCTAssertTrue(host.isRunning, file: file, line: line)
        XCTAssertTrue(signaling.isOpen, file: file, line: line)
        XCTAssertEqual(signaling.connects.count, 1, "the Mac must not have reconnected", file: file, line: line)
    }
}

@MainActor
final class StaleSignalTests: XCTestCase {
    private func trustedTimeoutCoordinator(isHost: Bool, defaults: UserDefaults,
                                           retriesIndefinitely: Bool = false) throws -> (RemoteCoordinator, ScriptedSignaling) {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        if isHost { try store.save(pair) } else { try store.save(pair.invitation) }
        let signaling = ScriptedSignaling()
        let coordinator = RemoteCoordinator(isHost: isHost, store: store, retryLimit: 2,
            retryBaseNanoseconds: 5_000_000, retriesIndefinitely: retriesIndefinitely,
            signaling: signaling, renewalScheduler: ManualScheduler(), defaults: defaults,
            handshakeTimeoutNanoseconds: 60_000_000)
        coordinator.allowLegacyPrivateRoute = true
        coordinator.restore()
        return (coordinator, signaling)
    }

    private func waitForTimeoutState(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }

    func testTimeoutRecoverySwitchPreservesThePhoneAndHostRetryBudget() async throws {
        for isHost in [false, true] {
            for disabled in [false, true] {
                let suite = "TimeoutBudget-\(UUID())"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defaults.set(disabled, forKey: RemoteCoordinator.transientTimeoutRecoveryDisabledKey)
                defer { defaults.removePersistentDomain(forName: suite) }
                let (coordinator, signaling) = try trustedTimeoutCoordinator(isHost: isHost, defaults: defaults)
                let trustedRoom = coordinator.invitation?.room
                coordinator.start()
                defer { coordinator.stop() }
                try await waitForTimeoutState { !coordinator.isRunning }
                XCTAssertEqual(signaling.connects.count, disabled ? 1 : 3)
                XCTAssertEqual(coordinator.retryAttempt, disabled ? 0 : 2)
                XCTAssertFalse(coordinator.reconnecting)
                XCTAssertTrue(coordinator.status.hasPrefix("Connection timed out"))
                XCTAssertEqual(coordinator.invitation?.room, trustedRoom, "timeout must preserve saved trust")
            }
        }
    }

    func testTimeoutRecoveryPolicyIsFrozenAndIndefiniteHostRetryStillWorks() async throws {
        let suite = "TimeoutSnapshot-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (host, signaling) = try trustedTimeoutCoordinator(isHost: true, defaults: defaults, retriesIndefinitely: true)
        // An absent key defaults on; a later write only applies to a new coordinator/process.
        defaults.set(true, forKey: RemoteCoordinator.transientTimeoutRecoveryDisabledKey)
        host.start()
        defer { host.stop() }
        try await waitForTimeoutState { signaling.connects.count >= 4 || !host.isRunning }
        XCTAssertTrue(host.isRunning)
        XCTAssertGreaterThanOrEqual(signaling.connects.count, 4, "a sharing host outlives the finite retry budget")
    }

    func testFatalServiceErrorsRemainTerminalWithEitherTimeoutSwitchState() throws {
        for disabled in [false, true] {
            let suite = "TimeoutFatal-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(disabled, forKey: RemoteCoordinator.transientTimeoutRecoveryDisabledKey)
            defer { defaults.removePersistentDomain(forName: suite) }
            for isHost in [false, true] {
                for code in ["upgrade_required", "unauthorized", "revoked"] {
                    let (coordinator, signaling) = try trustedTimeoutCoordinator(isHost: isHost, defaults: defaults)
                    coordinator.start()
                    signaling.deliver(RelayMessage(type: "error", code: code))
                    XCTAssertFalse(coordinator.isRunning, "\(code) must remain terminal")
                    XCTAssertFalse(coordinator.reconnecting)
                    XCTAssertEqual(signaling.connects.count, 1)
                    XCTAssertEqual(coordinator.retryAttempt, 0)
                    coordinator.stop()
                }
            }
        }
    }

    func testFreshEnrollmentTimeoutIsTerminalWithEitherRecoverySwitchState() async throws {
        for disabled in [false, true] {
            let suite = "TimeoutEnrollment-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(disabled, forKey: RemoteCoordinator.transientTimeoutRecoveryDisabledKey)
            defer { defaults.removePersistentDomain(forName: suite) }
            for isHost in [false, true] {
                let store = MemoryPairStore(), signaling = ScriptedSignaling()
                let coordinator = RemoteCoordinator(isHost: isHost, store: store,
                    retryBaseNanoseconds: 5_000_000, signaling: signaling, defaults: defaults,
                    handshakeTimeoutNanoseconds: 60_000_000)
                if isHost {
                    _ = try coordinator.createPair(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
                    coordinator.start()
                } else {
                    let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
                    try coordinator.enroll(pair.invitation.code())
                }
                defer { coordinator.stop() }
                try await waitForTimeoutState { !coordinator.isRunning }
                XCTAssertEqual(signaling.connects.count, 1)
                XCTAssertFalse(coordinator.awaitingApproval)
                XCTAssertNil(coordinator.pairingComparisonCode)
                XCTAssertNil(coordinator.media)
                if isHost { XCTAssertLessThan(try XCTUnwrap(store.read(HostPair.self)).invitation.expires, Date()) }
                else { XCTAssertNil(store.data, "a stalled enrollment cannot create saved trust") }
            }
        }
    }

    func testStopCancelsTimeoutRecoveryWithEitherSwitchState() async throws {
        for disabled in [false, true] {
            let suite = "TimeoutStop-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(disabled, forKey: RemoteCoordinator.transientTimeoutRecoveryDisabledKey)
            defer { defaults.removePersistentDomain(forName: suite) }
            let (phone, signaling) = try trustedTimeoutCoordinator(isHost: false, defaults: defaults)
            phone.start(); phone.stop()
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(signaling.connects.count, 1)
            XCTAssertFalse(phone.isRunning)
            XCTAssertEqual(phone.status, "Disconnected")
        }
    }

    func testOfflineRetiresRouteEpochUntilTheNextPhoneGetsANewOne() throws {
        let fixture = try HostFixture()
        fixture.startRegistered()
        let oldEpoch = String(repeating: "a", count: 32)
        let newEpoch = String(repeating: "b", count: 32)
        func route(_ epoch: String) throws -> RelayMessage {
            let deadline = Int64((Date().timeIntervalSince1970 + 60) * 1000)
            let json = """
            {"type":"route","version":1,"room":"\(fixture.invitation.room)","epoch":"\(epoch)","revision":1,"access":"local","expiresAt":\(deadline)}
            """
            return try JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
        }

        let oldRoute = try route(oldEpoch)
        fixture.signaling.deliver(oldRoute)
        XCTAssertEqual(fixture.host.routePolicyEpoch, oldEpoch)
        fixture.phoneLeaves()
        fixture.assertStillListening()
        XCTAssertNil(fixture.host.routePolicyEpoch)

        fixture.signaling.deliver(oldRoute)
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 1)
        XCTAssertNil(fixture.host.routePolicyEpoch)
        fixture.signaling.deliver(try route(newEpoch))
        XCTAssertEqual(fixture.host.routePolicyEpoch, newEpoch)
        fixture.signaling.deliver(RelayMessage(type: "peer", online: true))
        XCTAssertTrue(fixture.host.isRunning)
    }

    func testALateMessageFromThePreviousPhoneSessionNeverStopsTheMacListening() async throws {
        let fixture = try HostFixture()
        fixture.startRegistered(offer: RenewalOffer(version: 1, leaseSeconds: 1800, renewAfterSeconds: 900))
        let old = try SecureRandom.token()
        let session = try fixture.handshake(request: old)
        try fixture.prove(request: old, session: session)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…")

        fixture.phoneLeaves()
        fixture.assertStillListening()
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 0)

        fixture.signaling.deliver(try fixture.phone.seal("media", request: old, session: session, sequence: 2, body: candidateBody))
        fixture.signaling.deliver(try fixture.phone.seal("acceptedAck", request: old, session: session, sequence: 1))
        fixture.signaling.deliver(try fixture.phone.seal("proof", request: old, session: session))
        fixture.assertStillListening()
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 3)
        XCTAssertNotNil(fixture.host.renewalPlanForTesting, "ignoring stale signaling must not disturb renewal")

        let next = try SecureRandom.token()
        let nextSession = try fixture.handshake(request: next)
        XCTAssertNotEqual(nextSession, session)
        try fixture.prove(request: next, session: nextSession)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…", "the Mac still serves the next phone")
    }

    func testALateMessageDuringTheNextHandshakeIsIgnoredAndThatHandshakeCompletes() async throws {
        let fixture = try HostFixture()
        fixture.startRegistered()
        let first = try SecureRandom.token()
        let firstSession = try fixture.handshake(request: first)
        try fixture.prove(request: first, session: firstSession)
        fixture.phoneLeaves()

        let second = try SecureRandom.token()
        let secondSession = try fixture.handshake(request: second)
        fixture.signaling.deliver(try fixture.phone.seal("media", request: first, session: firstSession, sequence: 3, body: candidateBody))
        fixture.signaling.deliver(try fixture.phone.seal("proof", request: first, session: firstSession))
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 2)
        XCTAssertTrue(fixture.host.isRunning)

        try fixture.prove(request: second, session: secondSession)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…")
        XCTAssertEqual(fixture.signaling.connects.count, 1)
    }

    func testAReplayedOrCompetingRequestNeverDisturbsAnActiveHandshake() async throws {
        let fixture = try HostFixture()
        fixture.startRegistered()
        let request = try SecureRandom.token()
        let session = try fixture.handshake(request: request)
        let sentBefore = fixture.signaling.sent.count

        fixture.signaling.deliver(try fixture.phone.seal("request", request: request))
        fixture.signaling.deliver(try fixture.phone.seal("request", request: try SecureRandom.token()))
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 2)
        XCTAssertEqual(fixture.signaling.sent.count, sentBefore, "no second challenge, no reset")
        XCTAssertTrue(fixture.host.isRunning)

        try fixture.prove(request: request, session: session)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…", "the original handshake still completes")
    }

    func testAMessageSealedWithAnotherKeyIsDroppedWithoutAffectingTheMac() async throws {
        let fixture = try HostFixture()
        fixture.startRegistered()
        let stranger = Counterpart(cipher: try SignalCipher(key: SecureRandom.bytes(), room: fixture.invitation.room), plays: "client")
        fixture.signaling.deliver(try stranger.seal("request", request: try SecureRandom.token()))
        fixture.signaling.deliver(RelayMessage(type: "signal", payload: "not base64 at all"))
        fixture.assertStillListening()
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 2)

        let request = try SecureRandom.token()
        let session = try fixture.handshake(request: request)
        XCTAssertFalse(session.isEmpty)
    }

    func testTheServicesNoticeThatThePhoneAlreadyLeftIsNotAFailureButRealServiceErrorsStillAre() async throws {
        let fixture = try HostFixture()
        fixture.startRegistered()
        fixture.signaling.deliver(RelayMessage(type: "error", code: "peer_unavailable"))
        fixture.assertStillListening()
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 1)

        fixture.signaling.deliver(RelayMessage(type: "error", code: "room_not_approved"))
        XCTAssertFalse(fixture.host.isRunning)
        XCTAssertTrue(fixture.host.status.contains("room_not_approved"))
        XCTAssertFalse(fixture.host.hostRegistered)
    }

    func testAnAuthenticatedButMalformedMessageEndsThePhoneSessionButNotTheMacsRegistration() async throws {
        let fixture = try HostFixture()
        fixture.startRegistered()
        let request = try SecureRandom.token()
        let session = try fixture.handshake(request: request)
        try fixture.prove(request: request, session: session)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…")

        fixture.signaling.deliver(try fixture.phone.seal("media", request: request, session: session, sequence: 1))
        fixture.assertStillListening()
        XCTAssertEqual(fixture.host.staleMessagesIgnored, 0, "this one was current, so it ended the session instead of being ignored")

        let again = try SecureRandom.token()
        let againSession = try fixture.handshake(request: again)
        try fixture.prove(request: again, session: againSession)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…")

        fixture.signaling.deliver(try fixture.phone.seal("kind-from-a-newer-phone", request: again, session: againSession, sequence: 1))
        fixture.assertStillListening()
    }

    func testAPhoneThatStallsMidHandshakeDoesNotStopARegisteredMac() async throws {
        let fixture = try HostFixture(handshakeTimeoutNanoseconds: 60_000_000)
        fixture.startRegistered()
        _ = try fixture.handshake(request: try SecureRandom.token())
        try await Task.sleep(nanoseconds: 300_000_000)
        fixture.assertStillListening()

        let next = try SecureRandom.token()
        let session = try fixture.handshake(request: next)
        try fixture.prove(request: next, session: session)
        XCTAssertEqual(fixture.host.status, "Connecting live desktop…", "the abandoned attempt did not block the next phone")
    }

    func testAMacThatNeverReachedTheServiceStillReportsTheTimeout() async throws {
        let suite = "TimeoutRollback-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: RemoteCoordinator.transientTimeoutRecoveryDisabledKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try HostFixture(handshakeTimeoutNanoseconds: 60_000_000, defaults: defaults)
        fixture.host.start()
        defer { fixture.host.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(fixture.host.isRunning)
        XCTAssertTrue(fixture.host.status.hasPrefix("Connection timed out"))
        XCTAssertEqual(fixture.signaling.connects.count, 1, "the rollback restores terminal timeout behavior")
    }

    func testBlackholedPhoneAttemptRetriesAndAuthenticatesTheNextHandshake() async throws {
        let suite = "TimeoutPhoneSuccess-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 2,
                                      retryBaseNanoseconds: 5_000_000, signaling: signaling,
                                      renewalScheduler: ManualScheduler(), defaults: defaults,
                                      handshakeTimeoutNanoseconds: 100_000_000)
        phone.allowLegacyPrivateRoute = true
        phone.restore(); phone.start()
        defer { phone.stop() }
        // No registration, challenge or close callback arrives on the first socket.
        let deadline = ContinuousClock.now + .seconds(2)
        while signaling.connects.count < 2, phone.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(signaling.connects.count, 2)
        XCTAssertTrue(phone.isRunning)
        XCTAssertEqual(phone.retryAttempt, 1, "the timeout consumes the existing budget")
        guard phone.isRunning else { return }

        signaling.deliver(RelayMessage(type: "registered", role: "client"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let mac = try Counterpart(invitation: pair.invitation, plays: "host")
        let request = try mac.open(try XCTUnwrap(signaling.sent.last)).request
        let session = try SecureRandom.token()
        signaling.deliver(try mac.seal("challenge", request: request, session: session))
        XCTAssertEqual(try mac.open(try XCTUnwrap(signaling.sent.last)).kind, "proof")
        signaling.deliver(try mac.seal("accepted", request: request, session: session, sequence: 1))
        let acceptedAck = try mac.open(try XCTUnwrap(signaling.sent.last))
        XCTAssertEqual(acceptedAck.kind, "acceptedAck")
        XCTAssertEqual(acceptedAck.request, request)
        XCTAssertEqual(acceptedAck.session, session)
        XCTAssertTrue(phone.isRunning)
        let mediaDeadline = ContinuousClock.now + .seconds(5) // Connect awaits the codec capability snapshot
        while phone.media == nil, ContinuousClock.now < mediaDeadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(phone.media, "attempt two reached media negotiation after authenticating")
    }

    func testBlackholedHostRegistrationRetriesWithoutSuspendingSharing() async throws {
        let suite = "TimeoutHostSuccess-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try HostFixture(handshakeTimeoutNanoseconds: 100_000_000, defaults: defaults)
        fixture.host.start()
        defer { fixture.host.stop() }
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.signaling.connects.count < 2, fixture.host.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(fixture.signaling.connects.count, 2)
        XCTAssertTrue(fixture.host.isRunning)
        XCTAssertTrue(HostActiveAccessPolicy.isRunning(status: fixture.host.status,
            hostRegistered: fixture.host.hostRegistered, connected: fixture.host.connected,
            awaitingApproval: fixture.host.awaitingApproval), "the host auto-start reconciliation must keep sharing active")
        guard fixture.host.isRunning else { return }
        fixture.signaling.deliver(RelayMessage(type: "registered", role: "host"))
        XCTAssertTrue(fixture.host.hostRegistered)
    }

    func testAPhoneIgnoresAStaleChallengeAndFinishesTheCurrentHandshake() async throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                      signaling: signaling, renewalScheduler: ManualScheduler())
        phone.allowLegacyPrivateRoute = true
        let mac = try Counterpart(invitation: pair.invitation, plays: "host")
        phone.restore()
        phone.start()
        signaling.deliver(RelayMessage(type: "registered", role: "client"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let request = try mac.open(try XCTUnwrap(signaling.sent.last)).request
        XCTAssertEqual(phone.status, "Authenticating your Mac…")

        signaling.deliver(try mac.seal("challenge", request: try SecureRandom.token(), session: try SecureRandom.token()))
        signaling.deliver(try mac.seal("media", request: try SecureRandom.token(), session: try SecureRandom.token(), sequence: 4, body: candidateBody))
        XCTAssertEqual(phone.staleMessagesIgnored, 2)
        XCTAssertTrue(phone.isRunning)
        XCTAssertEqual(phone.status, "Authenticating your Mac…")

        let sentBefore = signaling.sent.count
        signaling.deliver(try mac.seal("challenge", request: request, session: try SecureRandom.token()))
        XCTAssertEqual(signaling.sent.count, sentBefore + 1, "the phone answered the real challenge with its proof")
        XCTAssertEqual(try mac.open(try XCTUnwrap(signaling.sent.last)).kind, "proof")
    }

    func testAPhoneStillFailsClosedOnAnAuthenticatedMessageThatBreaksTheProtocol() async throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                      signaling: signaling, renewalScheduler: ManualScheduler())
        phone.allowLegacyPrivateRoute = true
        let mac = try Counterpart(invitation: pair.invitation, plays: "host")
        phone.restore()
        phone.start()
        signaling.deliver(RelayMessage(type: "registered", role: "client"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let request = try mac.open(try XCTUnwrap(signaling.sent.last)).request
        let session = try SecureRandom.token()
        signaling.deliver(try mac.seal("challenge", request: request, session: session))

        signaling.deliver(try mac.seal("media", request: request, session: session, sequence: 1))
        XCTAssertFalse(phone.isRunning)
        XCTAssertEqual(phone.status, "Secure connection failed. Reconnect or pair again on your Mac.")
    }
}
