import XCTest
@testable import PocketDeskRemote

/// What a service would have to build byte for byte, and what the screen says. ActivityKit decodes pushed
/// state with default Codable strategies, so these pin the wire format.
final class SessionActivityWireTests: XCTestCase {
    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func matches(_ actual: [String: Any], _ expected: NSDictionary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual as NSDictionary, expected, file: file, line: line)
    }

    func testEveryStateEncodesToPlainStringsAndIntegers() throws {
        matches(try dictionary(SessionState.live(route: .direct)), ["phase": "live", "route": "direct"])
        matches(try dictionary(SessionState.paused(graceEnds: Date(timeIntervalSince1970: 1_790_000_045), route: .relay)),
                ["phase": "paused", "graceEndsAtUnix": 1_790_000_045, "route": "relay"])
        matches(try dictionary(SessionState.reconnecting()), ["phase": "reconnecting"])
        matches(try dictionary(SessionState.ended(.macStopped)), ["phase": "ended", "endedReason": "macStopped"])
        matches(try dictionary(SessionState.ended(.timeout)), ["phase": "ended", "endedReason": "timeout"])
    }

    func testAServiceCanBuildAStateByHandAndTheAppDecodesIt() throws {
        let pushed = #"{"phase":"ended","endedReason":"timeout"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: pushed), .ended(.timeout))
        let paused = #"{"phase":"paused","graceEndsAtUnix":1790000045,"route":"direct"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionState.self, from: paused)
        XCTAssertEqual(decoded.graceEndsAt, Date(timeIntervalSince1970: 1_790_000_045))
        let attributes = #"{"macId":"m_x","macLabel":"Your Mac","sessionId":"abc","startedAtUnix":1790000000}"#.data(using: .utf8)!
        let session = try JSONDecoder().decode(FarsideSessionAttributes.self, from: attributes)
        XCTAssertFalse(session.isPreview, "A real session omits the preview flag")
        XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testTheFieldsCannotCarryScreenContentTextOrLatency() throws {
        let full = SessionState(phase: .ended, graceEndsAtUnix: 1, route: .relay, endedReason: .error)
        XCTAssertEqual(Set(try dictionary(full).keys), ["phase", "graceEndsAtUnix", "route", "endedReason"])
        let attributes = FarsideSessionAttributes(macId: "m_x", macLabel: "Your Mac", sessionId: "s", startedAtUnix: 1, preview: true)
        XCTAssertEqual(Set(try dictionary(attributes).keys), ["macId", "macLabel", "sessionId", "startedAtUnix", "preview"])
    }

    func testStateStaysFarBelowTheFourKilobyteLimit() throws {
        let state = SessionState(phase: .paused, graceEndsAtUnix: 1_790_000_045, route: .relay, endedReason: .timeout)
        let attributes = FarsideSessionAttributes(macId: "m_0123456789abcdef", macLabel: String(repeating: "M", count: 128),
                                                  sessionId: "abcdef12", startedAtUnix: 1_790_000_000, preview: true)
        XCTAssertLessThan(try JSONEncoder().encode(state).count + JSONEncoder().encode(attributes).count, 512)
    }

    func testTheWidgetLinkIsTheSameRouteTheAppHandles() {
        XCTAssertEqual(FarsideRoute(url: SessionActivityLinks.session), .resumeSession)
        XCTAssertEqual(FarsideRoute.resumeSession.url, SessionActivityLinks.session)
    }

    // MARK: Words

    func testEveryStateSaysWhatItMeansInOneDeadpanClause() {
        typealias Copy = SessionActivityCopy
        XCTAssertEqual(Copy.title(for: .live()), "Holding your Mac")
        XCTAssertEqual(Copy.line(for: .live(route: .direct), macLabel: "Your Mac"), "Your Mac · direct")
        XCTAssertEqual(Copy.line(for: .live(route: .relay), macLabel: "Studio Mac"), "Studio Mac · relayed")
        XCTAssertEqual(Copy.line(for: .live(route: .local), macLabel: "Your Mac"), "Your Mac · same Wi-Fi")
        XCTAssertEqual(Copy.line(for: .live(), macLabel: "Your Mac"), "Your Mac")
        let grace = Date(timeIntervalSince1970: 1_790_000_024)
        XCTAssertEqual(Copy.title(for: .paused(graceEnds: grace)), "Mac on hold")
        XCTAssertEqual(Copy.line(for: .paused(graceEnds: grace), macLabel: "Your Mac"), "Farside lets go soon. Come back and it never happened.")
        XCTAssertEqual(Copy.title(for: .reconnecting()), "Reaching for your Mac")
        XCTAssertEqual(Copy.line(for: .reconnecting(), macLabel: "Your Mac"), "Hold on. It is a long way.")
        XCTAssertEqual(Copy.title(for: .ended(.user)), "Session ended")
        XCTAssertEqual(Copy.line(for: .ended(.user), macLabel: "Your Mac"), "Your Mac has its desk back.")
        XCTAssertEqual(Copy.title(for: .ended(.timeout)), "Let go of your Mac")
        XCTAssertEqual(Copy.line(for: .ended(.timeout), macLabel: "Your Mac"), "You were away, so Farside let go. Tap to reconnect.")
        XCTAssertEqual(Copy.title(for: .ended(.macStopped)), "Sharing stopped")
        XCTAssertEqual(Copy.line(for: .ended(.macStopped), macLabel: "Your Mac"), "It was stopped at the Mac.")
        XCTAssertEqual(Copy.title(for: .ended(.error)), "Session ended")
        XCTAssertEqual(Copy.line(for: .ended(.error), macLabel: "Your Mac"), "Something went wrong. Nothing was left open.")
    }

    func testAStaleActivityAdmitsItMayBeWrongInsteadOfFreezingOnLive() {
        XCTAssertEqual(SessionActivityCopy.title(for: .live(), stale: true), "Session ended?")
        XCTAssertEqual(SessionActivityCopy.line(for: .live(), macLabel: "Your Mac", stale: true), "Farside stopped updating. Open it to check.")
        XCTAssertEqual(SessionActivityCopy.accessibilitySummary(for: .live(), stale: true), "Farside. Session may have ended.")
    }

    func testNoWordOnAnySurfaceCarriesANumberOrALatencyFigure() {
        let states: [SessionState] = [.live(route: .direct), .live(route: .relay), .live(route: .local),
                                      .paused(graceEnds: Date(timeIntervalSince1970: 1_790_000_024), route: .direct),
                                      .reconnecting(route: .relay), .ended(.user), .ended(.timeout), .ended(.macStopped), .ended(.error)]
        for state in states {
            for stale in [false, true] {
                let words = [SessionActivityCopy.title(for: state, stale: stale),
                             SessionActivityCopy.line(for: state, macLabel: "Your Mac", stale: stale),
                             SessionActivityCopy.accessibilitySummary(for: state, stale: stale)]
                for text in words {
                    XCTAssertFalse(text.contains("ms"), "No latency in \(text)")
                    XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "No figures in \(text)")
                }
            }
        }
    }

    func testTheAccessibilitySummaryNamesTheStateWithoutTheMacName() {
        XCTAssertEqual(SessionActivityCopy.accessibilitySummary(for: .live()), "Farside. Connected to your Mac.")
        XCTAssertEqual(SessionActivityCopy.accessibilitySummary(for: .reconnecting()), "Farside. Reconnecting to your Mac.")
        XCTAssertEqual(SessionActivityCopy.accessibilitySummary(for: .ended(.timeout)), "Farside. Let go of your Mac.")
    }
}

