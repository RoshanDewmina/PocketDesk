import XCTest
@testable import PocketDeskRemote

typealias SessionState = FarsideSessionAttributes.ContentState

final class SessionActivityMachineTests: XCTestCase {
    private var machine = SessionActivityMachine()
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(connected: Bool = true, reconnecting: Bool = false, holdEndsAt: Date? = nil, backgrounded: Bool = false,
                          route: FarsideSessionAttributes.Route? = nil,
                          endReason: FarsideSessionAttributes.EndReason? = nil) -> SessionSnapshot {
        SessionSnapshot(connected: connected, reconnecting: reconnecting, holdEndsAt: holdEndsAt,
                        backgrounded: backgrounded, route: route, endReason: endReason)
    }

    func testTheActivityStartsWhenTheSessionConnectsAndNeverRepeats() {
        XCTAssertNil(machine.reduce(snapshot(connected: false)), "Nothing to show before a session exists")
        XCTAssertEqual(machine.reduce(snapshot()), .start(.live()))
        XCTAssertNil(machine.reduce(snapshot()))
        XCTAssertNil(machine.reduce(snapshot()))
        XCTAssertTrue(machine.hasActivity)
    }

    func testLeavingTheAppPausesWithTheHoldDeadlineAndComingBackResumes() {
        _ = machine.reduce(snapshot())
        let ends = t0.addingTimeInterval(24)
        XCTAssertEqual(machine.reduce(snapshot(holdEndsAt: ends, backgrounded: true)), .update(.paused(graceEnds: ends)))
        XCTAssertNil(machine.reduce(snapshot(holdEndsAt: ends, backgrounded: true)))
        XCTAssertEqual(machine.reduce(snapshot()), .update(.live()), "Back within the hold: it never happened")
    }

    func testAHoldThatRunsOutEndsAsTimeoutWithTheReasonTheModelGave() {
        _ = machine.reduce(snapshot())
        _ = machine.reduce(snapshot(holdEndsAt: t0, backgrounded: true))
        XCTAssertEqual(machine.reduce(snapshot(connected: false, backgrounded: true, endReason: .timeout)), .end(.timeout))
        XCTAssertFalse(machine.hasActivity)
        XCTAssertNil(machine.reduce(snapshot(connected: false, backgrounded: true, endReason: .timeout)), "Only one end")
    }

    func testTheEndReasonFallsBackToWhereThePersonWas() {
        _ = machine.reduce(snapshot())
        XCTAssertEqual(machine.reduce(snapshot(connected: false, backgrounded: true)), .end(.timeout))
        _ = machine.reduce(snapshot())
        XCTAssertEqual(machine.reduce(snapshot(connected: false)), .end(.error))
    }

    func testEveryReasonEndsTheActivityWithThatReason() {
        for reason in [FarsideSessionAttributes.EndReason.user, .timeout, .macStopped, .error] {
            var machine = SessionActivityMachine()
            _ = machine.reduce(snapshot())
            XCTAssertEqual(machine.reduce(snapshot(connected: false, endReason: reason)), .end(reason))
        }
    }

    func testReconnectingShowsOnlyWhenThePhonesOwnReconnectEngagesAfterALiveSession() {
        XCTAssertNil(machine.reduce(snapshot(connected: false, reconnecting: true)),
                     "A first connection in progress is not a Live Activity")
        _ = machine.reduce(snapshot())
        XCTAssertEqual(machine.reduce(snapshot(connected: false, reconnecting: true)), .update(.reconnecting()))
        XCTAssertNil(machine.reduce(snapshot(connected: false, reconnecting: true)))
        XCTAssertEqual(machine.reduce(snapshot()), .update(.live()), "Reconnected: back to live")
    }

    func testAReconnectThatGivesUpEndsInsteadOfSpinningForever() {
        _ = machine.reduce(snapshot())
        _ = machine.reduce(snapshot(connected: false, reconnecting: true))
        XCTAssertEqual(machine.reduce(snapshot(connected: false, reconnecting: false)), .end(.error))
    }

