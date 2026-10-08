import XCTest
import UIKit

/// Opt-in hardware checks of recent phone features against the owner's existing pairing and installed host.
/// None of these clicks, types, pastes or switches apps on the Mac, so script/physical/run.sh runs them as
/// read-only; anything that does belongs in PhysicalMacInputFeatureTests, and anything that needs the Mac
/// prepared belongs in PhysicalMacFixtureFeatureTests. They never tap the picture in Control mode and leave
/// no saved state behind.
final class PhysicalFeatureTests: XCTestCase, PhysicalFeatureDriving {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_LIFECYCLE_SMOKE"] == "1" else {
            throw XCTSkip("Requires explicit physical-device testing through script/physical/run.sh")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not physical feature acceptance")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    @MainActor
    func testBottomKeyboardOpensOnFirstTapAndMoreOffersControlView() throws {
        let app = try pairedSession()
        collapseDock(app)
        let keyboard = app.buttons["remote.keyboard.open"].firstMatch
        requireHittable(keyboard, app, "Bottom Keyboard button")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(keyboard.frame.midX, window.midX, "Keyboard belongs at the right: \(keyboard.frame)")
        XCTAssertGreaterThan(keyboard.frame.midY, window.height * 0.75, "Keyboard belongs at the bottom: \(keyboard.frame)")
        record("Bottom controls before the single Keyboard tap", app)
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4), "The first tap must open the keyboard")
        XCTAssertTrue(app.textViews["remote.text"].firstMatch.waitForExistence(timeout: 2))
        record("Keyboard open after one tap", app)
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let panel = openMore(app)
        let control = panel.buttons["Control desktop"].firstMatch
        let view = panel.buttons["Move view"].firstMatch
        requireHittable(control, app, "More Control segment")
        requireHittable(view, app, "More View segment")
        XCTAssertTrue(control.isSelected, "Control is the default segment")
        XCTAssertTrue(panel.buttons["remote.openApp"].firstMatch.exists)
        record("More with Control and View segment", app)
        closeControls(app)
    }

    @MainActor
    func testSmartZoomInViewModeSendsNoMacInput() throws {
        let app = try pairedSession()
        let viewRowBefore = settingsRowLabel("view", app)
        let panel = openMore(app)
        panel.buttons["Move view"].firstMatch.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "View must dismiss More")
        let zoom = app.buttons["remote.smartZoom.action"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "Live Zoom in must become available")
        XCTAssertEqual(zoom.label, "Zoom in")
        let canvas = element("remote.canvas", app)
        XCTAssertEqual(canvas.label, "Remote desktop view")
        mark("no-mac-input start")
        let fitShot = XCUIScreen.main.screenshot()
        zoom.tap()
        XCTAssertTrue(waitForLabel(zoom, "Back to view", timeout: 6), "Zoom in must zoom and offer Back to view")
        Thread.sleep(forTimeInterval: 0.5)
        let zoomedShot = XCUIScreen.main.screenshot()
        record("Smart Zoom zoomed by button", app)
        zoom.tap()
        XCTAssertTrue(waitForLabel(zoom, "Zoom in", timeout: 6), "Back to view must return")
        Thread.sleep(forTimeInterval: 0.5)
        let returnedShot = XCUIScreen.main.screenshot()
        XCTAssertEqual(canvas.label, "Remote desktop view", "Double-tap only in View mode; in Control mode it would click the Mac")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)).doubleTap()
        XCTAssertTrue(waitForLabel(zoom, "Back to view", timeout: 6), "Double-tap must zoom in View mode")
        record("Smart Zoom zoomed by double-tap", app)
        XCTAssertEqual(canvas.label, "Remote desktop view", "Double-tap only in View mode; in Control mode it would click the Mac")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)).doubleTap()
        XCTAssertTrue(waitForLabel(zoom, "Zoom in", timeout: 6), "A second double-tap must go back")
        zoom.tap()
        XCTAssertTrue(waitForLabel(zoom, "Back to view", timeout: 6))
        let viewRowZoomed = settingsRowLabel("view", app)
        mark("no-mac-input end")
        let zoomDiff = difference(fitShot, zoomedShot), returnDiff = difference(fitShot, returnedShot)
        result("smartzoom viewRowBefore=\"\(viewRowBefore)\" viewRowZoomed=\"\(viewRowZoomed)\" zoomDiff=\(zoomDiff) returnDiff=\(returnDiff)")
        attach("Smart Zoom measurements", "View row before: \(viewRowBefore)\nView row zoomed: \(viewRowZoomed)\nPicture difference zoomed: \(zoomDiff)\nPicture difference after Back: \(returnDiff)")
        XCTAssertTrue(viewRowZoomed.contains("×"), "Settings must report a magnified view: \(viewRowZoomed)")
        XCTAssertFalse(viewRowBefore.contains("×"), "Session must start at Fit/Fill: \(viewRowBefore)")
        XCTAssertGreaterThan(zoomDiff, returnDiff * 2, "Zoomed picture must differ far more than the returned one")
        let control = app.buttons["Control desktop"].firstMatch
        if control.waitForExistence(timeout: 3) && control.isHittable { control.tap() }
        let trackpad = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Remote desktop trackpad"), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [trackpad], timeout: 5), .completed, "Control mode restored: \(canvas.label)")
    }

    @MainActor
    func testMagnifierOpensDragsAndCloses() throws {
        let app = try pairedSession()
        openSettings(app)
        let open = app.buttons["remote.magnifier.open"].firstMatch
        revealRow(open, app)
        requireHittable(open, app, "Settings Magnifier")
        open.tap()
        let lens = element("remote.magnifier.lens", app)
        XCTAssertTrue(lens.waitForExistence(timeout: 8), "Magnifier must open the lens")
        XCTAssertTrue(lens.isHittable)
        mark("no-mac-input start")
        record("Magnifier open", app)
        let before = lens.frame
        let start = lens.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 70, dy: 110)), withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.4)
        let after = lens.frame
        result("magnifier before=\(before) after=\(after)")
        XCTAssertGreaterThan(abs(after.midX - before.midX) + abs(after.midY - before.midY), 40, "The lens must follow the drag: \(before) -> \(after)")
        record("Magnifier after drag", app)
        let close = app.buttons["remote.magnifier.close"].firstMatch
        requireHittable(close, app, "Magnifier close")
        close.tap()
        XCTAssertTrue(lens.waitForNonExistence(timeout: 5), "Close must remove the lens")
        mark("no-mac-input end")
    }

    @MainActor
    func testSelectTextFromPictureFindsAndCopiesKnownText() throws {
        let app = try pairedSession()
        openSettingsPage("view", title: "View", app)
        let select = app.buttons["remote.selectText"].firstMatch
        revealRow(select, app)
        requireHittable(select, app, "Select text from picture")
        select.tap()
        XCTAssertTrue(app.navigationBars["Select text"].waitForExistence(timeout: 10), "The frozen-text sheet must open")
        let reviewed = app.staticTexts["Review recognized text before copying."]
        if !reviewed.waitForExistence(timeout: 25) {
            record("Select text did not finish", app)
            XCTFail("Recognition did not finish: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        let editor = app.textViews["Recognized text, editable"].firstMatch
        let text = (editor.value as? String) ?? ""
        // Without a prepared Mac document the owner's live screen is recognized: record counts only.
        let expected = ProcessInfo.processInfo.environment["FARSIDE_OCR_EXPECT"]?.lowercased()
        result("ocr length=\(text.count) expected=\(expected ?? "none") found=\(expected.map { text.lowercased().contains($0) } ?? false)")
        record("Recognized text", app, tree: false)
        XCTAssertGreaterThan(text.trimmingCharacters(in: .whitespacesAndNewlines).count, 10, "OCR must recognize text in the live picture")
        if let expected { XCTAssertTrue(text.lowercased().contains(expected), "OCR must find the prepared known text") }
        let pasteboardBefore = UIPasteboard.general.changeCount
        app.buttons["Copy reviewed text"].firstMatch.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            UIPasteboard.general.changeCount != pasteboardBefore && UIPasteboard.general.hasStrings
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed, "Copy must change the phone pasteboard")
        app.navigationBars["Select text"].buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Select text"].waitForNonExistence(timeout: 5))
        // Read the phone pasteboard from the test runner (system paste consent allowed off-main).
        let pasted = readPasteboardString() ?? ""
        let matches = pasted.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
        result("ocr pasteboard length=\(pasted.count) equalsRecognized=\(matches)")
        XCTAssertTrue(matches, "The phone pasteboard must hold exactly the reviewed text")
    }

    @MainActor
    func testSavedViewRestoresViewport() throws {
        let app = try pairedSession()
        let name = "FarsideTest view"
        openSettingsPage("view", title: "View", app)
        let fitZoom = currentZoom(app)
        let slider = app.sliders["Zoom level"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.55)
        Thread.sleep(forTimeInterval: 1)
        let savedZoom = currentZoom(app)
        XCTAssertGreaterThan(savedZoom, fitZoom + 0.2, "Slider must zoom in: \(fitZoom) -> \(savedZoom)")
        goBack(app)
        openSettingsRow("taskViews", title: "Saved task views", app)
        let field = app.textFields["Name, such as Terminal"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        let save = app.buttons["Save current view"].firstMatch
        requireHittable(save, app, "Save current view")
        save.tap()
        let saved = app.buttons[name].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The named view must be listed")
        if app.keyboards.firstMatch.exists { app.navigationBars["Saved task views"].tap() }
        record("Saved named view", app)
        goBack(app)
        openSettingsRow("view", title: "View", app)
        slider.adjust(toNormalizedSliderPosition: 0)
        Thread.sleep(forTimeInterval: 1)
        let zoomedOut = currentZoom(app)
        XCTAssertLessThan(zoomedOut, savedZoom - 0.2, "Zoom out must change the viewport: \(zoomedOut)")
        goBack(app)
        openSettingsRow("taskViews", title: "Saved task views", app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        let displays = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " · "))
        let display = displays.firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 8), "Restoring must ask for the current display")
        record("Choose display for restore", app)
        if displays.count > 1 {
            // Choosing a display switches the Mac's shared display and the phone remembers it; with one
            // display the only choice is the current one.
            deleteSavedView(saved, name, app)
            closeControls(app)
            throw XCTSkip("The Mac shares more than one display; restore would switch the shared display")
        }
        mark("restore")
        display.tap()
        XCTAssertTrue(element("remote.controls.page", app).waitForNonExistence(timeout: 8), "Restore closes Settings")
        Thread.sleep(forTimeInterval: 2)
        record("Restored view", app, tree: false)
        openSettingsPage("view", title: "View", app)
        let restored = currentZoom(app)
        result("savedview fit=\(fitZoom) saved=\(savedZoom) zoomedOut=\(zoomedOut) restored=\(restored)")
        attach("Saved view zooms", "fit=\(fitZoom) saved=\(savedZoom) zoomedOut=\(zoomedOut) restored=\(restored)")
        XCTAssertEqual(restored, savedZoom, accuracy: 0.11, "Restore must return the saved zoom")
        goBack(app)
        openSettingsRow("taskViews", title: "Saved task views", app)
        deleteSavedView(saved, name, app)
        closeControls(app)
    }

    @MainActor
    private func deleteSavedView(_ saved: XCUIElement, _ name: String, _ app: XCUIApplication) {
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let below = app.buttons.matching(NSPredicate(format: "label == %@", "Delete")).allElementsBoundByIndex
            .filter { $0.frame.minY > saved.frame.minY }
            .min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(below, "The saved view row must offer Delete")
        below?.tap()
        XCTAssertTrue(app.buttons[name].waitForNonExistence(timeout: 5), "Leave no saved view behind")
    }
}

