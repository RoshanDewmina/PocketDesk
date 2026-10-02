import UserNotifications
import XCTest
@testable import PocketDeskRemote

@MainActor
final class ScreenRecordingApprovalPhoneTests: XCTestCase {
    func testTheMacsApprovalRefusalBecomesItsOwnStateWithExactSteps() {
        let error = FriendlyError.from(status: "Mac unavailable: screenRecordingApproval", previous: nil, macName: "Studio Mac")
        XCTAssertEqual(error?.kind, .screenRecordingApproval)
        XCTAssertEqual(error?.headline, "Approve screen recording on your Mac")
        let health = ConnectionHealth.after(FriendlyError.screenRecordingApproval)
        XCTAssertEqual(health.state, .screenRecordingApproval)
        XCTAssertEqual(health.title, "Approve screen recording on your Mac")
        XCTAssertTrue(health.nextStep.contains("System Settings → Privacy & Security → Screen & System Audio Recording"))
        XCTAssertTrue(health.nextStep.contains("tap Try again"))
        XCTAssertEqual(health.action, .retry)
        XCTAssertFalse(health.causeUnknown)
    }

    func testDuringASessionTheMacsReasonBeatsTheGenericStoppedCapture() {
        let health = ConnectionHealth.session(.init(connected: true, fresh: true, captureHealthy: false,
                                                    blocker: .screenRecordingApproval))
        XCTAssertEqual(health?.state, .screenRecordingApproval)
        let generic = ConnectionHealth.session(.init(connected: true, fresh: true, captureHealthy: false))
        XCTAssertEqual(generic?.state, .sharingStopped, "Without the Mac's report nothing is claimed")
    }

    func testThePhoneAsksForTheApprovalReasonAndTheWidgetShowsIt() throws {
        let expected: Set<String> = ["blocker.1", "blocker.2", "features.32", "input.causal.1",
                                     "input.pencil.1", "video.ltr.1", "video.timing.1"]
        let modern = MacShareBlocker.Handshake.phone
        XCTAssertEqual(Set(modern.features), expected)
        XCTAssertEqual(modern.features.count, 7, "The exact advertised list contains no duplicate names")
        let noClipboard = UserDefaults(suiteName: "TrustPackPhoneTests.\(UUID().uuidString)")!
        noClipboard.set(true, forKey: "clipboardAutoSyncDisabled")
        let optIn = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(sharpen: true, textClarity: true, fullColor: false), defaults: noClipboard)
        XCTAssertEqual(Set(optIn.features), expected.union(["video.refine.1"]))
        XCTAssertLessThanOrEqual(optIn.features.count, 8, "Refinement stays inside the eight-name bound")
        XCTAssertEqual(optIn.options, ["video.clarity.1", SessionFeature.deliberateEnd])
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(optIn)), expected.union(["video.refine.1", "video.clarity.1", SessionFeature.deliberateEnd]))
        XCTAssertEqual(MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(sharpen: false, textClarity: false, fullColor: false), defaults: noClipboard).options, [SessionFeature.deliberateEnd])
        noClipboard.set(true, forKey: DeliberateSessionEnd.disabledDefaultsKey)
        XCTAssertEqual(MacShareBlocker.Handshake.phoneRequest([], defaults: noClipboard), modern)
        let withClipboard = MacShareBlocker.Handshake.phoneRequest([], defaults: UserDefaults(suiteName: "TrustPackPhoneTests.\(UUID().uuidString)")!)
        XCTAssertEqual(withClipboard.options, [SessionFeature.clipboardSync, SessionFeature.deliberateEnd], "Default options remain outside the eight-name feature bound")
        XCTAssertEqual(withClipboard.features, modern.features)
        let modernBody = try JSONEncoder().encode(modern)
        XCTAssertLessThanOrEqual(modernBody.count, 1024)
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: modernBody), expected)
        XCTAssertEqual(MacShareBlocker.screenRecordingApproval.told(to: expected), .screenRecordingApproval)

        let legacy = MacShareBlocker.Handshake(features: ["blocker.1", "blocker.2"])
        let legacyFeatures = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(legacy))
        XCTAssertEqual(legacyFeatures, ["blocker.1", "blocker.2"], "The original two-feature handshake stays readable")
        XCTAssertFalse(legacyFeatures.contains(SessionFeature.extendedFeatureList))
        XCTAssertEqual(MacShareBlocker.screenRecordingApproval.told(to: legacyFeatures), .screenRecordingApproval)
        XCTAssertEqual(MacShareBlocker.screenRecordingApproval.told(to: ["blocker.1"]), .screenRecordingOff)
        XCTAssertEqual(MacWidgetSync.observedPresence(connected: false, departure: nil, failure: .screenRecordingApproval),
                       .screenRecordingApproval)
        XCTAssertEqual(MacWidgetSnapshot.Presence.screenRecordingApproval.label, "Approve on Mac")
    }
}

@MainActor
private final class FakeOwnerAuthenticator: DeviceOwnerAuthenticating {
    var answer: DeviceOwnerCheck = .passed
    private(set) var reasons: [String] = []
    let biometryName = "Face ID"

    func authenticate(reason: String) async -> DeviceOwnerCheck {
        reasons.append(reason)
        return answer
    }
}