    /// Renewing the lease, refreshing relay credentials and restarting ICE change none of the machine's
    /// inputs, so however many happen, the Lock Screen sees nothing.
    func testRenewalsAndCredentialRefreshesNeverChangeTheActivity() {
        _ = machine.reduce(snapshot(route: .relay))
        for _ in 0..<500 {
            XCTAssertNil(machine.reduce(snapshot(route: .relay)))
        }
        XCTAssertEqual(machine.current, .live(route: .relay))
    }

    func testARouteGapDuringAnIceRestartNeverBlanksTheRouteWord() {
        XCTAssertEqual(machine.reduce(snapshot(route: nil)), .start(.live(route: nil)))
        XCTAssertEqual(machine.reduce(snapshot(route: .relay)), .update(.live(route: .relay)))
        XCTAssertNil(machine.reduce(snapshot(route: nil)), "A statistics gap is not a change")
        XCTAssertNil(machine.reduce(snapshot(route: .relay)))
        XCTAssertEqual(machine.reduce(snapshot(route: .direct)), .update(.live(route: .direct)), "A real change still shows")
        XCTAssertEqual(machine.reduce(snapshot(holdEndsAt: t0, backgrounded: true, route: nil)), .update(.paused(graceEnds: t0, route: .direct)))
    }

    func testAnActivityEndedFromOutsideStartsFreshNextTime() {
        _ = machine.reduce(snapshot())
        machine.activityWasEnded()
        XCTAssertFalse(machine.hasActivity)
        XCTAssertEqual(machine.reduce(snapshot()), .start(.live()))
    }

    func testStaleDatesDistrustContentThatNothingRefreshes() {
        XCTAssertEqual(SessionActivityMachine.staleDate(for: .live(), now: t0), t0.addingTimeInterval(180))
        XCTAssertEqual(SessionActivityMachine.staleDate(for: .reconnecting(), now: t0), t0.addingTimeInterval(120))
        let grace = t0.addingTimeInterval(24)
        XCTAssertEqual(SessionActivityMachine.staleDate(for: .paused(graceEnds: grace), now: t0), grace.addingTimeInterval(5),
                       "A lost end goes stale just after the hold, never showing Paused forever")
        XCTAssertNil(SessionActivityMachine.staleDate(for: .ended(.user), now: t0))
        XCTAssertLessThan(SessionActivityMachine.keepAlive, 180, "The app refreshes a live state before it goes stale")
    }
}

final class SessionSnapshotTests: XCTestCase {
    private func derive(connected: Bool = false, running: Bool = false, status: String = "Ready to connect",
                        resume: ResumeState = .none, route: String? = nil) -> SessionSnapshot {
        SessionSnapshot.derive(connected: connected, running: running, status: status, resumeState: resume,
                               holdEndsAt: nil, routeName: route, endReason: nil)
    }

    func testReconnectingIsTheCoordinatorsOwnRetryAndNothingElse() {
        XCTAssertTrue(derive(running: true, status: "Connection interrupted · retrying…").reconnecting)
        XCTAssertTrue(derive(running: true, status: "Connecting securely…").reconnecting)
        XCTAssertTrue(derive(running: true, status: "Ready to connect", resume: .reconnecting).reconnecting)
        XCTAssertFalse(derive(running: false, status: "Connection interrupted · retrying…").reconnecting,
                       "A stopped coordinator is not reconnecting, whatever its last status said")
        XCTAssertFalse(derive(running: false, status: "Connection lost. Tap Connect to try again.").reconnecting)
        XCTAssertFalse(derive(running: false, status: "Disconnected").reconnecting)
        XCTAssertFalse(derive(connected: true, running: true, status: "Connection interrupted · retrying…").reconnecting,
                       "Connected means live, however the status reads for a moment")
    }

    func testRouteWordsAreCoarseAndUnknownOnesAreDropped() {
        XCTAssertEqual(derive(connected: true, route: "Direct").route, .direct)
        XCTAssertEqual(derive(connected: true, route: "Relay").route, .relay)
        XCTAssertNil(derive(connected: true, route: "Measuring…").route)
        XCTAssertNil(derive(connected: true, route: nil).route)
    }

    func testTheBackgroundedFlagFollowsTheResumeState() {
        XCTAssertTrue(derive(connected: true, resume: .backgrounded).backgrounded)
        XCTAssertFalse(derive(connected: true, resume: .none).backgrounded)
        XCTAssertFalse(derive(connected: true, resume: .reconnecting).backgrounded)
    }
}

