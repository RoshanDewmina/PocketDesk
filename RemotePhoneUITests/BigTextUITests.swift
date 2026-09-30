import XCTest

/// Big Text on the phone against the offline fixture (`--ui-input-probe`): the built-in probe
/// display offers two steps and answers each `displayScale` like a Mac; nothing reaches a Mac.
final class BigTextUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testChoosingAStepShowsProgressThenSelection() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-layout-check", "--ui-input-probe"]
        launchOffline(app)
        openControls(app)
        openSettingsPage(app, "picture")
        let step = app.buttons["remote.bigText.step.0"]
        scrollControls(app, to: step)
        XCTAssertTrue(app.buttons["remote.bigText.off"].isSelected, "Nothing saved yet, so Off is ticked")
        XCTAssertTrue(step.label.contains("looks like 1280 × 832"), step.label)
        step.tap()
        let pill = app.descendants(matching: .any)["remote.bigText.pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertTrue(step.waitForSelected(timeout: 5))
        XCTAssertFalse(app.buttons["remote.bigText.off"].isSelected)
        XCTAssertTrue(pill.waitForNonExistence(timeout: 5), "The Mac's answer clears the pill")
        let sessionOff = app.switches["remote.bigText.sessionOff"]
        scrollControls(app, to: sessionOff)
        XCTAssertTrue(sessionOff.exists)
        attachScreenshot("Big Text - step chosen")
    }

    @MainActor
    func testPanelRowAppearsOnceALevelIsSavedAndTurnsItOffForTheSession() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-layout-check", "--ui-input-probe"]
        launchOffline(app)
        openControls(app)
        let row = app.switches["remote.bigTextRow"]
        XCTAssertFalse(row.exists, "No saved level, so the panel has no Big Text row")
        openSettingsPage(app, "picture")
        let step = app.buttons["remote.bigText.step.0"]
        scrollControls(app, to: step)
        step.tap()
        XCTAssertTrue(step.waitForSelected(timeout: 5))
        let pill = app.descendants(matching: .any)["remote.bigText.pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertTrue(pill.waitForNonExistence(timeout: 5))
        tapDone(app)
        openControls(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "The panel grows by one row, so nothing in it scrolls")
        XCTAssertEqual(row.value as? String, "1")
        attachScreenshot("Big Text - panel row")
        let mark = probeMark(app)
        row.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [off], timeout: 3), .completed)
        var sent = false
        for _ in 0..<20 where !sent {
            Thread.sleep(forTimeInterval: 0.25)
            sent = probeEntries(app, after: mark).contains("displayScale")
        }
        XCTAssertTrue(sent, "Turning it off asks the Mac for its own size after the debounce")
    }

    // MARK: - Helpers (as in PhoneParityUITests)

    @MainActor
    private func launchOffline(_ app: XCUIApplication) {
        app.launch()
        let showControls = app.buttons["Show controls"]
        if showControls.waitForExistence(timeout: 3) { return }
        let returnButton = app.buttons["Return to Farside"]
        guard returnButton.waitForExistence(timeout: 5) else {
            return XCTFail("Offline fixture must open directly or offer explicit privacy recovery")
        }
        returnButton.tap()
        XCTAssertTrue(showControls.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openControls(_ app: XCUIApplication) {
        revealDock(app)
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        let content = app.descendants(matching: .any)["remote.controls.content"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { waitUntilStill(done) }
    }

    @MainActor
    private func revealDock(_ app: XCUIApplication) {
        if app.buttons["Hide controls"].exists { return }
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.swipeUp()
        let hide = app.buttons["Hide controls"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        waitUntilStill(hide)
    }

    @MainActor
    private func openSettingsPage(_ app: XCUIApplication, _ page: String) {
        let settings = app.buttons["remote.controls.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let row = app.buttons["remote.settings.\(page)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitUntilStill(row)
        row.tap()
    }

    /// Settings pages are short lists; rows further down are only created once scrolled into view.
    @MainActor
    private func scrollControls(_ app: XCUIApplication, to element: XCUIElement) {
        let content = app.descendants(matching: .any)["remote.controls.page"].firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable) { content.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        waitUntilStill(element)
    }

    @MainActor
    private func tapDone(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'"))
        XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 3))
        let visible = done.allElementsBoundByIndex.first { $0.isHittable } ?? done.firstMatch
        visible.tap()
    }

    @MainActor
    private func waitUntilStill(_ element: XCUIElement) {
        var previous = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.15)
            let current = element.frame
            if abs(current.minY - previous.minY) < 0.5 && abs(current.minX - previous.minX) < 0.5 { return }
            previous = current
        }
    }

    @MainActor
    private func rawProbe(_ app: XCUIApplication) -> [(sequence: Int, text: String)] {
        let probe = app.descendants(matching: .any)["remote.inputProbe"].firstMatch
        guard probe.waitForExistence(timeout: 3), let value = probe.value as? String, !value.isEmpty else { return [] }
        return value.components(separatedBy: " | ").compactMap { entry in
            let parts = entry.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let sequence = Int(parts[0]) else { return nil }
            return (sequence, String(parts[1]))
        }
    }

    @MainActor
    private func probeMark(_ app: XCUIApplication) -> Int {
        rawProbe(app).map(\.sequence).max() ?? 0
    }

    @MainActor
    private func probeEntries(_ app: XCUIApplication, after mark: Int) -> [String] {
        rawProbe(app).filter { $0.sequence > mark }.map(\.text)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private extension XCUIElement {
    func waitForSelected(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isSelected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
