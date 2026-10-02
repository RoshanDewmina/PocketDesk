import XCTest

final class FarsideRedesignUITests: XCTestCase {
    @MainActor
    func testFirstMinuteHomeSharesMacLinkAndKeepsOptionsInMore() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-first60", "-PocketDeskFirstPictureShown", "NO", "-PocketDeskFirst60Disabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["home.getMac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["getfarside.com/mac"].exists)
        app.buttons["home.getMac"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5)
                      || app.buttons["Copy"].waitForExistence(timeout: 3), "Get Mac opens the system share sheet")
        attach("First minute - get Mac share link")
        app.terminate()
        app.launchArguments = ["--ui-seed-pairing=First Mac", "--ui-first60", "-PocketDeskFirstPictureShown", "NO", "-PocketDeskFirst60Disabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["home.connect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.couch"].exists)
        XCTAssertFalse(app.switches["home.localOnly"].exists)
        XCTAssertFalse(app.buttons["home.agentAlerts"].exists)
        XCTAssertFalse(app.buttons["home.pairedMacs"].exists)
        app.buttons["Help and more"].tap()
        XCTAssertTrue(app.buttons["Farside Anywhere"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["How to steer"].exists)
        attach("First minute - later options remain in menu")
    }

    @MainActor
    func testFirstMinuteOptionsReturnAfterPictureAndKillSwitchRestoresHome() {
        let app = XCUIApplication()
        for arguments in [
            ["--ui-seed-pairing=First Mac", "--ui-first60", "-PocketDeskFirstPictureShown", "YES", "-PocketDeskFirst60Disabled", "NO"],
            ["--ui-seed-pairing=First Mac", "--ui-first60", "-PocketDeskFirstPictureShown", "NO", "-PocketDeskFirst60Disabled", "YES"]
        ] {
            app.launchArguments = arguments
            app.launch()
            XCTAssertTrue(app.buttons["home.couch"].waitForExistence(timeout: 5))
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<4 where !app.switches["home.localOnly"].isHittable { scroll.swipeUp() }
            XCTAssertTrue(app.switches["home.localOnly"].exists)
            app.terminate()
        }
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    func testIPadHomeKeepsConnectLeadingAndUtilitiesBesideTheCard() throws {
        try requireIPad()
        let app = XCUIApplication()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.launchArguments = ["--ui-demo-mac"]
            app.launch()
            let connect = app.buttons["home.connect"]
            let card = app.descendants(matching: .any)["home.mac"].firstMatch
            let utilities = app.buttons["home.pairedMacs"]
            XCTAssertTrue(connect.waitForExistence(timeout: 5))
            XCTAssertTrue(utilities.waitForExistence(timeout: 5))
            XCTAssertLessThan(connect.frame.maxX, utilities.frame.minX)
            XCTAssertEqual(card.frame.minY, utilities.frame.minY, accuracy: 4)
            XCTAssertTrue(connect.isHittable)
            XCTAssertTrue(app.staticTexts["Paired with this iPad"].exists)
            attach("iPad Home \(orientation)")
            app.terminate()
        }
    }

    @MainActor
    func testIPadHomeAccessibilityStacksUtilitiesBelowConnect() throws {
        try requireIPad()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let connect = app.buttons["home.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        let utilities = app.buttons["home.pairedMacs"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 where !utilities.isHittable { scroll.swipeUp() }
        XCTAssertTrue(utilities.isHittable, "Stacked utilities remain reachable")
        XCTAssertLessThanOrEqual(abs(connect.frame.midX - utilities.frame.midX), 10)
    }

    @MainActor
    func testIPadPairingFormCanScrollToTheDeviceSpecificSteps() throws {
        try requireIPad()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-pairing-scan", "--ui-camera-priming"]
        app.launch()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        let step = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Point this iPad")).firstMatch
        let form = app.descendants(matching: .any)["pairing.sheet"].firstMatch
        let scroll = form.scrollViews.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable }
        XCTAssertNotNil(scroll, "Scroll the presented form, rather than its covered Home")
        guard let scroll else { return }
        for _ in 0..<5 where !step.isHittable { scroll.swipeUp() }
        XCTAssertTrue(step.isHittable, "The device-specific instruction remains reachable")
        let finish = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Choose Allow on your Mac to finish")).firstMatch
        for _ in 0..<5 where !finish.isHittable { scroll.swipeUp() }
        XCTAssertTrue(finish.isHittable, "A short form must scroll through its final instruction")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        attach("iPad pairing form scrolled")
    }

    @MainActor
    private func requireIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad shell assertion") }
    }

