import XCTest
import Foundation

/// D38/D39: every connect stage follows a real state, nothing is guessed, and the phone name a Mac
/// shows comes only from the sealed pairing exchange.
final class ConnectMotionTests: XCTestCase {
    func testStagesComeFromTheCoordinatorsProgress() {
        XCTAssertEqual(ConnectStage(progress: 0), .idle)
        XCTAssertEqual(ConnectStage(progress: 1), .reaching)
        XCTAssertEqual(ConnectStage(progress: 2), .found)
        XCTAssertEqual(ConnectStage(progress: 3), .opening)
        XCTAssertEqual(ConnectStage(progress: 9), .opening)
        XCTAssertEqual(ConnectStage(progress: -1), .idle)
    }

    func testTheLockStepsOnlyOnRealEvents() {
        XCTAssertEqual(ResolutionLockStage(connected: false, videoTrack: false, pictureReady: false), .waiting)
        XCTAssertEqual(ResolutionLockStage(connected: true, videoTrack: false, pictureReady: false), .connected)
        XCTAssertEqual(ResolutionLockStage(connected: true, videoTrack: true, pictureReady: false), .videoTrack)
        XCTAssertEqual(ResolutionLockStage(connected: true, videoTrack: true, pictureReady: true), .picture)
        XCTAssertEqual(ResolutionLockStage(connected: false, videoTrack: false, pictureReady: true), .picture,
                       "A frame on screen is crisp whatever else is late")
    }

    func testAQuickConnectNeverShowsAWaitingRing() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(SearchRings.started(from: start, now: start.addingTimeInterval(0.39)), 0)
        XCTAssertEqual(SearchRings.started(from: start, now: start.addingTimeInterval(0.4)), 1)
        XCTAssertEqual(SearchRings.started(from: start, now: start.addingTimeInterval(2.01)), 2)
        let dates = SearchRings.dates(from: start)
        XCTAssertEqual(dates.count, SearchRings.count)
        XCTAssertEqual(try XCTUnwrap(dates.first).timeIntervalSince(start), 0.4, accuracy: 1e-6)
        XCTAssertTrue(dates.allSatisfy { $0.timeIntervalSince(start) >= SearchRings.delay - 1e-6 })
    }

    func testTheRouteCaptionShowsOnlyMeasuredParts() {
        let measured = SessionRouteCaption.parse("Direct · video/H264 · 60 fps · 14 ms network RTT · VideoToolbox")
        XCTAssertEqual(measured.text, "Direct · 14 ms")
        XCTAssertEqual(SessionRouteCaption.parse("Relay · codec pending · fps pending · 48 ms network RTT · x").text, "Relayed · 48 ms")
        XCTAssertNil(SessionRouteCaption.parse("Direct · codec pending · fps pending · RTT pending · x").text)
        XCTAssertNil(SessionRouteCaption.parse("Route pending · codec pending · fps pending · 9 ms network RTT · x").text)
        XCTAssertNil(SessionRouteCaption.parse("Route not measured").text)
        XCTAssertEqual(SessionRouteCaption.parse("Direct · v · 60 fps · 0 ms network RTT · x").text, "Direct · <1 ms")
    }

    func testAPhoneNameIsOneLineOfPrintableTextAndNeverTooLong() {
        XCTAssertEqual(PhoneIdentity.sanitized("Roshan’s iPhone"), "Roshan’s iPhone")
        XCTAssertEqual(PhoneIdentity.sanitized("  Roshan\n\tiPhone  "), "Roshan iPhone")
        XCTAssertEqual(PhoneIdentity.sanitized("evil\u{202E}enohP"), "evil enohP", "No bidi overrides")
        XCTAssertEqual(PhoneIdentity.sanitized("zero\u{200B}width"), "zero width")
        XCTAssertNil(PhoneIdentity.sanitized(" \n\u{0007} "))
        XCTAssertEqual(PhoneIdentity.sanitized(String(repeating: "a", count: 200))?.count, PhoneIdentity.maximumLength)
    }

    func testThePhoneNameBodyRoundTripsAndRejectsJunk() throws {
        let body = try XCTUnwrap(PhoneIdentity.body(for: "Roshan’s iPhone"))
        XCTAssertEqual(PhoneIdentity.decode(body), "Roshan’s iPhone")
        XCTAssertNil(PhoneIdentity.body(for: nil))
        XCTAssertNil(PhoneIdentity.body(for: "\n"))
        XCTAssertNil(PhoneIdentity.decode(nil))
        XCTAssertNil(PhoneIdentity.decode(Data("not json".utf8)))
        XCTAssertNil(PhoneIdentity.decode(Data(String(repeating: "x", count: 2_000).utf8)))
        let sneaky = try JSONEncoder().encode(PhoneIdentity(name: "Mac\u{202E}lppA"))
        XCTAssertEqual(PhoneIdentity.decode(sneaky), "Mac lppA")
    }

    func testTheMacShowsAGenericModelAsYourDevice() {
        XCTAssertEqual(PhoneDisplayName.display(nil), "Your iPhone")
        XCTAssertEqual(PhoneDisplayName.display("iPhone"), "Your iPhone")
        XCTAssertEqual(PhoneDisplayName.display("iPad"), "Your iPad")
        XCTAssertEqual(PhoneDisplayName.display("Roshan’s iPhone"), "Roshan’s iPhone")
        XCTAssertEqual(PhoneDisplayName.display("\n"), "Your iPhone")
        XCTAssertEqual(PhoneDisplayName.inSentence("Your iPhone"), "your iPhone")
        XCTAssertEqual(PhoneDisplayName.inSentence("Roshan’s iPhone"), "Roshan’s iPhone")
    }

    func testAnOlderPairWithoutANameStillDecodes() throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pair)) as? [String: Any])
        json.removeValue(forKey: "phoneName")
        let old = try JSONDecoder().decode(HostPair.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.phoneName)
        XCTAssertTrue(old.paired)
    }
}

