import XCTest

final class FarsideRedesignUITests: XCTestCase {
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
    func testDockOffersKeysMicClipFitModeSegmentsAndEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"]
        launchOfflineFixture(app)
        let handle = app.buttons["Show controls"]
        handle.swipeUp()
        XCTAssertTrue(app.buttons["Hide controls"].waitForExistence(timeout: 5))
        for label in ["Keyboard", "Voice input", "Clipboard", "Fit whole display", "Move view",
                      "Fit", "Fill", "View", "Control", "Controls", "End session"] {
            XCTAssertTrue(app.buttons[label].exists, "Dock is missing \(label)")
        }
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


/// Offline simulator receipts only. Synthesized gestures, fixture screenshots and XCTest audits
/// do not establish physical gesture feel, VoiceOver usability, or live-session snapshot privacy.
final class ClaimsVerificationUITests: XCTestCase {
    private let accessibilityXXXL = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = true // Enumerate every fixture even when an earlier audit finds issues.
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    func testCoachLessonsUseSynthesizedGesturesAllFive() {
        let app = XCUIApplication()
        // Each launch starts a particular lesson; only its real completion gate may reveal Next.
        // No Skip, model call or pre-completed fixture is used to claim that lesson passed.
        for lesson in 0..<5 {
            app.launchArguments = ["--ui-coach", "--ui-coach-probe", "--ui-coach-lesson=\(lesson)",
                                   "-pointerSensitivity", "1"]
            app.launch()
            let pad = app.descendants(matching: .any)["coach.pad"].firstMatch
            guard pad.waitForExistence(timeout: 5) else {
                XCTFail("Lesson \(lesson + 1) has no practice pad")
                capture(app, "coach-\(lesson + 1)-missing")
                app.terminate()
                continue
            }
            let next = app.buttons["coach.next"]
            XCTAssertFalse(next.exists, "A lesson must start behind its completion gate")
            switch lesson {
            case 0:
                for _ in 0..<40 where !next.exists {
                    guard let points = coachPositions(app) else { break }
                    moveFinger(pad, delta: CGVector(dx: (points[2] - points[0]) * 0.6,
                                                   dy: (points[3] - points[1]) * 0.6))
                }
            case 1:
                // Tap far from Yes: the existing pointer, rather than the finger, chooses Yes.
                pad.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tap()
            case 2:
                // Public XCTest offers no two-finger swipe. This is its public mouse-scroll API,
                // not touch-scroll proof. A missing gate is a failure, never a forced completion.
                receipt("coach-scroll-input-limitation", "XCTest scroll(byDeltaX:deltaY:) synthesizes pointer scrolling. "
                        + "Two-finger touch scrolling remains a physical/manual acceptance gate even if Next appears.")
                for _ in 0..<6 where !next.exists {
                    pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                        .scroll(byDeltaX: 0, deltaY: -180)
                }
            case 3:
                // Pointer starts on the file. Re-measure after each drop; pick it up again if
                // a partial drag has not reached the folder. Geometry comes from this pad.
                for _ in 0..<20 where !next.exists {
                    guard let points = coachPositions(app) else { break }
                    let desired = CGPoint(x: pad.frame.width - 78, y: pad.frame.height - 104)
                    let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
                    let delta = CGVector(dx: (desired.x - points[0]) * 0.4,
                                         dy: (desired.y - points[1]) * 0.4)
                    let end = start.withOffset(delta)
                    start.tap()
                    start.press(forDuration: 0.55, thenDragTo: end,
                                withVelocity: .slow, thenHoldForDuration: 0.1)
                }
            default:
                for _ in 0..<4 where !next.exists { pad.pinch(withScale: 2, velocity: 1) }
            }
            capture(app, "coach-\(lesson + 1)-completion-attempt")
            guard next.waitForExistence(timeout: 3) else {
                XCTFail("Lesson \(lesson + 1) did not pass through its gesture completion gate")
                app.terminate()
                continue
            }
            XCTAssertTrue(next.isHittable)
            next.tap()
            if lesson == 4 {
                let done = app.buttons["coach.done"]
                if done.waitForExistence(timeout: 3) {
                    capture(app, "coach-done-after-pinch")
                    XCTAssertTrue(done.isHittable)
                    done.tap()
                    XCTAssertTrue(app.descendants(matching: .any)["coach"].firstMatch.waitForNonExistence(timeout: 5))
                } else { XCTFail("Finish must reveal Done") }
            } else {
                let caption = app.staticTexts["coach.lesson"]
                let advanced = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label CONTAINS[c] %@", "Lesson \(lesson + 2) of 5"), object: caption)
                XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 3), .completed)
            }
            app.terminate()
        }
    }

    @MainActor
    func testSessionPinchChangesAccessibleZoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "--ui-controls-settings", "--ui-controls-page=view"]
        app.launch()
        guard recoverFixtureIfNeeded(app), let before = currentZoom(app) else { return }
        capture(app, "session-zoom-before-pinch")
        app.buttons["Done"].firstMatch.tap()
        let canvas = app.descendants(matching: .any)["remote.canvas"].firstMatch
        guard canvas.waitForExistence(timeout: 5) else { return XCTFail("Offline session has no canvas") }
        canvas.pinch(withScale: 2, velocity: 1)
        capture(app, "session-after-real-pinch-touches")
        if app.buttons["Show controls"].exists { app.buttons["Show controls"].swipeUp() }
        let controls = app.buttons["Controls"].firstMatch
        guard controls.waitForExistence(timeout: 5) else { return XCTFail("Controls must remain reachable after pinch") }
        controls.tap()
        let settings = app.buttons["remote.controls.settings"].firstMatch
        guard settings.waitForExistence(timeout: 5) else { return XCTFail("Settings must remain reachable after pinch") }
        settings.tap()
        let view = app.buttons["remote.settings.view"].firstMatch
        guard view.waitForExistence(timeout: 5) else { return XCTFail("View settings must expose zoom") }
        view.tap()
        guard let after = currentZoom(app) else { return }
        XCTAssertGreaterThan(after, before, "A synthesized pinch must change the accessible viewport zoom")
        receipt("session-pinch-zoom-values", "Before: \(before); after: \(after). Offline viewport only; no Mac zoom claim.")
        capture(app, "session-zoom-after-pinch")
        app.terminate()
    }

    @MainActor
    func testKeyboardAndNonRecordingDictationRemainReachable() {
        let app = XCUIApplication()
        for size in [[], accessibilityXXXL] {
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let name = "\(size.isEmpty ? "default" : "AX-XXXL")-\(orientation.rawValue)"
                app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill"] + size
                app.launch()
                if recoverFixtureIfNeeded(app) {
                    let handle = app.buttons["Show controls"]
                    if handle.waitForExistence(timeout: 5) { handle.doubleTap() }
                    else { XCTFail("Dock handle missing for \(name)") }
                    let editor = app.textViews.firstMatch
                    XCTAssertTrue(editor.waitForExistence(timeout: 5), "Keyboard editor must open for \(name)")
                    let command = app.buttons["Command"]
                    XCTAssertTrue(command.exists && command.isHittable && app.windows.firstMatch.frame.contains(command.frame),
                                  "Command must remain fully on screen for \(name)")
                    let hide = app.buttons["remote.keyboard.hide"]
                    XCTAssertTrue(hide.exists && hide.isHittable && app.windows.firstMatch.frame.contains(hide.frame),
                                  "Farside keyboard dismissal must remain fully on screen")
                    XCTAssertFalse(app.buttons["Send text"].isEnabled, "Offline fixture never sends a draft to a Mac")
                    capture(app, "keyboard-\(name)")
                    if hide.isHittable { hide.tap() }
                    XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
                }
                app.terminate()
                // This fixture loads a local transcript without requesting microphone access.
                app.launchArguments = ["--ui-layout-check", "--ui-voice-preview-check"] + size
                app.launch()
                if recoverFixtureIfNeeded(app) {
                    let transcript = app.descendants(matching: .any)["remote.voice.transcript"].firstMatch
                    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
                    let done = app.buttons["remote.voice.done"]
                    XCTAssertTrue(done.exists && done.isHittable && app.windows.firstMatch.frame.contains(done.frame),
                                  "Dictation Done must remain fully on screen for \(name)")
                    XCTAssertFalse(done.isEnabled, "Offline transcript cannot insert text on a Mac")
                    capture(app, "dictation-preview-\(name)")
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testOfflineConcealmentFixtureAndHomeBackgroundForeground() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-background-concealed-check"]
        app.launch()
        assertConcealed(app, name: "privacy-launch-concealed")
        let recovery = app.buttons["Return to Farside"]
        if recovery.isHittable { recovery.tap() }
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 5))
        capture(app, "privacy-before-home-background")
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
        capture(app, "privacy-home-background-system-screen")
        app.activate()
        assertConcealed(app, name: "privacy-after-home-foreground")
        receipt("privacy-evidence-boundary", "Real Home background/foreground lifecycle on an offline simulator fixture. "
                + "Attachments do not prove the live remote desktop's app-switcher snapshot on physical hardware is concealed.")
        if recovery.isHittable { recovery.tap() }
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 5), "Only explicit Return restores the fixture")
        app.terminate()
    }

    @MainActor
    func testAccessibilityAuditAllScreensDefaultSize() {
        auditInventory(sizeArguments: [], sizeName: "default")
    }

    @MainActor
    func testAccessibilityAuditAllScreensAccessibilityXXXL() {
        auditInventory(sizeArguments: accessibilityXXXL, sizeName: "AX-XXXL")
    }

    private enum AuditAction { case openLANWake }

    private struct AuditFixture {
        let name: String
        let arguments: [String]
        let marker: String
        var navigationTitle: String? = nil
        var action: AuditAction? = nil
        var orientation: UIDeviceOrientation = .portrait
    }

    @MainActor
    private func auditInventory(sizeArguments: [String], sizeName: String) {
        let session = ["--ui-layout-check", "--ui-viewport-fill"]
        var fixtures = [
            AuditFixture(name: "home-empty", arguments: ["--ui-x"], marker: "Paste a pairing code"),
            AuditFixture(name: "home-demo", arguments: ["--ui-demo-mac", "--ui-last-reached"], marker: "home.mac"),
            AuditFixture(name: "home-connecting", arguments: ["--ui-demo-mac", "--ui-status=Authenticating_your_Mac…"], marker: "phone.home"),
            AuditFixture(name: "pairing-paste", arguments: ["--ui-pairing-paste"], marker: "Pair Mac"),
            AuditFixture(name: "pairing-expired", arguments: ["--ui-pairing-paste", "--ui-pairing-expired"], marker: "pairing.feedback"),
            AuditFixture(name: "pairing-scan-permission", arguments: ["--ui-pairing-scan", "--ui-camera-priming"], marker: "Paste Code"),
            AuditFixture(name: "pairing-scan-denied", arguments: ["--ui-pairing-scan", "--ui-camera-denied"], marker: "Paste Code"),
            AuditFixture(name: "session", arguments: session, marker: "remote.canvas"),
            AuditFixture(name: "session-dock", arguments: session + ["--ui-dock-open"], marker: "Hide controls"),
            AuditFixture(name: "session-keyboard", arguments: session + ["--ui-keyboard-check"], marker: "remote.keyboard.hide"),
            AuditFixture(name: "session-dictation", arguments: session + ["--ui-voice-preview-check"], marker: "remote.voice.transcript"),
            AuditFixture(name: "session-clipboard", arguments: session + ["--ui-clipboard-row"], marker: "remote.clipboard.row"),
            AuditFixture(name: "session-controls", arguments: session + ["--ui-controls-check"], marker: "remote.controls.content"),
            AuditFixture(name: "session-settings", arguments: session + ["--ui-controls-settings"],
                         marker: "remote.controls.page", navigationTitle: "Settings"),
            AuditFixture(name: "session-data-notice", arguments: session + ["--ui-dock-open", "--ui-data-warning"], marker: "remote.dataWarning"),
            AuditFixture(name: "session-reconnecting", arguments: session + ["--ui-reconnecting"], marker: "remote.reconnecting"),
            AuditFixture(name: "session-sharing-stopped", arguments: session + ["--ui-issue-sharing"], marker: "remote.issue.screenSharingOff"),
            AuditFixture(name: "concealed", arguments: session + ["--ui-background-concealed-check"], marker: "Return to Farside"),
            AuditFixture(name: "paywall", arguments: ["--ui-paywall"], marker: "anywhere.paywall"),
            AuditFixture(name: "troubleshoot", arguments: ["--ui-demo-mac", "--ui-troubleshoot"], marker: "Close")
        ]
        for kind in ["network", "mic", "camera", "notifications"] {
            fixtures.append(AuditFixture(name: "primer-\(kind)", arguments: ["--ui-priming-\(kind)"], marker: "Continue"))
        }
        for lesson in 0...5 {
            fixtures.append(AuditFixture(name: lesson == 5 ? "coach-done" : "coach-lesson-\(lesson + 1)",
                                         arguments: ["--ui-coach", "--ui-coach-lesson=\(lesson)"],
                                         marker: lesson == 5 ? "coach.done" : "coach.pad"))
        }
        // All pages reachable from the current Settings rows, including the six principal pages.
        let settingsPages = [("display", "Display"), ("picture", "Picture"), ("pointer", "Pointer"),
                             ("touch", "Touch"), ("view", "View"), ("clipboard", "Clipboard"),
                             ("keyboard", "Keyboard and pointer"), ("steer", "How to steer"), ("diagnostics", "Diagnostics")]
        for (page, title) in settingsPages {
            let displayPreview = page == "display" ? ["--ui-input-probe", "--ui-probe-quiet"] : []
            fixtures.append(AuditFixture(name: "settings-\(page)", arguments: session + displayPreview +
                                         ["--ui-controls-settings", "--ui-controls-page=\(page)"],
                                         marker: "remote.controls.page", navigationTitle: title))
        }
        // The helper row belongs to overlay Settings (iPad or landscape phone). Navigate it
        // through the real row; never request a packet or manufacture helper authority.
        fixtures.append(AuditFixture(name: "settings-lan-wake", arguments: session + ["--ui-controls-settings"],
                                     marker: "Owner-registered wake target ID", navigationTitle: "LAN wake",
                                     action: .openLANWake, orientation: .landscapeLeft))
        for kind in ["napping", "unreachable", "busy", "locked", "needsPlan", "codeRejected", "declined",
                     "approvalTimedOut", "verifyFailed", "relayUnavailable", "connectionLost", "sessionGlitch",
                     "anywhereUnverified", "couchNotLocal", "couchControlOff"] {
            fixtures.append(AuditFixture(name: "error-\(kind)", arguments: ["--ui-demo-mac", "--ui-error=\(kind)"], marker: "error.primary"))
        }
        let app = XCUIApplication()
        var issues = [String]()
        for fixture in fixtures {
            let name = "\(sizeName)-\(fixture.name)"
            XCTContext.runActivity(named: "Accessibility audit \(name)") { _ in
                XCUIDevice.shared.orientation = fixture.orientation
                app.launchArguments = fixture.arguments + sizeArguments
                app.launch()
                // Recovery is explicit and applies only to ordinary offline session fixtures.
                if fixture.arguments.contains("--ui-layout-check"), fixture.name != "concealed" {
                    _ = recoverFixtureIfNeeded(app)
                }
                if fixture.action == .openLANWake {
                    let row = app.buttons["Wake another Mac on this LAN"].firstMatch
                    if row.waitForExistence(timeout: 5) {
                        let form = app.scrollViews.firstMatch
                        for _ in 0..<6 where !row.isHittable && form.exists { form.swipeUp() }
                        if row.isHittable { row.tap() }
                        else { issues.append("\(name): LAN wake row is not reachable") }
                    } else { issues.append("\(name): LAN wake row is missing from overlay Settings") }
                }
                let marker = app.descendants(matching: .any)[fixture.marker].firstMatch
                if !marker.waitForExistence(timeout: 5) {
                    issues.append("\(name): expected fixture marker missing: \(fixture.marker)")
                }
                if let title = fixture.navigationTitle, !app.navigationBars[title].waitForExistence(timeout: 5) {
                    issues.append("\(name): expected settings page title missing: \(title)")
                }
                audit(app, name: name, issues: &issues)
                // Audit content reachable below the fold as well as the initial view. Use a
                // container swipe, never press permission/connection/purchase actions.
                let scroll = app.scrollViews.firstMatch
                if scroll.exists {
                    scroll.swipeUp()
                    audit(app, name: "\(name)-scrolled", issues: &issues)
                }
                app.terminate()
            }
        }
        receipt("\(sizeName)-audit-inventory", "Fixtures attempted: \(fixtures.count)\nRecorded issues/errors: \(issues.count)\n"
                + "Coverage is limited to the named debug fixtures and LAN wake navigation. Native OS permission alerts, "
                + "hardware camera scanning, live authenticated/provider states, enabled wake confirmation, purchase flows, "
                + "and actual VoiceOver navigation are excluded and remain separate acceptance gates.\n"
                + issues.joined(separator: "\n\n"))
        XCTAssertTrue(issues.isEmpty, "All unfiltered .all audit findings and fixture/audit failures are retained; "
                      + "\(issues.count) issue(s). See inventory and per-screen attachments.")
    }

    @MainActor
    private func audit(_ app: XCUIApplication, name: String, issues: inout [String]) {
        capture(app, "\(name)-audit")
        let controls = app.buttons.allElementsBoundByIndex + app.switches.allElementsBoundByIndex
            + app.sliders.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex
            + app.secureTextFields.allElementsBoundByIndex + app.textViews.allElementsBoundByIndex
            + app.links.allElementsBoundByIndex
        let controlLines = controls.map { element in
            "type=\(element.elementType.rawValue); identifier=\(element.identifier); label=\(element.label); "
                + "value=\(String(describing: element.value)); enabled=\(element.isEnabled); frame=\(element.frame)"
        }
        receipt("\(name)-separate-accessible-controls", "Separately exposed control inventory for VoiceOver review. "
                + "This is an accessibility-tree receipt; actual VoiceOver navigation remains a physical acceptance gate.\n"
                + controlLines.joined(separator: "\n"))
        // SDK 27 XCUIAccessibilityAuditTypes.h: All = ~0UL; iOS availability begins at 17.
        // Returning true lets enumeration continue; every issue is retained and fails the
        // overall inventory assertion. No audit types, elements or issue classes are ignored.
        var findings = [String]()
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                let detail = "\(name)\nAudit type: \(issue.auditType.rawValue)\n\(issue.compactDescription)\n"
                    + "\(issue.detailedDescription)\nElement: \(issue.element?.debugDescription ?? "nil")"
                findings.append(detail)
                print(detail)
                self.receipt("\(name)-issue-\(findings.count)", detail)
                return true
            }
        } catch {
            let detail = "\(name): audit could not complete: \(error)"
            findings.append(detail)
            receipt("\(name)-audit-error", detail)
        }
        issues.append(contentsOf: findings)
    }

    @MainActor
    private func recoverFixtureIfNeeded(_ app: XCUIApplication) -> Bool {
        let recovery = app.buttons["Return to Farside"]
        if recovery.exists {
            guard recovery.isHittable else { XCTFail("Fixture privacy recovery is unreachable"); return false }
            recovery.tap()
        }
        return app.wait(for: .runningForeground, timeout: 5)
    }

    @MainActor
    private func assertConcealed(_ app: XCUIApplication, name: String) {
        XCTAssertTrue(app.staticTexts["Session ended"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Return to Farside"].exists)
        for label in ["Controls", "Keyboard", "Clipboard", "Release", "Send text"] {
            XCTAssertFalse(app.buttons[label].exists, "Concealed content must not expose \(label)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["remote.canvas"].firstMatch.exists)
        capture(app, name)
    }

    @MainActor
    private func currentZoom(_ app: XCUIApplication) -> Double? {
        let value = app.staticTexts["Current zoom"]
        guard value.waitForExistence(timeout: 5), let text = value.value as? String,
              let number = Double(text.replacingOccurrences(of: ",", with: ".")) else {
            XCTFail("View settings must expose the numeric zoom value")
            return nil
        }
        return number
    }

    @MainActor
    private func coachPositions(_ app: XCUIApplication) -> [Double]? {
        let probe = app.descendants(matching: .any)["coach.probe"].firstMatch
        guard let text = probe.value as? String else { XCTFail("Coach probe has no value"); return nil }
        let points = text.split(separator: ",").compactMap { Double($0) }
        guard points.count == 4 else { XCTFail("Coach probe has no pointer/target positions: \(text)"); return nil }
        return points
    }

    @MainActor
    private func moveFinger(_ pad: XCUIElement, delta: CGVector) {
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        // Keep each synthesized finger drag inside the pad, including short iPad/phone layouts.
        let limitX = pad.frame.width * 0.35, limitY = pad.frame.height * 0.35
        let end = start.withOffset(CGVector(dx: min(limitX, max(-limitX, delta.dx)),
                                           dy: min(limitY, max(-limitY, delta.dy))))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        receipt("\(name)-hierarchy", app.state == .runningForeground ? app.debugDescription : "App state: \(app.state.rawValue); screenshot shows system UI.")
    }

    private func receipt(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}


// Integration: append this extension to FarsideRedesignUITests.swift AFTER its existing
// ClaimsVerificationUITests declaration, only after the original simulator runs finish.
// Keep it in that same source file so the private audit/capture/receipt helpers are accessible.
// Do not add this staging file as another project source or rerun the original six methods.
extension ClaimsVerificationUITests {
    @objc @MainActor
    func testAccessibilityAuditSupplementalHomeUtilitiesDefaultSize() {
        supplementalAuditHomeUtilities(sizeArguments: [], sizeName: "default")
    }

    @objc @MainActor
    func testAccessibilityAuditSupplementalHomeUtilitiesAccessibilityXXXL() {
        supplementalAuditHomeUtilities(sizeArguments: accessibilityXXXL, sizeName: "AX-XXXL")
    }

    private enum SupplementalHomeEntry {
        case menu(String)
        case homeRow(String)
        case connectPromptLink
    }

    private struct SupplementalHomeFixture {
        let name: String
        let entry: SupplementalHomeEntry
        let title: String?
        let marker: String?
    }

    @MainActor
    private func supplementalAuditHomeUtilities(sizeArguments: [String], sizeName: String) {
        let fixtures = [
            SupplementalHomeFixture(name: "your-macs", entry: .menu("Your Macs"), title: "Your Macs", marker: nil),
            SupplementalHomeFixture(name: "connection-details", entry: .menu("Connection Details"),
                                    title: "Connection Details", marker: nil),
            SupplementalHomeFixture(name: "third-party-notices", entry: .menu("Third-Party Notices"),
                                    title: "Third-Party Notices", marker: nil),
            SupplementalHomeFixture(name: "server-data-disclosure", entry: .menu("Server Data"),
                                    title: "Server Data", marker: nil),
            SupplementalHomeFixture(name: "security-settings", entry: .menu("Settings"),
                                    title: "Settings", marker: "settings.security.requireOwner"),
            SupplementalHomeFixture(name: "alerts-lock-screen", entry: .homeRow("home.agentAlerts"),
                                    title: "Alerts & Lock Screen", marker: "agent.settings"),
            SupplementalHomeFixture(name: "useful-session-progress", entry: .homeRow("Session check"),
                                    title: "Session check", marker: nil),
            SupplementalHomeFixture(name: "connect-prompt", entry: .connectPromptLink,
                                    title: nil, marker: "connectPrompt")
        ]
        let quietDefaults = ["-agentAlerts.enabled", "NO", "-agentAlerts.breakThroughFocus", "NO",
                             "-lockScreen.showMacName", "NO", "-lockScreen.sessionActivity", "YES"]
        let app = XCUIApplication()
        var issues = [String]()
        var menuAudited = false
        XCUIDevice.shared.orientation = .portrait
        for fixture in fixtures {
            let name = "supplemental-\(sizeName)-\(fixture.name)"
            XCTContext.runActivity(named: "Accessibility audit \(name)") { _ in
                // This existing seed is an in-memory pairing to loopback port 9. Never select,
                // remove or change a real pairing; never press Connect or any network action.
                app.launchArguments = ["--ui-seed-pairing=Claims Fixture Mac", "--ui-x"] + quietDefaults + sizeArguments
                app.launch()
                guard app.descendants(matching: .any)["phone.home"].firstMatch.waitForExistence(timeout: 5) else {
                    issues.append("\(name): Home did not appear")
                    capture(app, "\(name)-missing-home")
                    app.terminate()
                    return
                }
                switch fixture.entry {
                case .menu(let label):
                    guard supplementalTapReachable(app.buttons["Help and more"], in: app) else {
                        issues.append("\(name): Help and more is not reachable")
                        capture(app, "\(name)-missing-menu")
                        app.terminate()
                        return
                    }
                    if !menuAudited {
                        audit(app, name: "supplemental-\(sizeName)-help-and-more-menu", issues: &issues)
                        menuAudited = true
                    }
                    // Your Macs also appears in the Home list underneath the menu. Exclude
                    // that row so this audit must follow the actual Help-and-more menu path.
                    let item = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                               label, "home.pairedMacs")).firstMatch
                    guard item.waitForExistence(timeout: 5), item.isHittable else {
                        issues.append("\(name): expected menu action is unreachable: \(label)")
                        capture(app, "\(name)-missing-menu-item")
                        app.terminate()
                        return
                    }
                    item.tap()
                case .homeRow(let identifier):
                    guard supplementalTapReachable(app.buttons[identifier], in: app) else {
                        issues.append("\(name): Home row is not reachable: \(identifier)")
                        capture(app, "\(name)-missing-home-row")
                        app.terminate()
                        return
                    }
                case .connectPromptLink:
                    // The existing .openMac route only asks a question for this idle seeded
                    // pairing. XCTest open(_:) is public on iOS 16.4+. Never press Connect.
                    app.open(URL(string: "farside://open")!)
                }
                if let title = fixture.title, !app.navigationBars[title].waitForExistence(timeout: 5) {
                    issues.append("\(name): expected destination title missing: \(title)")
                }
                if let identifier = fixture.marker,
                   !app.descendants(matching: .any)[identifier].firstMatch.waitForExistence(timeout: 5) {
                    issues.append("\(name): expected destination marker missing: \(identifier)")
                }
                if fixture.name == "connect-prompt" {
                    for identifier in ["connectPrompt.connect", "connectPrompt.close"] {
                        if !app.buttons[identifier].exists { issues.append("\(name): prompt control missing: \(identifier)") }
                    }
                    if app.descendants(matching: .any)["remote.canvas"].firstMatch.exists {
                        issues.append("\(name): URL unexpectedly opened a session rather than the consent question")
                    }
                }
                audit(app, name: name, issues: &issues)
                // Inspect bounded additional visible slices. Swipe only a scroll container;
                // no switches, picker options, remove/retry/send/Connect buttons are pressed.
                for step in 1...3 {
                    let scroll = app.scrollViews.firstMatch
                    guard scroll.exists else { break }
                    scroll.swipeUp()
                    audit(app, name: "\(name)-scrolled-\(step)", issues: &issues)
                }
                app.terminate()
            }
        }
        receipt("supplemental-\(sizeName)-audit-inventory",
                "Eight Home destinations plus Help-and-more menu. Initial view and up to three visible scroll slices.\n"
                + "This is a fixture/tree audit, not actual VoiceOver navigation or physical usability acceptance.\n"
                + "No setting mutation, pairing selection/removal, network action, purchase, notification request/test, "
                + "live activity preview or Connect button was exercised. Server Data disclosure was opened only.\n"
                + "Recorded issues/errors: \(issues.count)\n" + issues.joined(separator: "\n\n"))
        XCTAssertTrue(issues.isEmpty, "All supplemental .all findings and reachability errors are retained; "
                      + "\(issues.count) issue(s). See per-screen and inventory attachments.")
    }

    @MainActor
    private func supplementalTapReachable(_ button: XCUIElement, in app: XCUIApplication) -> Bool {
        guard button.waitForExistence(timeout: 5) else { return false }
        let home = app.descendants(matching: .any)["phone.home"].firstMatch
        let scroll = home.elementType == .scrollView ? home : home.scrollViews.firstMatch
        // Try the existing Home content in either direction; the header and lower rows can
        // begin above or below the visible window, especially at AX-XXXL.
        for _ in 0..<7 where !button.isHittable && scroll.exists { scroll.swipeUp() }
        for _ in 0..<7 where !button.isHittable && scroll.exists { scroll.swipeDown() }
        guard button.isHittable else { return false }
        button.tap()
        return true
    }
}
