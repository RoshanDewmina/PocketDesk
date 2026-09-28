import XCTest

final class NativeProtocolTests: XCTestCase {
    func testTextFocusUsesOptionalFieldsAndRejectsUnboundResults() throws {
        let probe = String(repeating: "a", count: 32)
        let request = RemoteAction(action: "click", epoch: 9,
            interaction: NativeInteraction(token: "fresh", clickCount: 1), textFocusProbe: probe)
        XCTAssertNoThrow(try request.validate())
        let reply = RemoteAction(action: "heartbeat", epoch: 9,
            textFocusProbe: probe, textFocusEditable: true)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.textFocusProbe, probe)
        XCTAssertEqual(decoded.textFocusEditable, true)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusEditable: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", textFocusProbe: probe).validate())
        XCTAssertThrowsError(try RemoteAction(action: "right", textFocusProbe: probe).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusProbe: "not-a-probe").validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", interaction: request.interaction,
            textFocusProbe: probe, textFocusEditable: true).validate())
    }

    func testQualityRequestIsOptionalAndBoundToCapabilityMessages() throws {
        let request = RemoteAction(action: "heartbeat", streamQuality: .sharp)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.streamQuality, .sharp)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", streamQuality: .balanced).validate())
        XCTAssertThrowsError(try RemoteAction(action: "move", streamQuality: .sharp).validate())
    }

    func testLegacyActionDecodesWithoutCapabilityEnvelope() throws {
        let data = Data(#"{"action":"click","x":0,"y":0,"text":"","key":"","modifiers":[],"epoch":1}"#.utf8)
        let action = try JSONDecoder().decode(RemoteAction.self, from: data)
        XCTAssertNil(action.interaction)
        XCTAssertNoThrow(try action.validate())
    }

    func testNativeEnvelopeRoundTripsAndRejectsMalformedFields() throws {
        let original = RemoteAction(action: "holdRenew", epoch: 9,
            interaction: NativeInteraction(token: "fresh", hold: "hold", clickCount: 2))
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.interaction, original.interaction)
        XCTAssertNoThrow(try decoded.validate())
        for invalid in [NativeInteraction(version: 2), NativeInteraction(token: ""),
                        NativeInteraction(hold: String(repeating: "a", count: 65)),
                        NativeInteraction(clickCount: 0), NativeInteraction(phase: "mystery"),
                        NativeInteraction(doubleClickInterval: .nan)] {
            XCTAssertThrowsError(try RemoteAction(action: "click", interaction: invalid).validate())
        }
    }
}
