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
    private let pairingIdentity = String(repeating: "a", count: 64)

    override func setUp() {
        super.setUp()
        fake = FakeNotificationCenter()
        defaults = makeTestDefaults("AgentAlertCenterTests")
        reports = AgentAlertReports()
        center = AgentAlertCenter(center: fake, defaults: defaults, reports: reports)
        center.now = { [clock] in clock }
        center.currentPairingIdentity = { [pairingIdentity] in pairingIdentity }
        registered = 0
        unregistered = 0
        center.registerForRemoteNotifications = { [unowned self] in registered += 1 }
        center.unregisterForRemoteNotifications = { [unowned self] in unregistered += 1 }
    }

    private func payload(_ id: String = "h_20af", kind: AgentKind = .claudeCode, reminder: Bool = false) -> AgentAlertPayload {
        AgentAlertPayload(helpRequestID: id, kind: kind, pairingIdentity: pairingIdentity,
                          threadID: "mac-7f3a", interruption: .timeSensitive, isReminder: reminder)
    }

    // MARK: Preferences

    func testEveryDefaultIsTheQuietOne() {
        let preferences = AgentAlertPreferences(defaults: defaults)
        XCTAssertFalse(preferences.alertsEnabled, "Nothing is on until the person turns it on")
        XCTAssertFalse(preferences.breakThroughFocus)
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
        XCTAssertEqual(request.content.title, "A task on your Mac needs you")
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
        XCTAssertEqual(request.content.title, "A task on your Mac needs you")
        XCTAssertEqual(request.content.body, "Still waiting on you.")
        XCTAssertEqual(request.content.relevanceScore, 0.3)
        let routed = try XCTUnwrap(AgentAlertPayload(userInfo: request.content.userInfo))
        XCTAssertEqual(routed.helpRequestID, "h_20af")
        XCTAssertEqual(routed.pairingIdentity, pairingIdentity,
                       "Snooze must keep the original pairing rather than bind a later Mac")
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

    func testTheReminderNamesNoAgent() async throws {
        await center.respond(.snooze, to: payload(kind: .codex), deliveredAt: clock, notificationIdentifier: nil)
        let content = try XCTUnwrap(fake.added.first?.content)
        XCTAssertEqual(content.title, "A task on your Mac needs you")
        XCTAssertFalse(content.title.contains("Codex") || content.body.contains("Codex"))
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

    func testOldOrUnboundNotificationCannotReportOrOpenReplacementMac() async {
        var old = payload("h_old")
        old.pairingIdentity = String(repeating: "b", count: 64)
        await center.respond(.open, to: old, deliveredAt: clock, notificationIdentifier: "old")
        XCTAssertEqual(center.presentation?.payload, old)
        XCTAssertFalse(center.isCurrentPairing(old))
        XCTAssertTrue(reports.queued.isEmpty)
        XCTAssertTrue(fake.removedDelivered.contains("old"))
        await center.respond(.snooze, to: old, deliveredAt: clock, notificationIdentifier: "old")
        XCTAssertTrue(fake.added.isEmpty)
        old.pairingIdentity = nil
        await center.respond(.notNow, to: old, deliveredAt: clock, notificationIdentifier: nil)
        XCTAssertFalse(center.wasDeclined("h_old"))
    }

    func testNotificationActionBeforePairingAttachKeepsItsIdentityForLaterReport() async {
        center.currentPairingIdentity = nil
        await center.respond(.notNow, to: payload("h_cold"), deliveredAt: clock, notificationIdentifier: "cold")
        XCTAssertEqual(reports.queued.first?.helpRequestID, "h_cold")
        XCTAssertEqual(reports.queued.first?.pairingIdentity, pairingIdentity)
        XCTAssertTrue(fake.removedDelivered.contains("cold"))
    }
}

@MainActor
final class AgentAlertReportsTests: XCTestCase {
    @MainActor
    private final class Sink: AgentAlertReportSink {
        var results: [AgentAlertReportResult] = []
        var attempted: [String] = []
        func submit(_ response: AgentAlertResponse) async -> AgentAlertReportResult {
            attempted.append(response.helpRequestID)
            return results.isEmpty ? .recorded : results.removeFirst()
        }
    }

    private func reports(now: Date) -> (AgentAlertReports, Sink) {
        let reports = AgentAlertReports()
        let invitation = PairInvitation(server: "wss://signal.example.test/signal",
                                        room: String(repeating: "a", count: 64),
                                        token: String(repeating: "b", count: 64),
                                        key: Data(repeating: 1, count: 32), expires: .distantFuture, name: "Test Mac")
        reports.configure(target: PushPairingTarget(invitation: invitation))
        reports.now = { now }
        let sink = Sink()
        reports.sink = sink
        return (reports, sink)
    }

    func testExpiredHeadIsDroppedBeforeFreshReport() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (reports, sink) = reports(now: now)
        let identity = try XCTUnwrap(reports.target?.notificationIdentity)
        reports.record(AgentAlertResponse(helpRequestID: "h_expired", pairingIdentity: identity, kind: .opened,
                                          at: now.addingTimeInterval(-901)))
        reports.record(AgentAlertResponse(helpRequestID: "h_fresh", pairingIdentity: identity, kind: .opened, at: now))
        await reports.flush()
        XCTAssertEqual(sink.attempted, ["h_fresh"])
        XCTAssertTrue(reports.queued.isEmpty)
    }

    func testUnknownEventDoesNotStarveLaterReport() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (reports, sink) = reports(now: now)
        sink.results = [.discard, .recorded]
        let identity = try XCTUnwrap(reports.target?.notificationIdentity)
        reports.record(AgentAlertResponse(helpRequestID: "h_live_control", pairingIdentity: identity, kind: .opened, at: now))
        reports.record(AgentAlertResponse(helpRequestID: "h_fresh", pairingIdentity: identity, kind: .opened, at: now))
        await reports.flush()
        XCTAssertEqual(sink.attempted, ["h_live_control", "h_fresh"])
        XCTAssertTrue(reports.queued.isEmpty)
    }

    func testColdLaunchKeepsOnlyMatchingPairingAnswers() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reports = AgentAlertReports()
        reports.now = { now }
        let invitation = PairInvitation(server: "wss://signal.example.test/signal",
                                        room: String(repeating: "a", count: 64),
                                        token: String(repeating: "b", count: 64),
                                        key: Data(repeating: 1, count: 32), expires: .distantFuture, name: "Test Mac")
        let target = try XCTUnwrap(PushPairingTarget(invitation: invitation))
        reports.record(.init(helpRequestID: "h_matching", pairingIdentity: target.notificationIdentity,
                             kind: .opened, at: now))
        reports.record(.init(helpRequestID: "h_old", pairingIdentity: String(repeating: "c", count: 64),
                             kind: .opened, at: now))
        XCTAssertEqual(reports.queued.count, 2, "A cold-launch action waits for pairing configuration")
        reports.configure(target: target)
        let sink = Sink()
        reports.sink = sink
        await reports.flush()
        XCTAssertEqual(sink.attempted, ["h_matching"])
        XCTAssertTrue(reports.queued.isEmpty)
    }

    func testPairSwitchDiscardsQueuedOldAnswer() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (reports, oldSink) = reports(now: now)
        oldSink.results = [.retry]
        let old = try XCTUnwrap(reports.target)
        reports.record(.init(helpRequestID: "h_old", pairingIdentity: old.notificationIdentity,
                             kind: .opened, at: now))
        let newInvitation = PairInvitation(server: "wss://signal.example.test/signal",
                                           room: String(repeating: "c", count: 64),
                                           token: String(repeating: "d", count: 64),
                                           key: Data(repeating: 1, count: 32), expires: .distantFuture, name: "New Mac")
        reports.configure(target: PushPairingTarget(invitation: newInvitation))
        XCTAssertTrue(reports.queued.isEmpty)
    }
}

