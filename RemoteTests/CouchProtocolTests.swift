import XCTest

final class CouchProtocolTests: XCTestCase {
    func testPictureSendsNoAcceptedAckBodySoOlderMacsSeeNothingNew() throws {
        XCTAssertNil(SessionModeRequest.body(for: .picture))
        let body = try XCTUnwrap(SessionModeRequest.body(for: .couch))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"mode":"couch"}"#)
    }

    func testTheMacReadsTheRequestLenientlyAndDefaultsToPicture() {
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: nil), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: SessionModeRequest.body(for: .couch)), .couch)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data(#"{"mode":"picture"}"#.utf8)), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data(#"{"mode":"hologram"}"#.utf8)), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data("not json".utf8)), .picture)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: Data(#"{"mode":"couch","later":1}"#.utf8)), .couch)
        let padded = Data((#"{"mode":"couch","pad":""# + String(repeating: "x", count: 300) + #""}"#).utf8)
        XCTAssertEqual(SessionModeRequest.mode(fromAcceptedAckBody: padded), .picture, "bodies over 256 bytes are ignored")
    }

    func testModeRequestValidatesOnlyAsABareActionWithAKnownMode() {
        XCTAssertNoThrow(try RemoteAction(action: "mode", epoch: 3, mode: "couch").validate())
        XCTAssertNoThrow(try RemoteAction(action: "mode", epoch: 3, mode: "picture").validate())
        let invalid: [RemoteAction] = [
            RemoteAction(action: "mode", epoch: 3),
            RemoteAction(action: "mode", epoch: 3, mode: "hologram"),
            RemoteAction(action: "mode", x: 1, epoch: 3, mode: "couch"),
            RemoteAction(action: "mode", key: "a", epoch: 3, mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, interaction: NativeInteraction(token: "t"), mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, features: [SessionFeature.couch], mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, display: 7, mode: "couch"),
            RemoteAction(action: "mode", epoch: 3, mode: "couch", modeReason: "notLocal"),
            RemoteAction(action: "click", epoch: 3, mode: "couch"),
            RemoteAction(action: "heartbeat", epoch: 3, mode: "couch"),
            RemoteAction(action: "pause", epoch: 3, mode: "couch"),
            RemoteAction(action: "capture", x: 1, epoch: 3, modeReason: "notLocal"),
            RemoteAction(action: "capture", x: 1, epoch: 3, mode: "not a word!"),
            RemoteAction(action: "capture", x: 1, epoch: 3, mode: "couch", modeReason: String(repeating: "a", count: 40))
        ]
        for action in invalid {
            XCTAssertThrowsError(try action.validate(), "\(action.action) \(action.mode ?? "nil") \(action.modeReason ?? "nil")")
        }
    }

    func testCaptureStatusCarriesModeAndAWellFormedReason() throws {
        let status = RemoteAction(action: "capture", x: 0, epoch: 4, features: [SessionFeature.couch],
                                  mode: SessionModeStatus.refused, modeReason: SessionModeRefusal.notLocal.rawValue)
        XCTAssertNoThrow(try status.validate())
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.mode, "refused")
        XCTAssertEqual(decoded.modeReason, "notLocal")
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 4, mode: "couch").validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", x: 1, epoch: 4, mode: "somethingNewer",
                                          modeReason: "futureReason").validate(),
                         "A newer Mac's words must not end an older phone's session")
    }

    func testCouchFeatureIsAdvertisableButNotInTheStaticList() {
        XCTAssertEqual(SessionFeature.couch, "couch.1")
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.couch))
        XCTAssertNoThrow(try RemoteAction(action: "capture", features: SessionFeature.host + [SessionFeature.couch]).validate())
    }

    func testRefusalCopyMatchesTheApprovedWording() {
        XCTAssertEqual(CouchCopy.refusal(.notLocal), CouchCopy.notLocal)
        XCTAssertEqual(CouchCopy.refusal(.controlOff), CouchCopy.controlOff)
        XCTAssertEqual(CouchCopy.refusal(.screenRecording), CouchCopy.needsScreenRecording)
        XCTAssertEqual(CouchCopy.notLocal, "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac’s network and try again.")
    }
}