/// Read-only checks that need the Mac prepared by feature-tests/driver.py (a 400×240 PNG on its clipboard)
/// and copy the Mac's real clipboard, so script/physical/run.sh runs them only with --features.
final class PhysicalMacFixtureFeatureTests: XCTestCase, PhysicalFeatureDriving {
    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FARSIDE_PHYSICAL_LIFECYCLE_SMOKE"] == "1", environment["FARSIDE_PHYSICAL_FEATURES"] == "1" else {
            throw XCTSkip("Needs the Mac prepared by feature-tests/driver.py: run through script/physical/run.sh --features")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator is not physical feature acceptance")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    @MainActor
    func testImageClipboardMacToPhone() throws {
        let app = try pairedSession()
        openFilesRow(app)
        let get = app.buttons["remote.clipboard.imageFromMac"].firstMatch
        requireHittable(get, app, "Get Mac image")
        let before = UIPasteboard.general.changeCount
        get.tap()
        let copied = app.staticTexts["Image copied from your Mac."]
        if !copied.waitForExistence(timeout: 25) {
            record("Mac image did not arrive", app)
            XCTFail("Notice: \(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("mage") })")
        }
        record("Mac image copied to phone", app)
        XCTAssertNotEqual(UIPasteboard.general.changeCount, before, "The phone pasteboard must change")
        XCTAssertTrue(UIPasteboard.general.hasImages, "The phone pasteboard must hold an image")
        let size = readPasteboardImageSize()
        result("image mac-to-phone hasImages=\(UIPasteboard.general.hasImages) size=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unread")")
        if let size {
            XCTAssertEqual(Int(size.width), 400, "The phone image must be the Mac's 400×240 PNG")
            XCTAssertEqual(Int(size.height), 240)
        }
    }
}

