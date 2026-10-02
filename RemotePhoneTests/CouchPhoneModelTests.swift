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

    func testFullDisconnectOffersUnchangedPhoneClipboardToTheNextMac() throws {
        let model = try liveCouch()
        model.sceneChanged(.active)
        var count = 10
        model.clipboard.pasteboardMetadata = { (count, true) }
        model.clipboard.writeToPasteboard = { _ in count += 1 }
        var frame = try ClipboardChunker.frames(for: ClipboardPayload(text: "Mac A copy"), operation: "data", transfer: "macasyncedcopy001")[0]
        frame.automatic = true
        model.clipboard.receive(frame)
        model.clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(model.clipboard.showsPasteChip)
        model.clipboard.cancel()
        model.clipboard.stopPasteboardMonitoring()
        model.clipboard.refreshPasteChip(available: true)
        XCTAssertFalse(model.clipboard.showsPasteChip, "Held-session resume must still suppress the Mac's own copy")
        model.disconnect()
        model.clipboard.refreshPasteChip(available: true)
        XCTAssertTrue(model.clipboard.showsPasteChip, "The next Mac has not received this unchanged phone clipboard")
        model.clipboard.stopPasteboardMonitoring()
    }

    func testCouchClipboardNeedsCurrentOwnerControl() throws {
        let model = try liveCouch()
        model.sceneChanged(.active)
        XCTAssertTrue(model.clipboardAvailable)
        model.ageCouchStatusForTesting(by: 1.01)
        XCTAssertFalse(model.clipboardAvailable, "A stale Couch heartbeat must also stop clipboard effects")
        try deliver(status(true, mode: "couch", features: couchFeatures), to: model)
        XCTAssertTrue(model.clipboardAvailable)
        try deliver(status(false, mode: "couch", features: couchFeatures), to: model)
        XCTAssertFalse(model.clipboardAvailable)
        try deliver(status(true, mode: "couch", features: couchFeatures), to: model)
        try deliver(RemoteAction(action: "viewing", x: 0, epoch: 2), to: model)
        XCTAssertFalse(model.clipboardAvailable, "Control consent remains required")
        model.disconnect()
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

    func testThePictureStartPreflightDoesNotLookLikeAnOlderMac() throws {
        let model = try liveCouch()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3), to: model)
        try deliver(RemoteAction(action: "capture", x: 0, epoch: 3), to: model)
        XCTAssertNotEqual(model.sessionNotice, CouchCopy.updateMac)
        XCTAssertEqual(model.requestedMode, .couch)
        XCTAssertFalse(model.canControl)
        try deliver(status(true, epoch: 3, mode: "picture", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .picture)
        XCTAssertNotEqual(model.sessionNotice, CouchCopy.updateMac)
    }

    func testAModeReasonIsShownOnceAsANotice() throws {
        let model = try liveCouch()
        try deliver(status(true, mode: "couch", reason: "screenRecording", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .couch, "Couch continues when the picture is refused")
        XCTAssertEqual(model.sessionNotice, CouchCopy.needsScreenRecording)
    }

    func testDisplayRefreshFailureKeepsLiveCouchAndShowsTheRetryNotice() throws {
        let model = try liveCouch()
        try deliver(status(true, mode: "couch", reason: "displayUnavailable", features: couchFeatures), to: model)
        XCTAssertEqual(model.sessionMode, .couch)
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(model.sessionNotice, CouchCopy.displayUnavailable)
        XCTAssertNil(model.pendingModeSwitch)
    }

    func testModeRequestsNeedACouchCapableConnectedMac() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.requestMode(.couch))
        XCTAssertNil(model.pendingModeSwitch)
        XCTAssertFalse(model.couchSwitchAvailable)
    }

    func testEndingACouchSessionLeavesTheNextStartOnThePicture() throws {
        let model = try liveCouch()
        XCTAssertEqual(model.connection.sessionModeRequest, .couch)
        model.disconnect()
        XCTAssertEqual(model.connection.sessionModeRequest, .picture, "a Shortcut or URL connect must not start Couch")
        XCTAssertEqual(model.requestedMode, .couch, "Home still retries the mode it asked for")
        XCTAssertEqual(model.attemptMode, .couch)
        XCTAssertEqual(model.sessionMode, .picture)
    }

    func testAReconnectComesBackAsTheSessionWasOnScreen() throws {
        let fromCouch = try liveCouch()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3), to: fromCouch)
        try deliver(status(true, epoch: 3, mode: "picture", features: couchFeatures), to: fromCouch)
        fromCouch.disconnect()
        XCTAssertEqual(fromCouch.requestedMode, .couch)
        XCTAssertEqual(fromCouch.attemptMode, .picture, "switched to the picture in the session")
        XCTAssertEqual(fromCouch.connection.sessionModeRequest, .picture)

        let fromPicture = connected(mode: .picture)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), to: fromPicture)
        try deliver(status(true, mode: "couch", features: couchFeatures), to: fromPicture)
        XCTAssertEqual(fromPicture.sessionMode, .couch)
        fromPicture.disconnect()
        XCTAssertEqual(fromPicture.attemptMode, .couch, "switched to Couch in the session")
        XCTAssertEqual(fromPicture.connection.sessionModeRequest, .picture, "the coordinator stopped")

        fromPicture.prepareConnection(mode: .picture)
        XCTAssertNil(fromPicture.lastOnScreenMode, "Home's next Connect starts from what it asks for")
        XCTAssertEqual(fromPicture.attemptMode, .picture)
    }

    /// The model owns a real coordinator (keychain store, network signaling) with no injection
    /// point, so a unit test cannot hold it running; the running branch is the pure rule `end()` calls.
    func testARunningRetryKeepsTheOnScreenModeAndAStoppedOneFallsBackToThePicture() {
        XCTAssertEqual(PhoneRemoteModel.modeRequestAfterSessionEnd(coordinatorRunning: true, attemptMode: .couch), .couch)
        XCTAssertEqual(PhoneRemoteModel.modeRequestAfterSessionEnd(coordinatorRunning: true, attemptMode: .picture), .picture)
        XCTAssertEqual(PhoneRemoteModel.modeRequestAfterSessionEnd(coordinatorRunning: false, attemptMode: .couch), .picture)
    }

    func testCouchFailuresOfferThePictureInstead() {
        let proof = FriendlyError.forCouch(status: "The devices could not verify a directly attached local link.", requestedCouch: true)
        XCTAssertEqual(proof?.kind, .couchNotLocal)
        XCTAssertEqual(proof?.action, .connectWithPicture)
        XCTAssertEqual(proof?.message, CouchCopy.notLocal)
        XCTAssertEqual(FriendlyError.forCouch(status: CouchCopy.phoneRefusedStatus, requestedCouch: true)?.kind, .couchNotLocal)
        XCTAssertNil(FriendlyError.forCouch(status: CouchCopy.phoneRefusedStatus, requestedCouch: false))
        XCTAssertEqual(FriendlyError.couch(.controlOff).message, CouchCopy.controlOff)
        XCTAssertEqual(FriendlyError.Action.connectWithPicture.title, "Connect with picture")
        XCTAssertEqual(MacStatus("Connecting live desktop…", couch: true).text, CouchCopy.checking)
        XCTAssertEqual(MacStatus("Connecting live desktop…").text, FriendlyError.cardStatus("Connecting live desktop…"))
    }
}
