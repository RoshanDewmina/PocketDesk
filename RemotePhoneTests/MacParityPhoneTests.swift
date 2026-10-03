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
        // Incoming status can legitimately cause outgoing display/release traffic.
        model.connection.inputPacketSenderForTesting = { _ in true }
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

    func testAMacThatCannotHideItsScreenSaysSoOncePerSessionAcrossCaptureRestarts() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.connection.startInputFixtureForTesting(session: "curtain-unavailable-fixture")
        defer { model.connection.stop() }

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                 curtain: PrivacyCurtainState.unavailable.rawValue), to: model)
        XCTAssertEqual(model.curtainState, .unavailable)
        XCTAssertEqual(model.sessionNotice, PhoneSessionNotice.curtainUnavailable)

        // Every capture start (Big Text step, audio toggle, display switch, resume) sends a
        // preflight status without features, which momentarily reads as "no curtain".
        try deliver(RemoteAction(action: "capture", x: 0, epoch: 2), to: model)
        XCTAssertNil(model.curtainState)
        let shown = model.sessionNoticeGeneration
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2, features: SessionFeature.host,
                                 curtain: PrivacyCurtainState.unavailable.rawValue), to: model)
        XCTAssertEqual(model.curtainState, .unavailable)
        XCTAssertEqual(model.sessionNoticeGeneration, shown, "The Accessibility explanation is not repeated after a restart")

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2, features: SessionFeature.host,
                                 curtain: PrivacyCurtainState.up.rawValue), to: model)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2, features: SessionFeature.host,
                                 curtain: PrivacyCurtainState.liftedLocally.rawValue), to: model)
        XCTAssertEqual(model.sessionNoticeGeneration, shown + 1, "A lift at the Mac is still news every time")
    }

    func testDisconnectedAndStoppedCallbacksCannotAdoptCurtainStatus() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        // Incoming status can legitimately cause outgoing display/release traffic.
        model.connection.inputPacketSenderForTesting = { _ in true }
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

@MainActor
final class ShortcutChipsPhoneTests: XCTestCase {
    private func fixture(enabled: Bool = true, supporting: Bool = true) throws -> (PhoneRemoteModel, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shortcuts.phone.\(UUID().uuidString)"))
        defaults.set(enabled, forKey: ShortcutChips.defaultsKey)
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        model.prepareConnection(mode: .couch)
        model.connection.startInputFixtureForTesting(session: "shortcut-chips")
        var packets: [ControlPacket] = []
        model.connection.inputPacketSenderForTesting = { packets.append($0); return true }
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 2), model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: 2), model)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 2,
            interaction: NativeInteraction(token: "t", doubleClickInterval: 0.5),
            features: SessionFeature.host + [SessionFeature.couch] + (supporting ? [SessionFeature.shortcutChips] : []), mode: "couch"), model)
        var context = try XCTUnwrap(packets.first(where: { $0.input?.kind == "offer" })?.input)
        context.kind = "accept"; context.anchor = String(repeating: "a", count: 32)
        try model.connection.receiveInputFixtureForTesting(ControlPacket(session: "shortcut-chips", sequence: 1,
            action: RemoteAction(action: "heartbeat", epoch: 2), input: context))
        model.connection.inputPacketSenderForTesting = { _ in true }
        return (model, defaults)
    }
    private func deliver(_ action: RemoteAction, _ model: PhoneRemoteModel) throws {
        try XCTUnwrap(model.connection.onControl)(JSONEncoder().encode(action))
    }
    private func app(_ bundle: String = "com.google.Chrome", epoch: UInt64 = 2) -> RemoteAction {
        RemoteAction(action: "heartbeat", epoch: epoch, frontmostApp: FrontmostApp(bundleID: bundle, displayName: "Chrome"))
    }
    func testAppUpdatesRequireCapabilityCurrentEpochAndOnSwitch() throws {
        for (enabled, supporting) in [(false, true), (true, false)] {
            let (model, _) = try fixture(enabled: enabled, supporting: supporting)
            defer { model.disconnect() }
            try deliver(app(), model)
            XCTAssertNil(model.frontmostApp)
            XCTAssertTrue(model.shortcutChips.isEmpty)
            XCTAssertFalse(model.tapShortcut(ShortcutCatalog.generic[0]))
        }
        let (model, _) = try fixture()
        defer { model.disconnect() }
        XCTAssertEqual(model.shortcutChips, ShortcutCatalog.generic)
        try deliver(app(epoch: 1), model)
        XCTAssertNil(model.frontmostApp)
        try deliver(app(), model)
        XCTAssertEqual(model.frontmostApp?.bundleID, "com.google.Chrome")
        XCTAssertEqual(model.shortcutChips, ShortcutCatalog.chips(for: "com.google.Chrome"))
        try deliver(app("com.example.unknown"), model)
        XCTAssertEqual(model.shortcutChips, ShortcutCatalog.generic)
        try deliver(RemoteAction(action: "heartbeat", epoch: 2, frontmostApp: FrontmostApp(bundleID: nil, displayName: nil)), model)
        XCTAssertEqual(model.shortcutChips, ShortcutCatalog.generic)
        model.disconnect()
        XCTAssertNil(model.frontmostApp)
        XCTAssertTrue(model.shortcutChips.isEmpty)
    }
    func testOneTapSendsOneExplicitChordAndNeverLatchesModifiers() throws {
        let (model, _) = try fixture()
        defer { model.disconnect() }
        try deliver(app(), model)
        let chip = try XCTUnwrap(model.shortcutChips.first(where: { $0.key == "t" && $0.modifiers == ["command", "shift"] }))
        var actions: [RemoteAction] = []
        model.connection.inputPacketSenderForTesting = { actions.append($0.action); return true }
        model.modifiers = ["option", "control"]
        XCTAssertTrue(model.tapShortcut(chip))
        let sent = try XCTUnwrap(actions.first)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(sent.action, "key")
        XCTAssertEqual(sent.key, "t")
        XCTAssertEqual(sent.modifiers, chip.modifiers)
        XCTAssertEqual(sent.epoch, 2)
        XCTAssertTrue(model.modifiers.isEmpty)
    }
    func testSecureFocusViewOnlyAndRuntimeNoCannotSendChips() throws {
        let (model, defaults) = try fixture()
        defer { model.disconnect() }
        var actions: [RemoteAction] = []
        model.connection.inputPacketSenderForTesting = { actions.append($0.action); return true }
        let chip = ShortcutCatalog.generic[0]
        model.receiveSecureFocus(secure: true)
        XCTAssertTrue(model.shortcutChips.isEmpty)
        XCTAssertFalse(model.tapShortcut(chip))
        XCTAssertTrue(actions.isEmpty)
        model.receiveSecureFocus(secure: false)
        defaults.set(false, forKey: ShortcutChips.defaultsKey)
        XCTAssertTrue(model.shortcutChips.isEmpty)
        XCTAssertFalse(model.tapShortcut(chip))
        XCTAssertTrue(actions.isEmpty)
        defaults.set(true, forKey: ShortcutChips.defaultsKey)
        model.controlAllowed = false
        XCTAssertTrue(model.shortcutChips.isEmpty)
        XCTAssertFalse(model.tapShortcut(chip))
        XCTAssertTrue(actions.isEmpty)
    }
}
