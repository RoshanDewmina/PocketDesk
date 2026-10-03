import XCTest
import SwiftUI
@testable import PocketDeskRemote

@MainActor
final class BigTextPhoneTests: XCTestCase {
    private var defaults: UserDefaults!
    private var model: PhoneRemoteModel!
    private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
    private let studio = DisplayDescriptor(id: 7, name: "Studio Display", width: 2560, height: 1440)

    func testBackgroundRetiresPendingScaleWithoutTimeoutNotice() throws {
        try connect(features: [SessionFeature.displayScale, SessionFeature.backgroundPause])
        model.sceneChanged(.active)
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        model.sceneChanged(.background)
        XCTAssertTrue(model.connection.connected, "Exercise the held authenticated peer, not an ordinary disconnect")
        model.chooseBigTextNow(1280)
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime) // Drive the existing timer seam.
        now += 9
        model.checkBigTextTimeout()
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertNil(model.sessionNotice)
    }

    func testNewAuthenticatedPeerRetiresOldScaleRequest() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        model.connection.startInputFixtureForTesting(session: "new-bigtext-peer")
        model.connection.onAuthenticated?()
        now += 9
        model.checkBigTextTimeout()
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertNil(model.sessionNotice)
    }

    func testConfirmedScaleReplyBeforeGeometryIsRetained() throws {
        try connect()
        try makeControllable()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        try reply(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1))
        XCTAssertEqual(model.geometryEpoch, 1, "A catalog cannot advance input geometry")
        XCTAssertFalse(model.canControl, "Confirmed text size cannot grant input on old geometry")
        now += 9
        model.checkBigTextTimeout()
        XCTAssertNil(model.sessionNotice, "An authenticated size confirmation survives delayed geometry")
        XCTAssertFalse(model.canControl)
        try send(RemoteAction(action: "geometry", x: 1024, y: 665, epoch: 2))
        model.checkBigTextTimeout()
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertNil(model.sessionNotice)
        XCTAssertFalse(model.canControl, "Geometry alone cannot renew capture readiness")
        try makeControllable(epoch: 2)
        XCTAssertTrue(model.canControl, "Only fresh new-epoch capture and a frame restore control")
    }

    func testLateFutureEpochConfirmationClearsOnlyItsTimeoutWithoutGrantingInput() throws {
        try connect()
        try makeControllable()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        now += 9
        model.checkBigTextTimeout()
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size")
        try reply(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1))
        XCTAssertNil(model.sessionNotice)
        XCTAssertEqual(model.geometryEpoch, 1)
        XCTAssertFalse(model.canControl)
    }

    func testFutureErrorHonorsTheExistingStatusReliabilityRollback() throws {
        defaults.set(true, forKey: PhoneRemoteModel.bigTextStatusDisabledKey)
        try connect()
        model.chooseBigTextNow(1024)
        try reply(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1, scaleError: "failed"))
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        try send(RemoteAction(action: "geometry", x: 1024, y: 665, epoch: 2))
        XCTAssertEqual(model.sessionNotice, PhoneRemoteModel.bigTextMessage(.failed))
    }

    func testNewerGeometryDiscardsDeferredCatalogWithoutAdoptingItsMode() throws {
        try connect()
        model.chooseBigTextNow(1024)
        try reply(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1))
        try send(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 3))
        XCTAssertEqual(model.bigText.currentWidth, 1470, "An epoch-2 catalog cannot update epoch-3 display metadata")
        XCTAssertEqual(model.geometryEpoch, 3)
        XCTAssertFalse(model.canControl)
    }

    func testUnrelatedFutureCatalogCannotConfirmOrReplaceTheLatestScaleRequest() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1280)
        let oldID = model.lastBigTextRequest!.requestID
        model.chooseBigTextNow(1024)
        try send(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1))
        try send(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1, scaleRequestID: oldID))
        try send(RemoteAction(action: "geometry", x: 1024, y: 665, epoch: 2))
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        now += 9
        model.checkBigTextTimeout()
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size", "Silence from the current request remains a real failure")
    }

    func testSessionPolishNoRestoresLegacyFutureReplyAndBackgroundTimeout() throws {
        model.disconnect()
        defaults.set(false, forKey: PhoneRemoteModel.sessionPolishKey)
        model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        model.bigTextRoomOverride = "room-a"
        model.connection.inputPacketSenderForTesting = { _ in true }
        try connect(features: [SessionFeature.displayScale, SessionFeature.backgroundPause])
        model.sceneChanged(.active)
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        try reply(RemoteAction(action: "displays", epoch: 2, displays: [described(current: 1024)], display: 1))
        model.sceneChanged(.background)
        now += 9
        model.checkBigTextTimeout()
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size")
        XCTAssertNil(model.sessionRecoveryHint)
    }

    func testConfirmedAppliedModeSuppressesCorrelatedFailure() throws {
        try connect()
        model.chooseBigTextNow(1024)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1, scaleError: "failed"))
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertNil(model.sessionNotice, "the applied size is stronger evidence than a stale host error")
    }

    func testLateConfirmedAppliedModeClearsTimeoutEvenWithHostError() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        now += 8.5
        model.checkBigTextTimeout()
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1, scaleError: "failed"))
        XCTAssertNil(model.sessionNotice)
    }

    func testProgressPillExpiresWithoutDiscardingRequestCorrelationOrInputGuard() throws {
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        XCTAssertEqual(model.bigTextPillTarget, 1024)
        now += 2.1
        model.checkBigTextTimeout()
        XCTAssertNil(model.bigTextPillTarget)
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        XCTAssertFalse(model.canControl)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1))
        XCTAssertEqual(model.bigText.pendingTarget, 1024, "generic catalogs still cannot complete requests")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1))
        XCTAssertNil(model.bigText.pendingTarget)
    }

    func testStatusReliabilityKillSwitchRestoresLegacyPendingPillAndErrors() throws {
        defaults.set(true, forKey: PhoneRemoteModel.bigTextStatusDisabledKey)
        try connect()
        var now: TimeInterval = 100
        model.bigTextClock = { now }
        model.chooseBigTextNow(1024)
        now += 2.1
        model.checkBigTextTimeout()
        XCTAssertEqual(model.bigTextPillTarget, 1024)
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1024)], display: 1, scaleError: "failed"))
        XCTAssertEqual(model.sessionNotice, PhoneRemoteModel.bigTextMessage(.failed))
    }

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults("BigTextPhoneTests")
        model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
                                 coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        model.bigTextRoomOverride = "room-a"
        // Existing request/correlation tests exercise the legacy saved-level path.
        defaults.set(true, forKey: "disableBigTextAutoLevel")
        model.connection.startInputFixtureForTesting(session: "bigtext")
        model.connection.inputPacketSenderForTesting = { _ in true }
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
        model.connection.startInputFixtureForTesting(session: "bigtext")
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

    private func makeControllable(epoch: UInt64 = 1) throws {
        model.sceneChanged(.active)
        try send(RemoteAction(action: "capture", x: 1, epoch: epoch, features: [SessionFeature.displayScale], display: 1))
        try send(RemoteAction(action: "viewing", x: 1, epoch: epoch))
        model.frameReceived()
        XCTAssertTrue(model.canControl, "The regression must begin with a genuinely admitted input path")
    }

    private func recordPackets() -> () -> [ControlPacket] {
        model.connection.startInputFixtureForTesting(session: "bigtext")
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        return { packets }
    }

    private func identifiedInvitation() throws -> PairInvitation {
        var invitation = try HostPair.create(server: "wss://offline.invalid/signal", name: "Mac").rotated().invitation
        invitation.durableHostID = try SecureRandom.token()
        invitation.ownerPairID = try SecureRandom.token()
        invitation.localServiceName = "fixture"
        return invitation
    }

    private func useTrustedModel(_ invitation: PairInvitation) throws {
        model.disconnect()
        let trust = PhoneTrustStore(records: MemoryStore(), legacy: MemoryStore())
        try trust.saveApproved(invitation)
        model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
                                 coordinator: RemoteCoordinator(isHost: false, store: PhonePairPersistence(trust: trust)))
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        model.connection.inputPacketSenderForTesting = { _ in true }
    }

    func testKnownManualChoiceWinsOverAutoAfterRePairingTheSameMac() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        let old = try identifiedInvitation()
        BigTextMemory(defaults: defaults).remember(1024, forRoom: old.room, display: builtIn, among: [builtIn])
        try useTrustedModel(old)
        try connect()
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024)
        var replacement = try identifiedInvitation()
        replacement.durableHostID = old.durableHostID
        try useTrustedModel(replacement)
        try connect()
        XCTAssertEqual(model.bigText.savedWidth, 1024)
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024, "the first-use 1280 level cannot overwrite the remembered manual level")
    }

    func testKnownPersistentOffWinsOverAutoAfterRePairingTheSameMac() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        let old = try identifiedInvitation()
        BigTextMemory(defaults: defaults).remember(nil, forRoom: old.room, display: builtIn, among: [builtIn])
        try useTrustedModel(old)
        try connect()
        XCTAssertNil(model.lastBigTextRequest)
        var replacement = try identifiedInvitation()
        replacement.durableHostID = old.durableHostID
        try useTrustedModel(replacement)
        try connect(current: 1280)
        XCTAssertNil(model.bigText.savedWidth)
        XCTAssertEqual(model.lastBigTextRequest?.width, 0, "persistent Off restores the baseline instead of choosing an automatic level")
        let trusted = try XCTUnwrap(model.connection.presentationHostTrust)
        XCTAssertTrue(model.bigTextMemory.hasSavedChoice(forHost: trusted, display: builtIn, among: [builtIn]))
    }

    func testFirstConnectAutomaticallyAppliesAndSavesAnOfferedLevel() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        try connect()
        XCTAssertEqual(model.lastBigTextRequest?.display, 1)
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
        XCTAssertEqual(model.bigText.savedWidth, 1280)
        XCTAssertEqual(model.bigTextMemory.width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1280)
        let id = model.lastBigTextRequest?.requestID
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: id))
        XCTAssertNil(model.bigText.pendingTarget)
        XCTAssertEqual(model.bigTextRequestsSent, 1)
    }

    func testAutoLevelUsesOnlyTheStreamedDisplayAndRemembersManualOverride() async throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        try sendSessionStart(features: [SessionFeature.displayScale])
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(), described(studio)], display: 1))
        XCTAssertEqual(model.lastBigTextRequest?.display, 1)
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: "room-a", display: studio, among: [builtIn, studio]))
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        model.chooseBigText(1024)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024)
        model.disconnect()
        try connect()
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024, "manual override wins on reconnect")
        XCTAssertEqual(model.bigTextMemory.width(forRoom: "room-a", display: builtIn, among: [builtIn]), 1024)
    }

    func testExplicitOffIsNotReplacedByAnAutomaticLevelOnReconnect() async throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        try connect()
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1))
        model.chooseBigText(nil)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.lastBigTextRequest?.width, 0)
        model.disconnect()
        try connect()
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertNil(model.bigText.savedWidth)
        XCTAssertTrue(model.bigTextMemory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
    }

    func testMacOptOutAndMissingOffersDoNotChooseOrSaveAnAutomaticLevel() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        try connect(features: [])
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
        try sendSessionStart(features: [SessionFeature.displayScale])
        try send(RemoteAction(action: "displays", epoch: 1, displays: [builtIn], display: 1))
        XCTAssertNil(model.lastBigTextRequest, "Mac allow/AX withdrawal removes mode metadata")
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
    }

    func testCouchSkipsAutoLevelAndPictureReturnAppliesIt() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        let features = [SessionFeature.displayScale, SessionFeature.couch, SessionFeature.displaySelection]
        let packets = recordPackets()
        try sendSessionStart(features: features)
        XCTAssertEqual(packets().filter { $0.action.action == "displays" }.count, 1)
        try send(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 1))
        try send(RemoteAction(action: "capture", x: 1, epoch: 1, features: features, display: 1, mode: "couch"))
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
        model.chooseBigText(1024)
        XCTAssertNil(model.bigText.savedWidth, "manual scaling is also unavailable without a picture")
        try send(RemoteAction(action: "capture", x: 1, epoch: 1, features: features, display: 1, mode: "picture"))
        XCTAssertEqual(packets().filter { $0.action.action == "displays" }.count, 2,
                       "picture return requests a fresh catalog before scaling")
        XCTAssertNil(model.lastBigTextRequest)
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
    }

    func testAutomaticLevelWaitsForTheRememberedDisplayBeforeSavingOrScaling() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        model.connection.startAllowed = { false }
        let invitation = try TestPairing.invitation()
        try model.connection.enroll(invitation.code())
        model.bigTextRoomOverride = nil
        let oldDisplayMemory = UserDefaults.standard.data(forKey: DisplayMemory.defaultsKey)
        defer {
            if let oldDisplayMemory { UserDefaults.standard.set(oldDisplayMemory, forKey: DisplayMemory.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: DisplayMemory.defaultsKey) }
        }
        DisplayMemory().remember(.init(id: studio.id, name: studio.name), forRoom: invitation.room)
        model.sceneChanged(.active)
        let packets = recordPackets()
        let features = [SessionFeature.displayScale, SessionFeature.displaySelection]
        try send(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 1))
        try send(RemoteAction(action: "viewing", x: 1, epoch: 1))
        try send(RemoteAction(action: "capture", x: 1, epoch: 1, features: features, display: 1))
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(), studio], display: 1))
        XCTAssertNil(model.lastBigTextRequest, "initial healthy status precedes the first controllable frame")
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: invitation.room, display: builtIn, among: [builtIn, studio]))
        model.frameReceived()
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(packets().last { $0.action.action == "display" }?.action.display, studio.id)
        XCTAssertNil(model.lastBigTextRequest, "selection must finish before scaling")
        try send(RemoteAction(action: "geometry", x: studio.width, y: studio.height, epoch: 2))
        try send(RemoteAction(action: "capture", x: 1, epoch: 2, features: features, display: studio.id))
        try send(RemoteAction(action: "displays", epoch: 2, displays: [described(), described(studio)], display: studio.id))
        XCTAssertEqual(model.lastBigTextRequest?.display, studio.id)
        XCTAssertEqual(packets().filter { $0.action.action == "displayScale" }.count, 1)
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: invitation.room, display: builtIn, among: [builtIn, studio]))
    }

    func testLiveViewOnlyDefersAutomaticSelectionUntilForegroundViewingReturns() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        let packets = recordPackets()
        let features = [SessionFeature.displayScale, SessionFeature.liveViewOnly]
        try send(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 1))
        try send(RemoteAction(action: "capture", x: 0, epoch: 1, features: features, display: 1))
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        try send(RemoteAction(action: "capture", liveViewOnly: true, x: 1, epoch: 1, features: features, display: 1))
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(packets().allSatisfy { $0.action.action != "displayScale" })
        XCTAssertFalse(model.bigTextMemory.hasSavedChoice(forRoom: "room-a", display: builtIn, among: [builtIn]))
        XCTAssertTrue(model.awaitingViewOnlyExitForTesting)
        let exit = try XCTUnwrap(packets().last { $0.action.action == "viewOnly" && $0.action.liveViewOnly == false })
        try send(RemoteAction(action: "capture", liveViewOnly: false,
                             liveViewOnlyRequestID: exit.action.liveViewOnlyRequestID,
                             x: 1, epoch: 1, features: features, display: 1))
        XCTAssertFalse(model.awaitingViewOnlyExitForTesting)
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
        XCTAssertEqual(packets().filter { $0.action.action == "displayScale" }.count, 1)
    }

    func testEnteringCouchCancelsADebouncedManualChange() async throws {
        try connect(current: 1470)
        model.chooseBigText(1024)
        try send(RemoteAction(action: "capture", x: 1, epoch: 1,
                             features: [SessionFeature.displayScale, SessionFeature.couch], display: 1, mode: "couch"))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertEqual(model.bigText.savedWidth, 1024, "saved for the next picture session")
    }

    func testAutomaticLevelWaitsForHealthyPicture() throws {
        defaults.set(false, forKey: "disableBigTextAutoLevel")
        try send(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 1))
        try send(RemoteAction(action: "capture", x: 0, epoch: 1, features: [SessionFeature.displayScale], display: 1))
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        XCTAssertNil(model.lastBigTextRequest)
        try send(RemoteAction(action: "capture", x: 1, epoch: 1, features: [SessionFeature.displayScale], display: 1))
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        XCTAssertEqual(model.lastBigTextRequest?.width, 1280)
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
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size")
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
        try send(RemoteAction(action: "capture", x: 1, epoch: 2, features: [SessionFeature.displayScale], display: 7))
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
        try send(RemoteAction(action: "capture", x: 1, epoch: 2, features: [SessionFeature.displayScale], display: 7))
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
        try send(RemoteAction(action: "capture", x: 1, epoch: 2, features: [SessionFeature.displayScale], display: 7))
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
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size")
        try reply(RemoteAction(action: "displays", epoch: 1, displays: [described()], display: 1))
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size", "a list without the change is not the late answer")
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
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size")
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
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size", "unrelated offered mode does not confirm success")
        nearby.scaleCurrentWidth = 1290
        try send(RemoteAction(action: "displays", epoch: 1, displays: [nearby], display: 1))
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size", "mode alone is not request ownership")
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
        model.announce("Couldn't confirm text size")
        try send(RemoteAction(action: "displays", epoch: 1, displays: [described(current: 1280)], display: 1, scaleRequestID: id))
        XCTAssertEqual(model.sessionNotice, "Couldn't confirm text size", "notice ownership is a generation, not text equality")
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

