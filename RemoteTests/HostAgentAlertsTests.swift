import XCTest
import Darwin

private final class RecordingPush: AgentPushRelay, @unchecked Sendable {
    private let stored = LockedBox<[AgentAlert]>([])
    private let answer = LockedBox<AgentPushOutcome>(.unavailable("not configured"))
    private let before = LockedBox<(@Sendable () async -> Void)?>(nil)
    var beforeDelivery: (@Sendable () async -> Void)? {
        get { before.value }
        set { before.value = newValue }
    }

    var outcome: AgentPushOutcome {
        get { answer.value }
        set { answer.value = newValue }
    }

    var delivered: [AgentAlert] { stored.value }

    func deliver(_ alert: AgentAlert, admission: AgentAlertBridge.Admission?) async -> AgentPushOutcome {
        await before.value?()
        guard admission?.isCurrent() != false else { return .unavailable("cancelled") }
        stored.mutate { $0.append(alert) }
        return answer.value
    }
}

/// The Mac's side of agent alerts: what each alert becomes once it has passed the bridge. The listener
/// itself is covered by `AgentAlertBridgeTests`; here the phone and the push service are fakes.
@MainActor
final class HostAgentAlertsTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var alerts: HostAgentAlerts!
    private var push: RecordingPush!
    private var now = Date(timeIntervalSince1970: 1_790_000_000)
    private var phoneIsLive = true
    private var phoneIsPaired = true
    private var channelAccepts = true
    private var sent: [AgentAlertFrame] = []
    private var diary: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("farside-host-alerts-\(UUID().uuidString)")
        suite = "FarsideHostAlertsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sent = []
        diary = []
        phoneIsLive = true
        phoneIsPaired = true
        channelAccepts = true
        push = RecordingPush()
        alerts = makeAlerts()
    }

    override func tearDown() async throws {
        alerts.shutDown()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func makeAlerts() -> HostAgentAlerts {
        let made = HostAgentAlerts(preferences: HostPreferences(defaults: defaults), directory: directory)
        made.now = { [unowned self] in now }
        made.isPhoneLive = { [unowned self] in phoneIsLive }
        made.hasPairedPhone = { [unowned self] in phoneIsPaired }
        made.deliverToPhone = { [unowned self] frame in
            if channelAccepts { sent.append(frame) }
            return channelAccepts
        }
        made.record = { [unowned self] text in diary.append(text) }
        made.push = push
        made.canUsePush = { true }
        made.pushIdentity = { "test-pair" }
        return made
    }

    private func alert(_ session: String = "0123456789ab", kind: AgentKind = .claudeCode) -> AgentAlert {
        AgentAlert(id: AgentAlert.makeID(), kind: kind, event: .needsUser, sessionHash: session, raisedAt: now)
    }

    private func turnOnWithoutListening() -> HostAgentAlerts {
        HostPreferences(defaults: defaults).agentAlerts = true
        alerts = makeAlerts()
        return alerts
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: Off, on, and off again

    private func queuedIntakeIsRetired(resetLink: Bool, live: Bool, keepListener: Bool = false) async throws {
        phoneIsLive = live
        push.outcome = .sent
        let entered = expectation(description: "authenticated intake queued before host delivery")
        let pauseOnce = LockedBox(true)
        let continuation = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        alerts.bridgeFactory = { directory, handler in
            AgentAlertBridge(directory: directory) { alert, admission in
                var shouldPause = false
                pauseOnce.mutate { value in shouldPause = value; value = false }
                if shouldPause {
                    await withCheckedContinuation { resume in
                        continuation.value = resume
                        entered.fulfill()
                    }
                }
                return await handler(alert, admission)
            }
        }
        if keepListener { await alerts.setOutcome(.completed, enabled: true) }
        await alerts.setEnabled(true)
        let discovery = try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile))
        let body = #"{"agent":{"kind":"codex","sessionHash":"112233445566"},"type":"needs_user"}"#
        func request(_ discovery: AgentAlertBridge.Discovery) -> String {
            "POST /agent/v1/event HTTP/1.1\r\nHost: 127.0.0.1:\(discovery.port)\r\nAuthorization: Bearer \(discovery.token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        let oldRequest = request(discovery)
        let oldAnswer = Task.detached { AgentAlertBridgeTests.send(oldRequest, toPort: UInt16(discovery.port)) }
        await fulfillment(of: [entered], timeout: 3)
        if resetLink { alerts.resetLink() }
        else { await alerts.setEnabled(false); await alerts.setEnabled(true) }
        try XCTUnwrap(continuation.value).resume()
        let reply = await oldAnswer.value
        XCTAssertTrue(reply.contains("\"state\":\"disabled\""), reply)
        XCTAssertTrue(sent.isEmpty, "A retired queued intake cannot reach the live channel")
        XCTAssertTrue(push.delivered.isEmpty, "A retired queued intake cannot start push")
        let current = try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile))
        let currentRequest = request(current)
        let currentReply = await Task.detached { AgentAlertBridgeTests.send(currentRequest, toPort: UInt16(current.port)) }.value
        let expected = live ? AgentAlertDisposition.forwarded : AgentAlertDisposition.pushed
        XCTAssertTrue(currentReply.contains("\"state\":\"\(expected.rawValue)\""), currentReply)
        XCTAssertEqual(live ? sent.count : push.delivered.count, 1, "Fresh intake remains usable")
    }

    func testQueuedIntakeCannotForwardAfterTokenReset() async throws {
        try await queuedIntakeIsRetired(resetLink: true, live: true)
    }

    func testQueuedIntakeCannotStartPushAfterTokenReset() async throws {
        try await queuedIntakeIsRetired(resetLink: true, live: false)
    }

    func testQueuedIntakeCannotReviveAfterOffOnForLivePhone() async throws {
        try await queuedIntakeIsRetired(resetLink: false, live: true)
    }

    func testQueuedIntakeCannotReviveAfterOffOnForPush() async throws {
        try await queuedIntakeIsRetired(resetLink: false, live: false)
    }

    func testQueuedIntakeCannotReviveWhenOtherOptInKeepsListenerAlive() async throws {
        try await queuedIntakeIsRetired(resetLink: false, live: true, keepListener: true)
    }

    func testQueuedIntakeCannotStartPushWhenOtherOptInKeepsListenerAlive() async throws {
        try await queuedIntakeIsRetired(resetLink: false, live: false, keepListener: true)
    }

    private func queuedPushIsRetired(resetLink: Bool) async throws {
        phoneIsLive = false
        push.outcome = .sent
        let entered = expectation(description: "push queued on relay executor")
        let pauseOnce = LockedBox(true)
        let continuation = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        push.beforeDelivery = {
            var shouldPause = false
            pauseOnce.mutate { value in shouldPause = value; value = false }
            if shouldPause {
                await withCheckedContinuation { resume in
                    continuation.value = resume
                    entered.fulfill()
                }
            }
        }
        await alerts.setEnabled(true)
        let discovery = try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile))
        let body = #"{"agent":{"kind":"codex","sessionHash":"112233445566"},"type":"needs_user"}"#
        let request = "POST /agent/v1/event HTTP/1.1\r\nHost: 127.0.0.1:\(discovery.port)\r\nAuthorization: Bearer \(discovery.token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let answer = Task.detached { AgentAlertBridgeTests.send(request, toPort: UInt16(discovery.port)) }
        await fulfillment(of: [entered], timeout: 3)
        if resetLink { alerts.resetLink() }
        else { await alerts.setEnabled(false); await alerts.setEnabled(true) }
        try XCTUnwrap(continuation.value).resume()
        let reply = await answer.value
        XCTAssertTrue(reply.contains("\"state\":\"disabled\""), reply)
        XCTAssertTrue(push.delivered.isEmpty, "A push actor hop must keep the original admission")
    }

    func testTokenResetWhilePushIsQueuedPreventsTheOutboundRequest() async throws {
        try await queuedPushIsRetired(resetLink: true)
    }

    func testOffOnWhilePushIsQueuedCannotReviveTheOutboundRequest() async throws {
        try await queuedPushIsRetired(resetLink: false)
    }

    func testNothingListensUntilThePersonTurnsItOn() async {
        XCTAssertFalse(alerts.isOn)
        XCTAssertNil(alerts.statusLine())
        let disposition = await alerts.receive(alert())
        XCTAssertEqual(disposition, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alerts.discoveryFile.path), "No listener, no discovery file")
        XCTAssertTrue(sent.isEmpty)
    }

    func testTurningItOnListensOnThisMacOnlyAndTurningItOffStops() async throws {
        await alerts.setEnabled(true)
        XCTAssertTrue(alerts.isOn)
        XCTAssertTrue(HostPreferences(defaults: defaults).agentAlerts, "The choice is remembered")
        XCTAssertEqual(alerts.statusLine(), "Listening on this Mac only")

        let listening = try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile))
        XCTAssertGreaterThan(listening.port, 0)
        XCTAssertEqual(try mode(of: alerts.discoveryFile), 0o600, "Only this user can read the token")
        XCTAssertEqual(try mode(of: directory), 0o700)

        await alerts.setEnabled(false)
        XCTAssertFalse(alerts.isOn)
        XCTAssertFalse(HostPreferences(defaults: defaults).agentAlerts)
        XCTAssertEqual(try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile)).port, 0,
                       "The file says nothing is listening")
        XCTAssertNil(alerts.statusLine())
    }

    func testItComesBackOnAtLaunchOnlyWhenItWasLeftOn() async throws {
        await alerts.startIfEnabled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: alerts.discoveryFile.path), "Off stays off")

        let restarted = turnOnWithoutListening()
        await restarted.startIfEnabled()
        XCTAssertGreaterThan(try XCTUnwrap(AgentAlertBridge.readDiscovery(at: restarted.discoveryFile)).port, 0)
    }

    func testAResetKeepsAnOldHooksTokenFromWorking() async throws {
        await alerts.setEnabled(true)
        let before = try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile)).token
        alerts.resetLink()
        let after = try XCTUnwrap(AgentAlertBridge.readDiscovery(at: alerts.discoveryFile)).token
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(diary.contains("Agent alert link reset"))
    }

    // MARK: What an alert becomes

    func testALivePhoneGetsTheAlertOnTheControlChannelAsAFrameWithNoWords() async {
        let alerts = turnOnWithoutListening()
        let incoming = alert(kind: .codex)
        let disposition = await alerts.receive(incoming)
        XCTAssertEqual(disposition, .forwarded)
        XCTAssertEqual(sent, [incoming.frame])
        XCTAssertEqual(sent.first?.kind, "codex")
        XCTAssertEqual(sent.first?.event, "needs_user")
        XCTAssertTrue(push.delivered.isEmpty, "A live session never also gets a push")
        XCTAssertTrue(diary.contains { $0.contains("Codex needs you") })
        XCTAssertFalse(diary.joined().contains(incoming.sessionHash), "The log never holds the session hash")
    }

    func testAPhoneThatIsNotInASessionIsForPushAndPushIsAStub() async {
        let alerts = turnOnWithoutListening()
        phoneIsLive = false
        alerts.push = UnconfiguredAgentPushRelay()
        let disposition = await alerts.receive(alert())
        XCTAssertEqual(disposition, .pushUnavailable, "It says plainly that nothing could be sent")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(diary.contains { $0.contains("not configured") })
    }

    func testOnceAPushServiceExistsThePhoneOutsideASessionGetsIt() async {
        let alerts = turnOnWithoutListening()
        phoneIsLive = false
        push.outcome = .sent
        let incoming = alert()
        let disposition = await alerts.receive(incoming)
        XCTAssertEqual(disposition, .pushed)
        XCTAssertEqual(push.delivered, [incoming])
        XCTAssertTrue(sent.isEmpty)
    }

    func testPendingRoomRemovalBlocksPushEvenWithAConfiguredRelay() async {
        let alerts = turnOnWithoutListening()
        phoneIsLive = false
        push.outcome = .sent
        alerts.canUsePush = { false }
        let disposition = await alerts.receive(alert())
        XCTAssertEqual(disposition, .pushUnavailable)
        XCTAssertTrue(push.delivered.isEmpty)
    }

    func testAChannelThatWillNotTakeTheFrameFallsBackToPush() async {
        let alerts = turnOnWithoutListening()
        channelAccepts = false
        push.outcome = .sent
        let disposition = await alerts.receive(alert())
        XCTAssertEqual(disposition, .pushed)
        XCTAssertEqual(push.delivered.count, 1)
    }

    func testWithNoPairedPhoneNothingIsSentAndNothingIsUsedUp() async {
        let alerts = turnOnWithoutListening()
        phoneIsPaired = false
        let first = await alerts.receive(alert("aaaaaaaaaaaa"))
        XCTAssertEqual(first, .noPhone)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(push.delivered.isEmpty)
        phoneIsPaired = true
        let second = await alerts.receive(alert("aaaaaaaaaaaa"))
        XCTAssertEqual(second, .forwarded, "The no-phone ask did not count against the session")
    }

    func testRepeatsFromOneSessionCollapseAndARunawayAgentIsStopped() async {
        let alerts = turnOnWithoutListening()
        let first = await alerts.receive(alert("aaaaaaaaaaaa"))
        let repeated = await alerts.receive(alert("aaaaaaaaaaaa"))
        XCTAssertEqual(first, .forwarded)
        XCTAssertEqual(repeated, .duplicate)
        XCTAssertEqual(sent.count, 1)

        now = now.addingTimeInterval(61)
        let later = await alerts.receive(alert("aaaaaaaaaaaa"))
        XCTAssertEqual(later, .forwarded, "A minute later it is a new ask")

        var last = AgentAlertDisposition.forwarded
        for index in 0..<8 {
            now = now.addingTimeInterval(1)
            last = await alerts.receive(alert(String(format: "%012x", index + 1)))
        }
        XCTAssertEqual(last, .rateLimited, "Six an hour, however many sessions ask")
        XCTAssertEqual(sent.count, 6)
        XCTAssertTrue(diary.contains { $0.contains("too many this hour") })
    }

    func testOutcomeChoicesAreIndependentAndAttentionThenCompletionBothForward() async {
        let alerts = turnOnWithoutListening()
        let outcome = AgentAlert(id: "h_112233445566", kind: .other, event: .completed,
                                 sessionHash: "aaaaaaaaaaaa", raisedAt: now, runHash: "bbbbbbbbbbbb")
        let result9766 = await alerts.receive(outcome)
        XCTAssertEqual(result9766, .disabled)
        await alerts.setOutcome(.completed, enabled: true)
        let result9890 = await alerts.receive(alert("aaaaaaaaaaaa"))
        XCTAssertEqual(result9890, .forwarded)
        let result9970 = await alerts.receive(outcome)
        XCTAssertEqual(result9970, .forwarded)
        await alerts.setEnabled(false)
        let result10075 = await alerts.receive(alert("cccccccccccc"))
        XCTAssertEqual(result10075, .disabled)
        var next = outcome; next.id = "h_112233445567"; next.runHash = "cccccccccccc"
        let result10240 = await alerts.receive(next)
        XCTAssertEqual(result10240, .forwarded)
        next.event = .failed; next.id = "h_112233445568"
        let result10360 = await alerts.receive(next)
        XCTAssertEqual(result10360, .disabled)
    }

    // MARK: The line in Settings

    func testSettingsSaysWhatTheLastAlertDid() async {
        let alerts = turnOnWithoutListening()
        XCTAssertEqual(alerts.statusLine(now: now), "Listening on this Mac only")
        _ = await alerts.receive(alert(kind: .claudeCode))
        XCTAssertEqual(alerts.statusLine(now: now), "Claude Code asked just now · told your iPhone")
        XCTAssertEqual(alerts.statusLine(now: now.addingTimeInterval(125)), "Claude Code asked 2 min ago · told your iPhone")
        XCTAssertEqual(alerts.statusLine(now: now.addingTimeInterval(7300)), "Claude Code asked 2 hr ago · told your iPhone")

        phoneIsLive = false
        now = now.addingTimeInterval(70)
        _ = await alerts.receive(alert("bbbbbbbbbbbb", kind: .cursor))
        XCTAssertEqual(alerts.statusLine(now: now), "Cursor asked just now · your iPhone is not in a session, and push is not on yet")
    }

    // MARK: The hook setup text

    func testTheHookSetupNamesTheScriptAndBothAgentsAndParsesAsJSON() throws {
        let path = "/Users/someone/Library/Application Support/Farside/farside-notify"
        let text = HostAgentAlerts.hookSetup(scriptPath: path)
        XCTAssertTrue(text.contains(path))
        XCTAssertTrue(text.contains("~/.claude/settings.json"))
        XCTAssertTrue(text.contains("~/.codex/hooks.json"))
        XCTAssertTrue(text.contains("Never a prompt, a file name or the agent's own words."))

        for agent in ["claude-code", "codex"] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(HostAgentAlerts.hooksJSON(agent: agent, scriptPath: path).utf8)) as? [String: Any])
            let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
            let command = try XCTUnwrap(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
            XCTAssertEqual(command, "\"\(path)\" --agent \(agent)", "A path with a space stays one word")
            XCTAssertEqual(hooks["Notification"] == nil, agent == "codex")
        }
    }

    func testTheScriptIsCopiedOutOfTheAppSoAnAgentsConfigSurvivesAnUpdate() throws {
        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("#!/bin/sh\necho one\n".utf8).write(to: bundled)

        let installed: URL
        guard case .installed(let url) = alerts.installScript(from: bundled) else {
            return XCTFail("A bundled hook script should install")
        }
        installed = url
        XCTAssertEqual(installed.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(installed.lastPathComponent, HostAgentAlerts.scriptName)
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "#!/bin/sh\necho one\n")
        XCTAssertEqual(try mode(of: installed), 0o755, "An agent has to be able to run it")
        XCTAssertEqual(try mode(of: directory), 0o700)

        try Data("#!/bin/sh\necho two\n".utf8).write(to: bundled)
        guard case .installed = alerts.installScript(from: bundled) else {
            return XCTFail("A newer bundled hook script should replace the installed copy")
        }
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "#!/bin/sh\necho two\n", "A newer app replaces the copy")

        XCTAssertEqual(alerts.installScript(from: nil), .missingBundledScript,
                       "A build without the script reports the missing resource")
    }

    func testHookSetupCopiesTheInstalledPathOnSuccess() throws {
        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        var copiedText: String?

        XCTAssertTrue(alerts.copyHookSetup(from: bundled, failureDisabled: false) { copiedText = $0 })
        let installed = directory.appendingPathComponent(HostAgentAlerts.scriptName)
        XCTAssertTrue(copiedText?.contains(installed.path) == true)
        XCTAssertFalse(copiedText?.contains("/path/to/") == true)
        XCTAssertEqual(alerts.failure, nil)
        XCTAssertEqual(alerts.hookSetupFailure, nil)
    }

    func testMissingHookScriptShowsSetupErrorAndLeavesClipboardUnchanged() {
        var clipboard = "previous clipboard value"

        XCTAssertFalse(alerts.copyHookSetup(from: nil, failureDisabled: false) { clipboard = $0 })
        XCTAssertEqual(clipboard, "previous clipboard value")
        XCTAssertEqual(alerts.statusLine(), "Agent hook setup could not be copied because its script is missing.")
    }

    func testHookSetupFailureDoesNotChangeClipboardWhenFixIsEnabled() throws {
        try Data("blocks directory creation".utf8).write(to: directory)
        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        var clipboard = "previous clipboard value"

        XCTAssertEqual(alerts.installScript(from: bundled), .writeFailed)
        XCTAssertFalse(alerts.copyHookSetup(from: bundled, failureDisabled: false) { clipboard = $0 })
        XCTAssertEqual(clipboard, "previous clipboard value")
        XCTAssertEqual(alerts.statusLine(), "Agent hook setup could not be copied because the script could not be installed.")
    }

    func testHookSetupFailureRetainsLegacyPlaceholderCopyWhenKillSwitchIsEnabled() throws {
        try Data("blocks directory creation".utf8).write(to: directory)
        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        var clipboard: String?

        XCTAssertTrue(alerts.copyHookSetup(from: bundled, failureDisabled: true) { clipboard = $0 })
        XCTAssertTrue(clipboard?.contains("/path/to/\(HostAgentAlerts.scriptName)") == true)
        XCTAssertNil(alerts.failure, "The rollback path keeps the legacy no-error behavior")
        XCTAssertNil(alerts.hookSetupFailure, "The rollback path keeps the legacy no-error behavior")
    }

    func testMissingHookScriptRetainsLegacyPlaceholderWhenKillSwitchIsEnabled() {
        var clipboard: String?

        XCTAssertTrue(alerts.copyHookSetup(from: nil, failureDisabled: true) { clipboard = $0 })
        XCTAssertTrue(clipboard?.contains("/path/to/\(HostAgentAlerts.scriptName)") == true)
        XCTAssertNil(alerts.hookSetupFailure)
    }

    func testSuccessfulHookCopyClearsOnlySetupFailureAndPreservesListenerFailure() async throws {
        try Data("blocks directory creation".utf8).write(to: directory)
        await alerts.setEnabled(true)
        XCTAssertEqual(alerts.failure, "Agent alerts could not start listening.")

        XCTAssertFalse(alerts.copyHookSetup(from: nil, failureDisabled: false) { _ in })
        XCTAssertEqual(alerts.hookSetupFailure, "Agent hook setup could not be copied because its script is missing.")
        XCTAssertEqual(alerts.statusLine(), "Agent hook setup could not be copied because its script is missing.")

        try FileManager.default.removeItem(at: directory)
        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        XCTAssertTrue(alerts.copyHookSetup(from: bundled, failureDisabled: false) { _ in })

        XCTAssertNil(alerts.hookSetupFailure)
        XCTAssertEqual(alerts.failure, "Agent alerts could not start listening.")
        XCTAssertEqual(alerts.statusLine(), "Agent alerts could not start listening.")
    }

    // MARK: From a hook, through the script and the bridge, to the phone

    private nonisolated static func runHook(script: URL, bridgeFile: URL, stdin: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "--agent", "claude-code"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "FARSIDE_BRIDGE_FILE": bridgeFile.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testAnAgentsHookReachesTheLivePhoneEndToEnd() async throws {
        alerts.now = { Date() }
        await alerts.setEnabled(true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("script/agent-hooks/farside-notify")
        let bridgeFile = alerts.discoveryFile
        let hook = #"{"session_id":"sess-9","cwd":"/tmp","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#

        let status = await Task.detached { Self.runHook(script: script, bridgeFile: bridgeFile, stdin: hook) }.value
        XCTAssertEqual(status, 0)
        XCTAssertEqual(sent.count, 1, "The phone was told once")
        let frame = try XCTUnwrap(sent.first)
        XCTAssertEqual(frame.kind, "claude_code")
        XCTAssertEqual(frame.event, "needs_user")
        XCTAssertTrue(AgentAlertFrame.isToken(frame.id, max: 64))
        XCTAssertFalse(String(describing: frame).contains("rm -rf"), "The tool's input never leaves the hook")
        try frame.validate()
        XCTAssertTrue(alerts.statusLine()?.hasPrefix("Claude Code asked just now") == true)

        let again = await Task.detached { Self.runHook(script: script, bridgeFile: bridgeFile, stdin: hook) }.value
        XCTAssertEqual(again, 0)
        XCTAssertEqual(sent.count, 1, "The same session asking again within a minute is the same ask")
    }
}
