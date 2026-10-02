import XCTest
import Foundation

/// A per-session failure on a sharing Mac (local proof timeout or invalidation) must end only that
/// phone's attempt. The Mac stays registered and Ready; only Stop Sharing or a fatal error stops it.
@MainActor
final class HostSessionFailureTests: XCTestCase {
    func testResetRejectsRetirementControlAndNestedReset() {
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), retryLimit: 0)
        phone.startInputFixtureForTesting(session: "retirement-fixture")
        var sent = 0
        var retirements = 0
        phone.inputPacketSenderForTesting = { _ in sent += 1; return true }
        phone.onPresentationInvalidated = {
            retirements += 1
            XCTAssertFalse(phone.sendControl(RemoteAction(action: "heartbeat", epoch: 1)))
            phone.stop()
        }
        phone.stop()
        XCTAssertEqual(retirements, 1)
        XCTAssertEqual(sent, 0, "Retired-session callbacks must not transmit")
        XCTAssertFalse(phone.connected)
    }

    @MainActor private final class LocalRouteBridge {
        let host = ScriptedSignaling()
        let phone = ScriptedSignaling()
        private var hostUp = false
        private var phoneUp = false
        private var peerAnnounced = false
        private let epoch = String(repeating: "e", count: 32)
        private var revision = 0

        init() {
            host.onConnect = { [weak self] connect in self?.registered(self?.host, role: "host", room: connect.invitation.room) }
            phone.onConnect = { [weak self] connect in self?.registered(self?.phone, role: "client", room: connect.invitation.room) }
            host.respond = { [weak self] message in
                guard message.type == "signal" else { return }
                Task { @MainActor in self?.phone.deliver(message) }
            }
            phone.respond = { [weak self] message in
                guard message.type == "signal" else { return }
                Task { @MainActor in self?.host.deliver(message) }
            }
        }

        private func decode(_ json: String) -> RelayMessage {
            try! JSONDecoder().decode(RelayMessage.self, from: Data(json.utf8))
        }

        private func registered(_ side: ScriptedSignaling?, role: String, room: String) {
            guard let side else { return }
            revision += 1
            let deadline = Int64((Date().timeIntervalSince1970 + 120) * 1000)
            side.deliver(decode(#"{"type":"registered","role":"\#(role)"}"#))
            side.deliver(decode(#"{"type":"route","version":1,"room":"\#(room)","epoch":"\#(epoch)","revision":\#(revision),"access":"local","expiresAt":\#(deadline)}"#))
            side.deliver(decode(#"{"type":"ice","servers":[]}"#))
            if side === host { hostUp = true } else { phoneUp = true }
            if hostUp && phoneUp && !peerAnnounced {
                peerAnnounced = true
                let online = decode(#"{"type":"peer","online":true}"#)
                host.deliver(online); phone.deliver(online)
            }
        }
    }

    private func waitFor(_ description: String, seconds: Double = 10, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw RemoteError.stale }
    }

    private func rig(proofTimeout: UInt64) -> (LocalRouteBridge, RemoteCoordinator, RemoteCoordinator) {
        let bridge = LocalRouteBridge()
        let host = RemoteCoordinator(isHost: true, store: MemoryPairStore(), retryLimit: 3,
                                     retryBaseNanoseconds: 10_000_000, retriesIndefinitely: true,
                                     registrationStableNanoseconds: 50_000_000, signaling: bridge.host,
                                     localProofTimeoutNanoseconds: proofTimeout)
        let phone = RemoteCoordinator(isHost: false, store: MemoryPairStore(), retryLimit: 0,
                                      signaling: bridge.phone, localProofTimeoutNanoseconds: proofTimeout)
        return (bridge, host, phone)
    }

    private func pairAndReachLocalProof(_ host: RemoteCoordinator, _ phone: RemoteCoordinator) async throws {
        let invitation = try host.createPair(server: "ws://127.0.0.1:9/signal", name: "Test Mac")
        host.start()
        try await waitFor("host registered") { host.hostRegistered }
        try phone.enroll(invitation.code())
        try await waitFor("approval pending") { host.awaitingApproval }
        host.approve()
    }

    func testHostLocalProofTimeoutEndsOnlyTheSession() async throws {
        let (bridge, host, phone) = rig(proofTimeout: 300_000_000)
        defer { withExtendedLifetime(bridge) {}; host.stop(); phone.stop() }
        try await pairAndReachLocalProof(host, phone)
        // On a machine without a single physical path the proof cannot start; that is also a
        // per-session failure and must behave the same way.
        try await waitFor("the local proof attempt ended") { host.lastSessionFailure != nil }
        XCTAssertTrue(["The devices could not verify a directly attached local link.",
                       "No directly attached Wi-Fi or Ethernet link is available."].contains(host.lastSessionFailure ?? ""))
        try await waitFor("host is registered and Ready again") {
            host.hostRegistered && !host.isStoppedForTesting && host.status == "Ready for your paired phone"
        }
        XCTAssertTrue(host.isRunning)
        XCTAssertFalse(host.connected)
    }

    func testHostPathChangeInvalidationEndsOnlyTheSession() async throws {
        let (bridge, host, phone) = rig(proofTimeout: 30_000_000_000)
        defer { withExtendedLifetime(bridge) {}; host.stop(); phone.stop() }
        try await pairAndReachLocalProof(host, phone)
        try await waitFor("local proof running or unavailable") {
            host.localLinkProofForTesting != nil || host.lastSessionFailure != nil
        }
        guard let proof = host.localLinkProofForTesting else {
            throw XCTSkip("No single directly attached IPv4 path on this machine: \(host.lastSessionFailure ?? "")")
        }
        proof.invalidateForTesting("test-path-change")
        try await waitFor("invalidation reached the coordinator") {
            host.lastSessionFailure == "The local network changed. Reconnect to verify the route again."
        }
        try await waitFor("host is registered and Ready again") {
            host.hostRegistered && !host.isStoppedForTesting && host.status == "Ready for your paired phone"
        }
        XCTAssertTrue(host.isRunning)
    }

    func testThePhoneStillFailsClosedOnItsOwnProofTimeout() async throws {
        let (bridge, host, phone) = rig(proofTimeout: 300_000_000)
        defer { withExtendedLifetime(bridge) {}; host.stop(); phone.stop() }
        try await pairAndReachLocalProof(host, phone)
        try await waitFor("phone attempt ended") { !phone.isRunning }
        XCTAssertNil(phone.lastSessionFailure)
    }
}


/// Authenticated control-channel close handshake. No sockets or physical display mutations.
@MainActor
final class DeliberateSessionEndTests: XCTestCase {
    private func phone() -> RemoteCoordinator {
        let coordinator = RemoteCoordinator(isHost: false, store: MemoryPairStore(), retryLimit: 2,
                                            signaling: ScriptedSignaling())
        coordinator.startInputFixtureForTesting(session: "deliberate-end")
        return coordinator
    }

    func testEndSendsOneSignalFreezesInputAndWaitsForAuthenticatedReceipt() throws {
        let phone = phone()
        defer { phone.stop() }
        var packets: [ControlPacket] = []
        phone.inputPacketSenderForTesting = { packets.append($0); return true }
        XCTAssertTrue(phone.sendControl(RemoteAction(action: "release", epoch: 7)))
        phone.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd])
        phone.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd])
        XCTAssertEqual(packets.map(\.action.action), ["release", "sessionEnd"])
        XCTAssertNil(packets.last?.input, "Ending a session is never a causal input grant")
        XCTAssertFalse(phone.sendControl(RemoteAction(action: "key", key: "a", epoch: 7)))
        XCTAssertFalse(phone.sendInputMoves([RemoteAction(action: "move", x: 1, epoch: 7)]))
        XCTAssertFalse(phone.isRunning, "No reconnect is permitted after deliberate End")
        XCTAssertTrue(phone.connected, "Keep only the transport alive for the receipt")
        XCTAssertThrowsError(try phone.receiveInputFixtureForTesting(
            ControlPacket(session: "another-session", sequence: 1, action: RemoteAction(action: "sessionEnd"))))
        XCTAssertTrue(phone.connected)
        try phone.receiveInputFixtureForTesting(ControlPacket(session: "deliberate-end", sequence: 1,
                                                              action: RemoteAction(action: "sessionEnd", epoch: 7)))
        XCTAssertFalse(phone.connected)
        XCTAssertFalse(phone.isRunning)
    }

    func testFailedSendAndRollbackCloseImmediatelyWithoutRetry() throws {
        let failed = phone()
        failed.inputPacketSenderForTesting = { _ in false }
        failed.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd])
        XCTAssertFalse(failed.connected)
        XCTAssertFalse(failed.isRunning)
        let suite = "DeliberateSessionEndTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DeliberateSessionEnd.disabledDefaultsKey)
        let rolledBack = phone()
        var sent = false
        rolledBack.inputPacketSenderForTesting = { _ in sent = true; return true }
        rolledBack.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd], defaults: defaults)
        XCTAssertFalse(sent)
        XCTAssertFalse(rolledBack.connected)
    }

    func testMissingReceiptClosesWithinTheBoundWithoutRetrying() async throws {
        let phone = phone()
        defer { phone.stop() }
        phone.inputPacketSenderForTesting = { _ in true }
        phone.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd])
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertFalse(phone.connected)
        XCTAssertFalse(phone.isRunning)
        XCTAssertEqual(phone.retryAttempt, 0)
    }

    func testTransportFailureDuringEndClosesWithoutRetry() {
        let phone = phone()
        defer { phone.stop() }
        phone.inputPacketSenderForTesting = { _ in true }
        phone.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd])
        phone.simulateTransportLossForTesting()
        XCTAssertFalse(phone.connected)
        XCTAssertFalse(phone.isRunning)
        XCTAssertEqual(phone.retryAttempt, 0)
    }

    func testLegacyHostGetsNoUnknownActionAndUnexpectedDropGetsNoEndSignal() {
        let legacy = phone()
        var packets: [ControlPacket] = []
        legacy.inputPacketSenderForTesting = { packets.append($0); return true }
        legacy.stopDeliberately(epoch: 7, hostFeatures: [])
        XCTAssertFalse(legacy.connected)
        XCTAssertTrue(packets.isEmpty)
        let dropped = phone()
        defer { dropped.stop() }
        dropped.inputPacketSenderForTesting = { packets.append($0); return true }
        dropped.simulateTransportLossForTesting()
        XCTAssertTrue(packets.isEmpty)
    }

    func testEndBeforeFirstGeometryUsesImmediateCloseWithoutSendingInvalidEpoch() {
        let phone = phone()
        var sent = false
        phone.inputPacketSenderForTesting = { _ in sent = true; return true }
        phone.stopDeliberately(epoch: 0, hostFeatures: [SessionFeature.deliberateEnd])
        XCTAssertFalse(sent)
        XCTAssertFalse(phone.connected)
    }

    func testResetCancelsOldCloseTimeoutBeforeAReplacementSession() async throws {
        let phone = phone()
        defer { phone.stop() }
        phone.inputPacketSenderForTesting = { _ in true }
        phone.stopDeliberately(epoch: 7, hostFeatures: [SessionFeature.deliberateEnd])
        phone.stop()
        phone.startInputFixtureForTesting(session: "replacement")
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertTrue(phone.connected)
        XCTAssertTrue(phone.isRunning)
    }
}