@MainActor
final class FakeActivityClient: SessionActivityClient {
    enum Event: Equatable {
        case start(state: SessionState, stale: Date?)
        case update(state: SessionState, stale: Date?)
        case end(FarsideSessionAttributes.EndReason)
        case endStrays
    }

    var isEnabled = true
    var startSucceeds = true
    private(set) var events: [Event] = []
    private(set) var attributes: [FarsideSessionAttributes] = []

    func start(attributes: FarsideSessionAttributes, state: SessionState, staleDate: Date?) async -> Bool {
        self.attributes.append(attributes)
        events.append(.start(state: state, stale: staleDate))
        return startSucceeds
    }

    func update(state: SessionState, staleDate: Date?) async { events.append(.update(state: state, stale: staleDate)) }
    func end(reason: FarsideSessionAttributes.EndReason) async { events.append(.end(reason)) }
    func endStrays() async { events.append(.endStrays) }

    var withoutStrayCleanup: [Event] { events.filter { $0 != .endStrays } }
}

@MainActor
final class SessionActivityControllerTests: XCTestCase {
    private var client: FakeActivityClient!
    private var controller: SessionActivityController!
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        client = FakeActivityClient()
        defaults = makeTestDefaults("SessionActivityControllerTests")
        controller = SessionActivityController(client: client)
        controller.now = { [now] in now }
        controller.preferences = { [defaults] in AgentAlertPreferences(defaults: defaults!) }
        controller.identity = { ("m_0123456789abcdef", "Studio Mac") }
        controller.reconnectDelay = 0.05
        controller.keepAliveInterval = nil
    }

    private func live(route: FarsideSessionAttributes.Route? = nil) -> SessionSnapshot { SessionSnapshot(connected: true, route: route) }
    private var gone: SessionSnapshot { SessionSnapshot(connected: false) }

    func testItStartsAfterTheHandshakeWithGenericNamesAndAnOpaqueId() async throws {
        controller.apply(live())
        await controller.settle()
        XCTAssertEqual(client.events, [.endStrays, .start(state: .live(), stale: now.addingTimeInterval(180))])
        let attributes = try XCTUnwrap(client.attributes.first)
        XCTAssertEqual(attributes.macLabel, "Your Mac", "The name shows only if the person turned that on")
        XCTAssertEqual(attributes.macId, "m_0123456789abcdef")
        XCTAssertEqual(attributes.startedAtUnix, 1_790_000_000)
        XCTAssertFalse(attributes.isPreview)
        XCTAssertNil(attributes.preview)
        XCTAssertEqual(attributes.sessionId.count, 8)
    }

    func testTheMacNameAppearsOnlyWhenTheChoiceIsOn() async {
        AgentAlertPreferences(defaults: defaults).showMacNameOnLockScreen = true
        controller.apply(live())
        await controller.settle()
        XCTAssertEqual(client.attributes.first?.macLabel, "Studio Mac")
    }

    func testItNeverStartsWithoutPermissionAChoiceOrAMac() async {
        client.isEnabled = false
        controller.apply(live())
        await controller.settle()
        XCTAssertTrue(client.withoutStrayCleanup.isEmpty, "Live Activities are off in Settings")
        XCTAssertFalse(controller.hasActivity)

        client.isEnabled = true
        AgentAlertPreferences(defaults: defaults).sessionLiveActivity = false
        controller.apply(live())
        await controller.settle()
        XCTAssertTrue(client.withoutStrayCleanup.isEmpty, "The person turned the Lock Screen session off")

        AgentAlertPreferences(defaults: defaults).sessionLiveActivity = true
        controller.identity = { nil }
        controller.apply(live())
        await controller.settle()
        XCTAssertTrue(client.withoutStrayCleanup.isEmpty, "Nothing is paired")
    }

    func testAPausedHoldGoesStaleJustAfterItEndsAndTheEndCarriesItsReason() async {
        let ends = now.addingTimeInterval(24)
        controller.apply(live())
        controller.apply(SessionActivityMachineHelpers.paused(ends: ends))
        controller.apply(SessionSnapshot(connected: false, backgrounded: true, endReason: .timeout))
        await controller.settle()
        XCTAssertEqual(client.withoutStrayCleanup, [
            .start(state: .live(), stale: now.addingTimeInterval(180)),
            .update(state: .paused(graceEnds: ends), stale: ends.addingTimeInterval(5)),
            .end(.timeout)
        ])
        XCTAssertFalse(controller.hasActivity)
    }

    func testABlipShorterThanTheDelayNeverShowsReconnecting() async {
        controller.apply(live())
        await controller.settle()
        controller.apply(SessionSnapshot(connected: false, reconnecting: true))
        controller.apply(live())
        await controller.settle()
        XCTAssertEqual(client.withoutStrayCleanup, [.start(state: .live(), stale: now.addingTimeInterval(180))],
                       "A drop that heals inside the delay is invisible")
    }

    func testASustainedDropShowsReconnectingThenLiveAgain() async {
        controller.apply(live())
        controller.apply(SessionSnapshot(connected: false, reconnecting: true))
        await controller.settle()
        controller.apply(live())
        await controller.settle()
        XCTAssertEqual(client.withoutStrayCleanup, [
            .start(state: .live(), stale: now.addingTimeInterval(180)),
            .update(state: .reconnecting(), stale: now.addingTimeInterval(120)),
            .update(state: .live(), stale: now.addingTimeInterval(180))
        ])
    }

    func testKeepAliveRefreshesLiveAndReconnectingButNeverPausedOrEnded() async {
        controller.apply(live())
        await controller.settle()
        await controller.keepAliveTick()
        XCTAssertEqual(client.withoutStrayCleanup.last, .update(state: .live(), stale: now.addingTimeInterval(180)))
        let ends = now.addingTimeInterval(24)
        controller.apply(SessionActivityMachineHelpers.paused(ends: ends))
        await controller.settle()
        let count = client.events.count
        await controller.keepAliveTick()
        XCTAssertEqual(client.events.count, count, "A paused state has its own stale date")
    }

    func testTurningTheChoiceOffMidSessionEndsTheActivityAndDoesNotRestartIt() async {
        controller.apply(live())
        await controller.settle()
        AgentAlertPreferences(defaults: defaults).sessionLiveActivity = false
        controller.apply(live(route: .direct))
        await controller.settle()
        XCTAssertEqual(client.withoutStrayCleanup.last, .end(.user))
        let count = client.events.count
        controller.apply(live(route: .relay))
        await controller.settle()
        XCTAssertEqual(client.events.count, count)
        XCTAssertFalse(controller.hasActivity)
    }

    func testARefusedStartIsRetriedOnTheNextChange() async {
        client.startSucceeds = false
        controller.apply(live())
        await controller.settle()
        XCTAssertFalse(controller.hasActivity)
        client.startSucceeds = true
        controller.apply(live())
        await controller.settle()
        XCTAssertTrue(controller.hasActivity)
        XCTAssertEqual(client.events.filter { if case .start = $0 { true } else { false } }.count, 2)
    }

    func testLeftoversFromAnEarlierLaunchAreEndedWhenTheAppStarts() async {
        await controller.reconcileOnLaunch()
        XCTAssertEqual(client.events, [.endStrays])
    }

    func testTheSampleIsLabelledAndNeverStartsOverARealSession() async throws {
        controller.startPreview(hold: .paused)
        try await Task.sleep(nanoseconds: 100_000_000)
        let attributes = try XCTUnwrap(client.attributes.first)
        XCTAssertTrue(attributes.isPreview, "Sample content is labelled")
        XCTAssertEqual(attributes.macLabel, "Your Mac")
        XCTAssertEqual(attributes.macId, "m_preview")

        let before = client.attributes.count
        controller.apply(live())
        await controller.settle()
        controller.startPreview(hold: .live)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.attributes.count, before + 1, "Only the real session started; the sample stood aside")
        XCTAssertFalse(client.attributes.last?.isPreview ?? true)
    }

    func testThePreviewIsRefusedWhenLiveActivitiesAreOff() async throws {
        client.isEnabled = false
        controller.startPreview(hold: .live)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(client.events.isEmpty)
    }
}

enum SessionActivityMachineHelpers {
    static func paused(ends: Date) -> SessionSnapshot {
        SessionSnapshot(connected: true, holdEndsAt: ends, backgrounded: true)
    }
}