@MainActor
final class PushRegistrarTests: XCTestCase {
    private final class PendingStore: PairPersistence {
        var data: Data?
        func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
        func read<T: Decodable>(_ type: T.Type) throws -> T? {
            try data.map { try JSONDecoder().decode(type, from: $0) }
        }
        func delete() throws { data = nil }
    }

    private func invitation(_ room: String = String(repeating: "a", count: 64),
                            token: String = String(repeating: "b", count: 64),
                            server: String = "wss://signal.example.test/signal") -> PairInvitation {
        PairInvitation(server: server, room: room, token: token,
                       key: Data(repeating: 1, count: 32), expires: .distantFuture, name: "Test Mac")
    }

    @MainActor
    private final class RetrySink: PushRegistrationSink {
        var shouldConfirm = false
        var registrations: [String] = []
        var disables = 0
        func submit(_ registration: PushRegistration) async -> PushSubmission {
            registrations.append(registration.deviceToken)
            return .sent
        }
        func disableAlerts() async -> PushSubmission {
            disables += 1
            return shouldConfirm ? .sent : .notSent("offline")
        }
    }

    func testOnlyHTTPSOriginFromExactPairedServerIsAccepted() {
        let expected = PushPairingTarget(invitation: invitation(server: "wss://signal.example.test/signal"))
        XCTAssertEqual(expected?.origin.absoluteString, "https://signal.example.test")
        XCTAssertEqual(expected?.notificationIdentity,
                       "bb4e6754bace2ee18161742a1bfbab72ac3865454f5f00951e7523912d1e7122",
                       "The phone must match the backend's authoritative room and pairing-hash formula")
        XCTAssertNil(PushPairingTarget(invitation: invitation(server: "ws://127.0.0.1/signal")))
        XCTAssertNil(PushPairingTarget(invitation: invitation(server: "wss://signal.example.test/other")))
        XCTAssertNil(PushPairingTarget(invitation: invitation(server: "wss://user@signal.example.test/signal")))
    }