/// The phone name travels inside the sealed `acceptedAck`: the Mac keeps it, and a message without
/// one keeps what was stored.
@MainActor
final class PhoneNameExchangeTests: XCTestCase {
    private func seal(_ cipher: SignalCipher, _ kind: String, request: String, session: String = "",
                      sequence: UInt64 = 0, body: Data? = nil) throws -> RelayMessage {
        RelayMessage(type: "signal", payload: try cipher.seal(
            ProtectedMessage(kind: kind, request: request, session: session, sequence: sequence, body: body), sender: "client"))
    }

    func testTheMacStoresTheNameAPairedPhoneSendsAfterAcceptance() async throws {
        let pair = try HostPair.create(server: "ws://127.0.0.1:9/signal", name: "Test Mac").rotated()
        let store = MemoryPairStore()
        try store.save(pair)
        let signaling = ScriptedSignaling()
        let host = RemoteCoordinator(isHost: true, store: store, retryLimit: 2, retryBaseNanoseconds: 10_000_000,
                                     registrationStableNanoseconds: 50_000_000, signaling: signaling,
                                     renewalScheduler: ManualScheduler(), handshakeTimeoutNanoseconds: 20_000_000_000)
        host.allowLegacyPrivateRoute = true
        host.restore()
        XCTAssertNil(host.peerName, "An older pair has no name")
        host.start()
        signaling.deliver(RelayMessage(type: "registered", role: "host"))
        signaling.deliver(RelayMessage(type: "ice", servers: []))

        let cipher = try SignalCipher(key: pair.invitation.key, room: pair.invitation.room)
        let request = try SecureRandom.token()
        signaling.deliver(RelayMessage(type: "peer", online: true))
        signaling.deliver(try seal(cipher, "request", request: request))
        let challenge = try cipher.open(try XCTUnwrap(signaling.sent.last?.payload), sender: "host")
        signaling.deliver(try seal(cipher, "proof", request: request, session: challenge.session))
        XCTAssertEqual(host.status, "Connecting live desktop…")

        signaling.deliver(try seal(cipher, "acceptedAck", request: request, session: challenge.session, sequence: 1,
                                   body: PhoneIdentity.body(for: "Roshan’s iPhone")))
        XCTAssertEqual(host.peerName, "Roshan’s iPhone")
        XCTAssertEqual(try store.read(HostPair.self)?.phoneName, "Roshan’s iPhone", "Kept with the pairing")
        host.stop()

        let reloaded = RemoteCoordinator(isHost: true, store: store, signaling: ScriptedSignaling())
        reloaded.restore()
        XCTAssertEqual(reloaded.peerName, "Roshan’s iPhone")
    }
}
