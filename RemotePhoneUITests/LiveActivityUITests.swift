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
    private var requestedLockScreenOrientation: UIDeviceOrientation = .portrait

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
        let actionPredicate = NSPredicate(format: "label IN {'Allow', 'Always Allow'}")
        func verifiedAction(in dialog: XCUIElement) -> XCUIElement? {
            guard dialog.exists && dialog.isHittable else { return nil }
            let labels = ([dialog.label] + dialog.staticTexts.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }.map(\.label))
                .joined(separator: " ").lowercased()
            guard labels.contains("farside"), labels.contains("live activit"), labels.contains("allow") else { return nil }
            return dialog.buttons.matching(actionPredicate).allElementsBoundByIndex
                .first { $0.exists && $0.isHittable }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var ownedAction: XCUIElement?
        repeat {
            // Prefer a native alert and take the action from that exact alert's descendants.
            for alert in springboard.alerts.allElementsBoundByIndex {
                if let action = verifiedAction(in: alert) { ownedAction = action; break }
            }
            if ownedAction == nil {
                let screen = springboard.frame
                let screenArea = screen.width * screen.height
                // Lock Screen questions can be custom containers. Full-screen SpringBoard/root
                // wrappers are excluded; use the smallest visible container owning copy and action.
                let dialogs = springboard.otherElements.containing(actionPredicate).allElementsBoundByIndex
                    .filter { dialog in
                        guard dialog.exists && dialog.isHittable else { return false }
                        let frame = dialog.frame
                        return frame.width > 0 && frame.height > 0
                            && frame.width * frame.height < screenArea * 0.9
                    }
                    .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                for dialog in dialogs {
                    if let action = verifiedAction(in: dialog) { ownedAction = action; break }
                }
            }
            if ownedAction != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let allow = ownedAction else {
            if springboard.buttons.matching(actionPredicate).firstMatch.exists {
                let reason = XCTAttachment(string: "SpringBoard Allow action had no verified common Farside Live Activity dialog container; left unanswered")
                reason.name = "missing-state-reason"
                reason.lifetime = .keepAlways
                add(reason)
            }
            return
        }
        let landscape = requestedLockScreenOrientation == .landscapeLeft || requestedLockScreenOrientation == .landscapeRight
        let name = (landscape ? "landscape-" : "") + (allow.label == "Always Allow"
            ? "system-live-activity-always-permission" : "system-live-activity-permission")
        let frame = springboard.frame
        if landscape ? frame.width > frame.height : frame.height > frame.width {
            attach(name)
        } else {
            let reason = XCTAttachment(string: "Verified Farside Live Activity question did not match requested \(landscape ? "landscape" : "portrait") SpringBoard frame")
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
        let environment = ProcessInfo.processInfo.environment
        let allOrientations = environment["FARSIDE_LIVE_ACTIVITY_ALL_ORIENTATIONS"] == "1"
        if allOrientations {
            #if targetEnvironment(simulator)
            let allowed = ["A69BA21A-8F6A-48BD-972B-FFCCA74036DD", "419A9E16-E7F7-4269-8690-BD2E4DD4437C"]
            let requestedID = environment["FARSIDE_NATIVE_SIMULATOR_ID"] ?? ""
            try XCTSkipUnless(allowed.contains(requestedID) && environment["SIMULATOR_UDID"] == requestedID,
                              "Landscape Lock Screen capture requires an allowed iPad simulator ID matching actual SIMULATOR_UDID")
            #else
            throw XCTSkip("Landscape Lock Screen capture is simulator-only")
            #endif
        }
        let orientations: [UIDeviceOrientation] = allOrientations ? [.portrait, .landscapeLeft] : [.portrait]
        attachPlan(orientations.flatMap { orientation in
            states.map { (orientation == .landscapeLeft ? "landscape-" : "") + "\($0.phase)-lockscreen" }
        })
        defer {
            requestedLockScreenOrientation = .portrait
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in orientations {
            requestedLockScreenOrientation = orientation
            XCUIDevice.shared.orientation = orientation
            for state in states {
                let name = (orientation == .landscapeLeft ? "landscape-" : "") + "\(state.phase)-lockscreen"
                start(state.phase)
                showLockScreen()
                var valid = assertButtons(for: state, where: "Lock Screen")
                if orientation == .landscapeLeft {
                    let deadline = ProcessInfo.processInfo.systemUptime + 4
                    var frame = springboard.frame
                    while frame.width <= frame.height && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                        frame = springboard.frame
                    }
                    let titleVisible = springboard.staticTexts[state.title].exists && springboard.staticTexts[state.title].isHittable
                    let actionsVisible = (!state.hasEnd || (springboard.buttons["End session"].exists && springboard.buttons["End session"].isHittable))
                        && (!state.hasReconnect || (springboard.buttons["Reconnect"].exists && springboard.buttons["Reconnect"].isHittable))
                    let landscapeVisible = frame.width > frame.height && titleVisible && actionsVisible
                    if !landscapeVisible {
                        let reason = XCTAttachment(string: "Landscape Lock Screen \(state.phase) was not verified: SpringBoard frame \(frame.width) × \(frame.height), phase visible=\(titleVisible), expected actions visible=\(actionsVisible)")
                        reason.name = "missing-state-reason"
                        reason.lifetime = .keepAlways
                        add(reason)
                    }
                    valid = valid && landscapeVisible
                }
                attachValidated(name, valid: valid)
                attachTree(name + "-tree")
                springboard.swipeUp()
                Thread.sleep(forTimeInterval: 1.5)
            }
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
