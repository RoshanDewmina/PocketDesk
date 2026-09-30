import XCTest
@testable import PocketDeskRemote

@MainActor
final class SharedCaptureScopePhoneTests: XCTestCase {
    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func connected() throws -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.prepareConnection(mode: .picture)
        model.connection.connected = true
        try deliver(RemoteAction(action: "geometry", x: 800, y: 600, epoch: 2), to: model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), to: model)
        return model
    }

    func testNarrowScopeOverridesControlTokensFeaturesAndAudioRequests() throws {
        let model = try connected()
        let scope = CaptureScopeFrame(epoch: 4, kind: .window, label: "Shared window", viewOnly: true)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2,
            interaction: NativeInteraction(token: "unexpected-token", doubleClickInterval: 0.5),
            features: SessionFeature.host + [SessionFeature.couch, SessionFeature.displayScale],
            mode: "picture", captureScope: scope), to: model)
        model.frameReceived()
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), to: model)
        XCTAssertTrue(model.captureScopeViewOnly)
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.controlAllowed)
        XCTAssertFalse(model.clipboardAvailable)
        XCTAssertFalse(model.fileTransferAvailable)
        XCTAssertFalse(model.canChooseDisplay)
        XCTAssertFalse(model.curtainSupported)
        model.setMacAudioMuted(false)
        XCTAssertTrue(model.macAudioMuted, "Narrow content cannot start an all-app output playback session")
        XCTAssertEqual(model.captureScopeDescription, "Shared window · view only · audio off")
    }

    func testLateBroadScopeCannotWidenCurrentScope() throws {
        let model = try connected()
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2, features: SessionFeature.host,
            mode: "picture", captureScope: .init(epoch: 5, kind: .application, label: "Shared application", viewOnly: true)), to: model)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2, features: SessionFeature.host,
            mode: "picture", captureScope: .init(epoch: 4, kind: .display, label: "Entire display", viewOnly: false)), to: model)
        XCTAssertEqual(model.sharedCaptureScope?.kind, .application)
        XCTAssertTrue(model.captureScopeViewOnly)
    }

    func testOldDisplayPeerWithoutAnnotationRetainsExistingPictureBehavior() throws {
        let model = try connected()
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2,
            interaction: NativeInteraction(token: "legacy-display-token", doubleClickInterval: 0.5),
            features: SessionFeature.host, mode: "picture"), to: model)
        model.frameReceived()
        XCTAssertNil(model.sharedCaptureScope)
        XCTAssertTrue(model.canControl)
        model.disconnect()
        XCTAssertNil(model.sharedCaptureScope)
        XCTAssertTrue(model.macAudioMuted)
    }
}
