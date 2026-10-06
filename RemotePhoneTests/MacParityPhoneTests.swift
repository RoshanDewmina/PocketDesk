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

/// Real admitted model/coordinator packets; the DEBUG input probe is deliberately absent.
@MainActor
final class OpenAppPhoneTests: XCTestCase {
    private final class Recorder {
        var packets: [ControlPacket] = []
        var accepts = true
    }
    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        try XCTUnwrap(model.connection.onControl)(JSONEncoder().encode(action))
    }
    private func admit(_ model: PhoneRemoteModel, recorder: Recorder, session: String,
                       epoch: UInt64, token: String) throws {
        model.prepareConnection(mode: .picture)
        model.sceneChanged(.active)
        model.connection.startInputFixtureForTesting(session: session)
        model.connection.inputPacketSenderForTesting = { recorder.packets.append($0); return recorder.accepts }
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: epoch), to: model)
        try deliver(RemoteAction(action: "viewing", x: 1, epoch: epoch), to: model)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: epoch,
            interaction: NativeInteraction(token: token, doubleClickInterval: 0.5),
            features: SessionFeature.host,
            mode: "picture"), to: model)
        model.frameReceived()
        var context = try XCTUnwrap(recorder.packets.last(where: { $0.input?.kind == "offer" })?.input)
        context.kind = "accept"; context.anchor = String(repeating: "a", count: 32)
        try model.connection.receiveInputFixtureForTesting(ControlPacket(session: session, sequence: 1,
            action: RemoteAction(action: "heartbeat", epoch: epoch), input: context))
        XCTAssertNil(model.inputProbe)
        XCTAssertTrue(model.canOpenMacApp)
        recorder.packets.removeAll()
    }
    private func fixture() throws -> (PhoneRemoteModel, Recorder) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "open-app.\(UUID().uuidString)"))
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), preferences: defaults,
            coordinator: RemoteCoordinator(isHost: false, store: MemoryStore()))
        let recorder = Recorder()
        try admit(model, recorder: recorder, session: "open-app", epoch: 2, token: "navigation-token")
        return (model, recorder)
    }
    private func assertDenied(_ model: PhoneRemoteModel, recorder: Recorder,
                              file: StaticString = #filePath, line: UInt = #line) {
        recorder.packets.removeAll()
        let draft = model.draft, composing = model.isComposingText
        let latches = model.modifiers, revision = model.autoKeyboardRevision
        XCTAssertFalse(model.canOpenMacApp, file: file, line: line)
        XCTAssertFalse(model.openMacApp(), file: file, line: line)
        XCTAssertTrue(recorder.packets.isEmpty, "Denied intent must not queue or retry input", file: file, line: line)
        XCTAssertEqual(model.draft, draft, file: file, line: line)
        XCTAssertEqual(model.isComposingText, composing, file: file, line: line)
        XCTAssertEqual(model.modifiers, latches, file: file, line: line)
        XCTAssertEqual(model.autoKeyboardRevision, revision, file: file, line: line)
    }

    func testOpenAppSendsExactlyCurrentCommandSpaceAndKeepsDraftLocal() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        let draft = "Local draft\ncafé 🧪"
        model.draft = draft
        model.modifiers = ["option", "control"]
        model.hardwareModifiers = ["shift"]
        let revision = model.autoKeyboardRevision
        XCTAssertTrue(model.openMacApp())
        XCTAssertEqual(recorder.packets.count, 1)
        let packet = try XCTUnwrap(recorder.packets.first)
        XCTAssertEqual(packet.session, "open-app")
        XCTAssertEqual(packet.action.action, "key")
        XCTAssertEqual(packet.action.key, "space")
        XCTAssertEqual(packet.action.modifiers, ["command"])
        XCTAssertEqual(packet.action.epoch, 2)
        XCTAssertEqual(packet.action.interaction?.token, "navigation-token")
        XCTAssertNil(packet.action.interaction?.hold)
        XCTAssertEqual(packet.input?.epoch, 2)
        XCTAssertEqual(packet.input?.anchor, String(repeating: "a", count: 32))
        XCTAssertTrue(packet.action.text.isEmpty)
        XCTAssertTrue(model.modifiers.isEmpty)
        XCTAssertEqual(model.hardwareModifiers, ["shift"], "Hardware modifiers retain their own lifetime")
        XCTAssertEqual(model.draft, draft)
        XCTAssertFalse(model.isComposingText)
        XCTAssertTrue(model.textEditable)
        XCTAssertEqual(model.autoKeyboardRevision, revision)
    }

    func testOpenAppSenderRefusalDoesNotRetryOrCommitDraft() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        model.draft = "Do not send\n秘密"
        model.modifiers = ["option"]
        recorder.accepts = false
        XCTAssertFalse(model.openMacApp())
        XCTAssertEqual(recorder.packets.map { $0.action.action }, ["key"])
        XCTAssertEqual(recorder.packets.first?.action.key, "space")
        XCTAssertEqual(recorder.packets.first?.action.modifiers, ["command"])
        XCTAssertTrue(model.modifiers.isEmpty, "Explicit admitted intent clears toolbar latches even on sender refusal")
        XCTAssertEqual(model.draft, "Do not send\n秘密")
        XCTAssertTrue(model.textEditable)
    }

    func testOpenAppRefusesHeldMouseWithoutReleasingIt() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        model.drag()
        XCTAssertTrue(model.dragging)
        XCTAssertEqual(recorder.packets.last?.action.action, "dragDown")
        model.modifiers = ["option"]
        assertDenied(model, recorder: recorder)
        XCTAssertTrue(model.dragging)
        XCTAssertNotNil(model.explicitHoldDeadline)
        // A stale presentation flag cannot bypass the actual private hold identity.
        model.dragging = false
        assertDenied(model, recorder: recorder)
        model.release()
        XCTAssertTrue(model.canOpenMacApp)
        recorder.packets.removeAll()
        XCTAssertTrue(model.openMacApp())
        XCTAssertEqual(recorder.packets.map { $0.action.key }, ["space"])
    }

    func testOpenAppRefusesCompositionAndPendingCommittedText() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        model.draft = "marked候補"
        model.isComposingText = true
        assertDenied(model, recorder: recorder)
        model.isComposingText = false
        model.sendText()
        XCTAssertFalse(model.textEditable)
        XCTAssertEqual(recorder.packets.last?.action.action, "text")
        assertDenied(model, recorder: recorder)
    }

    func testOpenAppRefusesPendingVoiceCommitWithoutChangingDraft() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        model.draft = "Keep local draft"
        XCTAssertTrue(model.sendVoiceText("pending voice"))
        XCTAssertEqual(model.voiceDeliveryStatus, .waiting)
        assertDenied(model, recorder: recorder)
        XCTAssertEqual(model.draft, "Keep local draft")
        XCTAssertEqual(model.voiceDeliveryStatus, .waiting)
    }

    func testOpenAppRechecksControlFreshnessAndSceneAtInvocation() throws {
        let mutations: [(String, (PhoneRemoteModel) -> Void)] = [
            ("control", { $0.controlAllowed = false }),
            ("fresh picture", { $0.fresh = false }),
            ("capture", { $0.captureHealthy = false }),
            ("drag presentation", { $0.dragging = true }),
            ("inactive", { $0.sceneChanged(.inactive) }),
            ("background", { $0.sceneChanged(.background) })
        ]
        for (name, mutate) in mutations {
            let (model, recorder) = try fixture()
            defer { model.disconnect() }
            model.draft = "local " + name
            mutate(model)
            model.modifiers = ["control"]
            assertDenied(model, recorder: recorder)
        }
    }

    func testOpenAppRejectsMissingAndExpiredNativeTokens() throws {
        for missing in [true, false] {
            let (model, recorder) = try fixture()
            defer { model.disconnect() }
            if missing {
                try deliver(RemoteAction(action: "capture", x: 1, epoch: 2,
                    interaction: NativeInteraction(token: nil, doubleClickInterval: 0.5),
                    features: SessionFeature.host, mode: "picture"), to: model)
            } else {
                // Existing deterministic clock seam ages the token by at most 0.5 s per call.
                for _ in 0..<3 { model.ageCouchStatusForTesting(by: 0.5) }
            }
            XCTAssertTrue(model.fresh)
            XCTAssertTrue(model.captureHealthy)
            assertDenied(model, recorder: recorder)
        }
    }

    func testOpenAppRejectsRetiredGeometryUntilCurrentAdmission() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        try deliver(RemoteAction(action: "geometry", x: 1200, y: 800, epoch: 3), to: model)
        model.frameReceived() // A decoded picture alone cannot restore the retired native token.
        assertDenied(model, recorder: recorder)
    }

    func testOpenAppRejectsScopedViewAndPendingLock() throws {
        for locked in [false, true] {
            let (model, recorder) = try fixture()
            defer { model.disconnect() }
            if locked {
                let request = PhoneAwayLockRequest(hostKey: "fixture-host", session: model.connection.presentationSessionID,
                    epoch: 2, sentAt: ProcessInfo.processInfo.systemUptime)
                XCTAssertTrue(model.sendAdmittedLockMacForTesting(request))
                XCTAssertTrue(model.lockMacPendingForTesting)
            } else {
                try deliver(RemoteAction(action: "capture", x: 1, epoch: 2,
                    interaction: NativeInteraction(token: "navigation-token", doubleClickInterval: 0.5),
                    features: SessionFeature.host, mode: "picture",
                    captureScope: .init(epoch: 4, kind: .window, label: "Shared window", viewOnly: true)), to: model)
                XCTAssertTrue(model.captureScopeViewOnly)
            }
            assertDenied(model, recorder: recorder)
        }
    }

    func testOpenAppRequiresNewSessionAdmissionAfterEnd() throws {
        let (model, recorder) = try fixture()
        defer { model.disconnect() }
        model.disconnect()
        assertDenied(model, recorder: recorder)
        model.connection.startInputFixtureForTesting(session: "replacement-unadmitted")
        assertDenied(model, recorder: recorder)
        model.connection.stop()
        try admit(model, recorder: recorder, session: "replacement", epoch: 9, token: "replacement-token")
        XCTAssertTrue(model.openMacApp())
        XCTAssertEqual(recorder.packets.count, 1)
        XCTAssertEqual(recorder.packets.first?.session, "replacement")
        XCTAssertEqual(recorder.packets.first?.action.epoch, 9)
        XCTAssertEqual(recorder.packets.first?.action.interaction?.token, "replacement-token")
    }

}