/// Feature checks that send input to the Mac: Workspace switches its front app, Open app types into
/// Spotlight and presses Return, the phone image is written to the Mac's clipboard, and the folder filter's
/// typing can reach the Mac while the trackpad keeps keyboard focus under the file browser.
final class PhysicalMacInputFeatureTests: PhysicalMacInputTestCase, PhysicalFeatureDriving {
    override func setUpMacInput() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testWorkspaceSwitchesToCalculator() throws {
        let app = try pairedSession()
        openSettingsPage("workspace", title: "Workspace", app)
        let calculator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Calculator")).firstMatch
        XCTAssertTrue(calculator.waitForExistence(timeout: 10), "Running apps list must include Calculator")
        for _ in 0..<8 where !calculator.isHittable { nudgeUp(app) }
        mark("workspace activate")
        calculator.tap()
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["Mac focus confirmed."].exists
                || app.staticTexts["Switch requested. Check the Mac picture before typing."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [outcome], timeout: 6), .completed, "The Mac must answer the switch")
        let confirmed = app.staticTexts["Mac focus confirmed."].exists
        result("workspace outcome=\(confirmed ? "confirmed" : "requested")")
        closeControls(app)
        Thread.sleep(forTimeInterval: 1)
        record("Picture after switching to Calculator", app, tree: false)
    }

    @MainActor
    func testOpenAppTypesCalculatorIntoSpotlight() throws {
        let app = try pairedSession()
        let panel = openMore(app)
        let openApp = panel.buttons["remote.openApp"].firstMatch
        requireHittable(openApp, app, "Open app")
        mark("open app start")
        openApp.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Open app closes More")
        Thread.sleep(forTimeInterval: 1.5)
        record("Picture after Open app", app, tree: false)
        openKeyboard(app)
        let draft = app.textViews["remote.text"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 3))
        draft.typeText("Calculator")
        let send = app.buttons["Send text"].firstMatch
        requireHittable(send, app, "Send text")
        send.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let keys = element("remote.keys", app)
        let enter = keys.buttons["Return"].firstMatch
        for _ in 0..<4 where !enter.isHittable { keys.swipeLeft() }
        requireHittable(enter, app, "Mac Return key")
        enter.tap()
        mark("open app end")
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        record("Picture after Spotlight Return", app, tree: false)
    }

    @MainActor
    func testImageClipboardPhoneToMac() throws {
        let png = Self.testImagePNG(width: 321, height: 123)
        UIPasteboard.general.setData(png, forPasteboardType: "public.png")
        XCTAssertTrue(UIPasteboard.general.hasImages)
        let app = try pairedSession()
        openFilesRow(app)
        let container = element("remote.clipboard.imageToMac", app)
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        let byLabel = app.buttons["Copy clipboard image to your Mac"].firstMatch
        let control = byLabel.exists ? byLabel : container.buttons.firstMatch
        requireHittable(control, app, "Image Paste control")
        record("Before system Paste control", app)
        mark("phone image paste")
        control.tap()
        let copied = app.staticTexts["Image copied to your Mac’s clipboard."]
        if !copied.waitForExistence(timeout: 25) {
            record("Phone image did not reach the Mac", app)
            XCTFail("Notice: \(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("mage") || $0.contains("lipboard") })")
        }
        record("Phone image copied to Mac", app)
    }

    @MainActor
    func testMacFolderBrowserDownloadsSharedFile() throws {
        try requireMacFixture()
        let app = try pairedSession()
        openFilesRow(app)
        let browse = app.buttons["remote.files.browseMac"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "Browse Mac folders must be offered")
        requireHittable(browse, app, "Browse Mac folders")
        browse.tap()
        XCTAssertTrue(app.navigationBars["Shared folders"].waitForExistence(timeout: 8))
        // The owner shared ~/Downloads. Open only Downloads › FarsideTest, filtering before anything is
        // recorded so no other Downloads names land in evidence.
        let root = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Downloads")).firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10), "The granted Downloads folder must be listed")
        record("Shared folder roots", app, tree: false)
        root.tap()
        let filter = app.textFields["Filter filenames"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "A shared folder offers a filename filter")
        filter.tap()
        filter.typeText("FarsideTest")
        app.buttons["Filter"].firstMatch.tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "FarsideTest")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "Filtered Downloads must show the FarsideTest folder")
        folder.tap()
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "farside-download-test.txt")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "The FarsideTest folder must list the test file")
        if app.keyboards.firstMatch.exists { app.navigationBars.firstMatch.tap() }
        record("FarsideTest folder listing", app)
        mark("download start")
        file.tap()
        let received = app.navigationBars["Received file"]
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved to Files")).firstMatch
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in received.exists || saved.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed, "The download must finish on the phone")
        record("Download finished", app)
        if received.exists {
            XCTAssertTrue(app.staticTexts["farside-download-test.txt"].exists, "Received sheet names the file")
            received.swipeDown(velocity: .fast)
        }
        mark("download end")
    }
}

