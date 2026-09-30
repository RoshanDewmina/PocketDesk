import XCTest
import Foundation

@MainActor
final class MacShareBlockerTests: XCTestCase {
    private let server = "ws://127.0.0.1:9/signal"

    private struct Sealer {
        let cipher: SignalCipher
        let role: String

        func seal(_ kind: String, request: String, session: String = "", sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
            RelayMessage(type: "signal", payload: try cipher.seal(
                ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: role))
        }

        func open(_ message: RelayMessage) throws -> ProtectedMessage {
            try cipher.open(try XCTUnwrap(message.payload), sender: role == "client" ? "host" : "client")
        }
    }

    private func pairedHost(blocker: MacShareBlocker?) throws -> (RemoteCoordinator, ScriptedSignaling, Sealer) {
        let pair = try HostPair.create(server: server, name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        let signaling = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                     registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                     renewalScheduler: ManualScheduler())
        host.allowLegacyPrivateRoute = true
        host.shareBlocker = { blocker }
        host.restore()
        host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        let phone = Sealer(cipher: try SignalCipher(key: pair.invitation.key, room: pair.invitation.room), role: "client")
        return (host, signaling, phone)
    }

    /// Plays a phone through request, challenge and proof; returns what the Mac sent after the proof.
    private func handshake(_ signaling: ScriptedSignaling, phone: Sealer, features: [String]?) throws -> [ProtectedMessage] {
        let request = try SecureRandom.token()
        let body = try features.map { try JSONEncoder().encode(MacShareBlocker.Handshake(features: $0)) }
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(try phone.seal("request", request: request, body: body))
        let challenge = try phone.open(try XCTUnwrap(signaling.sent.last))
        let before = signaling.sent.count
        signaling.deliver(try phone.seal("proof", request: request, session: challenge.session))
        return try signaling.sent.dropFirst(before).filter { $0.type == "signal" }.map(phone.open)
    }