@MainActor
final class DeviceOwnerGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var fake: FakeOwnerAuthenticator!
    private var gate: DeviceOwnerGate!

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults("DeviceOwnerGateTests")
        fake = FakeOwnerAuthenticator()
        gate = DeviceOwnerGate(preferences: PhoneSecurityPreferences(defaults: defaults), authenticator: fake)
    }

    func testOffByDefaultAndThenNothingIsAsked() async {
        XCTAssertFalse(gate.preferences.requireOwnerToConnect)
        let outcome = await gate.check(.connect(macName: "Studio Mac"))
        XCTAssertEqual(outcome, .notRequired)
        XCTAssertTrue(outcome.allows)
        XCTAssertTrue(fake.reasons.isEmpty)
    }

    func testWhenOnConnectAndForgetAskTheOwnerEachTime() async {
        gate.preferences.requireOwnerToConnect = true
        let connected = await gate.check(.connect(macName: "Studio Mac"))
        XCTAssertEqual(connected, .passed)
        fake.answer = .refused
        let forget = await gate.check(.forgetMac)
        XCTAssertEqual(forget, .refused)
        XCTAssertFalse(forget.allows)
        XCTAssertEqual(fake.reasons, ["Connect to Studio Mac", "Forget this Mac on this iPhone"])
        XCTAssertEqual(DeviceOwnerGate.message(for: forget, purpose: .forgetMac, biometryName: "Face ID"),
                       "Face ID didn’t confirm it’s you, so this Mac is still paired.")
    }

    func testNoPasscodeBlocksConnectButLetsThePersonTurnTheSettingOff() async {
        gate.preferences.requireOwnerToConnect = true
        fake.answer = .unavailable
        let outcome = await gate.check(.connect(macName: nil))
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(outcome.allows, "Fail closed: an owner check that can't run never lets Connect through")
        XCTAssertNotNil(DeviceOwnerGate.message(for: outcome, purpose: .connect(macName: nil), biometryName: "Face ID"))
        let turnedOff = await gate.setRequired(false)
        XCTAssertTrue(turnedOff)
        XCTAssertFalse(gate.preferences.requireOwnerToConnect)
        let turnedOn = await gate.setRequired(true)
        XCTAssertFalse(turnedOn, "It can't be turned on without a passcode")
    }

    func testChangingTheSettingNeedsTheOwner() async {
        fake.answer = .refused
        let refused = await gate.setRequired(true)
        XCTAssertFalse(refused)
        XCTAssertFalse(gate.preferences.requireOwnerToConnect)
        fake.answer = .passed
        let on = await gate.setRequired(true)
        XCTAssertTrue(on)
        XCTAssertTrue(PhoneSecurityPreferences(defaults: defaults).requireOwnerToConnect)
        fake.answer = .refused
        let off = await gate.setRequired(false)
        XCTAssertFalse(off)
        XCTAssertTrue(gate.preferences.requireOwnerToConnect, "A refused check leaves it on")
    }

    func testOnlyAConnectThatWillStartSomethingAsksSoALiveSessionIsNeverInterrupted() {
        XCTAssertTrue(ConnectGate.asksOwner(.proceed))
        XCTAssertFalse(ConnectGate.asksOwner(.alreadyUnderWay))
        XCTAssertFalse(ConnectGate.asksOwner(.notPaired))
        XCTAssertFalse(ConnectGate.asksOwner(.serverData))
        let live = ConnectGate.decide(paired: true, connected: true, running: true, restartsRunning: true, removalBlocked: false)
        XCTAssertFalse(ConnectGate.asksOwner(live), "A connected session is already under way")
        let widget = ConnectGate.decide(paired: true, connected: false, running: false, restartsRunning: false, removalBlocked: false)
        XCTAssertTrue(ConnectGate.asksOwner(widget), "Widget, Siri and link Connects are asked too")
    }
}

@MainActor
final class NotificationSettingsLinkTests: XCTestCase {
    private var fake: FakeNotificationCenter!
    private var center: AgentAlertCenter!

    override func setUp() {
        super.setUp()
        fake = FakeNotificationCenter()
        center = AgentAlertCenter(center: fake, defaults: makeTestDefaults("NotificationSettingsLinkTests"),
                                  reports: AgentAlertReports())
    }

    func testAuthorizationAsksForTheInAppSettingsLink() {
        XCTAssertTrue(AgentNotification.authorizationOptions.contains(.providesAppNotificationSettings))
        XCTAssertTrue(AgentNotification.authorizationOptions.contains(.alert))
        XCTAssertFalse(AgentNotification.authorizationOptions.contains(.provisional))
    }

    func testTheLinkIsAddedSilentlyOnlyForPeopleWhoAlreadyAllowedAlerts() async {
        fake.accessValue = .notDetermined
        await center.refreshSettingsLink()
        XCTAssertEqual(fake.authorizationRequests, 0, "Alerts off: iOS is never asked")
        center.preferences.alertsEnabled = true
        await center.refreshSettingsLink()
        XCTAssertEqual(fake.authorizationRequests, 0, "Not yet answered: no prompt at launch")
        fake.accessValue = .allowed
        await center.refreshSettingsLink()
        XCTAssertEqual(fake.authorizationRequests, 1)
    }

    func testIOSSettingsOpensAgentAlerts() {
        XCTAssertFalse(center.showsSettings)
        center.openSettingsFromSystem()
        XCTAssertTrue(center.showsSettings)
        XCTAssertNil(center.presentation)
    }
}
