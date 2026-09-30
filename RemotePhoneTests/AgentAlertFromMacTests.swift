import UserNotifications
import XCTest
@testable import PocketDeskRemote

/// An alert the Mac sends over the control channel while a session is live: one quiet banner with the app
/// in front, the notification a push would have been while the app holds the session in the background.
@MainActor
final class AgentAlertFromMacTests: XCTestCase {
    private var fake: FakeNotificationCenter!
    private var defaults: UserDefaults!
    private var center: AgentAlertCenter!
    private var appInFront = true
    private let clock = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        fake = FakeNotificationCenter()
        defaults = makeTestDefaults("AgentAlertFromMacTests")
        center = AgentAlertCenter(center: fake, defaults: defaults, reports: AgentAlertReports())
        center.now = { [clock] in clock }
        center.currentPairingIdentity = { String(repeating: "a", count: 64) }
        center.isForeground = { [unowned self] in appInFront }
        center.preferences.alertsEnabled = true
        appInFront = true
    }

    override func tearDown() {
        center.dismissBanner()
        super.tearDown()
    }

    private func frame(_ id: String = "h_0a1b2c3d4e5f", kind: AgentKind = .claudeCode) -> AgentAlertFrame {
        AgentAlertFrame(id: id, kind: kind, event: .needsUser, raisedAt: clock)
    }

    private func scheduled() async -> [UNNotificationRequest] {
        for _ in 0..<50 where fake.added.isEmpty { await Task.yield() }
        return fake.added
    }

    func testWithTheAppInFrontTheAlertIsOneQuietBannerOverThePicture() {
        center.receive(fromMac: frame())
        XCTAssertEqual(center.banner?.id, "h_0a1b2c3d4e5f")
        XCTAssertEqual(center.banner?.payload.kind, .claudeCode)
        XCTAssertEqual(center.banner?.receivedAt, clock)
        XCTAssertTrue(fake.added.isEmpty, "The picture already shows the Mac: nothing is scheduled")
        XCTAssertNil(center.presentation, "A banner never takes over the screen")
    }

    func testWhileTheAppHoldsTheSessionInTheBackgroundItBecomesTheNotificationAPushWouldHaveBeen() async throws {
        appInFront = false
        center.receive(fromMac: frame())
        let requests = await scheduled()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.identifier, "agent-mac-h_0a1b2c3d4e5f")
        XCTAssertEqual(request.content.categoryIdentifier, AgentAlertPayload.categoryIdentifier)
        XCTAssertTrue(request.trigger is UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(request.content.title, "A task on your Mac needs you")
        XCTAssertNil(center.banner)

        let payload = try XCTUnwrap(AgentAlertPayload(userInfo: request.content.userInfo),
                                    "It routes exactly like a push: the same payload comes back out of the tap")
        XCTAssertEqual(payload.helpRequestID, "h_0a1b2c3d4e5f")
        XCTAssertEqual(payload.kind, .claudeCode)
        XCTAssertEqual(payload.pairingIdentity, String(repeating: "a", count: 64),
                       "A local control-channel notification keeps its exact pairing through a reminder")
    }

    func testTheNotificationNeverNamesTheAgent() async throws {
        appInFront = false
        center.receive(fromMac: frame(kind: .codex))
        let requests = await scheduled()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.content.title, "A task on your Mac needs you")
        let aps = try XCTUnwrap(request.content.userInfo["aps"] as? [String: Any])
        XCTAssertNil((aps["alert"] as? [String: Any])?["title-loc-args"])
        for text in [request.content.title, request.content.subtitle, request.content.body] {
            XCTAssertFalse(text.contains("Codex"), text)
        }
    }

    func testTheFocusChoiceDecidesHowHardItInterrupts() async throws {
        appInFront = false
        center.preferences.breakThroughFocus = true
        center.receive(fromMac: frame("h_aaaa"))
        let firstBatch = await scheduled()
        let loud = try XCTUnwrap(firstBatch.first)
        XCTAssertEqual(loud.content.interruptionLevel, .timeSensitive)

        center.preferences.breakThroughFocus = false
        center.receive(fromMac: frame("h_bbbb"))
        for _ in 0..<50 where fake.added.count < 2 { await Task.yield() }
        XCTAssertEqual(fake.added.last?.content.interruptionLevel, .active)
    }

    func testNothingHappensWhileAlertsAreOff() async {
        center.preferences.alertsEnabled = false
        center.receive(fromMac: frame())
        appInFront = false
        center.receive(fromMac: frame("h_other"))
        XCTAssertNil(center.banner)
        await Task.yield()
        XCTAssertTrue(fake.added.isEmpty, "Off means the Mac's alerts are never announced, even mid-session")
    }

    func testARequestIsAnnouncedOnce() async {
        center.receive(fromMac: frame())
        XCTAssertNotNil(center.banner)
        center.dismissBanner()
        center.receive(fromMac: frame())
        XCTAssertNil(center.banner, "The same request again is the same ask")

        appInFront = false
        center.receive(fromMac: frame())
        await Task.yield()
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testARequestThePersonDeclinedIsNeverAnnouncedAgain() async {
        let payload = AgentAlertPayload(helpRequestID: "h_declined", kind: .claudeCode,
                                        pairingIdentity: String(repeating: "a", count: 64))
        await center.respond(.notNow, to: payload, deliveredAt: clock, notificationIdentifier: nil)
        center.receive(fromMac: frame("h_declined"))
        XCTAssertNil(center.banner)
        appInFront = false
        center.receive(fromMac: frame("h_declined"))
        await Task.yield()
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testAnEventOrVersionThisPhoneDoesNotKnowIsIgnored() async throws {
        let unknownEvent = #"{"version":1,"id":"h_new1","kind":"codex","event":"finished","raisedAt":1790000000}"#
        let futureVersion = #"{"version":2,"id":"h_new2","kind":"codex","event":"needs_user","raisedAt":1790000000}"#
        for json in [unknownEvent, futureVersion] {
            let parsed = try JSONDecoder().decode(AgentAlertFrame.self, from: Data(json.utf8))
            center.receive(fromMac: parsed)
        }
        XCTAssertNil(center.banner)
        appInFront = false
        center.receive(fromMac: try JSONDecoder().decode(AgentAlertFrame.self, from: Data(unknownEvent.utf8)))
        await Task.yield()
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testTheRememberedRequestsStayBounded() {
        for index in 0..<80 { center.receive(fromMac: frame("h_\(index)")) }
        XCTAssertEqual(center.banner?.id, "h_79")
        center.dismissBanner()
        center.receive(fromMac: frame("h_0"))
        XCTAssertEqual(center.banner?.id, "h_0", "Only the most recent requests are remembered, so memory does not grow")
    }

    // MARK: Through the model

    func testACaptureStatusFromTheMacReachesTheAlertCenter() throws {
        let shared = AgentAlertCenter.shared
        let original = (center: shared.center, preferences: shared.preferences, isForeground: shared.isForeground)
        shared.center = fake
        shared.preferences = AgentAlertPreferences(defaults: defaults)
        shared.preferences.alertsEnabled = true
        shared.isForeground = { true }
        defer {
            shared.dismissBanner()
            shared.center = original.center
            shared.preferences = original.preferences
            shared.isForeground = original.isForeground
        }

        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        let id = "h_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let action = RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                  agentAlert: frame(id, kind: .cursor))
        model.connection.onControl?(try JSONEncoder().encode(action))

        XCTAssertEqual(shared.banner?.id, id)
        XCTAssertEqual(shared.banner?.payload.kind, .cursor)
    }

    func testAStatusWithoutAnAlertLeavesTheBannerAlone() throws {
        let shared = AgentAlertCenter.shared
        let before = shared.banner
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.connection.onControl?(try JSONEncoder().encode(RemoteAction(action: "capture", x: 1, epoch: 1)))
        XCTAssertEqual(shared.banner, before)
    }
}
