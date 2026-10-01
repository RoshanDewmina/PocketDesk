import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacVitalsPhoneTests: XCTestCase {
    private let suite = "MacVitalsPhoneTests"
    private var defaults: UserDefaults!
    private var models: [PhoneRemoteModel] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        models.forEach { $0.connection.stop() }
        models.removeAll()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func model(connected: Bool = true) -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.vitalsMemory = MacVitalsMemory(defaults: defaults)
        models.append(model)
        // Keep the injected session bidirectional when capture requests displays.
        model.connection.inputPacketSenderForTesting = { _ in true }
        if connected { model.connection.startInputFixtureForTesting(session: "vitals-status-fixture") }
        return model
    }

    private func send(_ vitals: MacVitals?, to model: PhoneRemoteModel, features: [String] = SessionFeature.host,
                      busy: BusyState? = nil) throws {
        let action = RemoteAction(action: "capture", x: 1, epoch: 1, features: features, busy: busy, macVitals: vitals)
        let receive = try XCTUnwrap(model.connection.onControl)
        receive(try JSONEncoder().encode(action))
    }

    private func battery(_ percent: Int, load: String = "ok") -> MacVitals {
        MacVitals(power: "battery", batteryPercent: percent, charging: false, batteryWarning: 1, thermal: 0,
                  lowPowerMode: false, load: load)
    }

    // MARK: Per Mac

    func testLastReachedIsKeptPerMac() throws {
        let studio = Date(timeIntervalSince1970: 1_790_000_000), laptop = studio.addingTimeInterval(600)
        XCTAssertNil(LastReached.date(room: "studio-room", in: defaults))
        LastReached.record(studio, room: "studio-room", in: defaults)
        LastReached.record(laptop, room: "laptop-room", in: defaults)
        XCTAssertEqual(LastReached.date(room: "studio-room", in: defaults), studio, "Reaching another Mac never changes this one")
        XCTAssertEqual(LastReached.date(room: "laptop-room", in: defaults), laptop)
        LastReached.forget(room: "laptop-room", in: defaults)
        XCTAssertNil(LastReached.date(room: "laptop-room", in: defaults))
        XCTAssertEqual(LastReached.date(room: "studio-room", in: defaults), studio)
        XCTAssertNil(LastReached.date(room: nil, in: defaults))
        let stored = try XCTUnwrap(defaults.dictionary(forKey: LastReached.defaultsKey))
        XCTAssertFalse(stored.keys.contains("studio-room"), "Keyed by a digest, never the room")
    }

    func testTheOldSharedLastReachedMovesToTheSelectedMacOnce() {
        let legacy = Date(timeIntervalSince1970: 1_790_000_000)
        defaults.set(legacy.timeIntervalSince1970, forKey: LastReached.legacyDefaultsKey)
        LastReached.adoptLegacy(room: "studio-room", in: defaults)
        XCTAssertEqual(LastReached.date(room: "studio-room", in: defaults), legacy)
        XCTAssertNil(defaults.object(forKey: LastReached.legacyDefaultsKey))
        LastReached.adoptLegacy(room: "laptop-room", in: defaults)
        XCTAssertNil(LastReached.date(room: "laptop-room", in: defaults))
    }

    func testMacStatusSpeaksTheAskedMacsLastReached() throws {
        let studio = try TestPairing.mac(name: "Studio Mac"), laptop = try TestPairing.mac(name: "Laptop")
        let reached = Date(timeIntervalSince1970: 1_790_000_000)
        LastReached.record(reached, room: studio.invitation?.room, in: defaults)
        let service = MacStatusService()
        service.lastReached = { LastReached.date(room: $0.invitation?.room, in: self.defaults) }
        XCTAssertTrue(service.report(for: studio, outcome: .notAnswering).spoken.contains("since"))
        XCTAssertEqual(service.report(for: laptop, outcome: .notAnswering).spoken,
                       "I could not reach Laptop. It may be asleep, off or offline.")
    }

    // MARK: Model

    func testVitalsNeedTheFeature() throws {
        let model = model()
        try send(battery(64), to: model, features: SessionFeature.host.filter { $0 != SessionFeature.macVitals })
        XCTAssertFalse(model.macVitalsSupported)
        XCTAssertNil(model.currentMacVitals())
        XCTAssertNil(model.macVitals)
    }

    func testVitalsLastOnlyWhileStatusIsFresh() throws {
        let model = model()
        try send(battery(64), to: model)
        XCTAssertTrue(model.macVitalsSupported)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(model.currentMacVitals(now: now), battery(64))
        XCTAssertNil(model.currentMacVitals(now: now + PhoneRemoteModel.macVitalsMaxAge + 1))
    }

    func testAStatusWithoutVitalsClearsThem() throws {
        let model = model()
        try send(battery(64), to: model)
        try send(nil, to: model)
        XCTAssertNil(model.currentMacVitals())
    }

    func testUnplugNoticeReachesTheSession() throws {
        let model = model()
        try send(MacVitals(power: "ac", batteryPercent: 64, charging: true, load: "ok"), to: model)
        try send(battery(64), to: model)
        XCTAssertEqual(model.sessionNotice, "Your Mac is now on battery · 64%.")
    }

    func testAPowerPillHoldsTheUnplugNotice() throws {
        let model = model()
        let pill = BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "power")
        try send(MacVitals(power: "ac", batteryPercent: 64, charging: true, load: "ok"), to: model, busy: pill)
        try send(battery(64), to: model, busy: pill)
        XCTAssertNil(model.sessionNotice)
    }

    func testSessionEndRemembersALowBattery() throws {
        let model = model()
        try send(battery(4), to: model)
        model.connection.stop()
        XCTAssertEqual(model.vitalsMemory.lastSeen(room: nil, now: Date())?.percent, 4)
        XCTAssertNil(model.macVitals)
        XCTAssertFalse(model.macVitalsSupported)
    }

    func testAFailedAttemptKeepsTheLastSeenBattery() {
        let model = model(connected: false)
        model.vitalsMemory.record(battery(4), at: Date(), room: nil)
        model.connection.stop()
        XCTAssertEqual(model.vitalsMemory.lastSeen(room: nil, now: Date())?.percent, 4,
                       "An attempt that never got a status knows nothing new about the battery")
    }

    func testTheMacsSleepReportKeepsTheLastSeenBattery() throws {
        let model = model()
        try send(battery(4), to: model)
        let sleeping = RemoteAction(action: "capture", x: 0, epoch: 1, features: SessionFeature.host, hostState: "sleeping")
        let receive = try XCTUnwrap(model.connection.onControl)
        receive(try JSONEncoder().encode(sleeping))
        model.connection.stop()
        XCTAssertEqual(model.vitalsMemory.lastSeen(room: nil, now: Date())?.percent, 4,
                       "The Mac's last status before sleeping carries no vitals and must not erase the reading")
        XCTAssertEqual(model.lastDeparture, .sleeping)
    }

    func testAnOlderMacKeepsTheLastSeenBattery() throws {
        let model = model()
        model.vitalsMemory.record(battery(4), at: Date(), room: nil)
        try send(nil, to: model, features: SessionFeature.host.filter { $0 != SessionFeature.macVitals })
        model.connection.stop()
        XCTAssertEqual(model.vitalsMemory.lastSeen(room: nil, now: Date())?.percent, 4,
                       "A Mac that never reports vitals knows nothing new about the battery")
    }

    func testAHealthySessionClearsTheLastSeen() throws {
        let model = model()
        model.vitalsMemory.record(battery(4), at: Date(), room: nil)
        try send(MacVitals(power: "ac", batteryPercent: 30, charging: true, load: "ok"), to: model)
        model.connection.stop()
        XCTAssertNil(model.vitalsMemory.lastSeen(room: nil, now: Date()))
    }

    func testANewSessionAnnouncesAgain() throws {
        let model = model()
        try send(battery(15), to: model)
        XCTAssertEqual(model.sessionNotice, MacVitalsNotice.low(15))
        model.connection.stop()
        XCTAssertFalse(model.connection.connected)
        model.connection.startInputFixtureForTesting(session: "vitals-next-session-fixture")
        try send(battery(14), to: model)
        XCTAssertEqual(model.sessionNotice, MacVitalsNotice.low(14), "Ending the session resets the once-per-session notices")
    }

    func testDisconnectedAndStoppedCallbacksCannotAdoptOrRememberVitals() throws {
        let model = model(connected: false)
        let receive = try XCTUnwrap(model.connection.onControl)
        let initial = RemoteAction(action: "capture", x: 1, epoch: 1,
                                   features: SessionFeature.host, macVitals: battery(64))
        let data = try JSONEncoder().encode(initial)
        receive(data)
        XCTAssertNil(model.currentMacVitals())
        XCTAssertNil(model.macVitals)
        XCTAssertNil(model.sessionNotice)
        model.connection.startInputFixtureForTesting(session: "vitals-retained-fixture")
        receive(data)
        XCTAssertEqual(model.currentMacVitals(), battery(64))
        model.connection.stop()
        XCTAssertFalse(model.connection.connected)
        let late = RemoteAction(action: "capture", x: 1, epoch: 2,
                                features: SessionFeature.host, macVitals: battery(4))
        receive(try JSONEncoder().encode(late))
        XCTAssertNil(model.currentMacVitals())
        XCTAssertNil(model.macVitals)
        XCTAssertNil(model.sessionNotice, "A late low-battery status cannot publish a new notice")
        model.connection.stop()
        XCTAssertNil(model.vitalsMemory.lastSeen(room: nil, now: Date()), "A late status cannot become remembered battery evidence")
    }

    #if DEBUG
    func testPreviewForLayoutChecks() {
        let model = model()
        model.previewVitalsForTesting(MacVitalsPresentation.preview("battery12"), supported: true)
        XCTAssertTrue(model.previewingVitals)
        XCTAssertTrue(model.macVitalsSupported)
        XCTAssertEqual(model.currentMacVitals(now: .greatestFiniteMagnitude), MacVitalsPresentation.preview("battery12"))
        model.previewVitalsForTesting(nil, supported: false)
        XCTAssertFalse(model.macVitalsSupported)
    }
    #endif

    // MARK: Connection Health

    private func evidence(fresh: Bool = true, rtt: Int? = nil, blocker: MacShareBlocker? = nil,
                          vitals: MacVitals?) -> ConnectionHealth.SessionEvidence {
        ConnectionHealth.SessionEvidence(connected: true, fresh: fresh, captureHealthy: true, hostPresence: nil,
                                         route: "Direct", slowRoundTripMs: rtt, blocker: blocker, vitals: vitals)
    }

    func testLowBatteryRanksAfterPictureAndAccessibilityAndBeforeTheNetwork() throws {
        XCTAssertEqual(ConnectionHealth.session(evidence(fresh: false, vitals: battery(8)))?.state, .pictureStalled)
        XCTAssertEqual(ConnectionHealth.session(evidence(blocker: .accessibilityOff, vitals: battery(8)))?.state, .accessibilityOff)
        let low = try XCTUnwrap(ConnectionHealth.session(evidence(rtt: 400, vitals: battery(8))))
        XCTAssertEqual(low.state, .macBatteryLow)
        XCTAssertEqual(low.title, "Mac battery low")
        XCTAssertEqual(low.sessionLine, "Mac battery low · plug it in")
        XCTAssertTrue(low.detail.contains("8%"))
        XCTAssertFalse(low.isSlowOnly, "A battery about to run out outranks 'Controlling your Mac'")
    }

    func testBusyMacIsAdvisoryAndBeatsASlowNetwork() throws {
        let busy = try XCTUnwrap(ConnectionHealth.session(evidence(rtt: 400, vitals: battery(64, load: "busy"))))
        XCTAssertEqual(busy.state, .macUnderLoad)
        XCTAssertEqual(busy.title, "Mac busy")
        XCTAssertEqual(busy.sessionLine, "Mac busy · other apps are using it")
        XCTAssertTrue(busy.isSlowOnly)
        XCTAssertFalse(busy.detail.isEmpty)
        XCTAssertFalse(busy.nextStep.isEmpty)
        var memory = battery(64, load: "busy")
        memory.loadCause = "memory"
        XCTAssertTrue(try XCTUnwrap(ConnectionHealth.session(evidence(vitals: memory))).detail.contains("memory"))
    }

    func testOnlyALowBatteryOnBatteryIsAProblem() {
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: battery(11))))
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: MacVitals(power: "ac", batteryPercent: 5, charging: true))))
        var final = battery(30)
        final.batteryWarning = 3
        XCTAssertEqual(ConnectionHealth.session(evidence(vitals: final))?.state, .macBatteryLow)
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: MacVitals(thermal: 3, lowPowerMode: true))),
                     "Heat and Low Power Mode are the pill's and the caption's to say")
    }

    func testNoVitalsKeepsTodaysOrder() {
        XCTAssertEqual(ConnectionHealth.session(evidence(rtt: 400, vitals: nil))?.state, .networkSlow)
        XCTAssertNil(ConnectionHealth.session(evidence(vitals: nil)))
    }
}
