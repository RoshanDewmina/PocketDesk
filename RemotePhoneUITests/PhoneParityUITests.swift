import XCTest

/// Phone and iPad parity with Workbench: direct touch, middle click, hardware keyboard and
/// pointer passthrough, the mini map and the display picker. Input runs against the offline
/// fixture with `--ui-input-probe`, which admits input locally and records the exact control
/// actions the phone would send; nothing reaches a Mac.
final class PhoneParityUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: - Direct touch (internal key `touchInputMode`; no settings row)

    @MainActor
    func testDirectTapsLandOnTheTouchedMacPointAtFitFillZoomAndLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit", "-touchInputMode", "direct"]
        launchOffline(app)
        assertTargetsHitExactly(app, context: "Fit portrait")
        attachScreenshot("Direct touch - Fit portrait with probe targets")

        setZoom(app, sliderPosition: 0.12)
        assertTargetsHitExactly(app, context: "Zoomed portrait")

        rotate(app, to: .landscapeLeft)
        assertTargetsHitExactly(app, context: "Zoomed landscape")
        attachScreenshot("Direct touch - zoomed landscape")

        revealDock(app)
        app.buttons["Fill screen"].firstMatch.tap()
        collapseDock(app)
        assertTargetsHitExactly(app, context: "Fill landscape")
        rotate(app, to: .portrait)
        assertTargetsHitExactly(app, context: "Fill portrait")
    }

    @MainActor
    func testDirectDragTwoFingerRightClickAndThreeFingerMiddleClick() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit", "-touchInputMode", "direct"]
        launchOffline(app)
        // (0.5, 0.4) and (0.3, 0.6) of the Mac display: both visible in Fit.
        let start = app.descendants(matching: .any)["probe.target.7"].firstMatch
        let end = app.descendants(matching: .any)["probe.target.11"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        var mark = probeMark(app)
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let drag = probeEntries(app, after: mark)
        let pressed = drag.first(where: { $0.hasPrefix("moveTo") }).flatMap(point)
        let expected = sourceValue(start)
        XCTAssertNotNil(pressed, "\(drag)")
        XCTAssertEqual(pressed?.x ?? 0, expected?.x ?? -1, accuracy: 12, "The press lands where the finger went down: \(drag)")
        XCTAssertEqual(pressed?.y ?? 0, expected?.y ?? -1, accuracy: 12)
        XCTAssertTrue(drag.contains("dragDown 1"), "\(drag)")
        XCTAssertTrue(drag.last?.hasPrefix("dragUp") == true || drag.last == "release", "\(drag)")
        XCTAssertFalse(drag.contains { $0.hasPrefix("click") }, "A drag is not a click: \(drag)")

        let canvas = app.descendants(matching: .any)["remote.canvas"].firstMatch
        mark = probeMark(app)
        canvas.twoFingerTap()
        let right = probeEntries(app, after: mark)
        XCTAssertEqual(Array(right.suffix(2)).map { $0.components(separatedBy: " ").first ?? "" }, ["moveTo", "right"],
                       "Two fingers right-click what is under them: \(right)")

        mark = probeMark(app)
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        let middle = probeEntries(app, after: mark)
        XCTAssertEqual(middle.last, "middle 1", "\(middle)")
    }

    @MainActor
    func testTrackpadTapClicksWithoutMovingThePointer() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit", "--ui-touch-trackpad"]
        launchOffline(app)
        let mark = probeMark(app)
        app.descendants(matching: .any)["probe.target.7"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let entries = probeEntries(app, after: mark)
        XCTAssertEqual(entries.last, "click 1")
        XCTAssertFalse(entries.contains { $0.hasPrefix("moveTo") })
    }

    // MARK: - Hardware keyboard

    @MainActor
    func testHardwareKeysReachTheMacWithModifiersWithoutTheSoftwareKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit", "--ui-touch-trackpad"]
        launchOffline(app)
        primeHardwareKeyboard(app)
        let mark = probeMark(app)
        app.typeKey("a", modifierFlags: [])
        app.typeKey("c", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .shift)
        app.typeKey("7", modifierFlags: [])
        app.typeKey("e", modifierFlags: [.option, .control])
        app.typeKey(XCUIKeyboardKey.F5.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.forwardDelete.rawValue, modifierFlags: [])
        let entries = probeEntries(app, after: mark)
        for expected in ["key a", "key c command", "key left shift", "key 7", "key e control+option"] {
            XCTAssertTrue(entries.contains(expected), "\(expected) missing from \(entries)")
        }
        // XCTest's synthesized Escape and Forward Delete never reach the app in the iOS 27 simulator
        // (not even as unmapped presses), so they are recorded here and verified by unit tests and
        // on hardware.
        let escape = XCTAttachment(string: "Escape delivered: \(entries.contains { $0.hasPrefix("key escape") }); "
            + "Forward Delete delivered: \(entries.contains { $0.hasPrefix("key forwardDelete") }); entries: \(entries)")
        escape.name = "Escape probe"
        escape.lifetime = .keepAlways
        add(escape)
        // The iOS 27 simulator delivers XCTest's F5 as HID F4; the HID→Mac table itself is unit-tested.
        XCTAssertTrue(entries.contains("key f5") || entries.contains("key f4"), "No function key in \(entries)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "A hardware keyboard never raises the on-screen keyboard")
        attachScreenshot("Hardware keys - probe log")
    }

    @MainActor
    func testReservedShortcutsRemapAndCommandShortcutsPassThrough() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit"]
        launchOffline(app)
        primeHardwareKeyboard(app)
        let mark = probeMark(app)
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [.control, .option])
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [.control, .option])
        app.typeKey("h", modifierFlags: [.control, .option])
        app.typeKey("4", modifierFlags: [.control, .option])
        app.typeKey("m", modifierFlags: [.control, .option])
        app.typeKey("m", modifierFlags: [.control, .option, .shift])
        app.typeKey("w", modifierFlags: [.control, .option])
        app.typeKey("z", modifierFlags: [.command, .shift])
        let entries = probeEntries(app, after: mark)
        for expected in ["key tab command", "key space command", "key h command", "key 4 command+shift",
                         "key m command", "key m command+shift", "key w command", "key z command+shift"] {
            XCTAssertTrue(entries.contains(expected), "\(expected) missing from \(entries)")
        }
        XCTAssertTrue(app.buttons["Show controls"].exists, "Substitutes operate on the Mac while Farside stays open")
    }

    /// The public Close responder action must keep a remote-control session open and close on
    /// the Mac exactly once. ⌘M is characterized separately because iPadOS can reserve it.
    @MainActor
    func testWindowShortcutsGoToTheMacAndKeepFarsideOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit"]
        launchOffline(app)
        primeHardwareKeyboard(app)
        let variants: [XCUIElement.KeyModifierFlags] = [.command, [.command, .shift], [.command, .option]]
        for modifiers in variants {
            let mark = probeMark(app)
            app.typeKey("w", modifierFlags: modifiers)
            let stayed = app.buttons["Show controls"].waitForExistence(timeout: 3)
            let after = stayed ? probeEntries(app, after: mark) : []
            let expected = "key w command" + (modifiers.contains(.shift) ? "+shift" : "")
                + (modifiers.contains(.option) ? "+option" : "")
            XCTAssertTrue(stayed, "Close must leave Farside open: \(after)")
            XCTAssertEqual(after.filter { $0.hasPrefix("key ") }, [expected], "Close must reach the Mac exactly once")
        }
        attachScreenshot("Close shortcuts keep the session open")
    }

    /// A platform observation, not a direct-⌘M forwarding requirement. The required Minimize
    /// path is ⌃⌥M above. Recover explicitly after any system window action and verify input.
    @MainActor
    func testSystemCommandMCharacterizationAndRecovery() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad window shortcut observation")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit"]
        launchOffline(app)
        primeHardwareKeyboard(app)
        let mark = probeMark(app)
        app.typeKey("m", modifierFlags: .command)
        let state = app.state
        guard let recovery = recoverActionableFixtureAfterSystemWindowAction(app) else { return }
        let after = probeEntries(app, after: mark)
        let note = XCTAttachment(string: "iPadOS \(UIDevice.current.systemVersion): direct ⌘M; "
            + "immediate app state: \(state.rawValue); recovery: \(recovery); "
            + "delivered entries after recovery: \(after)")
        note.name = "System Command-M characterization"
        note.lifetime = .keepAlways
        add(note)
        let recovered = probeMark(app)
        app.typeKey("m", modifierFlags: [.control, .option])
        XCTAssertEqual(probeEntries(app, after: recovered).filter { $0.hasPrefix("key ") }, ["key m command"])
        XCTAssertTrue(app.buttons["Show controls"].exists)
    }

    @MainActor
    func testReservedShortcutSubstitutesCanBeTurnedOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit",
                               "-remapReservedShortcuts", "NO"]
        launchOffline(app)
        primeHardwareKeyboard(app)
        let mark = probeMark(app)
        app.typeKey("m", modifierFlags: [.control, .option])
        XCTAssertEqual(probeEntries(app, after: mark).filter { $0.hasPrefix("key ") }, ["key m control+option"])
        XCTAssertTrue(app.buttons["Show controls"].exists)
    }

    @MainActor
    func testKeysGoToTheDraftWhileTheKeyboardBarIsOpenAndNeverTwice() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fill"]
        launchOffline(app)
        primeHardwareKeyboard(app)
        app.buttons["Show controls"].doubleTap()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let mark = probeMark(app)
        field.typeText("hi")
        XCTAssertEqual(field.value as? String, "hi")
        XCTAssertTrue(probeEntries(app, after: mark).filter { $0.hasPrefix("key") }.isEmpty,
                      "Typing into the draft must not also press keys on the Mac")
        // On iPad the software keyboard has its own "Hide keyboard" key; use Farside's.
        app.buttons["remote.keyboard.hide"].tap()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 5))
        let after = probeMark(app)
        app.typeKey("b", modifierFlags: [])
        // A slow synthesized press may auto-repeat, exactly as a held key would; nothing else may appear.
        let keys = probeEntries(app, after: after).filter { $0.hasPrefix("key") }
        XCTAssertEqual(keys.first, "key b", "Closing the bar hands the hardware keyboard back to the Mac")
        XCTAssertEqual(Set(keys), ["key b"], "\(keys)")
    }

    // MARK: - Hardware pointer (iPad)

    @MainActor
    func testMouseFollowsClicksRightClicksAndScrollsOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Pointer passthrough is iPadOS only")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit", "--ui-touch-trackpad"]
        launchOffline(app)
        let target = app.descendants(matching: .any)["probe.target.7"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        let centre = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let expected = sourceValue(target)!

        var mark = probeMark(app)
        centre.hover()
        let hover = probeEntries(app, after: mark).last(where: { $0.hasPrefix("moveTo") }).flatMap(point)
        XCTAssertNotNil(hover, "Hovering moves the Mac pointer: \(probeEntries(app, after: mark))")
        XCTAssertEqual(hover?.x ?? 0, expected.x, accuracy: 6)
        XCTAssertEqual(hover?.y ?? 0, expected.y, accuracy: 6)

        mark = probeMark(app)
        centre.click()
        var entries = probeEntries(app, after: mark)
        XCTAssertEqual(entries.last, "click 1", "\(entries)")

        Thread.sleep(forTimeInterval: 0.6)
        mark = probeMark(app)
        centre.rightClick()
        entries = probeEntries(app, after: mark)
        XCTAssertTrue(entries.last == "right 1" || entries.last == "click 1 control", "\(entries)")

        mark = probeMark(app)
        centre.scroll(byDeltaX: 0, deltaY: -120)
        entries = probeEntries(app, after: mark)
        XCTAssertTrue(entries.contains { $0.hasPrefix("scroll began") }, "\(entries)")
        XCTAssertTrue(entries.contains { $0.hasPrefix("scroll ended") || $0.hasPrefix("scroll cancelled") }, "\(entries)")
        attachScreenshot("iPad pointer passthrough - probe log")
    }

    // MARK: - Mini map

    @MainActor
    func testMiniMapAppearsWhenZoomedPansByDragJumpsByTapAndFades() throws {
        let iPad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        // A longer fade keeps the map up through slow simulator steps (a busy Mac can take seconds
        // per query); the fade itself is still checked at the end.
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit", "--ui-minimap-reset",
                               "--ui-minimap-linger=30"]
            + (iPad ? [] : ["-miniMap.phoneLandscape", "YES"])
        launchOffline(app)
        if !iPad { rotate(app, to: .landscapeLeft) }
        let map = app.descendants(matching: .any)["remote.minimap"].firstMatch
        XCTAssertFalse(map.exists, "Fit at 1× shows everything: nothing to navigate")

        // Deep enough that the display is cropped both ways (iPad portrait shows the full height at
        // lower zoom), so the outline can move in both directions.
        setZoom(app, sliderPosition: iPad ? 0.55 : 0.2)
        XCTAssertTrue(map.waitForExistence(timeout: 4), "Zooming in shows the mini map")
        attachScreenshot(iPad ? "Mini map - iPad" : "Mini map - iPhone landscape")
        let viewport = app.descendants(matching: .any)["remote.minimap.viewport"].firstMatch
        XCTAssertTrue(viewport.exists)
        let before = viewport.frame
        let beforeCentre = try XCTUnwrap(miniMapCentre(viewport), "\(String(describing: viewport.value))")
        XCTAssertTrue(map.frame.insetBy(dx: -1, dy: -1).contains(before), "The outline sits inside the overview")

        var mark = probeMark(app)
        let grab = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.2, thenDragTo: grab.withOffset(CGVector(dx: -14, dy: 8)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
        let dragNotes = probeEntries(app, after: mark)
        let dragged = viewport.frame
        let draggedCentre = try XCTUnwrap(miniMapCentre(viewport))
        let trace = "\(dragNotes); outline \(before) → \(dragged); centre \(beforeCentre) → \(draggedCentre)"
        attachScreenshot(iPad ? "Mini map after drag - iPad" : "Mini map after drag - iPhone landscape")
        XCTAssertLessThan(draggedCentre.across, beforeCentre.across, "Dragging left shows more of the left: \(trace)")
        XCTAssertGreaterThan(draggedCentre.down, beforeCentre.down, "Dragging down shows more below: \(trace)")

        mark = probeMark(app)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.88)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        let jumpNotes = probeEntries(app, after: mark)
        let jumped = viewport.frame
        let jumpedCentre = try XCTUnwrap(miniMapCentre(viewport))
        let jumpTrace = "\(jumpNotes); outline \(dragged) → \(jumped); centre \(draggedCentre) → \(jumpedCentre)"
        XCTAssertGreaterThan(jumpedCentre.across, draggedCentre.across, "Tapping jumps toward the tapped corner: \(jumpTrace)")
        XCTAssertGreaterThan(jumpedCentre.down, draggedCentre.down, jumpTrace)
        let note = XCTAttachment(string: "drag: \(trace)\njump: \(jumpTrace)")
        note.name = iPad ? "Mini map probe - iPad" : "Mini map probe - iPhone landscape"
        note.lifetime = .keepAlways
        add(note)

        XCTAssertTrue(map.waitForNonExistence(timeout: 45), "It fades once the view is still")
    }

    @MainActor
    func testMiniMapSettingIsReachableAndIPhonePortraitNeverShowsIt() throws {
        let iPad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fill", "--ui-minimap-reset"]
        launchOffline(app)
        openControls(app)
        openSettingsPage(app, "view")
        let setting = app.descendants(matching: .any)["remote.minimap.setting"].firstMatch
        scrollControls(app, to: setting)
        XCTAssertEqual(setting.label, iPad ? "Mini map" : "Mini map in landscape")
        attachScreenshot("Mini map setting")
        if !iPad {
            setting.tap()
            tapDone(app)
            collapseDock(app)
            let map = app.descendants(matching: .any)["remote.minimap"].firstMatch
            XCTAssertFalse(map.waitForExistence(timeout: 2), "iPhone shows it in landscape only")
            rotate(app, to: .landscapeLeft)
            XCTAssertTrue(map.waitForExistence(timeout: 4), "Fill crops in landscape, so the overview appears")
            // Leave the default (off) for other tests.
            openControls(app)
            openSettingsPage(app, "view")
            scrollControls(app, to: setting)
            setting.tap()
        }
    }

    // MARK: - Display picker

    @MainActor
    func testDisplayPickerListsDisplaysAndSwitchesTheStream() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-viewport-fit"]
        launchOffline(app)
        openControls(app)
        openDisplayPicker(app)
        let builtIn = app.buttons["remote.display.1"]
        let studio = app.buttons["remote.display.2"]
        scrollControls(app, to: studio)
        XCTAssertTrue(builtIn.exists)
        XCTAssertTrue(builtIn.isSelected, "The streamed display is ticked")
        XCTAssertTrue(studio.label.contains("Studio Display"))
        XCTAssertTrue(studio.label.contains("2560 × 1440"), studio.label)
        attachScreenshot("Display picker")
        let mark = probeMark(app)
        studio.tap()
        XCTAssertTrue(probeEntries(app, after: mark).contains("display 2"))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: studio)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed, "The Mac confirms the new display")
        XCTAssertFalse(builtIn.isSelected)
        attachScreenshot("Display picker - switched")
    }

    // MARK: - Screenshots

    /// Clean screenshots of the parity features for the design record. Skipped unless the runner
    /// gets `TEST_RUNNER_FARSIDE_SCREENSHOTS=1`.
    @MainActor
    func testCaptureParityScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_SCREENSHOTS"] == "1",
                          "Set TEST_RUNNER_FARSIDE_SCREENSHOTS=1 to capture parity screenshots")
        continueAfterFailure = true
        let iPad = UIDevice.current.userInterfaceIdiom == .pad
        let prefix = iPad ? "ipad-" : ""
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet", "--ui-viewport-fill",
                               "--ui-minimap-reset", "--ui-minimap-pinned", "--ui-pointer-preview", "-touchInputMode", "direct"]
        launchOffline(app)
        openControls(app)
        openDisplayPicker(app)
        scrollControls(app, to: app.buttons["remote.display.2"])
        attachScreenshot("\(prefix)display-picker")
        tapDone(app)
        openControls(app)
        openSettingsPage(app, "keyboard")
        let shortcuts = app.buttons["Shortcuts"].firstMatch
        scrollControls(app, to: shortcuts)
        shortcuts.tap()
        app.descendants(matching: .any)["remote.controls.page"].firstMatch.swipeUp()
        attachScreenshot("\(prefix)keyboard-shortcuts")
        tapDone(app)
        collapseDock(app)

        if iPad {
            setZoom(app, sliderPosition: 0.2)
            let map = app.descendants(matching: .any)["remote.minimap"].firstMatch
            if map.waitForExistence(timeout: 4) { attachScreenshot("ipad-minimap") }
            rotate(app, to: .landscapeLeft)
            if map.waitForExistence(timeout: 4) { attachScreenshot("ipad-landscape-minimap") }
        } else {
            app.terminate()
            app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet", "--ui-viewport-fill",
                                   "--ui-minimap-pinned", "--ui-pointer-preview", "-miniMap.phoneLandscape", "YES"]
            launchOffline(app)
            rotate(app, to: .landscapeLeft)
            setZoom(app, sliderPosition: 0.15)
            let map = app.descendants(matching: .any)["remote.minimap"].firstMatch
            if map.waitForExistence(timeout: 4) { attachScreenshot("landscape-minimap") }
        }
    }

    // MARK: - Software keyboard recovery

    /// The offline fixture simulates an editable-focus reply after an admitted canvas tap.
    @MainActor
    func testManualKeyboardDefaultAndExplicitNoAtLargestType() {
        for (orientation, override, name) in [(UIDeviceOrientation.portrait, [String](), "portrait-unset"),
                                              (.landscapeLeft, ["-FarsideAutoKeyboard", "NO"], "landscape-NO")] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication()
            app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                                   "--ui-viewport-fit", "--ui-software-keyboard", "--ui-manual-keyboard-check",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] + override
            app.launch()
            waitForLayout(app, orientation: orientation)
            XCTAssertLessThanOrEqual(min(app.frame.width, app.frame.height), 375,
                                     "Run this layout check on a small iPhone")
            let canvas = app.descendants(matching: .any)["remote.canvas"].firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            let mark = probeMark(app)
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            XCTAssertTrue(probeEntries(app, after: mark).contains("click 1"))
            XCTAssertTrue(probeEntries(app, after: mark).contains("note editable focus"))
            let automaticOpen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                         object: app.buttons["remote.keyboard.hide"])
            automaticOpen.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [automaticOpen], timeout: 1), .completed,
                           "Mac editable focus must not open the phone keyboard")
            let button = app.buttons["remote.keyboard.open"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.label, "Keyboard")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame))
            XCTAssertFalse(button.frame.intersects(app.buttons["Show controls"].frame))
            attachScreenshot("manual-keyboard-\(name)-largest-type-closed")
            button.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(button.exists, "Only Hide keyboard remains while typing")
            let hide = app.buttons["remote.keyboard.hide"]
            XCTAssertTrue(hide.waitForExistence(timeout: 5))
            XCTAssertTrue(hide.isHittable)
            let draft = app.textViews["remote.text"].firstMatch
            XCTAssertTrue(draft.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(draft.frame))
            XCTAssertLessThanOrEqual(draft.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            XCTAssertLessThanOrEqual(hide.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            attachScreenshot("manual-keyboard-\(name)-largest-type-open")
            hide.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThan(button.frame.midY, app.windows.firstMatch.frame.height * 0.75,
                                 "The Keyboard button sits along the bottom, level with the controls handle")
            revealDock(app)
            let controls = app.buttons["Controls"].firstMatch
            XCTAssertTrue(controls.isHittable)
            XCTAssertTrue(button.waitForNonExistence(timeout: 5), "The open dock has its own Keyboard tile")
            XCTAssertTrue(app.buttons["Keyboard"].firstMatch.isHittable)
            attachScreenshot("manual-keyboard-\(name)-largest-type-expanded-controls")
            controls.tap()
            XCTAssertFalse(button.exists)
            app.terminate()
        }
    }

    @MainActor
    func testMacTextFocusOpensKeyboardOnlyWithExplicitYes() {
        for setting in ["NO", "YES"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet", "--ui-viewport-fit",
                                   "--ui-software-keyboard", "--ui-manual-keyboard-check", "-FarsideAutoKeyboard", setting]
            launchOffline(app)
            let mark = probeMark(app)
            app.descendants(matching: .any)["remote.canvas"].firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            XCTAssertTrue(probeEntries(app, after: mark).contains("note editable focus"))
            if setting == "YES" {
                XCTAssertTrue(app.textViews["remote.text"].firstMatch.waitForExistence(timeout: 5))
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                app.buttons["remote.keyboard.hide"].tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            } else {
                let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                      object: app.buttons["remote.keyboard.hide"])
                opened.isInverted = true
                XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 1), .completed)
                XCTAssertTrue(app.buttons["remote.keyboard.open"].exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testManualKeyboardButtonIsHiddenWithoutControlInCouchAndViewMode() {
        for arguments in [["--ui-layout-check"], ["--ui-layout-check", "--ui-input-probe", "--ui-couch"]] {
            let app = XCUIApplication()
            app.launchArguments = arguments
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["remote.layout.state"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["remote.keyboard.open"].exists)
            app.terminate()
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet"]
        launchOffline(app)
        let button = app.buttons["remote.keyboard.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        revealDock(app)
        XCTAssertTrue(button.waitForNonExistence(timeout: 5), "The open dock has its own Keyboard tile")
        app.buttons["Move view"].firstMatch.tap()
        app.buttons["Hide controls"].firstMatch.swipeDown()
        XCTAssertFalse(button.waitForExistence(timeout: 2), "No Keyboard button while only moving the view")
        revealDock(app)
        app.buttons["Control desktop"].firstMatch.tap()
        app.buttons["Hide controls"].firstMatch.swipeDown()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAutomaticKeyboardFirstOpenAndReopenKeepChromeVisibleInPortrait() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                               "--ui-viewport-fit", "--ui-auto-keyboard-preview-check", "-FarsideAutoKeyboard", "YES"]
        app.launch()

        assertKeyboardChromeAndCanvasAreUsable(app, context: "first portrait automatic open")
        attachScreenshot("Keyboard first open - portrait")

        let hide = app.buttons["remote.keyboard.hide"]
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(hide.waitForNonExistence(timeout: 5))
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))

        handle.doubleTap()
        assertKeyboardChromeAndCanvasAreUsable(app, context: "portrait reopen without rotation")
        attachScreenshot("Keyboard reopened without rotation - portrait")
    }

    @MainActor
    func testAutomaticKeyboardFirstOpenKeepsChromeVisibleInInitialLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-input-probe", "--ui-probe-quiet",
                               "--ui-viewport-fit", "--ui-auto-keyboard-preview-check", "-FarsideAutoKeyboard", "YES"]
        app.launch()

        waitForLayout(app, orientation: .landscapeLeft)
        assertKeyboardChromeAndCanvasAreUsable(app, context: "first landscape automatic open")
        attachScreenshot("Keyboard first open - initial landscape")

        let hide = app.buttons["remote.keyboard.hide"]
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(hide.waitForNonExistence(timeout: 5))
        let handle = app.buttons["Show controls"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.doubleTap()
        assertKeyboardChromeAndCanvasAreUsable(app, context: "landscape reopen without rotation")
        waitForLayout(app, orientation: .landscapeLeft)
        attachScreenshot("Keyboard reopened without rotation - landscape")
    }

    @MainActor
    private func assertKeyboardChromeAndCanvasAreUsable(
        _ app: XCUIApplication, context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let field = app.textViews["remote.text"].firstMatch
        let hide = app.buttons["remote.keyboard.hide"]
        let keyboard = app.keyboards.firstMatch
        for (element, name) in [(field, "draft"), (hide, "Hide keyboard"), (keyboard, "software keyboard")] {
            let visible = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                           "\(context): \(name) must be visible and hittable", file: file, line: line)
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.frame.contains(field.frame), "\(context): draft must stay on screen", file: file, line: line)
        XCTAssertTrue(window.frame.contains(hide.frame), "\(context): Hide must stay on screen", file: file, line: line)
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 2,
                                 "\(context): keyboard must not cover the draft", file: file, line: line)
        XCTAssertLessThanOrEqual(hide.frame.maxY, keyboard.frame.minY + 2,
                                 "\(context): keyboard must not cover Hide", file: file, line: line)

        let panelTop = min(field.frame.minY, hide.frame.minY)
        XCTAssertGreaterThan(panelTop - window.frame.minY, 30,
                             "\(context): the Mac canvas must retain a usable strip", file: file, line: line)
        let visibleCanvasY = window.frame.minY + (panelTop - window.frame.minY) * 0.55
        let point = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.78, dy: (visibleCanvasY - window.frame.minY) / window.frame.height))
        let mark = probeMark(app)
        point.tap()
        XCTAssertTrue(probeEntries(app, after: mark).contains("click 1"),
                      "\(context): transparent dock space must still deliver a canvas click", file: file, line: line)
        XCTAssertTrue(field.isHittable && hide.isHittable && keyboard.exists,
                      "\(context): using the visible canvas must not lose keyboard chrome", file: file, line: line)
    }

    // MARK: - Helpers

    @MainActor
    private func assertTargetsHitExactly(_ app: XCUIApplication, context: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        // Stay clear of the dock handle, the top notices and the probe's own overlay.
        let usable = window.insetBy(dx: 12, dy: 0).divided(atDistance: 70, from: .minYEdge).remainder
            .divided(atDistance: 90, from: .maxYEdge).remainder
        let overlay = app.descendants(matching: .any)["remote.inputProbe"].firstMatch.frame
            .union(app.buttons["remote.inputProbe.clear"].frame).insetBy(dx: -16, dy: -16)
        let targets = (0..<20).map { app.descendants(matching: .any)["probe.target.\($0)"].firstMatch }
        let onScreen = targets.filter {
            let centre = CGPoint(x: $0.frame.midX, y: $0.frame.midY)
            return $0.exists && usable.contains(centre) && !overlay.contains(centre)
        }
        // Up to five spread across what is visible keeps the run short.
        let stride = max(1, onScreen.count / 5)
        let visible = Swift.stride(from: 0, to: onScreen.count, by: stride).map { onScreen[$0] }.prefix(5)
        guard visible.count >= 2, let a = visible.first, let b = visible.last,
              let sa = sourceValue(a), let sb = sourceValue(b) else {
            return XCTFail("\(context): need two visible probe targets", file: file, line: line)
        }
        // Two screen points, expressed in Mac points at the current zoom.
        let perPoint = max(abs(sb.x - sa.x) / max(abs(b.frame.midX - a.frame.midX), 1),
                           abs(sb.y - sa.y) / max(abs(b.frame.midY - a.frame.midY), 1))
        let tolerance = 2 * perPoint
        for target in visible {
            let mark = probeMark(app)
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let entries = probeEntries(app, after: mark)
            guard let expected = sourceValue(target),
                  let moved = entries.first(where: { $0.hasPrefix("moveTo") }).flatMap(point) else {
                XCTFail("\(context): no moveTo for \(target.identifier) (value \(String(describing: target.value)), "
                        + "frame \(target.frame)): \(entries)", file: file, line: line)
                continue
            }
            XCTAssertEqual(moved.x, expected.x, accuracy: tolerance, "\(context) \(target.identifier) x", file: file, line: line)
            XCTAssertEqual(moved.y, expected.y, accuracy: tolerance, "\(context) \(target.identifier) y", file: file, line: line)
            XCTAssertEqual(entries.last, "click 1", "\(context): a tap clicks where it lands", file: file, line: line)
            // Let the double-click window pass so the next target is a fresh single tap.
            Thread.sleep(forTimeInterval: 0.55)
        }
    }

    private func point(_ entry: String) -> CGPoint? {
        let parts = entry.components(separatedBy: " ")
        guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Probe targets carry their Mac point as "x1296 y135".
    private func sourceValue(_ element: XCUIElement) -> CGPoint? {
        guard let raw = element.value else { return nil }
        let parts = String(describing: raw).replacingOccurrences(of: ",", with: "").components(separatedBy: " ")
        guard parts.count == 2, parts[0].hasPrefix("x"), parts[1].hasPrefix("y"),
              let x = Double(parts[0].dropFirst()), let y = Double(parts[1].dropFirst()) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The first hardware key on a fresh simulator makes iOS ask which layout the keyboard has.
    /// Press Shift alone (Farside sends nothing for a bare modifier) and answer the question.
    @MainActor
    private func primeHardwareKeyboard(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let monitor = addUIInterruptionMonitor(withDescription: "Hardware keyboard detected") { alert in
            let buttons = alert.buttons.allElementsBoundByIndex.filter(\.exists)
            guard let button = buttons.first(where: { ["Done", "OK", "Continue"].contains($0.label) }) ?? buttons.last
            else { return false }
            button.tap()
            return true
        }
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            let buttons = alert.buttons.allElementsBoundByIndex.filter(\.exists)
            (buttons.first(where: { ["Done", "OK", "Continue"].contains($0.label) }) ?? buttons.last)?.tap()
            _ = alert.waitForNonExistence(timeout: 3)
        }
        removeUIInterruptionMonitor(monitor)
    }

    /// iPadOS can complete a system window action after the previous accessibility snapshot.
    /// Never use a cached controls element as foreground evidence, and never relaunch a process
    /// that the system ended. An ended offline fixture is labeled separately from a resumed view.
    @MainActor
    private func recoverActionableFixtureAfterSystemWindowAction(_ app: XCUIApplication) -> String? {
        let controls = app.buttons["Show controls"]
        let probe = app.descendants(matching: .any)["remote.inputProbe"].firstMatch
        let concealed = app.descendants(matching: .any)["remote.concealed"].firstMatch
        let returnButton = app.buttons["Return to Farside"]
        var explicitReturn: String?

        // Allow the deferred scene transition from the system shortcut to become observable.
        Thread.sleep(forTimeInterval: 3)
        guard app.state != .notRunning else {
            XCTFail("The system ended Farside; recovery must not silently relaunch the fixture")
            return nil
        }
        // `activate` brings a still-running minimized/background scene forward without resetting it.
        app.activate()

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            guard app.state != .notRunning else {
                XCTFail("Farside ended while recovering from the system window action")
                return nil
            }
            if explicitReturn == nil, returnButton.exists, returnButton.isHittable {
                let ended = app.staticTexts["Session ended"].exists
                explicitReturn = ended ? "explicit Return after Session ended (not same-session recovery)"
                                       : "explicit Return after concealment"
                returnButton.tap()
            }
            if app.state == .runningForeground, !concealed.exists,
               controls.exists, controls.isHittable, probe.exists {
                return explicitReturn ?? "foreground fixture remained actionable"
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Farside never became foreground, non-concealed, and actionable after the system window action")
        return nil
    }

    /// Raw probe entries: "`sequence` description".
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

    /// The newest sequence number, so a check can read only what its own action produced.
    @MainActor
    private func probeMark(_ app: XCUIApplication) -> Int {
        rawProbe(app).map(\.sequence).max() ?? 0
    }

    @MainActor
    private func probeEntries(_ app: XCUIApplication, after mark: Int) -> [String] {
        rawProbe(app).filter { $0.sequence > mark }.map(\.text)
    }

    /// Where the view is centred, as VoiceOver reads the outline: "49 percent of the screen,
    /// centred 50 percent across and 51 percent down".
    @MainActor
    private func miniMapCentre(_ outline: XCUIElement) -> (across: Int, down: Int)? {
        guard let text = outline.value as? String else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return (numbers[1], numbers[2])
    }

    /// Settings pages are short lists; rows further down are only created once scrolled into view.
    @MainActor
    private func scrollControls(_ app: XCUIApplication, to element: XCUIElement) {
        let content = app.descendants(matching: .any)["remote.controls.page"].firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable) { content.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        waitUntilStill(element)
    }

    /// Controls › Settings › one page, by the summary row's identifier (touch, view, keyboard, …).
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

    /// iPhone portrait: the Display row under the keys. Landscape and iPad: Settings › Display.
    @MainActor
    private func openDisplayPicker(_ app: XCUIApplication) {
        let row = app.buttons["remote.displayRow"].firstMatch
        if row.waitForExistence(timeout: 3) {
            row.tap()
        } else {
            openSettingsPage(app, "display")
        }
    }

    /// In landscape the key overlay's Done sits under the Settings sheet; tap the one on top.
    @MainActor
    private func tapDone(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'"))
        XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 3))
        let visible = done.allElementsBoundByIndex.first { $0.isHittable } ?? done.firstMatch
        visible.tap()
    }

    @MainActor
    private func setZoom(_ app: XCUIApplication, sliderPosition: CGFloat) {
        openControls(app)
        openSettingsPage(app, "view")
        let zoom = app.sliders["Zoom level"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
        zoom.adjust(toNormalizedSliderPosition: sliderPosition)
        tapDone(app)
        collapseDock(app)
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

    /// The dock arrives on a spring; tapping while it still moves can land on the row below.
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
    private func collapseDock(_ app: XCUIApplication) {
        let hide = app.buttons["Hide controls"].firstMatch
        guard hide.waitForExistence(timeout: 2) else { return }
        hide.swipeDown()
        XCTAssertTrue(app.buttons["Show controls"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        waitForLayout(app, orientation: orientation)
        Thread.sleep(forTimeInterval: 0.6)
    }

    @MainActor
    private func waitForLayout(_ app: XCUIApplication, orientation: UIDeviceOrientation) {
        // Device and interface landscape names are inverse in UIKit. Duo can remain
        // nearly square in landscape, so observe the session's settled layout instead.
        let expected: String
        switch orientation {
        case .portrait: expected = "portrait"
        case .portraitUpsideDown: expected = "portraitUpsideDown"
        case .landscapeLeft: expected = "landscapeRight"
        case .landscapeRight: expected = "landscapeLeft"
        default: return XCTFail("A layout check requires an interface orientation")
        }
        let probe = app.descendants(matching: .any)["remote.layout.state"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard probe.exists, let raw = probe.value as? String,
                  let data = raw.data(using: .utf8),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return state["orientation"] as? String == expected && state["ready"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 5), .completed,
                       "The app must settle its layout in \(expected); probe: \(String(describing: probe.value))")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

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
}