@MainActor
final class ExpiringBackgroundExecution: BackgroundExecution {
    private(set) var isActive = false
    var remainingTime: TimeInterval? = 29
    private var onExpiration: (@MainActor () -> Void)?

    func begin(onExpiration: @escaping @MainActor () -> Void) -> Bool {
        self.onExpiration = onExpiration
        isActive = true
        return true
    }

    func end() {
        onExpiration = nil
        isActive = false
    }

    /// iOS ran out of background time.
    func expire() { onExpiration?() }
}

/// The real model, driven through the same paths the app uses.
@MainActor
final class SessionActivityModelTests: XCTestCase {
    private func capture(_ features: [String] = [SessionFeature.backgroundPause]) throws -> Data {
        try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, features: features))
    }

    func testALiveSessionThatLeavesTheAppIsPausedWithARealDeadlineThenEndsAsTimeout() throws {
        let background = ExpiringBackgroundExecution()
        let model = PhoneRemoteModel(background: background)
        model.sceneChanged(.active)
        model.connection.connected = true
        model.connection.onControl?(try capture())
        let live = model.sessionSnapshot
        XCTAssertTrue(live.connected)
        XCTAssertNil(live.holdEndsAt)
        XCTAssertFalse(live.backgrounded)

        model.sceneChanged(.background)
        let paused = model.sessionSnapshot
        XCTAssertTrue(paused.connected, "The hold keeps the session")
        XCTAssertTrue(paused.backgrounded)
        let ends = try XCTUnwrap(paused.holdEndsAt)
        XCTAssertEqual(ends.timeIntervalSinceNow, 24, accuracy: 3, "The hold is what iOS granted, minus the margin")

        background.expire()
        let ended = model.sessionSnapshot
        XCTAssertFalse(ended.connected)
        XCTAssertFalse(ended.reconnecting, "A released hold is over, not a reconnect")
        XCTAssertNil(ended.holdEndsAt)
        XCTAssertEqual(ended.endReason, .timeout)
    }

    func testAMacWithoutBackgroundPauseIsReleasedAtOnceAsTimeout() {
        let model = PhoneRemoteModel(background: ExpiringBackgroundExecution())
        model.sceneChanged(.active)
        model.connection.connected = true
        model.sceneChanged(.background)
        let snapshot = model.sessionSnapshot
        XCTAssertFalse(snapshot.connected)
        XCTAssertEqual(snapshot.endReason, .timeout)
        XCTAssertNil(snapshot.holdEndsAt)
    }

    func testPressingEndIsRecordedAsTheUserEndingIt() {
        let model = PhoneRemoteModel(background: ExpiringBackgroundExecution())
        model.connection.connected = true
        model.disconnect()
        let snapshot = model.sessionSnapshot
        XCTAssertFalse(snapshot.connected)
        XCTAssertFalse(snapshot.reconnecting)
        XCTAssertEqual(snapshot.endReason, .user)
    }

    /// The coordinator renews the room lease, refreshes relay credentials and restarts ICE on the Mac's
    /// side while the session stays connected. On the phone that touches its route diagnostics and relay
    /// flag, never anything the snapshot reads.
    func testWhatRenewalTouchesOnThePhoneNeverMovesTheSnapshot() {
        let model = PhoneRemoteModel(background: ExpiringBackgroundExecution())
        model.connection.connected = true
        let before = model.sessionSnapshot
        model.connection.diagnostics = "Route: relay · udp"
        model.connection.hasRelay = true
        model.connection.diagnostics = "Route: relay · udp · refreshed"
        model.connection.hasRelay = false
        XCTAssertEqual(model.sessionSnapshot, before)
    }

    /// Model and hub together, as the app runs them: a change on the model reaches the client.
    func testTheHubTurnsModelChangesIntoLockScreenChanges() async throws {
        let client = FakeActivityClient()
        let controller = SessionActivityController(client: client)
        let defaults = makeTestDefaults("SessionActivityHub")
        controller.preferences = { AgentAlertPreferences(defaults: defaults) }
        controller.keepAliveInterval = nil
        let hub = FarsideSystemIntegrations(activity: controller)
        let model = PhoneRemoteModel(background: ExpiringBackgroundExecution())
        hub.attach(model)
        hub.macIdentity = { ("m_0123456789abcdef", "Studio Mac") }
        addTeardownBlock { @MainActor in
            SessionIntentBridge.shared.handler = nil
            MacStatusService.shared.currentSession = { (false, false) }
            AgentAlertCenter.shared.isSessionLive = { false }
        }

        model.connection.connected = true
        try await Task.sleep(nanoseconds: 200_000_000)
        await controller.settle()
        XCTAssertTrue(client.events.contains { if case .start = $0 { true } else { false } }, "The handshake starts the activity")

        model.disconnect()
        try await Task.sleep(nanoseconds: 200_000_000)
        await controller.settle()
        XCTAssertEqual(client.events.last, .end(.user))
        XCTAssertFalse(controller.hasActivity)
    }
}
