import UserNotifications
import XCTest
@testable import PocketDeskRemote

@MainActor
final class AgentAlertCenterTests: XCTestCase {
    private var fake: FakeNotificationCenter!
    private var defaults: UserDefaults!
    private var reports: AgentAlertReports!
    private var center: AgentAlertCenter!
    private var registered = 0
    private var unregistered = 0
    private let clock = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        fake = FakeNotificationCenter()
        defaults = makeTestDefaults("AgentAlertCenterTests")
        reports = AgentAlertReports()
        center = AgentAlertCenter(center: fake, defaults: defaults, reports: reports)
        center.now = { [clock] in clock }
        registered = 0
        unregistered = 0
        center.registerForRemoteNotifications = { [unowned self] in registered += 1 }
        center.unregisterForRemoteNotifications = { [unowned self] in unregistered += 1 }
    }

    private func payload(_ id: String = "h_20af", kind: AgentKind = .claudeCode, reminder: Bool = false) -> AgentAlertPayload {
        AgentAlertPayload(helpRequestID: id, kind: kind, threadID: "mac-7f3a", interruption: .timeSensitive, isReminder: reminder)
    }

    // MARK: Preferences

    func testEveryDefaultIsTheQuietOne() {
        let preferences = AgentAlertPreferences(defaults: defaults)
        XCTAssertFalse(preferences.alertsEnabled, "Nothing is on until the person turns it on")
        XCTAssertFalse(preferences.breakThroughFocus)
        XCTAssertTrue(preferences.showAgentName)
        XCTAssertFalse(preferences.showMacNameOnLockScreen, "Lock screens are visible to other people")
        XCTAssertTrue(preferences.sessionLiveActivity)
        preferences.alertsEnabled = true
        preferences.showMacNameOnLockScreen = true
        XCTAssertTrue(AgentAlertPreferences(defaults: defaults).alertsEnabled)
        XCTAssertTrue(AgentAlertPreferences(defaults: defaults).showMacNameOnLockScreen)
    }

    // MARK: Permission

    func testTurningAlertsOnAsksIOSOnlyAfterExplaining() async {
        fake.accessValue = .notDetermined
        let result = await center.setAlertsEnabled(true)
        XCTAssertEqual(result, .needsPriming, "The view shows the priming screen first")
        XCTAssertEqual(fake.authorizationRequests, 0, "iOS is never asked before the explanation")
        XCTAssertFalse(center.preferences.alertsEnabled)

        let granted = await center.requestAndEnable()
        XCTAssertTrue(granted)
        XCTAssertEqual(fake.authorizationRequests, 1)
        XCTAssertTrue(center.preferences.alertsEnabled)
        XCTAssertEqual(registered, 1, "Only now does this phone ask for a push address")
    }

    func testADeniedAnswerLeavesAlertsOffAndPointsAtSettings() async {
        fake.accessValue = .notDetermined
        fake.grantsPermission = false
        let granted = await center.requestAndEnable()
        XCTAssertFalse(granted)
        XCTAssertFalse(center.preferences.alertsEnabled)
        XCTAssertEqual(registered, 0)
        let again = await center.setAlertsEnabled(true)
        XCTAssertEqual(again, .deniedInSettings, "Only the person can change it in Settings")
    }

    func testAlreadyAllowedEnablesAtOnceAndOffForgetsThePhone() async {
        fake.accessValue = .allowed
        let on = await center.setAlertsEnabled(true)
        XCTAssertEqual(on, .enabled)
        XCTAssertTrue(center.preferences.alertsEnabled)
        XCTAssertEqual(registered, 1)
        let off = await center.setAlertsEnabled(false)
        XCTAssertEqual(off, .enabled)
        XCTAssertFalse(center.preferences.alertsEnabled)
        XCTAssertEqual(unregistered, 1, "Turning alerts off deletes this phone's push address")
    }

    func testCategoriesAreRegisteredWithTheSystem() {
        center.registerCategories()
        XCTAssertEqual(Set(fake.categories.map(\.identifier)), ["AGENT_HELP", "AGENT_HELP_REMINDER"])
    }

    // MARK: Test alert

    func testTheTestAlertNeedsPermissionAndLooksLikeARealOne() async throws {
        fake.accessValue = .denied
        let refused = await center.sendTestAlert()
        XCTAssertFalse(refused)
        XCTAssertTrue(fake.added.isEmpty)

        fake.accessValue = .allowed
        let sent = await center.sendTestAlert(after: 3)
        XCTAssertTrue(sent)
        let request = try XCTUnwrap(fake.added.first)
        XCTAssertEqual(request.content.categoryIdentifier, "AGENT_HELP")
        XCTAssertEqual(request.content.title, "An agent needs you")
        XCTAssertEqual(request.content.body, "This is a test. Nothing on your Mac is stuck.")
        XCTAssertEqual(request.content.interruptionLevel, .active, "Time Sensitive only after the person turned it on")
        XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 3)
        let routed = try XCTUnwrap(AgentAlertPayload(userInfo: request.content.userInfo))
        XCTAssertTrue(routed.isTest)
        XCTAssertEqual(routed.kind, .other)
    }

    func testTheTestAlertBreaksThroughFocusOnlyWhenAskedTo() async throws {
        fake.accessValue = .allowed
        center.preferences.breakThroughFocus = true
        _ = await center.sendTestAlert()
        XCTAssertEqual(fake.added.first?.content.interruptionLevel, .timeSensitive)
    }

    // MARK: What a tap and the actions do

    func testTappingOpensTheSheetForThatRequestAndNothingConnects() async {
        await center.respond(.open, to: payload(kind: .codex), deliveredAt: clock, notificationIdentifier: "n1")
        XCTAssertEqual(center.presentation?.id, "h_20af")
        XCTAssertEqual(center.presentation?.payload.kind, .codex)
        XCTAssertTrue(SystemRequestInbox.shared.pending.isEmpty, "A tap grants nothing: no connect is queued")
        XCTAssertEqual(reports.queued.map(\.kind), [.opened])
    }

    func testNotNowDeclinesRemovesTheNotificationAndCancelsTheReminder() async {
        await center.respond(.snooze, to: payload(), deliveredAt: clock, notificationIdentifier: "n1")
        await center.respond(.open, to: payload(), deliveredAt: clock, notificationIdentifier: "n1")
        await center.respond(.notNow, to: payload(), deliveredAt: clock, notificationIdentifier: "n2")
        XCTAssertTrue(center.wasDeclined("h_20af"))
        XCTAssertTrue(fake.removedPending.contains("agent-snooze-h_20af"), "A declined request gets no reminder")
        XCTAssertTrue(fake.removedDelivered.contains("n2"))
        XCTAssertNil(center.presentation, "Not now closes its own sheet")
        XCTAssertEqual(reports.queued.last?.kind, .declined)
    }

    func testSnoozeSchedulesOneQuietReminderInFifteenMinutes() async throws {
        await center.respond(.snooze, to: payload(), deliveredAt: clock, notificationIdentifier: "n1")
        XCTAssertEqual(fake.removedDelivered, ["n1"])
        let request = try XCTUnwrap(fake.added.first)
        XCTAssertEqual(request.identifier, "agent-snooze-h_20af")
        XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 15 * 60)
        XCTAssertEqual(request.content.categoryIdentifier, "AGENT_HELP_REMINDER")
        XCTAssertEqual(request.content.interruptionLevel, .passive, "The reminder never lights the screen or breaks Focus")
        XCTAssertEqual(request.content.threadIdentifier, "mac-7f3a")
        XCTAssertEqual(request.content.title, "Claude Code needs you")
        XCTAssertEqual(request.content.body, "Still waiting on you.")
        XCTAssertEqual(request.content.relevanceScore, 0.3)
        let routed = try XCTUnwrap(AgentAlertPayload(userInfo: request.content.userInfo))
        XCTAssertEqual(routed.helpRequestID, "h_20af")
        XCTAssertTrue(routed.isReminder)
    }

    func testASecondSnoozeNeverSchedulesASecondReminder() async {
        await center.respond(.snooze, to: payload(), deliveredAt: clock, notificationIdentifier: "n1")
        await center.respond(.snooze, to: payload(reminder: true), deliveredAt: clock, notificationIdentifier: "n2")
        XCTAssertEqual(fake.added.count, 1, "At most one reminder per request")
        XCTAssertEqual(fake.removedDelivered, ["n1", "n2"])
    }

    func testSnoozingADeclinedRequestSchedulesNothing() async {
        await center.respond(.notNow, to: payload(), deliveredAt: clock, notificationIdentifier: nil)
        await center.respond(.snooze, to: payload(), deliveredAt: clock, notificationIdentifier: nil)
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testTheReminderRespectsTheHideAgentNameChoice() async {
        center.preferences.showAgentName = false
        await center.respond(.snooze, to: payload(kind: .codex), deliveredAt: clock, notificationIdentifier: nil)
        XCTAssertEqual(fake.added.first?.content.title, "An agent needs you")
    }

    func testSwipingAwayIsNotADecision() async {
        await center.respond(.dismissed, to: payload(), deliveredAt: clock, notificationIdentifier: "n1")
        XCTAssertFalse(center.wasDeclined("h_20af"))
        XCTAssertTrue(fake.added.isEmpty)
        XCTAssertTrue(fake.removedPending.isEmpty)
        XCTAssertEqual(reports.queued.map(\.kind), [.dismissed])
    }

    func testActionIdentifiersMapToActionsAndUnknownOnesAreIgnored() {
        XCTAssertEqual(AgentAlertCenter.Action(actionIdentifier: UNNotificationDefaultActionIdentifier), .open)
        XCTAssertEqual(AgentAlertCenter.Action(actionIdentifier: "SNOOZE_15"), .snooze)
        XCTAssertEqual(AgentAlertCenter.Action(actionIdentifier: "NOT_NOW"), .notNow)
        XCTAssertEqual(AgentAlertCenter.Action(actionIdentifier: UNNotificationDismissActionIdentifier), .dismissed)
        XCTAssertNil(AgentAlertCenter.Action(actionIdentifier: "TAKE_OVER"), "There is no Take over or Approve action")
        XCTAssertNil(AgentAlertCenter.Action(actionIdentifier: "APPROVE"))
    }

    // MARK: Foreground presentation

    func testAnAlertInFrontOfTheHomeScreenBannersAndSounds() {
        center.isSessionLive = { false }
        XCTAssertEqual(center.presentationOptions(for: payload(), deliveredAt: clock), [.banner, .list, .sound])
        XCTAssertEqual(center.presentationOptions(for: payload(reminder: true), deliveredAt: clock), [.banner, .list],
                       "A reminder is quiet")
        XCTAssertNil(center.banner)
    }

    func testDuringALiveSessionTheAlertIsOneQuietBannerNotASystemOne() {
        center.isSessionLive = { true }
        XCTAssertEqual(center.presentationOptions(for: payload(), deliveredAt: clock), [], "The picture already shows the Mac")
        XCTAssertEqual(center.banner?.id, "h_20af")
        center.dismissBanner()
        XCTAssertNil(center.banner)
    }

    func testADeclinedRequestIsNotAnnouncedAgain() async {
        await center.respond(.notNow, to: payload(), deliveredAt: clock, notificationIdentifier: nil)
        XCTAssertEqual(center.presentationOptions(for: payload(), deliveredAt: clock), [])
        center.showBanner(AgentAlertPresentation(payload: payload(), receivedAt: clock))
        XCTAssertNil(center.banner)
    }

    func testALinkThatNamesOnlyTheRequestOpensItAsAnAgent() {
        center.open(linkedRequest: "h_77")
        XCTAssertEqual(center.presentation?.id, "h_77")
        XCTAssertEqual(center.presentation?.payload.kind, .other, "A link carries no agent name")
    }

    func testAnswersAreRememberedInOrderAndCapped() async {
        for index in 0..<70 {
            await center.respond(.notNow, to: payload("h_\(index)"), deliveredAt: clock, notificationIdentifier: nil)
        }
        XCTAssertTrue(center.wasDeclined("h_69"))
        XCTAssertFalse(center.wasDeclined("h_0"), "Old answers roll off")
        XCTAssertEqual(reports.queued.count, AgentAlertReports.capacity)
    }
}

