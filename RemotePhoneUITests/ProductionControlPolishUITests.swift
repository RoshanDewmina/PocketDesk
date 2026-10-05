import XCTest
import UIKit

/// Ordinary production UI only. Existing DEBUG offline input admission records validated
/// actions locally; these tests neither authenticate a Mac nor prove physical input delivery.
final class ProductionControlPolishUITests: XCTestCase {
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
    func testDefaultPhoneMoreViewAndSettingsAcrossRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Phone chrome check")
        try exerciseChromeAcrossRotation(accessibility: false, requireStackedPortrait: false)
    }

    @MainActor
    func testAccessibilityPhoneMoreViewAndSettingsAcrossRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Phone chrome check")
        try exerciseChromeAcrossRotation(accessibility: true, requireStackedPortrait: false)
    }

    @MainActor
    func testIPadStackedMoreViewAndSettingsAcrossRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires regular iPad layout")
        try exerciseChromeAcrossRotation(accessibility: false, requireStackedPortrait: true)
    }

    @MainActor
    func testAccessibilityIPadStackedMoreViewAndSettingsAcrossRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires regular iPad layout")
        try exerciseChromeAcrossRotation(accessibility: true, requireStackedPortrait: true)
    }

    @MainActor
    func testManualKeyboardDefaultPreservesUnicodeThroughHideAndReopen() {
        exerciseManualKeyboard(extra: [])
    }

    @MainActor
    func testManualKeyboardExplicitNoPreservesUnicodeThroughHideAndReopen() {
        exerciseManualKeyboard(extra: ["-FarsideAutoKeyboard", "NO"])
    }

    @MainActor
    func testCouchKeepsKeyboardClipboardAndMoreWithoutIdleDictate() {
        let app = launch(extra: ["--ui-couch", "-UIPreferredContentSizeCategoryName",
                                 UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        defer { app.terminate() }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            rotate(app, to: orientation)
            assertIdleVoiceAbsent(app)
            XCTAssertFalse(app.buttons["remote.keyboard.open"].exists,
                           "Couch retains its own Keyboard tile instead of the picture edge control")
            for id in ["remote.couch.keys", "remote.couch.clip", "remote.couch.controls"] {
                assertTarget(app.buttons[id].firstMatch, in: app, name: id)
            }
            XCTAssertEqual(app.buttons["remote.couch.controls"].label, "More")
            app.buttons["remote.couch.controls"].tap()
            let panel = element("remote.controls.content", app)
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            XCTAssertFalse(panel.buttons["Move view"].exists, "Couch has no picture mode to move")
            openAndCloseSettings(app)
        }
    }

    @MainActor
    func testActiveVoiceCancelAndHeldDropRemainReachable() {
        // The existing preview supplies a transcript without opening a microphone or granting input.
        let voice = launch(extra: ["--ui-voice-preview-check"], inputProbe: false)
        defer { voice.terminate() }
        let transcript = element("remote.voice.transcript", voice)
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertFalse(voice.buttons["remote.voice.done"].isEnabled,
                       "A non-recording offline preview must never insert into a Mac")
        let cancel = voice.buttons["Cancel voice input"].firstMatch
        assertTarget(cancel, in: voice, name: "Active voice cancellation")
        record("Active voice retains cancellation", voice)
        cancel.tap()
        XCTAssertTrue(transcript.waitForNonExistence(timeout: 5))
        assertIdleVoiceAbsent(voice)
        voice.terminate()

        let held = launch(extra: ["--ui-hold-preview=explicit"])
        defer { held.terminate() }
        let chip = element("remote.holdChip", held)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        let drop = chip.buttons["Drop"].firstMatch
        assertTarget(drop, in: held, name: "Held-input Drop")
        assertIdleVoiceAbsent(held)
        record("Explicit hold retains Drop", held)
        drop.tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "The real local hold state must clear")
        XCTAssertFalse(held.buttons["Drop"].exists)
    }

    @MainActor
    func testExplicitLegacyRollbackRestoresOldControls() {
        let app = launch(extra: ["-FarsideBottomControls", "NO"])
        defer { app.terminate() }
        revealDock(app, legacy: true)
        for name in ["Keyboard", "Clipboard", "Controls", "Voice input", "Control desktop", "Move view"] {
            XCTAssertTrue(app.buttons[name].firstMatch.exists, "Explicit NO must retain \(name)")
        }
        XCTAssertFalse(app.buttons["More"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        record("Explicit old-layout rollback", app)
    }

    @MainActor
    private func exerciseChromeAcrossRotation(accessibility: Bool, requireStackedPortrait: Bool) throws {
        let category = accessibility ? UIContentSizeCategory.accessibilityExtraExtraExtraLarge : .large
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", category.rawValue])
        defer { app.terminate() }
        // A single app/editor/model lifetime survives both landscape sides and the portrait return.
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            rotate(app, to: orientation)
            if requireStackedPortrait && orientation == .portrait {
                XCTAssertTrue(element("remote.stacked.keys", app).waitForExistence(timeout: 5))
                XCTAssertTrue(element("remote.stacked.pad", app).exists)
            }
            assertIdleVoiceAbsent(app)
            let keyboard = app.buttons["remote.keyboard.open"]
            assertTarget(keyboard, in: app, name: "Manual Keyboard")
            XCTAssertGreaterThan(keyboard.frame.midY, app.windows.firstMatch.frame.midY,
                                 "The ordinary manual action belongs at the bottom, not mid-edge")
            XCTAssertFalse(keyboard.frame.intersects(app.buttons["Show controls"].frame))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            revealDock(app)
            let more = app.buttons["More"].firstMatch
            assertTarget(more, in: app, name: "More")
            // This fixture does not negotiate automatic clipboard sync: its truthful branch is Clipboard.
            XCTAssertTrue(app.buttons["Clipboard"].firstMatch.exists)
            XCTAssertFalse(app.buttons["Controls"].exists)
            XCTAssertFalse(app.buttons["Move view"].exists, "Mode selection moved out of the dock")
            assertIdleVoiceAbsent(app)
            record("Ordinary More before opening \(orientation) \(category.rawValue)", app)
            for name in ["Fit whole display", "Fill screen"] {
                assertTarget(app.buttons[name].firstMatch, in: app, name: name)
            }
            more.tap()
            let panel = element("remote.controls.content", app)
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            record("Actual More mode controls before target assertions \(orientation) \(category.rawValue)", app)
            let control = panel.buttons["Control desktop"].firstMatch
            let view = panel.buttons["Move view"].firstMatch
            assertTarget(control, in: app, name: "More Control")
            assertTarget(view, in: app, name: "More View")
            XCTAssertTrue(control.isSelected)
            let macKey = panel.buttons["Double-click"].firstMatch
            XCTAssertTrue(macKey.isEnabled, "Existing local probe admission must remain active")
            openAndCloseSettings(app)

            revealDock(app)
            app.buttons["More"].firstMatch.tap()
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["Move view"].firstMatch.tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "View must dismiss More")
            XCTAssertTrue(app.buttons["Hide controls"].firstMatch.waitForNonExistence(timeout: 5), "View must collapse the dock")
            if !requireStackedPortrait {
                XCTAssertTrue(app.buttons["More"].firstMatch.waitForNonExistence(timeout: 5))
            } // The independent iPad deck can remain while its dock is collapsed.
            XCTAssertFalse(app.buttons["remote.keyboard.open"].exists)
            let canvas = element("remote.canvas", app)
            XCTAssertEqual(canvas.label, "Remote desktop view")
            let mark = probeMark(app)
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            XCTAssertEqual(canvas.label, "Remote desktop view")
            let forbidden = Set(["click", "right", "double", "middle", "auxClick", "move", "moveTo",
                                 "dragDown", "dragUp", "scroll", "key", "text"])
            let leakedInput = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.probeEntries(app, after: mark).contains { forbidden.contains(String($0.split(separator: " ").first ?? "")) }
            }, object: nil)
            leakedInput.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [leakedInput], timeout: 1), .completed,
                           "A View-mode picture tap cannot fall through to Mac input")
            let escape = app.buttons["Control desktop"].firstMatch
            assertTarget(escape, in: app, name: "Return to Control")
            record("Ordinary View before Control return \(orientation)", app)
            escape.tap()
            XCTAssertEqual(canvas.label, "Remote desktop trackpad")
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func exerciseManualKeyboard(extra: [String]) {
        let app = launch(extra: ["--ui-software-keyboard", "--ui-manual-keyboard-check",
                                 "-UIPreferredContentSizeCategoryName",
                                 UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue] + extra)
        defer { app.terminate() }
        let canvas = element("remote.canvas", app)
        let beforeFocus = probeMark(app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.probeEntries(app, after: beforeFocus).contains("note editable focus")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 5), .completed)
        let automatic = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                 object: app.buttons["remote.keyboard.hide"])
        automatic.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [automatic], timeout: 1), .completed,
                       "Editable focus cannot open the default/explicit-NO manual keyboard")
        let keyboard = app.buttons["remote.keyboard.open"]
        assertTarget(keyboard, in: app, name: "Manual Keyboard tap target")
        let mark = probeMark(app)
        keyboard.tap() // Actual hit testing and UIKit focus, not a fixture-open flag.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let draft = app.textViews["remote.text"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5) && draft.isHittable)
        XCTAssertEqual(draft.value as? String, "")
        let text = "café — 東京🙂\nsecond line"
        draft.typeText(text)
        XCTAssertEqual(draft.value as? String, text)
        assertIdleVoiceAbsent(app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            rotate(app, to: orientation)
            let hide = app.buttons["remote.keyboard.hide"].firstMatch
            assertTarget(hide, in: app, name: "Hide keyboard")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(draft.frame))
            XCTAssertLessThanOrEqual(draft.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            XCTAssertLessThanOrEqual(hide.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            XCTAssertEqual(draft.value as? String, text)
            record("Manual Unicode before Hide \(orientation)", app)
            hide.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            assertTarget(keyboard, in: app, name: "Manual Keyboard reopen")
            keyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(draft.value as? String, text)
        }
        XCTAssertFalse(probeEntries(app, after: mark).contains { $0 == "text" || $0.hasPrefix("text ") },
                       "Typing, rotating, Hide and reopen must never submit the draft")
        XCTAssertTrue(app.buttons["Send text"].isEnabled, "The unchanged explicit Send remains available")
    }

    @MainActor
    private func launch(extra: [String], inputProbe: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fit", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if inputProbe { app.launchArguments += ["--ui-input-probe", "--ui-probe-quiet"] }
        app.launchArguments += extra
        app.launch()
        let layout = element("remote.layout.state", app)
        if !layout.waitForExistence(timeout: 3) {
            let recover = app.buttons["Return to Farside"]
            XCTAssertTrue(recover.waitForExistence(timeout: 5), "Retain explicit privacy recovery")
            recover.tap()
        }
        rotate(app, to: .portrait)
        return app
    }

    @MainActor
    private func revealDock(_ app: XCUIApplication, legacy: Bool = false) {
        if app.buttons[legacy ? "Controls" : "More"].firstMatch.isHittable { return }
        let handle = app.buttons["Show controls"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5) && handle.isHittable)
        handle.tap()
        XCTAssertTrue(app.buttons["Hide controls"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openAndCloseSettings(_ app: XCUIApplication) {
        let panel = element("remote.controls.content", app)
        let settings = panel.buttons["remote.controls.settings"].firstMatch
        record("More before real Settings tap", app)
        assertTarget(settings, in: app, name: "More Settings")
        settings.tap()
        let page = element("remote.controls.page", app)
        let row = app.buttons["remote.settings.picture"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            page.exists && row.exists && row.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        // This real row exists only when Settings received session: true. Observe it without
        // opening LANWakeView or sending a wake request; no negotiated permission is required.
        let sessionRow = page.buttons["Wake another Mac on this LAN"].firstMatch
        for _ in 0..<8 where !(sessionRow.exists && sessionRow.isHittable) {
            page.swipeUp()
        }
        assertTarget(sessionRow, in: app, name: "Session-only Wake another Mac row")
        record("Actual Settings session-only row without activation", app)
        let done = app.navigationBars["Settings"].buttons["Done"].firstMatch
        record("Actual Settings before Done", app)
        assertTarget(done, in: app, name: "Settings Done")
        done.tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertIdleVoiceAbsent(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["Voice input"].exists, "No dedicated idle voice entry; system keyboard mic is unaffected")
        XCTAssertFalse(app.buttons["Dictate"].exists)
    }

    @MainActor
    private func assertTarget(_ target: XCUIElement, in app: XCUIApplication, name: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.exists && target.isEnabled && target.isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed { record(name + " readiness failure", app) }
        XCTAssertEqual(result, .completed, name)
        let frame = target.frame
        XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) width: \(frame)")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) height: \(frame)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "\(name) must be fully on screen: \(frame)")
    }

    @MainActor
    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let expected = orientation == .landscapeLeft ? "landscapeRight" : orientation == .landscapeRight ? "landscapeLeft" : "portrait"
        let probe = element("remote.layout.state", app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard probe.exists, let raw = probe.value as? String, let data = raw.data(using: .utf8),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return state["orientation"] as? String == expected && state["ready"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                       "Layout must settle in \(expected); \(String(describing: probe.value))")
    }

    @MainActor
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func probeRows(_ app: XCUIApplication) -> [(Int, String)] {
        let probe = element("remote.inputProbe", app)
        XCTAssertTrue(probe.exists, "Input assertions require the existing observable local probe")
        let raw = probe.value as? String ?? ""
        return raw.components(separatedBy: " | ").compactMap { row in
            let parts = row.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let sequence = Int(parts[0]) else { return nil }
            return (sequence, String(parts[1]))
        }
    }

    @MainActor
    private func probeMark(_ app: XCUIApplication) -> Int { probeRows(app).map { $0.0 }.max() ?? 0 }

    @MainActor
    private func probeEntries(_ app: XCUIApplication, after mark: Int) -> [String] {
        probeRows(app).filter { $0.0 > mark }.map { $0.1 }
    }

    @MainActor
    private func record(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