    @MainActor
    func testKeyboardBarPutsCommandFirstAndInReachInPortrait() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        app.buttons["Show controls"].doubleTap()
        let command = app.buttons["Command"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.isHittable, "⌘ must be visible without scrolling the key row")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(command.frame), "⌘ sits fully on screen in portrait")
        XCTAssertLessThan(command.frame.minX, app.buttons["Escape"].frame.minX, "Modifiers come first")
        attach("Keyboard bar - modifiers first")
    }

    @MainActor
    func testDockOffersActionTilesSegmentsAndEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        let handle = app.buttons["Show controls"]
        handle.swipeUp()
        XCTAssertTrue(app.buttons["Hide controls"].waitForExistence(timeout: 5))
        for label in ["Keyboard", "Voice input", "Clipboard", "Controls", "Control desktop", "Move view",
                      "Fit whole display", "Fill screen", "End session"] {
            XCTAssertTrue(app.buttons[label].exists, "Dock is missing \(label)")
        }
        XCTAssertTrue(app.buttons["Control desktop"].isSelected, "Control is the default touch mode")
        XCTAssertTrue(app.buttons["Fill screen"].isSelected, "The fixture starts in Fill")
        app.buttons["Clipboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.clipboard.row"].firstMatch.waitForExistence(timeout: 3))
        attach("Dock - clipboard row")
        app.buttons["Hide controls"].swipeDown()
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["End session"].exists)
    }

    @MainActor
    func testGestureCoachRunsOnALocalPadAndCanBeSkipped() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-coach"]
        app.launch()
        let coach = app.descendants(matching: .any)["coach"].firstMatch
        XCTAssertTrue(coach.waitForExistence(timeout: 5))
        let pad = app.descendants(matching: .any)["coach.pad"].firstMatch
        XCTAssertTrue(pad.exists)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)))
        attach("Gesture coach - move lesson")
        app.buttons["Skip"].tap()
        XCTAssertTrue(coach.waitForNonExistence(timeout: 5), "Skip closes the lessons")
    }

    @MainActor
    func testMoveLessonCanBeCompletedWithRealTouches() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-coach", "--ui-coach-probe"]
        app.launch()
        let pad = app.descendants(matching: .any)["coach.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        let probe = app.descendants(matching: .any)["coach.probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let next = app.buttons["coach.next"]
        for _ in 0..<40 where !next.exists {
            guard let values = (probe.value as? String)?.split(separator: ",").compactMap({ Double($0) }),
                  values.count == 4 else { return XCTFail("coach.probe has no positions") }
            let dx = values[2] - values[0], dy = values[3] - values[1]
            // Finger-to-pointer gain can exceed 1, so move part of the way and re-measure.
            let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = start.withOffset(CGVector(dx: dx * 0.6, dy: dy * 0.6))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        }
        XCTAssertTrue(next.waitForExistence(timeout: 3), "Lesson 1 passes with real touches on the practice pad")
        attach("Gesture coach - move lesson passed")
        next.tap()
        let lesson = app.staticTexts["coach.lesson"]
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", "Lesson 2 of 5 · Click"),
                                                 object: lesson)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 3), .completed,
                       "Next must advance to the click lesson (caption is visually uppercase)")
    }

    @MainActor
    func testAccessibilityXXXLCoachCompletionDoneIsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-coach", "--ui-coach-lesson=5",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let done = app.buttons["coach.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable && app.windows.firstMatch.frame.contains(done.frame))
        attach("AX-XXXL coach completion")
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["coach"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testAccessibilityXXXLCoachCanScrollAndSkipInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-coach", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let coach = app.descendants(matching: .any)["coach"].firstMatch
        XCTAssertTrue(coach.waitForExistence(timeout: 5))
        let scroll = coach.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "The lesson words must scroll, independently of Home")
        scroll.swipeUp()
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.isHittable && app.windows.firstMatch.frame.contains(skip.frame))
        attach("AX-XXXL coach landscape scrolled")
        skip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["coach"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testAccessibilityXXXLCanSkipEveryLessonInBothOrientations() {
        let app = XCUIApplication()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for lesson in 0..<5 {
                app.launchArguments = ["--ui-coach", "--ui-coach-lesson=\(lesson)",
                                       "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                app.launch()
                let coach = app.descendants(matching: .any)["coach"].firstMatch
                XCTAssertTrue(coach.waitForExistence(timeout: 5))
                let skip = app.buttons["Skip"]
                XCTAssertTrue(skip.isHittable && app.windows.firstMatch.frame.contains(skip.frame))
                skip.tap()
                XCTAssertTrue(coach.waitForNonExistence(timeout: 5), "Skip closes lesson \(lesson + 1)")
                app.terminate()
            }
        }
    }

    @MainActor
    func testAccessibilityXXXLZoomLessonFinishAndDoneAreReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-coach", "--ui-coach-lesson=4",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let pad = app.descendants(matching: .any)["coach.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.buttons["coach.next"].exists {
            pad.pinch(withScale: 2, velocity: 1)
        }
        let finish = app.buttons["coach.next"]
        XCTAssertTrue(finish.waitForExistence(timeout: 3))
        XCTAssertTrue(finish.isHittable && app.windows.firstMatch.frame.contains(finish.frame))
        attach("AX-XXXL zoom lesson passed")
        finish.tap()
        let done = app.buttons["coach.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3) && done.isHittable)
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["coach"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testAccessibilityXXXLPrimingContinueStaysOnScreen() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for kind in ["network", "mic", "camera", "notifications"] {
                app.launchArguments = ["--ui-priming-\(kind)", "-UIPreferredContentSizeCategoryName",
                                       "UICTContentSizeCategoryAccessibilityXXXL"]
                app.launch()
                // SwiftUI propagates the primer root identifier onto its safe-area button.
                let next = app.buttons["Continue"]
                XCTAssertTrue(next.waitForExistence(timeout: 5))
                XCTAssertTrue(next.isHittable && app.windows.firstMatch.frame.contains(next.frame),
                              "\(kind) Continue must remain fully on screen in \(orientation)")
                attach("AX-XXXL \(kind) primer \(orientation)")
                app.terminate()
            }
        }
    }

    @MainActor
    func testAccessibilityXXXLPairingMethodsAndCancelAreReachable() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.launchArguments = ["--ui-pairing-scan", "--ui-camera-priming",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5) && cancel.isHittable)
            let paste = app.buttons["Paste Code"]
            for _ in 0..<4 where !paste.isHittable { app.scrollViews.containing(.button, identifier: "Paste Code").firstMatch.swipeUp() }
            XCTAssertTrue(paste.isHittable)
            paste.tap()
            XCTAssertTrue(app.buttons["Pair Mac"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["Pair Mac"].frame))
            attach("AX-XXXL pairing paste")
            cancel.tap()
            XCTAssertFalse(app.buttons["Pair Mac"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testFriendlyErrorGivesOneFixAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-demo-mac", "--ui-error=napping"]
        app.launch()
        let error = app.descendants(matching: .any)["error.napping"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["error.primary"].exists)
        XCTAssertTrue(app.staticTexts["Your Mac is napping."].exists)
        attach("Friendly error - napping")
        app.buttons["Close"].tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["home.mac"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testPairingSaysWhenACodeHasExpired() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-pairing-paste", "--ui-pairing-expired"]
        app.launch()
        let feedback = app.descendants(matching: .any)["pairing.feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.label.contains("expired"), "The scanner and paste field say why a code failed")
        XCTAssertTrue(app.buttons["Pair Mac"].exists)
        attach("Pairing - expired code")
    }

    @MainActor
    private func launchOfflineFixture(_ app: XCUIApplication) {
        app.launch()
        let showControls = app.buttons["Show controls"]
        if showControls.waitForExistence(timeout: 3) { return }
        let returnButton = app.buttons["Return to Farside"]
        guard returnButton.waitForExistence(timeout: 5) else {
            return XCTFail("Offline fixture must either open directly or offer explicit privacy recovery")
        }
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5))
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