@MainActor
final class SessionPreferencesReadTests: XCTestCase {
    private final class CountingDefaults: UserDefaults, @unchecked Sendable {
        var reads: [String: Int] = [:]
        override func bool(forKey key: String) -> Bool {
            reads[key, default: 0] += 1
            return super.bool(forKey: key)
        }
        override func object(forKey key: String) -> Any? {
            reads[key, default: 0] += 1
            return super.object(forKey: key)
        }
    }

    func testSelectingAnotherMacCannotInheritThePreviousMacLockReport() throws {
        let defaults = makeTestDefaults("b13-lock-destination")
        let trust = PhoneTrustStore(records: MemoryStore(), legacy: MemoryStore())
        let first = try HostPair.create(server: "wss://offline.invalid/signal", name: "First Mac").rotated().invitation
        let second = try HostPair.create(server: "wss://offline.invalid/signal", name: "Second Mac").rotated().invitation
        try trust.saveApproved(first)
        try trust.saveApproved(second)
        let snapshot = try trust.snapshot()
        let firstHost = try XCTUnwrap(snapshot.hosts.first { $0.invitation == first })
        let secondHost = try XCTUnwrap(snapshot.hosts.first { $0.invitation == second })
        try trust.select(hostID: firstHost.id)
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: PhonePairPersistence(trust: trust)))
        defer { model.disconnect() }
        model.connection.startInputFixtureForTesting(session: "first-mac-lock")
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 0, epoch: 1,
            features: SessionFeature.host, hostState: HostPresence.locked.rawValue)))
        model.connection.stop()
        XCTAssertEqual(model.recoveryHostPresence, .locked)
        XCTAssertNotNil(model.recoveryMacNotice)
        XCTAssertTrue(model.selectPairedMac(id: "m_" + secondHost.id, trust: trust))
        XCTAssertNil(model.recoveryHostPresence)
        XCTAssertNil(model.recoveryMacNotice)
        XCTAssertFalse(model.sessionRecoveryHint?.contains("last reported") == true)
    }

    func testFirst60SwitchDoesNotReadPreferencesDuringRepeatedPresentation() throws {
        let suite = "b13-counting-" + UUID().uuidString
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        defer { model.disconnect() }
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        _ = model.bigTextPillTarget // Sample the injected scale policy before measuring the hot path.
        let initial = defaults.reads[First60.disabledDefaultsKey, default: 0]
        let scaleInitial = defaults.reads[PhoneRemoteModel.bigTextStatusDisabledKey, default: 0]
        for _ in 0..<1000 {
            XCTAssertTrue(model.first60Enabled)
            _ = model.first60InlineHint
            _ = model.bigTextPillTarget
        }
        XCTAssertEqual(defaults.reads[First60.disabledDefaultsKey, default: 0], initial,
                       "An internal rollback switch must be sampled once, not during each presentation")
        XCTAssertEqual(defaults.reads[PhoneRemoteModel.bigTextStatusDisabledKey, default: 0], scaleInitial)
        print("b13 1000 presentation cycles: First60 counted reads=\(defaults.reads[First60.disabledDefaultsKey, default: 0] - initial), BigText counted reads=\(defaults.reads[PhoneRemoteModel.bigTextStatusDisabledKey, default: 0] - scaleInitial)")
    }
}