    func testPairSwitchRetainsOldDisableIdentityAndUsesNewOriginForRegistration() async throws {
        let defaults = makeTestDefaults("PushRegistrarPairSwitch")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let store = PendingStore()
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: store)
        let old = try XCTUnwrap(PushPairingTarget(invitation: invitation()))
        let newInvitation = invitation(String(repeating: "c", count: 64),
                                       token: String(repeating: "d", count: 64),
                                       server: "wss://new.example.test/signal")
        let next = try XCTUnwrap(PushPairingTarget(invitation: newInvitation))
        let oldSink = RetrySink()
        let newSink = RetrySink()
        registrar.sinkForTarget = { target in target == old ? oldSink : newSink }
        registrar.configure(invitation: invitation())
        registrar.received(token: Data([0xA1]))
        await registrar.submit()

        registrar.configure(invitation: newInvitation)
        await registrar.submit()
        let pending = try XCTUnwrap(store.read([PendingPushDisable].self)?.first)
        XCTAssertEqual(pending.target, old)
        XCTAssertGreaterThan(oldSink.disables, 0)
        XCTAssertNil(registrar.deviceToken, "A new pairing waits for a fresh APNs callback")

        registrar.received(token: Data([0xB2]))
        await registrar.submit()
        XCTAssertEqual(registrar.target, next)
        XCTAssertEqual(newSink.registrations.last, "b2")
        XCTAssertFalse(oldSink.registrations.contains("b2"))
        XCTAssertEqual(newSink.disables, 0)
    }

    func testCurrentTokenStaysInMemoryAndOptOutPersistsOnlyPairingProof() {
        let defaults = makeTestDefaults("PushRegistrarTests")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let store = PendingStore()
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: store)
        registrar.sinkForTarget = { _ in RetrySink() }
        registrar.configure(invitation: invitation())
        XCTAssertNil(registrar.deviceToken)
        registrar.received(token: Data([0x00, 0xAB, 0x0F, 0xFF]))
        XCTAssertEqual(registrar.deviceToken, "00ab0fff")
        XCTAssertNil(defaults.string(forKey: "push.deviceToken"), "The current APNs token stays in memory only")
        registrar.forget()
        XCTAssertNil(registrar.deviceToken)
        XCTAssertEqual(try? store.read([PendingPushDisable].self)?.first?.target,
                       PushPairingTarget(invitation: invitation()))
        XCTAssertFalse(String(decoding: store.data ?? Data(), as: UTF8.self).contains("00ab0fff"),
                       "The current APNs address is never cached for opt-out")
        XCTAssertEqual(registrar.status, .idle)
    }

    func testTheRegistrationCarriesPreferencesAndNoPrivateContent() throws {
        let defaults = makeTestDefaults("PushRegistrarRecord")
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: PendingStore())
        XCTAssertNil(registrar.registration(), "No address, no registration")
        let preferences = AgentAlertPreferences(defaults: defaults)
        preferences.alertsEnabled = true
        preferences.breakThroughFocus = true
        registrar.received(token: Data([1, 2, 3]))
        let record = try XCTUnwrap(registrar.registration(preferences: preferences, now: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(record.deviceToken, "010203")
        XCTAssertTrue(record.alertsEnabled)
        XCTAssertTrue(record.timeSensitive)
        XCTAssertFalse(record.showAgentName, "Alerts never name an agent, so the service is never asked to")
        XCTAssertEqual(record.updatedAt, 1_790_000_000)
        XCTAssertEqual(record.environment, "sandbox", "The environment comes from signed-build configuration")
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["deviceToken", "environment", "alertsEnabled", "timeSensitive", "showAgentName",
                              "locale", "appBuild", "osMajor", "updatedAt"], "No Mac name, agent text or screen content")
    }

    func testNothingIsSentUntilAServiceExists() async {
        let defaults = makeTestDefaults("PushRegistrarSink")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: PendingStore())
        registrar.received(token: Data([9]))
        await registrar.submit()
        XCTAssertNil(registrar.lastSubmission, "Without a pairing, no proof or address is sent")
        registrar.failed(RemoteError.invalidMessage)
        if case .failed = registrar.status {} else { XCTFail("A failed registration is reported") }
    }

    func testOptOutRetriesWithPairingProofWithoutAnyDeviceToken() async {
        let defaults = makeTestDefaults("PushRegistrarRemoval")
        AgentAlertPreferences(defaults: defaults).alertsEnabled = true
        let store = PendingStore()
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: store)
        let sink = RetrySink()
        registrar.sinkForTarget = { _ in sink }
        registrar.configure(invitation: invitation())
        AgentAlertPreferences(defaults: defaults).alertsEnabled = false
        registrar.forget()
        await registrar.submit()
        XCTAssertNil(registrar.deviceToken)
        if case .failed(let message) = registrar.status {
            XCTAssertTrue(message.contains("pending"), "An offline tokenless opt-out must stay visible as unfinished")
        } else { XCTFail("A failed tokenless opt-out cannot appear idle") }
        XCTAssertEqual(try? store.read([PendingPushDisable].self)?.first?.target,
                       PushPairingTarget(invitation: invitation()))
        XCTAssertGreaterThan(sink.disables, 0)
        let relaunched = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: store)
        let nextSink = RetrySink()
        nextSink.shouldConfirm = true
        relaunched.sinkForTarget = { _ in nextSink }
        await relaunched.submit()
        XCTAssertNil(relaunched.deviceToken, "The retry succeeds before APNs returns a new address")
        XCTAssertGreaterThan(nextSink.disables, 0)
        XCTAssertNil(try? store.read([PendingPushDisable].self))
    }

    func testReenableCancelsOldDisableBeforeNewRegistration() async {
        let defaults = makeTestDefaults("PushRegistrarReenable")
        let preferences = AgentAlertPreferences(defaults: defaults)
        preferences.alertsEnabled = true
        let store = PendingStore()
        let registrar = PushRegistrar(defaults: defaults, environmentOverride: "sandbox", removalStore: store)
        let sink = RetrySink()
        registrar.sinkForTarget = { _ in sink }
        registrar.configure(invitation: invitation())
        registrar.received(token: Data([0x01]))
        await registrar.submit()

        preferences.alertsEnabled = false
        registrar.forget()
        XCTAssertNotNil(try? store.read([PendingPushDisable].self)?.first)
        preferences.alertsEnabled = true
        registrar.received(token: Data([0x02]))
        await registrar.submit()

        XCTAssertNil(try? store.read([PendingPushDisable].self))
        XCTAssertEqual(sink.disables, 0, "A queued old opt-out cannot erase the newly enabled address")
        XCTAssertEqual(sink.registrations.last, "02")
    }
}
