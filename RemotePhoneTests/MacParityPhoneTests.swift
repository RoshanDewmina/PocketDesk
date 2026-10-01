import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacParityPhoneTests: XCTestCase {
    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        let receive = try XCTUnwrap(model.connection.onControl)
        receive(try JSONEncoder().encode(action))
    }

    func testCurtainStateAndRecoveryNoticeFollowTheMacsStatus() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.connection.startInputFixtureForTesting(session: "curtain-status-fixture")
        defer { model.connection.stop() }

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1,
                                 features: [SessionFeature.clipboardText, SessionFeature.backgroundPause]), to: model)
        XCTAssertFalse(model.curtainSupported, "An older Mac has no curtain")
        XCTAssertNil(model.curtainState)

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                 curtain: PrivacyCurtainState.up.rawValue,
                                 hostEvent: HostLifecycleEvent.recovered.rawValue), to: model)
        XCTAssertEqual(model.curtainState, .up)
        XCTAssertEqual(model.sessionNotice, PhoneSessionNotice.hostRecovered)

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                 curtain: PrivacyCurtainState.liftedLocally.rawValue,
                                 hostEvent: HostLifecycleEvent.recovered.rawValue), to: model)
        XCTAssertEqual(model.curtainState, .liftedLocally)
        XCTAssertEqual(model.sessionNotice, PhoneSessionNotice.curtainLiftedLocally,
                       "The recovery notice is shown once per session; the lift is news")

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                 curtain: "somethingNew"), to: model)
        XCTAssertEqual(model.curtainState, .off, "Unknown future states read as off")
    }

    func testDisconnectedAndStoppedCallbacksCannotAdoptCurtainStatus() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        defer { model.connection.stop() }
        let receive = try XCTUnwrap(model.connection.onControl)
        let status = RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                  curtain: PrivacyCurtainState.up.rawValue,
                                  hostEvent: HostLifecycleEvent.recovered.rawValue)
        let data = try JSONEncoder().encode(status)
        receive(data)
        XCTAssertNil(model.curtainState)
        XCTAssertNil(model.sessionNotice)
        model.connection.startInputFixtureForTesting(session: "curtain-retained-fixture")
        receive(data)
        XCTAssertEqual(model.curtainState, .up)
        XCTAssertEqual(model.sessionNotice, PhoneSessionNotice.hostRecovered)
        model.connection.stop()
        XCTAssertFalse(model.connection.connected)
        XCTAssertNil(model.curtainState)
        let previousNotice = model.sessionNotice
        let late = RemoteAction(action: "capture", x: 1, epoch: 2, features: SessionFeature.host,
                                curtain: PrivacyCurtainState.failed.rawValue)
        receive(try JSONEncoder().encode(late))
        XCTAssertNil(model.curtainState, "A retained callback cannot republish a curtain after Stop")
        XCTAssertEqual(model.sessionNotice, previousNotice, "A late failure cannot publish a new notice")
    }

    func testCurtainRequestsNeedALiveControlledSession() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.canChangeCurtain)
        XCTAssertFalse(model.setMacCurtain(true), "Nothing is sent without a connected Mac that allows control")
    }
}