@MainActor
final class First60PhoneTests: XCTestCase {
    private var defaults: UserDefaults!
    private var model: PhoneRemoteModel!
    private var packets: [ControlPacket] = []
    private var display: DisplayDescriptor {
        var value = DisplayDescriptor(id: 1, name: "Built-in", width: 1470, height: 956)
        value.scaleSteps = [ScaleStep(width: 1024, height: 665)]
        value.scaleBaselineWidth = 1470
        value.scaleCurrentWidth = 1470
        return value
    }
    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults("First60PhoneTests")
        defaults.set(true, forKey: BigTextAutoLevel.disabledKey)
        packets = []
    }
    override func tearDown() {
        model?.disconnect()
        model = nil
        super.tearDown()
    }
    private func start(features: [String] = []) throws {
        let trust = PhoneTrustStore(records: MemoryStore(), legacy: MemoryStore())
        try trust.saveApproved(TestPairing.invitation())
        model = PhoneRemoteModel(background: FakeBackgroundExecution(), resumeStore: SessionResumeStore(defaults: defaults), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: PhonePairPersistence(trust: trust)))
        model.bigTextMemory = BigTextMemory(defaults: defaults)
        model.bigTextRoomOverride = "first60-room"
        model.prepareConnection(mode: .picture)
        model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: "first60")
        model.connection.inputPacketSenderForTesting = { [weak self] packet in self?.packets.append(packet); return true }
        model.connection.onAuthenticated?()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 1))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: features, display: 1))
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 1))
    }
    private func deliver(_ action: RemoteAction) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }
    private func rememberWidth(_ width: Double) throws {
        BigTextMemory(defaults: defaults).remember(width, forHost: try XCTUnwrap(model.connection.presentationHostTrust),
            display: display, among: [display])
    }
    private func catalog(current: Double = 1470, error: String? = nil) throws {
        var value = display
        value.scaleCurrentWidth = current
        try deliver(RemoteAction(action: "displays", epoch: 1, displays: [value], display: 1,
            scaleError: error, scaleRequestID: error != nil || current != 1470 ? model.lastBigTextRequest?.requestID : nil))
    }
    private func lastClick() throws -> RemoteAction {
        try XCTUnwrap(packets.last { $0.action.action == "click" }?.action)
    }
    private func applied(_ request: RemoteAction, accepted: Bool, requestID: String? = nil) throws {
        var response = RemoteAction(action: "inputApplied", epoch: 1)
        response.inputAppliedReceipt = InputAppliedReceipt(requestID: try XCTUnwrap(requestID ?? request.inputRequestID), kind: "click", accepted: accepted)
        try deliver(response)
    }
    func testInitialAutomaticScaleSettlesBeforeIrisAndReconnectDoesNotHold() throws {
        try start(features: [SessionFeature.displayScale])
        try rememberWidth(1024)
        XCTAssertFalse(model.firstPictureReady)
        try catalog()
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        XCTAssertNil(model.bigTextPillTarget, "Initial display change is behind the iris")
        XCTAssertFalse(model.firstPictureReady)
        try catalog(current: 1024)
        XCTAssertTrue(model.firstPictureReady)
        XCTAssertFalse(defaults.bool(forKey: PhoneRemoteModel.firstPictureShownKey), "Opening a gate supplies no picture")
        model.frameReceived()
        XCTAssertTrue(defaults.bool(forKey: PhoneRemoteModel.firstPictureShownKey))
        model.disconnect()
        model.connection.startInputFixtureForTesting(session: "first60-reconnect")
        model.connection.onAuthenticated?()
        XCTAssertTrue(model.firstPictureReady)
    }
    func testInitialFailureFallsBackButManualFailureKeepsDiagnostics() throws {
        try start(features: [SessionFeature.displayScale])
        try rememberWidth(1024)
        try catalog()
        try catalog(error: "failed")
        XCTAssertEqual(model.sessionNotice, "Using your Mac’s current text size.")
        XCTAssertTrue(model.firstPictureReady)
        model.chooseBigTextNow(1024)
        XCTAssertEqual(model.bigTextPillTarget, 1024)
        try catalog(error: "failed")
        XCTAssertEqual(model.sessionNotice, PhoneRemoteModel.bigTextMessage(.failed))
    }
    func testSetupOpenDefersScaleUntilAcceptedDoneStatus() async throws {
        try start(features: [SessionFeature.displayScale])
        try rememberWidth(1024)
        try model.connection.setFirst60SetupStatusForTesting(.init(open: true, mediaReady: true))
        try catalog()
        XCTAssertNil(model.lastBigTextRequest)
        XCTAssertFalse(model.bigText.autoApplied)
        XCTAssertTrue(model.firstPictureReady, "The phone may show setup without resizing the Mac's Done target")
        XCTAssertFalse(model.firstPictureSettling)
        try model.connection.setFirst60SetupStatusForTesting(.init(open: false, mediaReady: true))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(model.lastBigTextRequest?.width, 1024)
        XCTAssertNil(model.bigTextPillTarget)
        XCTAssertTrue(model.firstPictureSettling, "Keep the mounted renderer covered during the initial post-Done resize")
        try catalog(current: 1024)
        XCTAssertFalse(model.firstPictureSettling)
    }
    func testDeferredInitialResizeVeilIsBoundedAndEndCancelsIt() async throws {
        try start(features: [SessionFeature.displayScale])
        try rememberWidth(1024)
        try model.connection.setFirst60SetupStatusForTesting(.init(open: true, mediaReady: true))
        try catalog()
        model.frameReceived()
        try model.connection.setFirst60SetupStatusForTesting(.init(open: false, mediaReady: true))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(model.firstPictureSettling)
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 1.1)
        XCTAssertFalse(model.firstPictureSettling)
        XCTAssertEqual(model.bigText.pendingTarget, 1024, "Bounded presentation waiting never invents scale confirmation")
        model.disconnect()
        model.connection.startInputFixtureForTesting(session: "first60-reconnected")
        model.connection.onAuthenticated?()
        XCTAssertTrue(model.firstPictureReady)
        XCTAssertFalse(model.firstPictureSettling)
    }
    func testPrivacyPendingWaitsForAppliedCurtainStatus() throws {
        try start(features: [SessionFeature.displayScale, SessionFeature.privacyCurtain])
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1,
            features: [SessionFeature.displayScale, SessionFeature.privacyCurtain], curtain: "pending", display: 1))
        try catalog()
        XCTAssertFalse(model.firstPictureReady)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1,
            features: [SessionFeature.displayScale, SessionFeature.privacyCurtain], curtain: "up", display: 1))
        XCTAssertTrue(model.firstPictureReady)
    }
    func testUnansweredGateIsBoundedAndDisconnectRetiresItsDeadline() throws {
        try start(features: [SessionFeature.displayScale])
        XCTAssertFalse(model.firstPictureReady)
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 1.1)
        XCTAssertTrue(model.firstPictureReady)
        XCTAssertFalse(defaults.bool(forKey: PhoneRemoteModel.firstPictureShownKey))
        model.connection.onAuthenticated?()
        XCTAssertFalse(model.firstPictureReady)
        model.disconnect()
        model.expireViewOnlyExitForTesting(at: ProcessInfo.processInfo.systemUptime + 2)
        XCTAssertFalse(model.firstPictureReady)
    }
    func testHintsAdvanceOnceFromRealMoveThenCorrelatedAppliedClickOnly() throws {
        try start(features: [SessionFeature.inputReceipt])
        model.frameReceived()
        XCTAssertEqual(model.first60InlineHint, "Slide to move")
        _ = model.gesture(.move(.zero))
        XCTAssertEqual(model.first60HintStage, .move)
        XCTAssertTrue(model.gesture(.move(CGSize(width: 1, height: 0))))
        XCTAssertEqual(model.first60InlineHint, "Tap to click")
        XCTAssertTrue(model.gesture(.click(count: 1)))
        let click = try lastClick()
        XCTAssertEqual(model.first60HintStage, .click, "A successful local send is not a posted click")
        try applied(click, accepted: true, requestID: String(repeating: "f", count: 32))
        XCTAssertEqual(model.first60HintStage, .click)
        try applied(click, accepted: false)
        XCTAssertEqual(model.first60HintStage, .click)
        XCTAssertTrue(model.gesture(.click(count: 1)))
        let next = try lastClick()
        try applied(next, accepted: true)
        XCTAssertEqual(model.first60HintStage, .finished)
        XCTAssertNil(model.first60InlineHint)
        try applied(next, accepted: true)
        XCTAssertEqual(defaults.integer(forKey: PhoneRemoteModel.first60HintStageKey), First60HintStage.finished.rawValue)
        let restored = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        XCTAssertEqual(restored.first60HintStage, .finished)
        restored.disconnect()
    }
    func testAppliedDoneClickCompletesHintWhileDeferredScaleTemporarilyBlocksControl() async throws {
        try start(features: [SessionFeature.displayScale, SessionFeature.inputReceipt])
        try rememberWidth(1024)
        try model.connection.setFirst60SetupStatusForTesting(.init(open: true, mediaReady: true))
        try catalog()
        model.frameReceived()
        XCTAssertTrue(model.gesture(.move(CGSize(width: 1, height: 0))))
        XCTAssertEqual(model.first60InlineHint, "Tap to click")
        XCTAssertTrue(model.gesture(.click(count: 1)))
        let doneClick = try lastClick()
        XCTAssertEqual(model.first60HintStage, .click, "Sending Done does not prove it was posted")

        try model.connection.setFirst60SetupStatusForTesting(.init(open: false, mediaReady: true))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(model.bigText.pendingTarget, 1024)
        XCTAssertFalse(model.canControl)
        XCTAssertNil(model.first60InlineHint)
        try applied(doneClick, accepted: true)
        XCTAssertEqual(model.first60HintStage, .finished, "Exact posted Done still counts while its resize is pending")
        XCTAssertEqual(defaults.integer(forKey: PhoneRemoteModel.first60HintStageKey), First60HintStage.finished.rawValue)
    }
    func testMixedPeerDoesNotPretendToConfirmClickAndKillSwitchRestoresNormalPresentation() throws {
        try start()
        model.frameReceived()
        XCTAssertTrue(model.gesture(.move(CGSize(width: 1, height: 0))))
        XCTAssertEqual(model.first60HintStage, .click)
        XCTAssertNil(model.first60InlineHint, "Legacy Mac cannot supply an applied click receipt")
        model.disconnect()
        defaults.set(true, forKey: First60.disabledDefaultsKey)
        try start(features: [SessionFeature.displayScale])
        XCTAssertTrue(model.firstPictureReady)
        XCTAssertNil(model.first60InlineHint)
    }
}
