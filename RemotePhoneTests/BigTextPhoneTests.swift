import XCTest
@testable import PocketDeskRemote

@MainActor
final class BigTextPhoneTests: XCTestCase {
    private var defaults: UserDefaults!
    private var model: PhoneRemoteModel!
    private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
    private let studio = DisplayDescriptor(id: 7, name: "Studio Display", width: 2560, height: 1440)

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults("BigTextPhoneTests")
        model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        model.bigTextRoomOverride = "room-a"
    }

    override func tearDown() {
        model.disconnect()
        model = nil
        super.tearDown()
    }

    private func send(_ action: RemoteAction) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func reply(_ action: RemoteAction) throws {
        var correlated = action
        correlated.scaleRequestID = correlated.scaleRequestID ?? model.lastBigTextRequest?.requestID
        try send(correlated)
    }

    private func sendSessionStart(features: [String]) throws {
        try send(RemoteAction(action: "geometry", x: builtIn.width, y: builtIn.height, epoch: 1))
        try send(RemoteAction(action: "capture", x: 1, epoch: 1, features: features, display: 1))
    }

    private func described(_ display: DisplayDescriptor? = nil, current: Double = 1470) -> DisplayDescriptor {
        var d = display ?? builtIn
        d.scaleSteps = [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1024, height: 665)]
        d.scaleBaselineWidth = 1470
        d.scaleCurrentWidth = current
        return d
    }

    private func connect(features: [String] = [SessionFeature.displayScale], current: Double = 1470) throws {
        try sendSessionStart(features: features)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: current)], display: 1))
    }

    func testSavedLevelAppliesOnceWhenTheMacSupportsIt() throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect()
        XCTAssertEqual(model.lastBigTextRequest?.display, 1)
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
        XCTAssertEqual(model.bigText.savedWidth, 1280)
        XCTAssertEqual(model.bigText.pendingTarget, 1280)
        let requestID = model.lastBigTextRequest?.requestID
        model.lastBigTextRequest = nil
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: requestID))
        XCTAssertNil(model.lastBigTextRequest, "applied once per session")
        XCTAssertNil(model.bigText.pendingTarget, "the Mac's answer clears the pill")
        XCTAssertEqual(model.bigText.currentWidth, 1280)
        XCTAssertEqual(model.bigText.steps.map(\.width), [1280, 1024])
    }

    func testNothingIsSentToAnOlderMac() throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect(features: [])
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertFalse(model.bigTextSupported)
        model.chooseBigText(1024)
        model.setBigTextOffForSession(true)
        XCTAssertNil(model.lastBigTextRequest)
    }

    func testSavedLevelAtOrAboveTheMacsSizeDoesNothing() throws {
        BigTextMemory(defaults: defaults).remember(1600, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect()
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertNil(model.sessionNotice)
    }

    func testRapidChoicesSendOnlyTheLast() async throws {
        try connect()
        model.chooseBigText(1280)
        model.chooseBigText(1024)
        XCTAssertNil(model.lastBigTextRequest, "nothing leaves before the pause")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024)
        XCTAssertEqual(model.bigTextRequestsSent, 1, "one request for several quick choices")
        XCTAssertEqual(model.bigText.savedWidth, 1024)
        XCTAssertEqual(BigTextMemory(defaults: defaults).width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1024)
    }

    func testBusyKeepsWaitingForTheLatestAnswer() throws {
        try connect()
        model.chooseBigTextNow(1024)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1, scaleError: "busy"))
        XCTAssertEqual(model.bigText.pendingTarget, 1024, "a superseded request is followed by the latest answer")
        XCTAssertNil(model.sessionNotice)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1))
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertEqual(model.bigText.currentWidth, 1024)
    }

    func testOffForThisSessionKeepsTheSavedLevel() async throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect(current: 1280)
        XCTAssertNil(model.lastBigTextRequest, "already at the saved level")
        model.setBigTextOffForSession(true)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 0)
        XCTAssertTrue(model.bigText.sessionOff)
        XCTAssertEqual(model.bigText.savedWidth, 1280)
        XCTAssertEqual(BigTextMemory(defaults: defaults).width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1280)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        model.setBigTextOffForSession(false)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
    }

    func testPendingTimesOutWithAMessage() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        XCTAssertNotNil(model.bigText.pendingTarget)
        now += 7.5
        model.checkBigTextTimeout()
        XCTAssertNotNil(model.bigText.pendingTarget, "still within 8 s")
        now += 1
        model.checkBigTextTimeout()
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size")
    }

    func testErrorsBecomeFriendlyNotices() throws {
        try connect()
        model.chooseBigTextNow(1280)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1, scaleError: "disabled"))
        XCTAssertEqual(model.sessionNotice, "Big Text is turned off on this Mac.")
        XCTAssertEqual(PhoneRemoteModel.bigTextMessage(.noAccessibility), "Big Text needs Accessibility permission on your Mac.")
        XCTAssertEqual(PhoneRemoteModel.bigTextMessage(.unsupported), "This display doesn't offer larger sizes.")
        XCTAssertEqual(PhoneRemoteModel.bigTextMessage(.failed),
                       "Couldn't change text size. If an app is full screen on your Mac, exit full screen and try again.")
        XCTAssertNil(PhoneRemoteModel.bigTextMessage(.busy))
    }

    func testSwitchingDisplayAppliesThatDisplaysLevel() throws {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(1024, forRoom: "room-a", display: studio, among: [builtIn, studio])
        try sendSessionStart(features: [SessionFeature.displayScale])
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280), described(studio)], display: 1))
        XCTAssertNil(model.lastBigTextRequest)
        try send(RemoteAction(action: "geometry", x: studio.width, y: studio.height, epoch: 2))
        try reply(RemoteAction(action: "displays", epoch: 2, displays: [described(), described(studio)], display: 7))
        XCTAssertEqual(model.lastBigTextRequest?.display, 7)
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024)
    }

    func testPendingTextSizeChangeBlocksPointerAndKeyboardAdmission() throws {
        try connect()
        model.chooseBigTextNow(1280)
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.hardwareKey("a", modifiers: []))
        XCTAssertFalse(model.commandShortcut("space"))
    }

    func testSharingStoppedCardIsHiddenWhileTextSizeChanges() throws {
        try connect()
        model.fresh = true
        model.captureHealthy = false
        XCTAssertTrue(model.showsSharingStoppedCard)
        model.chooseBigTextNow(1280)
        XCTAssertFalse(model.showsSharingStoppedCard, "capture is stopped on purpose during the change")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        XCTAssertTrue(model.showsSharingStoppedCard, "hidden only while the change is pending")
    }

    func testSharingStoppedCardReturnsAfterTheTimeout() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.fresh = true
        model.captureHealthy = false
        model.chooseBigTextNow(1280)
        XCTAssertFalse(model.showsSharingStoppedCard)
        now += 8.5
        model.checkBigTextTimeout()
        XCTAssertTrue(model.showsSharingStoppedCard)
    }

    func testNothingIsSentWhenTheMacIsAtItsOwnSize() throws {
        try connect()
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertEqual(model.bigTextRequestsSent, 0)
    }

    func testMacLeftOnBigTextReturnsToNormalWithoutASavedLevel() throws {
        try connect(current: 1280)
        XCTAssertEqual(model.lastBigTextRequest?.display, 1)
        XCTAssertEqual(model.lastBigTextRequest?.width, 0, "another phone or a crash left the Mac on Big Text")
        XCTAssertEqual(model.bigText.pendingTarget, 0)
        model.lastBigTextRequest = nil
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        XCTAssertNil(model.lastBigTextRequest, "once per display per session")
        XCTAssertEqual(model.bigTextRequestsSent, 1)
    }

    func testOffForThisSessionResetsASwitchedDisplayLeftOnBigText() throws {
        let memory = BigTextMemory(defaults: defaults)
        memory.remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn, studio])
        memory.remember(1024, forRoom: "room-a", display: studio, among: [builtIn, studio])
        try sendSessionStart(features: [SessionFeature.displayScale])
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280), described(studio)], display: 1))
        XCTAssertNil(model.lastBigTextRequest)
        model.setBigTextOffForSession(true)
        try send(RemoteAction(action: "geometry", x: studio.width, y: studio.height, epoch: 2))
        try reply(RemoteAction(action: "displays", epoch: 2,
                              displays: [described(), described(studio, current: 1280)], display: 7))
        XCTAssertEqual(model.lastBigTextRequest?.display, 7)
        XCTAssertEqual(model.lastBigTextRequest?.width, 0, "off for the session, not the saved 1024")
        XCTAssertEqual(model.bigTextRequestsSent, 1)
    }

    func testMacLeftOnBigTextWaitsForAPendingRequest() throws {
        try connect()
        model.chooseBigTextNow(1024)
        try send(RemoteAction(action: "geometry", x: studio.width, y: studio.height, epoch: 2))
        try reply(RemoteAction(action: "displays", epoch: 2,
                              displays: [described(), described(studio, current: 1280)], display: 7, scaleError: "busy"))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024, "never while a request is pending")
        XCTAssertEqual(model.bigTextRequestsSent, 1)
        try reply(RemoteAction(action: "displays", epoch: 2,
                              displays: [described(current: 1024), described(studio, current: 1280)], display: 7))
        XCTAssertEqual(model.lastBigTextRequest?.display, 7)
        XCTAssertEqual(model.lastBigTextRequest?.width, 0)
        XCTAssertEqual(model.bigTextRequestsSent, 2)
    }

    func testUnknownScaleErrorIsIgnored() throws {
        try connect()
        model.chooseBigTextNow(1024)
        let reply = RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1,
                                 scaleError: "fromANewerMac")
        XCTAssertNoThrow(try reply.validate(), "a newer Mac's error code must not end the session")
        try self.reply(reply)
        XCTAssertNil(model.sessionNotice)
        XCTAssertNil(model.bigText.pendingTarget, "the list is still the Mac's answer")
        XCTAssertEqual(model.bigText.currentWidth, 1024)
    }

    func testLateSuccessClearsTheTimeoutNotice() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        now += 8.5
        model.checkBigTextTimeout()
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size", "a list without the change is not the late answer")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        XCTAssertNil(model.sessionNotice, "the change did happen, only late")
    }

    func testLateSuccessKeepsANewerNotice() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        now += 8.5
        model.checkBigTextTimeout()
        model.announce("Copied to your Mac")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        XCTAssertEqual(model.sessionNotice, "Copied to your Mac")
    }

    func testLegacyScaleHostDoesNotStartACorrelatedRequest() throws {
        try connect(features: ["display.scale.1"])
        model.chooseBigTextNow(1280)
        XCTAssertFalse(model.bigTextSupported)
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertNil(model.lastBigTextRequest)
    }

    func testOldReplyAndUnrelatedListCannotClearNewerRequest() throws {
        try connect()
        model.chooseBigTextNow(1280)
        let a = model.lastBigTextRequest!.requestID
        model.chooseBigTextNow(1024)
        let b = model.lastBigTextRequest!.requestID
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: a))
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1,
                              scaleError: "failed", scaleRequestID: a))
        XCTAssertNil(model.sessionNotice, "A's failure is not B's notice")
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1))
        XCTAssertEqual(model.bigText.pendingTarget, 1024, "a generic list has no completion identity")
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1, scaleRequestID: b))
        XCTAssertNil(model.bigText.pendingTarget)
    }

    func testRepeatedSameWidthRequestsHaveDistinctCompletionOwnership() throws {
        try connect()
        model.chooseBigTextNow(1280)
        let a = model.lastBigTextRequest!.requestID
        model.chooseBigTextNow(1280)
        let b = model.lastBigTextRequest!.requestID
        XCTAssertNotEqual(a, b)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: a))
        XCTAssertEqual(model.bigText.pendingTarget, 1280)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: b))
        XCTAssertNil(model.bigText.pendingTarget)
    }

    func testOldEpochCompletionCannotClearTheCurrentRequest() throws {
        try connect()
        model.chooseBigTextNow(1280)
        let id = model.lastBigTextRequest!.requestID
        try send(RemoteAction(action: "geometry", x: 1280, y: 832, epoch: 2))
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: id))
        XCTAssertEqual(model.bigText.pendingTarget, 1280)
        try send(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1280)], display: 1, scaleRequestID: id))
        XCTAssertNil(model.bigText.pendingTarget)
    }

    func testUnsupportedRequestedWidthCannotClearItsTimeoutBySeeingAnotherStep() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(700)
        let id = model.lastBigTextRequest!.requestID
        now += 8.5
        model.checkBigTextTimeout()
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1, scaleRequestID: id))
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size")
    }

    func testLateNearestWidthSuccessClearsOnlyItsTimeoutNotice() throws {
        var nearby = described()
        nearby.scaleSteps = [ScaleStep(width: 1290, height: 839), ScaleStep(width: 1024, height: 665)]
        try sendSessionStart(features: [SessionFeature.displayScale])
        try send(RemoteAction(action: "displays", epoch: 1, displays: [nearby], display: 1))
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        let id = model.lastBigTextRequest!.requestID
        now += 8.5
        model.checkBigTextTimeout()
        nearby.scaleCurrentWidth = 1024
        try send(RemoteAction(action: "displays", epoch: 1, displays: [nearby], display: 1, scaleRequestID: id))
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size", "unrelated offered mode does not confirm success")
        nearby.scaleCurrentWidth = 1290
        try send(RemoteAction(action: "displays", epoch: 1, displays: [nearby], display: 1))
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size", "mode alone is not request ownership")
        try send(RemoteAction(action: "displays", epoch: 1, displays: [nearby], display: 1, scaleRequestID: id))
        XCTAssertNil(model.sessionNotice)
    }

    func testLateSuccessCannotClearANewerIdenticalNotice() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        let id = model.lastBigTextRequest!.requestID
        now += 8.5
        model.checkBigTextTimeout()
        model.announce("Couldn't change text size")
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: id))
        XCTAssertEqual(model.sessionNotice, "Couldn't change text size", "notice ownership is a generation, not text equality")
    }

    func testEndClearsSessionState() throws {
        BigTextMemory(defaults: defaults).remember(1280, forRoom: "room-a", display: builtIn, among: [builtIn])
        try connect()
        model.disconnect()
        XCTAssertEqual(model.bigText, BigTextState())
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertFalse(model.bigTextSupported)
    }
}
