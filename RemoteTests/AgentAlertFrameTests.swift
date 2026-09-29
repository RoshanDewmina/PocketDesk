import XCTest

/// The alert as it crosses the control channel: a request id, an agent kind and an event name from short
/// fixed vocabularies, and a time. Nothing an agent says.
final class AgentAlertFrameTests: XCTestCase {
    private let raised = Date(timeIntervalSince1970: 1_790_000_000)

    private func frame(id: String = "h_0a1b2c3d4e5f", kind: AgentKind = .claudeCode) -> AgentAlertFrame {
        AgentAlertFrame(id: id, kind: kind, event: .needsUser, raisedAt: raised)
    }

    func testACaptureStatusCarriesAnAlertThroughEncodingAndValidation() throws {
        let sent = RemoteAction(action: "capture", x: 1, epoch: 4, agentAlert: frame())
        try sent.validate()
        let received = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(sent))
        try received.validate()
        XCTAssertEqual(received.agentAlert, frame())
        XCTAssertEqual(received.agentAlert?.agentKind, .claudeCode)
        XCTAssertEqual(received.agentAlert?.alertEvent, .needsUser)
        XCTAssertEqual(received.agentAlert?.raisedDate, raised)
        XCTAssertEqual(received.agentAlert?.isUnderstood, true)
    }

    func testAStatusWithoutAnAlertIsUnchanged() throws {
        let plain = RemoteAction(action: "capture", x: 1, epoch: 4)
        try plain.validate()
        XCTAssertNil(plain.agentAlert)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(json.contains("agentAlert"), "An old phone sees exactly the message it always saw")
    }

    func testAnAlertRidesOnlyOnACaptureStatus() {
        for action in ["move", "click", "heartbeat", "viewing", "geometry", "textResult", "holdRenew", "curtain", "pause"] {
            XCTAssertThrowsError(try RemoteAction(action: action, agentAlert: frame()).validate(), action)
        }
    }

    func testTheFrameHoldsFiveShortFieldsAndNothingElse() throws {
        let data = try JSONEncoder().encode(frame())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "id", "kind", "event", "raisedAt"])
        XCTAssertLessThan(data.count, 160, "It rides on a status message that goes out every few seconds")
    }

    /// A frame as a newer or different Mac would have written it, sent inside a status the phone decodes.
    private func received(_ frameJSON: String) throws -> RemoteAction {
        let frame = try JSONDecoder().decode(AgentAlertFrame.self, from: Data(frameJSON.utf8))
        let sent = try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 1, agentAlert: frame))
        return try JSONDecoder().decode(RemoteAction.self, from: sent)
    }

    func testAnUnfamiliarKindIsWellFormedAndShownAsAnAgent() throws {
        let action = try received(#"{"version":1,"id":"h_ab12","kind":"aider","event":"needs_user","raisedAt":1790000000}"#)
        try action.validate()
        XCTAssertEqual(action.agentAlert?.agentKind, .other, "Never echoed: the name comes from the fixed list")
        XCTAssertEqual(action.agentAlert?.isUnderstood, true)
    }

    func testAnEventOrVersionTheMacKnowsAndThisPhoneDoesNotIsIgnoredNotFatal() throws {
        let newEvent = #"{"version":1,"id":"h_ab12","kind":"codex","event":"finished","raisedAt":1790000000}"#
        let newVersion = #"{"version":2,"id":"h_ab12","kind":"codex","event":"needs_user","raisedAt":1790000000}"#
        for json in [newEvent, newVersion] {
            let action = try received(json)
            try action.validate()
            XCTAssertEqual(action.agentAlert?.isUnderstood, false, "A newer Mac must not be able to end an older phone's session")
        }
    }

    func testAMalformedFrameIsRefused() {
        let cases: [(String, (inout AgentAlertFrame) -> Void)] = [
            ("empty id", { $0.id = "" }),
            ("space in the id", { $0.id = "h 0a1b" }),
            ("newline in the id", { $0.id = "h_0a1b\n" }),
            ("punctuation in the id", { $0.id = "h_0a1b;drop" }),
            ("long id", { $0.id = String(repeating: "a", count: 65) }),
            ("kind with a space", { $0.kind = "claude code" }),
            ("long kind", { $0.kind = String(repeating: "k", count: 25) }),
            ("empty event", { $0.event = "" }),
            ("event with a symbol", { $0.event = "needs-user" }),
            ("version zero", { $0.version = 0 }),
            ("version seventeen", { $0.version = 17 }),
            ("negative time", { $0.raisedAt = -1 }),
            ("a time past the year 2100", { $0.raisedAt = 4_102_444_801 })
        ]
        for (name, change) in cases {
            var bad = frame()
            change(&bad)
            XCTAssertThrowsError(try RemoteAction(action: "capture", agentAlert: bad).validate(), name)
        }
    }

    func testTheHostsAlertMakesAFrameAndTheIdIsShortAndUnguessable() {
        let alert = AgentAlert(id: AgentAlert.makeID(), kind: .cursor, event: .needsUser, sessionHash: "0123456789ab", raisedAt: raised)
        XCTAssertEqual(alert.frame.kind, "cursor")
        XCTAssertEqual(alert.frame.id, alert.id)
        XCTAssertEqual(alert.frame.raisedAt, 1_790_000_000)
        XCTAssertNoThrow(try alert.frame.validate())

        let ids = (0..<200).map { _ in AgentAlert.makeID() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue(id.hasPrefix("h_"))
            XCTAssertEqual(id.count, 14)
            XCTAssertTrue(id.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) })
        }
    }

    func testOnlyAShortLowercaseHexHashCountsAsASessionHash() {
        XCTAssertTrue(AgentAlert.isSessionHash("0123456789ab"))
        XCTAssertTrue(AgentAlert.isSessionHash("01234567"))
        XCTAssertFalse(AgentAlert.isSessionHash("0123456"))
        XCTAssertFalse(AgentAlert.isSessionHash("0123456789abcdef0"))
        XCTAssertFalse(AgentAlert.isSessionHash("0123456789AB"))
        XCTAssertFalse(AgentAlert.isSessionHash("0123456789ag"))
        XCTAssertFalse(AgentAlert.isSessionHash("sess-123"))
    }
}