protocol PhysicalFeatureDriving: XCTestCase {}

extension PhysicalFeatureDriving {
    // MARK: - Session helpers

    fileprivate func requireMacFixture() throws {
        guard ProcessInfo.processInfo.environment["FARSIDE_PHYSICAL_FEATURES"] == "1" else {
            throw XCTSkip("Needs the Mac prepared by feature-tests/driver.py: run through script/physical/run.sh --features")
        }
    }

    @MainActor
    fileprivate func pairedSession() throws -> XCUIApplication {
        let app = XCUIApplication()
        // A stray tap on the paste chip would write the Mac clipboard and press ⌘V there.
        app.launchArguments = ["-clipboardPasteChipDisabled", "YES", "-clipboardPasteAfterSending", "NO"]
        app.launch()
        let connect = app.buttons["home.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "Preserve the existing pairing")
        connect.tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 20))
        let handle = app.buttons["Show controls"].firstMatch
        if handle.exists && handle.isHittable { handle.swipeUp() }
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let click = app.buttons["Double-click"].firstMatch
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: click)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 20), .completed,
                       "Fresh authenticated frames must re-admit controls; do not send a Mac click")
        closeControls(app)
        return app
    }

    @MainActor
    fileprivate func revealDock(_ app: XCUIApplication) {
        if app.buttons["More"].firstMatch.isHittable { return }
        let handle = app.buttons["Show controls"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.swipeUp()
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    fileprivate func collapseDock(_ app: XCUIApplication) {
        let hide = app.buttons["Hide controls"].firstMatch
        guard hide.exists && hide.isHittable else { return }
        hide.swipeDown()
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    @discardableResult
    fileprivate func openMore(_ app: XCUIApplication) -> XCUIElement {
        revealDock(app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "More must open")
        return panel
    }

    @MainActor
    fileprivate func openSettings(_ app: XCUIApplication) {
        let panel = openMore(app)
        let settings = panel.buttons["remote.controls.settings"].firstMatch
        requireHittable(settings, app, "More Settings")
        settings.tap()
        XCTAssertTrue(element("remote.controls.page", app).waitForExistence(timeout: 5), "Settings must open")
    }

    @MainActor
    fileprivate func openSettingsPage(_ page: String, title: String, _ app: XCUIApplication) {
        openSettings(app)
        openSettingsRow(page, title: title, app)
    }

    @MainActor
    fileprivate func openSettingsRow(_ page: String, title: String, _ app: XCUIApplication) {
        let row = app.buttons["remote.settings.\(page)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings must list \(page)")
        revealRow(row, app)
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(title) must open")
    }

    @MainActor
    fileprivate func settingsRowLabel(_ page: String, _ app: XCUIApplication) -> String {
        openSettings(app)
        let row = app.buttons["remote.settings.\(page)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        revealRow(row, app)
        let label = row.label
        closeControls(app)
        return label
    }

    @MainActor
    fileprivate func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    fileprivate func closeControls(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(element("remote.controls.content", app).waitForNonExistence(timeout: 5)
                      && element("remote.controls.page", app).waitForNonExistence(timeout: 5), "Controls must close")
    }

    @MainActor
    fileprivate func openFilesRow(_ app: XCUIApplication) {
        revealDock(app)
        let files = app.buttons["Files"].firstMatch.exists ? app.buttons["Files"].firstMatch : app.buttons["Clipboard"].firstMatch
        requireHittable(files, app, "Files tile")
        files.tap()
        XCTAssertTrue(element("remote.clipboard.row", app).waitForExistence(timeout: 5), "Files row must open")
    }

    @MainActor
    fileprivate func openKeyboard(_ app: XCUIApplication) {
        let edge = app.buttons["remote.keyboard.open"].firstMatch
        if edge.exists && edge.isHittable {
            edge.tap()
        } else {
            revealDock(app)
            app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Keyboard", "remote.keyboard.open")).firstMatch.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Keyboard must open")
    }

    @MainActor
    fileprivate func currentZoom(_ app: XCUIApplication) -> Double {
        let value = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Current zoom")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5), "View must show Current zoom")
        let parsed = Double((value.value as? String) ?? "")
        if parsed == nil { record("Current zoom unreadable", app) }
        XCTAssertNotNil(parsed, "Current zoom value: \(String(describing: value.value))")
        return parsed ?? -1
    }

    @MainActor
    fileprivate func revealRow(_ row: XCUIElement, _ app: XCUIApplication) {
        // The Settings sheet animates to its large detent; scroll toward the row from where it is.
        Thread.sleep(forTimeInterval: 0.8)
        let window = app.windows.firstMatch.frame
        for _ in 0..<12 {
            if row.exists && row.isHittable && window.contains(row.frame) { return }
            if row.exists && row.frame.midY < window.midY { nudge(app, down: true) } else { nudge(app, down: false) }
        }
    }

    @MainActor
    fileprivate func nudgeUp(_ app: XCUIApplication) { nudge(app, down: false) }

    @MainActor
    fileprivate func nudge(_ app: XCUIApplication, down: Bool) {
        let page = element("remote.controls.page", app)
        guard page.exists else {
            XCTFail("Scroll only inside Settings; a drag over the picture in Control mode would drag on the Mac")
            return
        }
        let from = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.4 : 0.75))
        let to = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.45))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor
    fileprivate func requireHittable(_ target: XCUIElement, _ app: XCUIApplication, _ name: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.exists && target.isEnabled && target.isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 8)
        if result != .completed { record(name + " readiness failure", app) }
        XCTAssertEqual(result, .completed, name)
    }

    @MainActor
    fileprivate func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)],
                       timeout: timeout) == .completed
    }

    @MainActor
    fileprivate func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    // MARK: - Evidence

    fileprivate func mark(_ name: String) {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = format.string(from: Date())
        print("FARSIDE_MARK \(name.replacingOccurrences(of: " ", with: "_")) \(stamp) \(Date().timeIntervalSince1970)")
        attach("Mark " + name, "\(stamp) \(Date().timeIntervalSince1970)")
    }

    fileprivate func result(_ text: String) {
        print("FARSIDE_RESULT " + text)
        attach("Result", text)
    }

    fileprivate func attach(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    fileprivate func record(_ name: String, _ app: XCUIApplication, tree: Bool = true) {
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
        guard tree else { return }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    /// Mean absolute luminance difference (0–255) between two screenshots at 48×48.
    fileprivate func difference(_ a: XCUIScreenshot, _ b: XCUIScreenshot) -> Double {
        guard let pa = Self.luminance(a.image), let pb = Self.luminance(b.image), pa.count == pb.count, !pa.isEmpty else { return -1 }
        let total = zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return (Double(total) / Double(pa.count) * 100).rounded() / 100
    }

    fileprivate static func luminance(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    fileprivate static func testImagePNG(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor(red: 0.9, green: 0.1, blue: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            context.fill(CGRect(x: 10, y: 10, width: width / 3, height: height / 3))
        }
    }

    /// Reading another app's pasteboard can raise the system paste consent; read off the main
    /// thread and allow it from SpringBoard so the runner does not deadlock.
    @MainActor
    fileprivate func readPasteboardString() -> String? {
        let done = expectation(description: "pasteboard string read")
        var value: String?
        DispatchQueue.global().async { value = UIPasteboard.general.string; done.fulfill() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        wait(for: [done], timeout: 10)
        return value
    }

    @MainActor
    fileprivate func readPasteboardImageSize() -> CGSize? {
        let done = expectation(description: "pasteboard read")
        var size: CGSize?
        DispatchQueue.global().async {
            if let data = UIPasteboard.general.data(forPasteboardType: "public.png"), let image = UIImage(data: data) {
                size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            } else if let image = UIPasteboard.general.image {
                size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            }
            done.fulfill()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        wait(for: [done], timeout: 10)
        return size
    }
}
