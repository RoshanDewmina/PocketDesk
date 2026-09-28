import XCTest

final class NativeProtocolTests: XCTestCase {
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
