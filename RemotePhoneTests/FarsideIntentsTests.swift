import AppIntents
import XCTest
@testable import PocketDeskRemote

@MainActor
final class FarsideIntentsTests: XCTestCase {
    private var savedLoader: (() -> [PairedMac])!
    private var savedControlSelection: (() -> String?)!
    private var savedControlSwitch: Any?

    override func setUp() {
        super.setUp()
        savedLoader = PairedMacs.loader
        savedControlSelection = ControlConnectRequest.selectedMacID
        savedControlSwitch = UserDefaults.standard.object(forKey: FarsideControlConnect.defaultsKey)
        UserDefaults.standard.removeObject(forKey: FarsideControlConnect.defaultsKey)
        _ = SystemRequestInbox.shared.drain()
    }

    override func tearDown() {
        PairedMacs.loader = savedLoader
        ControlConnectRequest.selectedMacID = savedControlSelection
        if let savedControlSwitch {
            UserDefaults.standard.set(savedControlSwitch, forKey: FarsideControlConnect.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FarsideControlConnect.defaultsKey)
        }
        SessionIntentBridge.shared.handler = nil
        MacStatusService.shared.currentSession = { (false, false) }
        _ = SystemRequestInbox.shared.drain()
        super.tearDown()
    }

    // MARK: Safety baseline

    func testSystemExposesAnAuthenticatedForegroundControlConnectIntent() throws {
        let metadata = try IntentMetadata.load()
        let actions = try XCTUnwrap(metadata["actions"] as? [String: [String: Any]])
        let control = try XCTUnwrap(actions["ControlConnectIntent"], "The system needs a Connect control intent")
        XCTAssertEqual(control["authenticationPolicy"] as? Int, 1)
        XCTAssertEqual(control["openAppWhenRun"] as? Bool, true)
        XCTAssertEqual(control["supportedModes"] as? Int, ControlConnectIntent.supportedModes.rawValue)
    }

    func testControlOpensTheAppWithoutARequestWhenNoMacIsPaired() async throws {
        PairedMacs.loader = { [] }
        ControlConnectRequest.selectedMacID = { nil }
        _ = try await ControlConnectIntent().perform()
        XCTAssertTrue(SystemRequestInbox.shared.pending.isEmpty)
    }

    func testControlUsesTheLastSelectedPairedMacAndQueuesTheNormalConnect() async throws {
        let first = try TestPairing.mac(name: "Studio")
        let selected = try TestPairing.mac(name: "Air")
        PairedMacs.loader = { [first, selected] }
        ControlConnectRequest.selectedMacID = { selected.id }
        _ = try await ControlConnectIntent().perform()
        XCTAssertEqual(SystemRequestInbox.shared.pending, [.connect(macID: selected.id)])
    }

    func testControlKillSwitchOnlyOpensTheApp() async throws {
        let selected = try TestPairing.mac()
        PairedMacs.loader = { [selected] }
        ControlConnectRequest.selectedMacID = { selected.id }
        UserDefaults.standard.set(false, forKey: FarsideControlConnect.defaultsKey)
        _ = try await ControlConnectIntent().perform()
        XCTAssertTrue(SystemRequestInbox.shared.pending.isEmpty)
    }

    func testControlNeverFallsBackToAnotherMacAfterTheSelectionIsRemoved() async throws {
        let other = try TestPairing.mac()
        PairedMacs.loader = { [other] }
        ControlConnectRequest.selectedMacID = { "m_removed" }
        _ = try await ControlConnectIntent().perform()
        XCTAssertTrue(SystemRequestInbox.shared.pending.isEmpty)
    }

