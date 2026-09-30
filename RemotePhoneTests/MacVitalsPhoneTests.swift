import XCTest
@testable import PocketDeskRemote

@MainActor
final class MacVitalsPhoneTests: XCTestCase {
    private let suite = "MacVitalsPhoneTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func model() -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.vitalsMemory = MacVitalsMemory(defaults: defaults)
        return model
    }

    private func send(_ vitals: MacVitals?, to model: PhoneRemoteModel, features: [String] = SessionFeature.host,
                      busy: BusyState? = nil) throws {
        let action = RemoteAction(action: "capture", x: 1, epoch: 1, features: features, busy: busy, macVitals: vitals)
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func battery(_ percent: Int, load: String = "ok") -> MacVitals {
        MacVitals(power: "battery", batteryPercent: percent, charging: false, batteryWarning: 1, thermal: 0,
                  lowPowerMode: false, load: load)
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
        model.connection.onEnded?()
        XCTAssertEqual(model.vitalsMemory.lastSeen(now: Date())?.percent, 4)
        XCTAssertNil(model.macVitals)
        XCTAssertFalse(model.macVitalsSupported)
    }

    func testAFailedAttemptKeepsTheLastSeenBattery() {
        let model = model()
        model.vitalsMemory.record(battery(4), at: Date())
        model.connection.onEnded?()
        XCTAssertEqual(model.vitalsMemory.lastSeen(now: Date())?.percent, 4,
                       "An attempt that never got a status knows nothing new about the battery")
    }

    func testAHealthySessionClearsTheLastSeen() throws {
        let model = model()
        model.vitalsMemory.record(battery(4), at: Date())
        try send(MacVitals(power: "ac", batteryPercent: 30, charging: true, load: "ok"), to: model)
        model.connection.onEnded?()
        XCTAssertNil(model.vitalsMemory.lastSeen(now: Date()))
    }

    func testANewSessionAnnouncesAgain() throws {
        let model = model()
        try send(battery(15), to: model)
        XCTAssertEqual(model.sessionNotice, MacVitalsNotice.low(15))
        model.connection.onEnded?()
        try send(battery(14), to: model)
        XCTAssertEqual(model.sessionNotice, MacVitalsNotice.low(14), "Ending the session resets the once-per-session notices")
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
                                         route: "Direct", roundTripMs: rtt, blocker: blocker, vitals: vitals)
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
