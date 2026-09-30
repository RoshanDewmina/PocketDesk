import XCTest
@testable import PocketDeskRemote

@MainActor
final class CouchPhoneModelTests: XCTestCase {
    private let couchFeatures = SessionFeature.host + [SessionFeature.couch]

    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func connected(mode: SessionMode) -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: mode)
        model.connection.connected = true
        return model
    }

    private func status(_ healthy: Bool, epoch: UInt64 = 2, mode: String?, reason: String? = nil,
                        features: [String]) -> RemoteAction {
        RemoteAction(action: "capture", x: healthy ? 1 : 0, epoch: epoch,
                     interaction: healthy ? NativeInteraction(token: "t", doubleClickInterval: 0.5) : nil,
                     features: features, mode: mode, modeReason: reason)
    }

    private func liveCouch() throws -> PhoneRemoteModel {
        let model = connected(mode: .couch)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), to: model)
        try deliver(status(true, mode: "couch", features: couchFeatures), to: model)
        return model
    }

    func testCouchControlsWithoutAPicture() throws {
        let model = try liveCouch()
        XCTAssertEqual(model.sessionMode, .couch)
        XCTAssertFalse(model.fresh)
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(model.connection.sessionModeRequest, .couch)
    }

    func testThePictureSessionStillNeedsAFreshFrame() throws {
        let model = connected(mode: .picture)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), to: model)
        try deliver(status(true, mode: "picture", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertFalse(model.canControl, "no frame yet")
        model.frameReceived()
        XCTAssertTrue(model.canControl)
    }

    func testAnOlderMacKeepsThePictureAndSaysSo() throws {
        let model = connected(mode: .couch)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: model)
        try deliver(status(true, mode: nil, features: SessionFeature.host), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertEqual(model.sessionNotice, CouchCopy.updateMac)
        XCTAssertEqual(model.connection.sessionModeRequest, .picture, "a reconnect asks for what is on screen")
        XCTAssertFalse(model.canControl, "still needs a picture frame")
    }

    func testARefusalEndsTheAttemptAndSaysWhy() throws {
        let model = connected(mode: .couch)
        model.connection.status = "Connected"
        try deliver(status(false, mode: SessionModeStatus.refused, reason: "controlOff", features: couchFeatures), to: model)
        XCTAssertEqual(model.couchRefusal, .controlOff)
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.sessionEndReason, .error)
        XCTAssertEqual(model.connection.status, "Disconnected", "the refusal stopped the coordinator")
        XCTAssertFalse(model.connection.connected)
        XCTAssertFalse(model.connection.isRunning)
        model.clearCouchRefusal()
        XCTAssertNil(model.couchRefusal)
    }

    func testAnUnhealthyCouchStatusStopsControl() throws {
        let model = try liveCouch()
        try deliver(status(false, mode: "couch", features: couchFeatures), to: model)
        XCTAssertFalse(model.canControl)
    }

    func testAStaleCouchStatusStopsControl() throws {
        let model = try liveCouch()
        model.ageCouchStatusForTesting(by: 1.01)
        XCTAssertFalse(model.canControl, "no Mac status for over 1 s in Couch mode")
    }

    func testAPictureStatusInsideACouchSessionSwitchesBack() throws {
        let model = try liveCouch()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3), to: model)
        try deliver(status(true, epoch: 3, mode: "picture", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertFalse(model.canControl, "the picture path needs its first frame again")
        XCTAssertEqual(model.connection.sessionModeRequest, .picture)
    }

    func testAModeReasonIsShownOnceAsANotice() throws {
        let model = try liveCouch()
        try deliver(status(true, mode: "couch", reason: "screenRecording", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .couch, "Couch continues when the picture is refused")
        XCTAssertEqual(model.sessionNotice, CouchCopy.needsScreenRecording)
    }

    func testModeRequestsNeedACouchCapableConnectedMac() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.requestMode(.couch))
        XCTAssertNil(model.pendingModeSwitch)
        XCTAssertFalse(model.couchSwitchAvailable)
    }
}
