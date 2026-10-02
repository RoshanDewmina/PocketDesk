import XCTest

/// The session Live Activity as the system draws it: in the Dynamic Island once the app is in the
/// background, on the Lock Screen, and its End button. The sample activity the app starts under
/// `--ui-live-activity` walks through the same views and states a real session does.
///
/// These tests drive SpringBoard and the simulated Lock Screen, which takes minutes, so they run only
/// when the runner is started with `TEST_RUNNER_FARSIDE_SPRINGBOARD=1`. Each one attaches screenshots
/// and SpringBoard's accessibility tree to the result bundle.
final class LiveActivityUITests: XCTestCase {
    private struct SampleState {
        let phase: String
        let title: String
        let hasEnd: Bool
        let hasReconnect: Bool
    }

    private let states = [
        SampleState(phase: "live", title: "Holding your Mac", hasEnd: true, hasReconnect: false),
        SampleState(phase: "paused", title: "Mac on hold", hasEnd: true, hasReconnect: false),
        SampleState(phase: "reconnecting", title: "Reaching for your Mac", hasEnd: true, hasReconnect: false),
        SampleState(phase: "ended", title: "Let go of your Mac", hasEnd: false, hasReconnect: true),
    ]

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_SPRINGBOARD"] == "1",
                          "Set TEST_RUNNER_FARSIDE_SPRINGBOARD=1 to drive SpringBoard")
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func attachTree(_ name: String) {
        let attachment = XCTAttachment(string: springboard.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func start(_ phase: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x", "--ui-live-activity=\(phase)",
                               "-lockScreen.sessionActivity", "YES", "-lockScreen.showMacName", "NO"]
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        return app
    }

    private func toHomeScreen(settle: TimeInterval) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: settle)
    }

    /// Locks the simulated phone only, then wakes it to the Lock Screen.
    private func showLockScreen() {
        toHomeScreen(settle: 2.0)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 2.0)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        answerTheSystemQuestionIfAsked()
    }

    /// The first Live Activity an app starts makes the system ask, on the Lock Screen, whether to allow
    /// them, and later asks again whether to always allow them. Both answers are remembered for the app.
    private func answerTheSystemQuestionIfAsked() {
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'Always Allow'}")).firstMatch
        guard allow.waitForExistence(timeout: 3), allow.isHittable else { return }
        let question = springboard.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] 'Farside' AND label CONTAINS[c] 'live activit' AND label CONTAINS[c] 'allow'"))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        // Native permission copy may be split into a title and body inside an alert.
        let namedAlert = springboard.alerts.allElementsBoundByIndex.first { alert in
            guard alert.exists && alert.isHittable else { return false }
            let labels = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
                .joined(separator: " ").lowercased()
            return labels.contains("farside") && labels.contains("live activit")
                && labels.contains("allow") && alert.buttons[allow.label].exists
        }
        guard question != nil || namedAlert != nil else {
            let reason = XCTAttachment(string: "SpringBoard Allow action was not a verified Farside Live Activity question; left unanswered")
            reason.name = "missing-state-reason"
            reason.lifetime = .keepAlways
            add(reason)
            return
        }
        let name = allow.label == "Always Allow"
            ? "system-live-activity-always-permission" : "system-live-activity-permission"
        let frame = springboard.frame
        if frame.height > frame.width {
            attach(name)
        } else {
            let reason = XCTAttachment(string: "Verified Farside Live Activity question did not have a portrait SpringBoard frame")
            reason.name = "missing-state-reason"
            reason.lifetime = .keepAlways
            add(reason)
            attach("missing-" + name)
        }
        allow.tap()
        Thread.sleep(forTimeInterval: 2.0)
    }

    private var islandContainer: XCUIElement {
        springboard.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'jindo-container-view'")).firstMatch
    }

    /// A long press on the island expands the activity.
    private func expandIsland() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.045)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func collapseIsland() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func assertButtons(for state: SampleState, where surface: String) -> Bool {
        let titleVisible = springboard.staticTexts[state.title].waitForExistence(timeout: 5)
        let endMatches = springboard.buttons["End session"].exists == state.hasEnd
        let reconnectMatches = springboard.buttons["Reconnect"].exists == state.hasReconnect
        XCTAssertTrue(titleVisible,
                      "\(surface): \(state.phase) should say \"\(state.title)\"")
        XCTAssertEqual(springboard.buttons["End session"].exists, state.hasEnd,
                       "\(surface): End session for \(state.phase)")
        XCTAssertEqual(springboard.buttons["Reconnect"].exists, state.hasReconnect,
                       "\(surface): Reconnect for \(state.phase)")
        return titleVisible && endMatches && reconnectMatches
    }

    private func attachPlan(_ names: [String]) {
        let plan = XCTAttachment(string: names.joined(separator: "\n"))
        plan.name = "capture-plan"
        plan.lifetime = .keepAlways
        add(plan)
    }

    private func attachValidated(_ name: String, valid: Bool) {
        if !valid {
            let reason = XCTAttachment(string: "Native Live Activity state/root validation failed for " + name)
            reason.name = "missing-state-reason"
            reason.lifetime = .keepAlways
            add(reason)
        }
        attach(valid ? name : "missing-" + name)
    }

    @MainActor
    func testEveryStateShowsInTheIslandAndExpands() throws {
        attachPlan(states.flatMap { ["\($0.phase)-compact", "\($0.phase)-expanded"] })
        for state in states {
            let app = start(state.phase)
            toHomeScreen(settle: 8.0)
            // The first activity after an install can take a while: the system loads the widget extension cold.
            let islandVisible = islandContainer.waitForExistence(timeout: 40)
            XCTAssertTrue(islandVisible, "\(state.phase): the island shows the activity")
            Thread.sleep(forTimeInterval: 4.0)
            // Identify this phase in the expanded activity before accepting the compact Island.
            expandIsland()
            if !springboard.staticTexts[state.title].waitForExistence(timeout: 4) { expandIsland() }
            let phaseMatches = islandVisible && assertButtons(for: state, where: "island identity")
            collapseIsland()
            attachValidated("\(state.phase)-compact", valid: phaseMatches && islandContainer.exists)
            attachTree("\(state.phase)-compact-tree")
            expandIsland()
            if !springboard.staticTexts[state.title].waitForExistence(timeout: 4) { expandIsland() }
            attachValidated("\(state.phase)-expanded", valid: islandVisible && assertButtons(for: state, where: "island"))
            attachTree("\(state.phase)-expanded-tree")
            collapseIsland()
            app.terminate()
        }
    }

    @MainActor
    func testTheLockScreenShowsEveryStateWithTheRightButton() throws {
        attachPlan(states.map { "\($0.phase)-lockscreen" })
        for state in states {
            start(state.phase)
            showLockScreen()
            attachValidated("\(state.phase)-lockscreen", valid: assertButtons(for: state, where: "Lock Screen"))
            attachTree("\(state.phase)-lockscreen-tree")
            springboard.swipeUp()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    /// Some checks need a real iPhone; on the simulator they skip and say why (SYSTEM-INTEGRATIONS-REPORT).
    private func skipOnSimulator(_ reason: String) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Needs a real iPhone: \(reason)")
        #endif
    }

    /// App Shortcuts are what Spotlight offers for the app. The system indexes them on its own schedule, so
    /// this attaches what it shows and asserts only that the app itself is found.
    @MainActor
    func testSpotlightOffersTheApp() throws {
        try skipOnSimulator("the simulator's Spotlight never shows XCUITest a search field")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-seed-pairing=Studio Mac", "--ui-x"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        toHomeScreen(settle: 2.0)
        springboard.swipeDown()
        var field = springboard.searchFields.firstMatch
        if !field.waitForExistence(timeout: 4) {
            springboard.otherElements["spotlight-pill"].firstMatch.tap()
            field = springboard.searchFields.firstMatch
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Spotlight opens with a search field")
        field.typeText("Farside")
        Thread.sleep(forTimeInterval: 4)
        attach("spotlight-farside")
        attachTree("spotlight-farside-tree")
        XCTAssertTrue(springboard.staticTexts["Farside"].firstMatch.waitForExistence(timeout: 5), "Spotlight finds the app")
        for shortcut in ["Connect to Mac", "End session", "Is my Mac awake?"] {
            let found = springboard.staticTexts[shortcut].firstMatch.exists
            add(XCTAttachment(string: "\(shortcut): \(found ? "shown" : "not shown yet")"))
        }
        springboard.buttons["Cancel"].firstMatch.tap()
    }

    /// The button runs `EndSessionIntent` for a phone that is locked and an app that is in the background.
    @MainActor
    func testTheEndButtonEndsTheActivityFromTheLockScreen() throws {
        try skipOnSimulator("the simulator's Lock Screen has no passcode, so it cannot show End working on a locked phone, and it did not reliably wake the app for the intent")
        start("live")
        showLockScreen()
        attach("end-before")
        let end = springboard.buttons["End session"]
        XCTAssertTrue(end.waitForExistence(timeout: 5), "the Lock Screen offers End session")
        end.tap()
        // The intent runs in the app, which the system may have to wake first: give it time on a busy machine.
        XCTAssertTrue(springboard.staticTexts["Session ended"].waitForExistence(timeout: 20),
                      "one tap ends the session and shows the closing state")
        attach("end-after")
        XCTAssertFalse(springboard.buttons["End session"].exists, "the kill switch does not outlive the session")
        XCTAssertTrue(springboard.staticTexts["Session ended"].waitForNonExistence(timeout: 20),
                      "the ended activity leaves the Lock Screen on its own")
        attach("end-gone")
    }
}