    func testControlRequiresUnlockAndForegroundAndNeverClaimsConnected() {
        XCTAssertEqual(ControlConnectIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(ControlConnectIntent.supportedModes, .foreground(.immediate))
        XCTAssertTrue(ControlConnectIntent.openAppWhenRun)
        XCTAssertEqual(FarsideControlConnect.resultText, "Opening Farside.")
        XCTAssertFalse(FarsideControlConnect.resultText.lowercased().contains("connected"))
    }

    func testControlTitleUsesTheSnapshotNameOrThePlainFallback() {
        XCTAssertEqual(FarsideControlConnect.title(snapshot: nil), "Connect to Mac")
        XCTAssertEqual(FarsideControlConnect.title(snapshot: .init(macName: "  \n")), "Connect to Mac")
        XCTAssertEqual(FarsideControlConnect.title(snapshot: .init(macName: "Roshan's MacBook Air")),
                       "Connect to Roshan's MacBook Air")
    }

    func testOnlyEndSessionRunsFromALockedPhone() {
        XCTAssertEqual(ConnectToMacIntent.authenticationPolicy, .requiresAuthentication, "Opening control needs an unlock")
        XCTAssertEqual(MacStatusIntent.authenticationPolicy, .requiresAuthentication, "Mac state is private")
        XCTAssertEqual(EndSessionIntent.authenticationPolicy, .alwaysAllowed, "Ending moves toward safety")
    }

    func testConnectNeedsTheAppInFrontAndTheRestRunInTheBackground() {
        XCTAssertEqual(ConnectToMacIntent.supportedModes, .foreground(.immediate))
        XCTAssertEqual(MacStatusIntent.supportedModes, .background)
        XCTAssertEqual(EndSessionIntent.supportedModes, .background)
    }

    /// What the system reads is the extracted metadata, not the Swift types, so check that too.
    func testTheSystemSeesTheSamePolicyAndThreeShortcutsThatNameOnlyFarside() throws {
        let metadata = try IntentMetadata.load()
        let actions = try XCTUnwrap(metadata["actions"] as? [String: [String: Any]])
        XCTAssertEqual(actions["ConnectToMacIntent"]?["authenticationPolicy"] as? Int, 1)
        XCTAssertEqual(actions["MacStatusIntent"]?["authenticationPolicy"] as? Int, 1)
        XCTAssertEqual(actions["EndSessionIntent"]?["authenticationPolicy"] as? Int, 0)

        let shortcuts = try XCTUnwrap(metadata["autoShortcuts"] as? [[String: Any]])
        XCTAssertEqual(Set(shortcuts.compactMap { $0["actionIdentifier"] as? String }),
                       ["ConnectToMacIntent", "EndSessionIntent", "MacStatusIntent"])
        XCTAssertLessThanOrEqual(shortcuts.count, 10, "Apple allows ten App Shortcuts")
        for shortcut in shortcuts {
            let phrases = (shortcut["phraseTemplates"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
            XCTAssertFalse(phrases.isEmpty)
            for phrase in phrases {
                XCTAssertTrue(phrase.contains("${applicationName}"), "Every phrase carries the app name: \(phrase)")
                for other in ["claude", "codex", "cursor", "chatgpt", "openai", "anthropic", "far side"] {
                    XCTAssertFalse(phrase.lowercased().contains(other), "Phrases name only Farside: \(phrase)")
                }
            }
            XCTAssertNotNil(shortcut["shortTitle"], "Spotlight needs a short title")
            XCTAssertNotNil(shortcut["systemImageName"], "Spotlight needs an image")
        }
    }

    // MARK: Which Mac

    func testMacEntityIdsAreOpaqueStableAndPerPairing() throws {
        let first = try TestPairing.invitation()
        let second = try TestPairing.invitation()
        let id = PairedMacs.opaqueID(room: first.room)
        XCTAssertEqual(id, PairedMacs.opaqueID(room: first.room))
        XCTAssertNotEqual(id, PairedMacs.opaqueID(room: second.room))
        XCTAssertTrue(id.hasPrefix("m_"))
        XCTAssertFalse(id.contains(first.room), "The service knows the room id; Shortcuts must not")
        XCTAssertEqual(id.count, 18)
    }

    func testLegacyEntityAliasResolvesOnceToCanonicalMac() async throws {
        let canonical = PairedMac(id: "m_" + String(repeating: "a", count: 64), name: "Studio", invitation: nil,
                                  legacyAliases: ["m_legacy"])
        PairedMacs.loader = { [canonical] }
        let found = try await MacEntityQuery().entities(for: [canonical.id, "m_legacy"])
        XCTAssertEqual(found.map(\.id), [canonical.id])
        var chosen = MacEntity(canonical)
        chosen.id = "m_legacy"
        let resolved = try await resolvePairedMac(chosen) { _ in XCTFail("explicit legacy alias must not disambiguate"); return chosen }
        XCTAssertEqual(resolved.id, canonical.id)
        XCTAssertNil(PairedMacs.mac(withID: "m_missing"))
    }

    func testEntityQuerySuggestsAndResolvesPairedMacs() async throws {
        let studio = try TestPairing.mac(name: "Studio Mac")
        PairedMacs.loader = { [studio] }
        let query = MacEntityQuery()
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.name), ["Studio Mac"])
        let found = try await query.entities(for: [studio.id, "m_unknown"])
        XCTAssertEqual(found.map(\.id), [studio.id])
    }

    func testTheOnlyPairedMacIsUsedWithoutAsking() async throws {
        let studio = try TestPairing.mac()
        PairedMacs.loader = { [studio] }
        var asked = false
        let chosen = try await resolvePairedMac(nil) { _ in asked = true; throw FarsideIntentError.unknownMac }
        XCTAssertEqual(chosen, studio)
        XCTAssertFalse(asked)
    }

    func testSeveralMacsAskWhichOneAndAnUnknownAnswerIsRefused() async throws {
        let studio = try TestPairing.mac(name: "Studio Mac")
        let air = try TestPairing.mac(name: "MacBook Air")
        PairedMacs.loader = { [studio, air] }
        var offered: [String] = []
        let chosen = try await resolvePairedMac(nil) { options in
            offered = options.map(\.name)
            return options[1]
        }
        XCTAssertEqual(offered, ["Studio Mac", "MacBook Air"])
        XCTAssertEqual(chosen, air)

        let named = try await resolvePairedMac(MacEntity(studio)) { _ in throw FarsideIntentError.unknownMac }
        XCTAssertEqual(named, studio, "A Mac given by name is never asked about")

        do {
            _ = try await resolvePairedMac(MacEntity(PairedMac(id: "m_removed", name: "Old", invitation: nil))) { $0[0] }
            XCTFail("A Mac that is no longer paired must be refused")
        } catch let error as FarsideIntentError {
            XCTAssertEqual(error, .unknownMac)
        }
    }

    func testNoPairedMacSaysToPairOne() async {
        PairedMacs.loader = { [] }
        do {
            _ = try await ConnectToMacIntent().perform()
            XCTFail("Nothing to connect to")
        } catch let error as FarsideIntentError {
            XCTAssertEqual(error, .noPairedMac)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertTrue(SystemRequestInbox.shared.pending.isEmpty, "A refused connect must not queue anything")
    }

    // MARK: Connect

    func testConnectQueuesOneRequestForTheAppAndReplies() async throws {
        let studio = try TestPairing.mac()
        PairedMacs.loader = { [studio] }
        _ = try await ConnectToMacIntent().perform()
        XCTAssertEqual(SystemRequestInbox.shared.pending, [.connect(macID: studio.id)])
    }

    func testTheInboxKeepsRequestsInOrderUntilDrained() {
        let inbox = SystemRequestInbox()
        inbox.post(.connect(macID: "m_a"))
        inbox.post(.route(.openMac))
        XCTAssertEqual(inbox.drain(), [.connect(macID: "m_a"), .route(.openMac)])
        XCTAssertTrue(inbox.drain().isEmpty)
    }

    // MARK: Is my Mac awake?

    func testMacStatusSpeaksPlainlyAndNeverCallsSilenceSleep() throws {
        let mac = try TestPairing.mac(name: "Studio Mac")
        let service = MacStatusService()
        service.lastReached = { _ in nil }
        XCTAssertEqual(service.report(for: mac, outcome: .answering),
                       .init(state: .awake, spoken: "Studio Mac answered just now and looks awake."))
        let silent = service.report(for: mac, outcome: .notAnswering)
        XCTAssertEqual(silent.state, .notAnswering)
        XCTAssertEqual(silent.spoken, "I could not reach Studio Mac. It may be asleep, off or offline.")
        XCTAssertFalse(silent.spoken.contains("went to sleep"), "Only the Mac itself can say it slept")
        XCTAssertEqual(service.report(for: mac, outcome: .sessionBusy).state, .busy)
        XCTAssertEqual(service.report(for: mac, outcome: .serviceUnreachable).spoken,
                       "I could not reach the connection service. Check that this iPhone is online.")
        for outcome in [MacReachabilityProbe.Outcome.answering, .notAnswering, .sessionBusy, .serviceUnreachable] {
            let spoken = service.report(for: mac, outcome: outcome).spoken
            XCTAssertFalse(spoken.contains("!"), "Spoken replies carry no exclamations or jokes: \(spoken)")
            XCTAssertFalse(spoken.contains("Farside"), "Siri replies omit the app name: \(spoken)")
        }
    }

    func testMacStatusSaysWhenItLastHeardFromTheMac() throws {
        let mac = try TestPairing.mac(name: "Studio Mac")
        let service = MacStatusService()
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12, minute: 0))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 9, minute: 5))!
        service.now = { now }
        service.lastReached = { _ in earlier }
        let report = service.report(for: mac, outcome: .notAnswering)
        XCTAssertEqual(report.spoken, "I have not heard from Studio Mac since \(earlier.formatted(date: .omitted, time: .shortened)). It may be asleep, off or offline.")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: earlier)!
        XCTAssertEqual(LastReached.spoken(yesterday, now: now, calendar: calendar),
                       "yesterday \(yesterday.formatted(date: .omitted, time: .shortened))")
        let older = calendar.date(byAdding: .day, value: -5, to: earlier)!
        XCTAssertEqual(LastReached.spoken(older, now: now, calendar: calendar), older.formatted(.dateTime.month(.abbreviated).day()))
    }

    func testMacStatusNeverProbesWhileThisAppHoldsOrReachesForTheMac() async throws {
        let mac = try TestPairing.mac(name: "Studio Mac")
        let transport = FakeSignalingTransport()
        let service = MacStatusService()
        service.makeProbe = { MacReachabilityProbe(makeTransport: { transport }) }
        service.currentSession = { (true, true) }
        var report = await service.report(for: mac)
        XCTAssertEqual(report, .init(state: .connected, spoken: "You are connected to Studio Mac right now."))
        service.currentSession = { (false, true) }
        report = await service.report(for: mac)
        XCTAssertEqual(report, .init(state: .connecting, spoken: "Connecting to Studio Mac right now."))
        XCTAssertTrue(transport.connects.isEmpty, "A second registration would collide with this phone's own session")
    }

    func testMacStatusAsksTheServiceWhenNothingIsRunning() async throws {
        let mac = try TestPairing.mac(name: "Studio Mac")
        let transport = FakeSignalingTransport()
        transport.replies = [RelayMessage(type: "registered", role: "client")]
        let service = MacStatusService()
        service.makeProbe = { MacReachabilityProbe(makeTransport: { transport }) }
        let report = await service.report(for: mac)
        XCTAssertEqual(report.state, .awake)
        XCTAssertEqual(transport.connects.count, 1)
        XCTAssertNil(transport.connects.first?.hostToken, "The probe registers as the phone")
    }

    func testMacStatusIntentReturnsTheStateForShortcuts() async throws {
        let studio = try TestPairing.mac(name: "Studio Mac")
        PairedMacs.loader = { [studio] }
        let transport = FakeSignalingTransport()
        transport.replies = [RelayMessage(type: "error", code: "host_unavailable_or_unauthorized")]
        let original = MacStatusService.shared.makeProbe
        MacStatusService.shared.makeProbe = { MacReachabilityProbe(makeTransport: { transport }) }
        defer { MacStatusService.shared.makeProbe = original }
        let result = try await MacStatusIntent().perform()
        XCTAssertEqual(result.value, "notAnswering")
    }

    // MARK: End session

    func testEndSessionAsksTheAppWhenItIsThere() async throws {
        let handler = RecordingSessionHandler()
        SessionIntentBridge.shared.handler = handler
        _ = try await EndSessionIntent().perform()
        XCTAssertEqual(handler.endRequests, 1)
    }

    func testEndSessionWithNothingOpenSaysSoAndChangesNothing() async {
        SessionIntentBridge.shared.handler = nil
        let outcome = await SessionIntentBridge.shared.endSession()
        XCTAssertEqual(outcome, .nothingToEnd)
    }

    func testEndSessionReleasesTheLiveSession() async {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.connection.connected = true
        let integrations = FarsideSystemIntegrations()
        integrations.attach(model)
        let outcome = await integrations.endSessionFromIntent()
        XCTAssertEqual(outcome, .ended)
        XCTAssertFalse(model.connection.connected)
        XCTAssertFalse(model.connection.isRunning, "The coordinator must not keep retrying after End")
        XCTAssertEqual(model.connection.status, "Disconnected")
    }

    func testEndSessionWithNoSessionAndNoActivityHasNothingToEnd() async {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        let integrations = FarsideSystemIntegrations()
        integrations.attach(model)
        let outcome = await integrations.endSessionFromIntent()
        XCTAssertEqual(outcome, .nothingToEnd)
    }
}

enum IntentMetadata {
    static func load() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                                subdirectory: "Metadata.appintents"),
                                "The build must extract App Intents metadata into the app")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }
}
