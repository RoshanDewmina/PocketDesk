import UserNotifications
import XCTest
@testable import PocketDeskRemote

final class AgentAlertPayloadTests: XCTestCase {
    /// The repo's `script/push-samples`, found from this file: simulator tests can read the Mac's disk.
    static var samplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("script/push-samples")
    }

    static func sample(_ name: String) throws -> [AnyHashable: Any] {
        let data = try Data(contentsOf: samplesDirectory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
    }

    // MARK: The schema in the spec

    func testTheSpecPayloadRoutesToItsHelpRequest() throws {
        let payload = try XCTUnwrap(AgentAlertPayload(userInfo: Self.sample("agent-needs-you.apns")))
        XCTAssertEqual(payload.helpRequestID, "h_20af")
        XCTAssertEqual(payload.pairingIdentity, "bb4e6754bace2ee18161742a1bfbab72ac3865454f5f00951e7523912d1e7122")
        XCTAssertEqual(payload.kind, .claudeCode)
        XCTAssertEqual(payload.threadID, "mac-7f3a")
        XCTAssertEqual(payload.interruption, .timeSensitive)
        XCTAssertFalse(payload.isReminder)
        XCTAssertFalse(payload.isTest)
    }

    /// Every sample file, with what the phone must make of it.
    func testEachSampleFileRoutesTheWayItsNameSays() throws {
        struct Expected { var id: String; var kind: AgentKind; var interruption: AgentAlertPayload.Interruption; var reminder = false }
        let routed: [String: Expected] = [
            "agent-needs-you.apns": .init(id: "h_20af", kind: .claudeCode, interruption: .timeSensitive),
            "agent-needs-you-active.apns": .init(id: "h_3b71", kind: .codex, interruption: .active),
            "agent-needs-you-unknown-agent.apns": .init(id: "h_5c02", kind: .other, interruption: .active),
            "agent-snooze-reminder.apns": .init(id: "h_20af", kind: .claudeCode, interruption: .passive, reminder: true)
        ]
        for (file, expected) in routed {
            let payload = try XCTUnwrap(AgentAlertPayload(userInfo: Self.sample(file)), file)
            XCTAssertEqual(payload.helpRequestID, expected.id, file)
            XCTAssertEqual(payload.pairingIdentity,
                           "bb4e6754bace2ee18161742a1bfbab72ac3865454f5f00951e7523912d1e7122", file)
            XCTAssertEqual(payload.kind, expected.kind, file)
            XCTAssertEqual(payload.interruption, expected.interruption, file)
            XCTAssertEqual(payload.isReminder, expected.reminder, file)
            XCTAssertEqual(FarsideRoute.agentAlert(id: payload.helpRequestID), FarsideRoute(url: FarsideRoute.agentAlert(id: payload.helpRequestID).url), file)
        }
        for file in ["agent-malformed-id.apns", "agent-wrong-category.apns"] {
            XCTAssertNil(AgentAlertPayload(userInfo: try Self.sample(file)), "\(file) must not route")
        }
    }

    func testSampleFilesAreValidForSimctlAndCarryNoFreeText() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.samplesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "apns" }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 4096, "simctl and APNs cap a payload at 4096 bytes: \(file.lastPathComponent)")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file.lastPathComponent)
            XCTAssertNotNil(object["aps"] as? [String: Any], "simctl requires an aps key: \(file.lastPathComponent)")
        }
        for name in ["agent-needs-you.apns", "agent-needs-you-active.apns", "agent-needs-you-unknown-agent.apns", "agent-snooze-reminder.apns"] {
            let aps = try XCTUnwrap(Self.sample(name)["aps"] as? [String: Any])
            let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
            XCTAssertNil(alert["title"], "The alert is keys and an agent name, never prose: \(name)")
            XCTAssertNil(alert["body"], "The alert is keys and an agent name, never prose: \(name)")
            XCTAssertNotNil(alert["title-loc-key"])
            XCTAssertNotNil(alert["loc-key"])
        }
    }

    // MARK: Hostile and broken input

    func testUnfamiliarAgentNamesAreNeverEchoed() {
        XCTAssertEqual(AgentKind(displayName: "rm -rf /"), .other)
        XCTAssertEqual(AgentKind(displayName: ""), .other)
        XCTAssertEqual(AgentKind(displayName: "  claude code "), .claudeCode)
        XCTAssertEqual(AgentKind(displayName: "CODEX"), .codex)
        XCTAssertEqual(AgentKind.other.displayName, "An agent")
        XCTAssertEqual(AgentKind(wire: "claude_code"), .claudeCode)
        XCTAssertEqual(AgentKind(wire: "nonsense"), .other)
        XCTAssertEqual(AgentKind(wire: nil), .other)
    }

    func testBrokenPayloadsNeverRoute() {
        let goodAps: [String: Any] = ["category": "AGENT_HELP"]
        let cases: [(String, [AnyHashable: Any])] = [
            ("empty", [:]),
            ("no aps", ["hid": "h_1"]),
            ("aps is not a dictionary", ["aps": "x", "hid": "h_1"]),
            ("no category", ["aps": [:] as [String: Any], "hid": "h_1"]),
            ("other category", ["aps": ["category": "X"], "hid": "h_1"]),
            ("no id", ["aps": goodAps]),
            ("id is a number", ["aps": goodAps, "hid": 20]),
            ("id is empty", ["aps": goodAps, "hid": ""]),
            ("id has spaces", ["aps": goodAps, "hid": "h 1"]),
            ("id has slashes", ["aps": goodAps, "hid": "../h_1"]),
            ("id is far too long", ["aps": goodAps, "hid": String(repeating: "a", count: 65)])
        ]
        for (name, userInfo) in cases {
            XCTAssertNil(AgentAlertPayload(userInfo: userInfo), name)
        }
    }

    func testOddFieldsAreIgnoredNotTrusted() throws {
        var userInfo = try Self.sample("agent-needs-you.apns")
        var aps = try XCTUnwrap(userInfo["aps"] as? [String: Any])
        aps["thread-id"] = "not valid!"
        aps["interruption-level"] = "banana"
        aps["alert"] = ["title-loc-args": [42, "Codex"]]
        userInfo["aps"] = aps
        userInfo["extra"] = ["ignored": true]
        let payload = try XCTUnwrap(AgentAlertPayload(userInfo: userInfo))
        XCTAssertNil(payload.threadID)
        XCTAssertNil(payload.interruption)
        XCTAssertEqual(payload.kind, .other, "A first argument that is not a name from the list is not used")
    }

    func testALocalTwinParsesBackToTheSamePayload() throws {
        let payload = AgentAlertPayload(helpRequestID: "h_abc9", kind: .cursor,
                                        pairingIdentity: String(repeating: "a", count: 64),
                                        threadID: "mac-1", interruption: .timeSensitive)
        XCTAssertEqual(AgentAlertPayload(userInfo: payload.userInfo), payload)
        var test = payload
        test.isTest = true
        XCTAssertEqual(AgentAlertPayload(userInfo: test.userInfo), test)
        var reminder = payload
        reminder.isReminder = true
        XCTAssertEqual(AgentAlertPayload(userInfo: reminder.userInfo), reminder)
    }

    // MARK: Category

    func testTheCategoryHasTwoBackgroundActionsAndSafePreviewCopy() throws {
        let categories = AgentNotification.categories()
        let help = try XCTUnwrap(categories.first { $0.identifier == "AGENT_HELP" })
        XCTAssertEqual(help.actions.map(\.identifier), ["SNOOZE_15", "NOT_NOW"])
        XCTAssertEqual(help.actions.map(\.title), ["Snooze 15 min", "Not now"])
        for action in help.actions {
            XCTAssertFalse(action.options.contains(.foreground), "An action that only opens the app repeats the tap")
            XCTAssertFalse(action.options.contains(.destructive))
            XCTAssertFalse(action.options.contains(.authenticationRequired), "Neither action touches the Mac")
        }
        XCTAssertTrue(help.options.contains(.customDismissAction))
        XCTAssertTrue(help.options.contains(.hiddenPreviewsShowTitle))
        XCTAssertEqual(help.hiddenPreviewsBodyPlaceholder, "An agent needs you.")

        let reminder = try XCTUnwrap(categories.first { $0.identifier == "AGENT_HELP_REMINDER" })
        XCTAssertEqual(reminder.actions.map(\.identifier), ["NOT_NOW"], "The one reminder cannot be snoozed again")
        XCTAssertEqual(categories.count, 2)
    }

    func testSnoozeStaysFirstSoAWatchDoubleTapOnlySnoozes() throws {
        let reason = "Double Tap on Series 9 / Ultra 2 runs the first non-destructive action, so an accidental pinch must only snooze"
        let categories = AgentNotification.categories()
        let help = try XCTUnwrap(categories.first { $0.identifier == "AGENT_HELP" })
        let first = try XCTUnwrap(help.actions.first)
        XCTAssertEqual(first.identifier, "SNOOZE_15", reason)
        XCTAssertFalse(first.options.contains(.destructive), reason)
        XCTAssertFalse(first.options.contains(.foreground), reason)
        XCTAssertFalse(first.options.contains(.authenticationRequired), reason)

        let reminder = try XCTUnwrap(categories.first { $0.identifier == "AGENT_HELP_REMINDER" })
        XCTAssertEqual(reminder.actions.first?.identifier, "NOT_NOW", "The reminder has no Snooze. " + reason)
    }

    func testAlertCopyLivesInTheBundleAndIsLiteral() {
        XCTAssertEqual(String(format: NSLocalizedString("AGENT_NEEDS_YOU_TITLE", comment: ""), "Claude Code"), "Claude Code needs you")
        XCTAssertEqual(NSLocalizedString("AGENT_NEEDS_YOU_BODY", comment: ""),
                       "Stuck on something only a human can click. Open Farside on your iPhone to look.")
        XCTAssertFalse(NSLocalizedString("AGENT_NEEDS_YOU_BODY", comment: "").contains("Tap"), "On a Watch, a tap leads nowhere")
        XCTAssertEqual(NSLocalizedString("AGENT_REMINDER_BODY", comment: ""), "Still waiting on you.")
        for key in ["AGENT_NEEDS_YOU_BODY", "AGENT_TEST_BODY", "AGENT_REMINDER_BODY"] {
            XCTAssertFalse(NSLocalizedString(key, comment: "").contains("!"), "Summaries read this text: keep it literal")
        }
    }

    // MARK: Small helpers

    func testAgeIsShortAndHonest() {
        XCTAssertEqual(AgentAlertPresentation.ageText(5), "just now")
        XCTAssertEqual(AgentAlertPresentation.ageText(44), "just now")
        XCTAssertEqual(AgentAlertPresentation.ageText(120), "2 min ago")
        XCTAssertEqual(AgentAlertPresentation.ageText(59 * 60), "59 min ago")
        XCTAssertEqual(AgentAlertPresentation.ageText(3600), "1 hr ago")
        XCTAssertEqual(AgentAlertPresentation.ageText(3 * 3600 + 500), "3 hr ago")
        XCTAssertEqual(AgentAlertPresentation.ageText(-30), "just now")
        let asked = Date(timeIntervalSince1970: 1_000)
        let item = AgentAlertPresentation(payload: .init(helpRequestID: "h_1", kind: .other), receivedAt: asked)
        XCTAssertEqual(item.freshness(at: asked.addingTimeInterval(14 * 60)), .fresh)
        XCTAssertEqual(item.freshness(at: asked.addingTimeInterval(16 * 60)), .old)
    }
}