    func testAMacWithoutScreenRecordingTellsAPhoneThatAsksAndKeepsListening() throws {
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingOff)
        let replies = try handshake(signaling, phone: phone, features: [MacShareBlocker.feature])
        XCTAssertEqual(replies.map(\.kind), [MacShareBlocker.refusalKind])
        let refusal = try JSONDecoder().decode(MacShareBlocker.Refusal.self, from: try XCTUnwrap(replies.first?.body))
        XCTAssertEqual(refusal.reason, .screenRecordingOff)
        XCTAssertFalse(host.connected)
        XCTAssertTrue(host.hostRegistered, "The Mac stays reachable so the next attempt hears the reason too")
        XCTAssertEqual(host.status, "Ready for your paired phone")
        XCTAssertNil(host.media, "Nothing is streamed")
    }

    func testAnOlderPhoneIsNeitherToldNorAccepted() throws {
        let (host, signaling, phone) = try pairedHost(blocker: .screenRecordingOff)
        let replies = try handshake(signaling, phone: phone, features: nil)
        XCTAssertTrue(replies.isEmpty, "An older phone never receives a message kind it cannot read")
        XCTAssertTrue(host.hostRegistered)
        XCTAssertNil(host.media)
    }

    func testWithoutABlockerTheSessionIsAcceptedAsBefore() throws {
        let (host, signaling, phone) = try pairedHost(blocker: nil)
        let replies = try handshake(signaling, phone: phone, features: [MacShareBlocker.feature])
        XCTAssertEqual(replies.map(\.kind), ["accepted"])
        XCTAssertEqual(host.status, "Connecting live desktop…")
    }

    func testThePhoneAsksAndStopsWithTheMacsReason() async throws {
        let pair = try HostPair.create(server: server, name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair.invitation)
        let signaling = ScriptedSignaling()
        let phone = RemoteCoordinator(isHost: false, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                      signaling: signaling, renewalScheduler: ManualScheduler())
        phone.allowLegacyPrivateRoute = true
        phone.restore()
        phone.start()
        signaling.deliver(RelayMessage(type: "registered", role: "client"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))
        signaling.deliver(RelayMessage(type: "peer", online: true))
        let mac = Sealer(cipher: try SignalCipher(key: pair.invitation.key, room: pair.invitation.room), role: "host")
        let request = try mac.open(try XCTUnwrap(signaling.sent.last))
        XCTAssertEqual(request.kind, "request")
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: request.body).contains(MacShareBlocker.feature))

        let session = try SecureRandom.token()
        signaling.deliver(try mac.seal("challenge", request: request.request, session: session))
        XCTAssertEqual(try mac.open(try XCTUnwrap(signaling.sent.last)).kind, "proof")
        let body = try JSONEncoder().encode(MacShareBlocker.Refusal(reason: .screenRecordingOff))
        signaling.deliver(try mac.seal(MacShareBlocker.refusalKind, request: request.request, session: session,
                                       sequence: 1, body: body))
        XCTAssertEqual(phone.macBlocker, .screenRecordingOff)
        XCTAssertEqual(phone.status, "Mac unavailable: screenRecordingOff")
        XCTAssertFalse(phone.isRunning, "A missing grant is not retried by itself")
    }

    func testHandshakeFeaturesAreBounded() throws {
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: nil), [])
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: Data("not json".utf8)), [])
        let many = try JSONEncoder().encode(MacShareBlocker.Handshake(features: (0..<9).map { "f\($0)" }))
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: many), [])
        let odd = try JSONEncoder().encode(MacShareBlocker.Handshake(features: ["", String(repeating: "a", count: 33), "blocker.1"]))
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: odd), ["blocker.1"])
    }

    func testTheMacsOwnPresenceWinsAndAccessibilityIsToldOnlyToPhonesThatAsk() {
        XCTAssertEqual(MacShareBlocker.sessionState(presence: .displayAsleep, phoneUnderstands: true,
                                                    controlAllowed: true, accessibilityGranted: false), "displayAsleep")
        XCTAssertEqual(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true,
                                                    controlAllowed: true, accessibilityGranted: false), "accessibilityOff")
        XCTAssertNil(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: false,
                                                  controlAllowed: true, accessibilityGranted: false))
        XCTAssertNil(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true,
                                                  controlAllowed: false, accessibilityGranted: false),
                     "Control turned off on purpose is not a missing grant")
        XCTAssertNil(MacShareBlocker.sessionState(presence: nil, phoneUnderstands: true,
                                                  controlAllowed: true, accessibilityGranted: true))
        XCTAssertTrue(ClipboardFrame.isWellFormedStatus(MacShareBlocker.screenRecordingOff.rawValue))
        XCTAssertTrue(ClipboardFrame.isWellFormedStatus(MacShareBlocker.accessibilityOff.rawValue))
    }

    func testTheMacListensWithoutSharingOnlyWhenScreenRecordingIsTheOnlyThingMissing() {
        func listen(wants: Bool = true, suppressed: Bool = false, active: Bool = false, listening: Bool = false,
                    other: Bool = false, screen: Bool = false, paired: Bool = true, service: Bool = true) -> Bool {
            MacShareBlocker.shouldListenWithoutSharing(wantsSharing: wants, suppressed: suppressed, sharingActive: active,
                                                       listening: listening, otherAccessRunning: other,
                                                       screenRecordingGranted: screen, hasPairedPhone: paired,
                                                       serviceConfigured: service)
        }
        XCTAssertTrue(listen())
        XCTAssertFalse(listen(screen: true), "With the grant, sharing starts normally instead")
        XCTAssertFalse(listen(wants: false), "Stop Sharing means not reachable at all")
        XCTAssertFalse(listen(suppressed: true))
        XCTAssertFalse(listen(active: true))
        XCTAssertFalse(listen(listening: true))
        XCTAssertFalse(listen(other: true))
        XCTAssertFalse(listen(paired: false))
        XCTAssertFalse(listen(service: false))
    }
}
