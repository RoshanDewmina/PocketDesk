import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacReachabilityProbeTests: XCTestCase {
    private func probe(_ transport: FakeSignalingTransport, timeout: TimeInterval = 2) -> MacReachabilityProbe {
        MacReachabilityProbe(timeout: timeout, makeTransport: { transport })
    }

    func testAMacThatIsRegisteredAnswers() async throws {
        let transport = FakeSignalingTransport()
        transport.replies = [RelayMessage(type: "registered", role: "client"), RelayMessage(type: "ice")]
        let invitation = try TestPairing.invitation()
        let outcome = await probe(transport).check(invitation)
        XCTAssertEqual(outcome, .answering)
        XCTAssertEqual(transport.connects.count, 1)
        XCTAssertNil(transport.connects[0].hostToken, "It registers as the phone, never as a host")
        XCTAssertEqual(transport.connects[0].features, ["probe.1"],
                       "Only probe.1: the service answers and closes it without admitting a phone; no renewal, relay or route")
        XCTAssertEqual(transport.connects[0].invitation, invitation)
        XCTAssertTrue(transport.sent.isEmpty, "It says nothing beyond registering, so it can never start a session")
        XCTAssertEqual(transport.closeCount, 1, "It leaves as soon as it has its answer")
    }

    func testTheRegisterFrameCarriesTheProbeFeature() throws {
        let frame = SignalingClient.registerMessage(invitation: try TestPairing.invitation(), hostToken: nil,
                                                    features: MacReachabilityProbe.features, entitlement: nil)
        XCTAssertEqual(frame.role, "client")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        XCTAssertEqual(json["features"] as? [String], ["probe.1"],
                       "A featureless register is refused as upgrade_required on staging and production")
    }

    func testTheServiceSaysNoMacIsThere() async throws {
        let transport = FakeSignalingTransport()
        transport.replies = [RelayMessage(type: "error", code: "host_unavailable_or_unauthorized")]
        let outcome = await probe(transport).check(try TestPairing.invitation())
        XCTAssertEqual(outcome, .notAnswering)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testAnotherPhoneSessionIsReportedAsBusyNotAsAsleep() async throws {
        let transport = FakeSignalingTransport()
        transport.replies = [RelayMessage(type: "error", code: "already_connected")]
        let outcome = await probe(transport).check(try TestPairing.invitation())
        XCTAssertEqual(outcome, .sessionBusy)
    }

    func testOtherServiceErrorsMeanTheServiceCouldNotBeAsked() async throws {
        for code in ["relay_unavailable", "rate_limit", "invalid_registration", "authentication_timeout"] {
            let transport = FakeSignalingTransport()
            transport.replies = [RelayMessage(type: "error", code: code)]
            let outcome = await probe(transport).check(try TestPairing.invitation())
            XCTAssertEqual(outcome, .serviceUnreachable, code)
        }
    }

    func testSilenceEndsAsUnreachableAfterTheTimeout() async throws {
        let transport = FakeSignalingTransport()
        let started = Date()
        let outcome = await probe(transport, timeout: 0.15).check(try TestPairing.invitation())
        XCTAssertEqual(outcome, .serviceUnreachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testADroppedSocketAndAFailedConnectAreUnreachable() async throws {
        let dropped = FakeSignalingTransport()
        dropped.dropsAfterConnect = true
        let droppedOutcome = await probe(dropped).check(try TestPairing.invitation())
        XCTAssertEqual(droppedOutcome, .serviceUnreachable)

        let failing = FakeSignalingTransport()
        failing.connectError = RemoteError.invalidPairing
        let failedOutcome = await probe(failing).check(try TestPairing.invitation())
        XCTAssertEqual(failedOutcome, .serviceUnreachable)
    }

    func testOnlyTheFirstAnswerCounts() async throws {
        let transport = FakeSignalingTransport()
        transport.replies = [RelayMessage(type: "registered", role: "client"),
                             RelayMessage(type: "error", code: "host_unavailable_or_unauthorized")]
        let outcome = await probe(transport).check(try TestPairing.invitation())
        XCTAssertEqual(outcome, .answering)
    }
}
