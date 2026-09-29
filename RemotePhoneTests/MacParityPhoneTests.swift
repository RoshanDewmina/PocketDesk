import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacParityPhoneTests: XCTestCase {
    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    func testCurtainStateAndRecoveryNoticeFollowTheMacsStatus() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())

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

    func testCurtainRequestsNeedALiveControlledSession() {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        XCTAssertFalse(model.canChangeCurtain)
        XCTAssertFalse(model.setMacCurtain(true), "Nothing is sent without a connected Mac that allows control")
    }
}