@MainActor
final class PushRegistrarTests: XCTestCase {
    @MainActor
    private final class RetrySink: PushRegistrationSink {
        var shouldConfirm = false
        func submit(_ registration: PushRegistration) async -> PushSubmission { .sent }
        func remove(deviceToken: String) async -> PushSubmission {
            return shouldConfirm ? .sent : .notSent("offline")
        }
    }

    func testTheTokenIsStoredHexOnThePhoneAndForgottenOnRequest() {
        let defaults = makeTestDefaults("PushRegistrarTests")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox")
        XCTAssertNil(registrar.deviceToken)
        registrar.received(token: Data([0x00, 0xAB, 0x0F, 0xFF]))
        XCTAssertEqual(registrar.deviceToken, "00ab0fff")
        XCTAssertNil(defaults.string(forKey: "push.deviceToken"), "The current APNs token stays in memory only")
        registrar.forget()
        XCTAssertNil(registrar.deviceToken)
        XCTAssertEqual(defaults.string(forKey: "push.pendingRemoval"), "00ab0fff")
        XCTAssertEqual(registrar.status, .idle)
    }

    func testTheRegistrationCarriesPreferencesAndNoPrivateContent() throws {
        let defaults = makeTestDefaults("PushRegistrarRecord")
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox")
        XCTAssertNil(registrar.registration(), "No address, no registration")
        let preferences = AgentAlertPreferences(defaults: defaults)
        preferences.alertsEnabled = true
        preferences.breakThroughFocus = true
        registrar.received(token: Data([1, 2, 3]))
        let record = try XCTUnwrap(registrar.registration(preferences: preferences, now: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(record.deviceToken, "010203")
        XCTAssertTrue(record.alertsEnabled)
        XCTAssertTrue(record.timeSensitive)
        XCTAssertTrue(record.showAgentName)
        XCTAssertEqual(record.updatedAt, 1_790_000_000)
        XCTAssertEqual(record.environment, "sandbox", "The environment comes from signed-build configuration")
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["deviceToken", "environment", "alertsEnabled", "timeSensitive", "showAgentName",
                              "locale", "appBuild", "osMajor", "updatedAt"], "No Mac name, agent text or screen content")
    }

    func testNothingIsSentUntilAServiceExists() async {
        let defaults = makeTestDefaults("PushRegistrarSink")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox")
        registrar.received(token: Data([9]))
        await registrar.submit()
        XCTAssertEqual(registrar.lastSubmission, .notSent("No Farside push service is configured."))
        registrar.failed(RemoteError.invalidMessage)
        if case .failed = registrar.status {} else { XCTFail("A failed registration is reported") }
    }

    func testOptOutKeepsOnlyADeletionTokenUntilTheServiceConfirmsRemoval() async {
        let defaults = makeTestDefaults("PushRegistrarRemoval")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox")
        registrar.received(token: Data([0xAB, 0xCD]))
        let sink = RetrySink()
        registrar.sink = sink
        AgentAlertPreferences(defaults: defaults).alertsEnabled = false
        registrar.forget()
        await registrar.submit()
        XCTAssertNil(registrar.deviceToken)
        XCTAssertEqual(defaults.string(forKey: "push.pendingRemoval"), "abcd")
        sink.shouldConfirm = true
        await registrar.submit()
        XCTAssertNil(defaults.string(forKey: "push.pendingRemoval"))
    }
}
