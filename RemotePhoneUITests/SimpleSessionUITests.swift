import XCTest

/// Rendered layout and accessibility checks only. The local preview supplies no admitted
/// Workspace source, live camera animation, Mac input, typing or physical performance proof.
/// Existing DEBUG input probe enables local UI controls and records actions without transmission.
final class SimpleSessionUITests: XCTestCase {
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
    func testPortraitBottomKeyboardAndMoreOwnsTouchMode() {
        let app = launchPreview()
        defer { app.terminate() }
        let keyboard = element("remote.keyboard.open", in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.isHittable)
        XCTAssertGreaterThan(keyboard.frame.midY, app.windows.firstMatch.frame.midY, "Manual Keyboard belongs near the bottom")
        record("Simple portrait collapsed manual Keyboard", app)
        openDock(app)
        assertSimpleTiles(app)
        XCTAssertFalse(app.buttons["Move view"].exists, "Touch mode belongs inside More")
        record("Simple portrait expanded Keyboard Files More", app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["Control desktop"].exists)
        let view = panel.buttons["Move view"].firstMatch
        XCTAssertTrue(view.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "remote.controls.settings").count, 1, "More has one Settings entry")
        record("Simple More owns Control View", app)
        view.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.exists && canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForExistence(timeout: 5), "Choosing View closes the expanded dock")
        XCTAssertTrue(wait { !app.buttons["More"].exists })
        record("View chrome before accessibility assertions", app)
        assertBetaViewChrome(app)
        #if FARSIDE_WORKSPACE_BETA
        XCTAssertTrue(app.buttons["Zoom in"].exists, "View exposes named beta focus control; this test does not activate it")
        XCTAssertTrue(element("remote.beta.workspace", in: app).exists)
        XCTAssertFalse(app.staticTexts["Workspace ready"].exists, "An offline preview must not invent Workspace readiness")
        #endif
        record("Simple View closes More and dock", app)
        let control = app.buttons["Control desktop"].firstMatch
        XCTAssertTrue(control.isHittable)
        control.tap()
        XCTAssertTrue(wait { canvas.label != "Remote desktop view" && keyboard.isHittable })
        record("Simple return to Control retains manual Keyboard", app)
    }

    @MainActor
    func testLandscapeExpandedDockUsesWidthAndKeepsMoreReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchPreview()
        defer { app.terminate() }
        openDock(app)
        assertSimpleTiles(app)
        let dock = element("remote.dock", in: app)
        XCTAssertTrue(dock.exists)
        XCTAssertGreaterThan(dock.frame.width, dock.frame.height)
        XCTAssertLessThan(dock.frame.height, app.windows.firstMatch.frame.height * 0.75, "Wide dock must leave room for the picture")
        XCTAssertTrue(app.buttons["End session"].firstMatch.isHittable)
        record("Simple landscape wide dock", app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["Move view"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["remote.controls.settings"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Done"].firstMatch.isHittable)
        record("Simple landscape More", app)
        panel.buttons["Move view"].firstMatch.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        record("View chrome before accessibility assertions", app)
        assertBetaViewChrome(app)
        record("Simple landscape View chrome", app)
    }

    @MainActor
    func testLargeTextMoreAndSettingsRemainReachableWithoutDictate() {
        let app = launchPreview(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { app.terminate() }
        openDock(app)
        assertSimpleTiles(app)
        record("Simple large text expanded dock", app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["Move view"].firstMatch.isHittable)
        let settings = app.buttons["remote.controls.settings"].firstMatch
        XCTAssertTrue(settings.isHittable)
        record("Simple large text More", app)
        panel.buttons["Move view"].firstMatch.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        record("View chrome before accessibility assertions", app)
        assertBetaViewChrome(app)
        record("Simple large text View chrome", app)
        app.buttons["Control desktop"].firstMatch.tap()
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].firstMatch.isHittable)
        record("Simple large text session Settings", app)
    }

    @MainActor
    func testExtraLargeTextPortraitKeepsPictureAndNamedViewActions() {
        assertViewLayout(category: "UICTContentSizeCategoryXXXL", orientation: .portrait,
                         title: "Simple XXXL portrait compact View chrome")
    }

    @MainActor
    func testExtraLargeTextLandscapeKeepsPictureAndNamedViewActions() {
        assertViewLayout(category: "UICTContentSizeCategoryXXXL", orientation: .landscapeLeft,
                         title: "Simple XXXL landscape compact View chrome")
    }

    @MainActor
    func testAccessibilityTextLandscapeKeepsPictureAndSecondaryViewActions() {
        assertViewLayout(category: "UICTContentSizeCategoryAccessibilityXXXL", orientation: .landscapeLeft,
                         title: "Simple Accessibility XXXL landscape compact View chrome", inspectOptions: true)
    }

    @MainActor
    func testManualKeyboardOpensDockWithoutDedicatedDictateTile() {
        let app = launchPreview(extra: ["--ui-software-keyboard"])
        defer { app.terminate() }
        let keyboard = element("remote.keyboard.open", in: app)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5) && keyboard.isHittable)
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        let draft = app.textViews["remote.text"].firstMatch
        XCTAssertTrue(draft.isHittable, "Manual Keyboard opens the real draft field")
        XCTAssertTrue(app.buttons["remote.keyboard.hide"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["Voice input"].exists)
        XCTAssertFalse(app.buttons["Move view"].exists)
        record("Simple manual keyboard dock no dedicated Dictate", app)
        // Exercise actual editor teardown with a local multiline Unicode draft. Never press Send.
        let localDraft = "Local draft\ncafé"
        draft.tap()
        draft.typeText(localDraft)
        XCTAssertTrue(wait { draft.value as? String == localDraft })
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists && keyboard.isHittable })
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(draft.waitForExistence(timeout: 5) && draft.isHittable)
        XCTAssertTrue(wait { draft.value as? String == localDraft }, "Hide and reopen retain the exact local draft")
        record("Simple manual keyboard retains multiline Unicode draft", app)
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists && keyboard.isHittable })
    }

    @MainActor
    func testOpenAppDefaultKeepsKeyboardManualAndSendsOnlySpotlight() {
        // Omit the override to exercise the ordinary default as well as the explicit NO case below.
        let app = launchPreview(explicitManualKeyboard: false)
        defer { app.terminate() }
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        let open = app.buttons["remote.navigation.openApp"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isEnabled)
        assertVisibleTarget(open, inside: panel, window: app.windows.firstMatch, name: "Open app")
        record("Open app default manual Keyboard before invocation", app)
        open.tap()
        XCTAssertTrue(wait { !open.exists && !app.buttons["Done"].firstMatch.isHittable })
        assertSingleSpotlightCommand(app)
        assertKeyboardStaysClosed(app)
        XCTAssertTrue(app.buttons["Keyboard"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["Voice input"].exists)
        record("Open app accepted shortcut with Keyboard still manual", app)
    }

    @MainActor
    func testOpenAppExplicitManualKeyboardPreservesUnicodeDraftThroughHideAndReopen() {
        let app = launchPreview(extra: ["--ui-software-keyboard"])
        defer { app.terminate() }
        app.buttons["Keyboard"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        let draft = app.textViews["remote.text"].firstMatch
        let localDraft = "Local draft\ncafé"
        XCTAssertTrue(draft.isHittable)
        draft.tap(); draft.typeText(localDraft)
        XCTAssertTrue(wait { draft.value as? String == localDraft })
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let open = app.buttons["remote.navigation.openApp"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isHittable && open.isEnabled)
        open.tap()
        XCTAssertTrue(wait { !open.exists })
        assertSingleSpotlightCommand(app)
        assertKeyboardStaysClosed(app)
        app.buttons["Keyboard"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { draft.value as? String == localDraft }, "Spotlight must not submit or replace the local draft")
        record("Open app then manual Keyboard retains exact Unicode draft", app)
        app.buttons["remote.keyboard.hide"].firstMatch.tap()
    }

    @MainActor
    func testOpenAppIsDisabledInViewAndCannotSendThroughItsHitRegion() {
        let app = launchPreview()
        defer { app.terminate() }
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["Move view"].firstMatch.tap()
        XCTAssertTrue(wait { self.element("remote.canvas", in: app).label == "Remote desktop view" })
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let open = app.buttons["remote.navigation.openApp"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(open.isEnabled, "The model's local probe still allows control; View must independently disable navigation")
        let before = probeText(app)
        // Tap the visible disabled row, never the remote canvas. This must not dismiss More or send input.
        open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(panel.exists)
        XCTAssertEqual(probeText(app), before)
        XCTAssertFalse(probeText(app).contains("key space command"))
        assertKeyboardStaysClosed(app)
        record("View refuses Open app without input fallthrough", app)
    }

    @MainActor
    func testOpenAppPortraitMoreSettingsDoneAndDropRemainReachable() {
        assertNavigationReachability(category: nil, orientation: .portrait)
    }

    @MainActor
    func testOpenAppLandscapeMoreSettingsDoneAndDropRemainReachable() {
        assertNavigationReachability(category: nil, orientation: .landscapeLeft)
    }

    @MainActor
    func testOpenAppAccessibilityPortraitMoreSettingsDoneAndDropRemainReachable() {
        assertNavigationReachability(category: "UICTContentSizeCategoryAccessibilityXXXL", orientation: .portrait)
    }

    @MainActor
    func testOpenAppAccessibilityLandscapeMoreSettingsDoneAndDropRemainReachable() {
        assertNavigationReachability(category: "UICTContentSizeCategoryAccessibilityXXXL", orientation: .landscapeLeft)
    }

    @MainActor
    func testOverflowingPortraitMoreKeepsPointerFollowPanelAtScrollViewport() throws {
        let app = launchPreview(extra: ["--ui-controls-scroll-geometry"])
        defer { app.terminate() }
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let scroll = app.scrollViews["remote.controls.scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let beforeSnapshot = stableControlsGeometry(in: app)
        recordControlsGeometry("Overflowing short More before content scroll", app, snapshot: beforeSnapshot)
        let before = try XCTUnwrap(beforeSnapshot, "Require two unchanged geometry snapshots before checking the short detent")
        XCTAssertLessThan(before.scroll.height, app.windows.firstMatch.frame.height * 0.8,
                          "This must exercise the ordinary short detent, with the trackpad still admitted")
        XCTAssertFalse(before.geometry.blocked)
        assertViewportReference(before)
        assertSameFrame(before.geometry.panel, before.reference, name: "Initial panel versus layout viewport")
        XCTAssertGreaterThan(before.geometry.content.height, before.reference.height + 400, "The content must actually overflow")

        // The fixture scrolls the native ScrollView itself. A sheet swipe could expand its
        // detent instead, hiding the production bug by blocking pointer following entirely.
        let fixture = app.buttons["remote.controls.geometryScroll"].firstMatch
        XCTAssertTrue(fixture.isHittable)
        fixture.tap()
        let contentMoved = wait {
            guard let geometry = self.controlsGeometry(in: app) else { return false }
            return geometry.content.minY < before.geometry.content.minY - 100
        }
        let afterSnapshot = stableControlsGeometry(in: app)
        recordControlsGeometry("Overflowing short More retains stationary pointer-follow panel", app, snapshot: afterSnapshot)
        XCTAssertTrue(contentMoved, "The regression is invalid unless actual content moved inside the viewport")
        let after = try XCTUnwrap(afterSnapshot, "Require two unchanged geometry snapshots after the content scroll")
        XCTAssertLessThan(after.geometry.content.minY, before.geometry.content.minY - 100)
        XCTAssertFalse(after.geometry.blocked, "Keep the production nonblocking short-detent path under test")
        assertViewportReference(after)
        assertSameFrame(after.scroll, before.scroll, name: "Native scroll extent stays stationary")
        assertSameFrame(after.reference, before.reference, name: "Layout viewport stays stationary")
        assertSameFrame(after.geometry.panel, after.reference, name: "Scrolled panel versus layout viewport")
        assertSameFrame(after.geometry.panel, before.geometry.panel, name: "Pointer-follow panel stays stationary")
        XCTAssertFalse(probeText(app).contains("key space command"))
    }

    private struct ControlsGeometry: Equatable {
        let panel: CGRect
        let content: CGRect
        let blocked: Bool

        init?(_ value: String) {
            let fields = value.split(separator: ";").reduce(into: [String: String]()) { result, entry in
                let pair = entry.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
            func rect(_ key: String) -> CGRect? {
                let values = fields[key]?.split(separator: ",").compactMap { Double($0) } ?? []
                guard values.count == 4, values.allSatisfy({ $0.isFinite }) else { return nil }
                return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            }
            guard let panel = rect("panel"), let content = rect("content"),
                  let blocked = fields["blocked"], ["true", "false"].contains(blocked) else { return nil }
            self.panel = panel
            self.content = content
            self.blocked = blocked == "true"
        }
    }

    @MainActor
    private func controlsGeometry(in app: XCUIApplication) -> ControlsGeometry? {
        let probe = element("remote.controls.geometryProbe", in: app)
        guard probe.exists, let value = probe.value as? String else { return nil }
        return ControlsGeometry(value)
    }

    private struct ControlsGeometrySnapshot: Equatable {
        let geometry: ControlsGeometry
        let reference: CGRect
        let scroll: CGRect
    }

    @MainActor
    private func stableControlsGeometry(in app: XCUIApplication) -> ControlsGeometrySnapshot? {
        let reference = element("remote.controls.viewportReference", in: app)
        let scroll = app.scrollViews["remote.controls.scroll"].firstMatch
        var previous: ControlsGeometrySnapshot?
        var settled: ControlsGeometrySnapshot?
        let stable = wait {
            guard reference.exists, scroll.exists, let geometry = self.controlsGeometry(in: app) else {
                previous = nil
                return false
            }
            let current = ControlsGeometrySnapshot(geometry: geometry, reference: reference.frame, scroll: scroll.frame)
            guard !geometry.panel.isEmpty, !current.reference.isEmpty, !current.scroll.isEmpty else {
                previous = nil
                return false
            }
            defer { previous = current }
            // Readiness requires stable measurements, not agreement with the expected result.
            guard current == previous else { return false }
            settled = current
            return true
        }
        return stable ? settled : nil
    }

    private func assertViewportReference(_ snapshot: ControlsGeometrySnapshot,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.reference.minX, snapshot.scroll.minX, accuracy: 1, "Viewport/native scroll minX", file: file, line: line)
        XCTAssertEqual(snapshot.reference.minY, snapshot.scroll.minY, accuracy: 1, "Viewport/native scroll minY", file: file, line: line)
        XCTAssertEqual(snapshot.reference.width, snapshot.scroll.width, accuracy: 1, "Viewport/native scroll width", file: file, line: line)
        XCTAssertTrue(snapshot.scroll.insetBy(dx: -1, dy: -1).contains(snapshot.reference),
                      "The layout viewport must remain inside the native scroll extent, including its safe area", file: file, line: line)
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, name: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, name + " minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, name + " minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, name + " width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, name + " height", file: file, line: line)
    }

    @MainActor
    private func recordControlsGeometry(_ title: String, _ app: XCUIApplication, snapshot: ControlsGeometrySnapshot?) {
        record(title, app)
        let probe = element("remote.controls.geometryProbe", in: app)
        let reference = element("remote.controls.viewportReference", in: app)
        let scroll = app.scrollViews["remote.controls.scroll"].firstMatch
        let probeValue = probe.exists ? String(describing: probe.value) : "missing"
        let referenceFrame = reference.exists ? String(describing: reference.frame) : "missing"
        let scrollFrame = scroll.exists ? String(describing: scroll.frame) : "missing"
        let diagnostic = XCTAttachment(string: "stable snapshot: \(String(describing: snapshot))\n"
            + "latest probe: \(probeValue)\n"
            + "latest reference: \(referenceFrame)\nlatest native scroll: \(scrollFrame)")
        diagnostic.name = title + " full geometry"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
    }

    @MainActor
    private func assertNavigationReachability(category: String?, orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let app = launchPreview(extra: category.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        defer { app.terminate() }
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        let open = app.buttons["remote.navigation.openApp"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        record("Open app More geometry \(orientation.rawValue) \(category ?? "default")", app)
        assertVisibleTarget(open, inside: panel, window: app.windows.firstMatch, name: "Open app")
        let settings = app.buttons["remote.controls.settings"].firstMatch
        let done = app.buttons["Done"].firstMatch
        assertVisibleTarget(settings, inside: panel, window: app.windows.firstMatch, name: "Settings")
        assertVisibleTarget(done, inside: panel, window: app.windows.firstMatch, name: "Done")
        XCTAssertFalse(open.frame.intersects(settings.frame))
        XCTAssertFalse(open.frame.intersects(done.frame))
        let hold = panel.buttons["Hold click"].firstMatch
        revealInControls(hold, app)
        assertVisibleTarget(hold, inside: panel, window: app.windows.firstMatch, name: "Hold click")
        hold.tap()
        let drop = panel.buttons["Drop"].firstMatch
        XCTAssertTrue(drop.waitForExistence(timeout: 5))
        assertVisibleTarget(drop, inside: panel, window: app.windows.firstMatch, name: "Drop")
        XCTAssertFalse(open.isEnabled, "Holding inside More must disable navigation immediately")
        drop.tap()
        revealInControls(open, app, towardTop: true)
        XCTAssertTrue(open.isEnabled)
        revealInControls(settings, app, towardTop: true)
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        let settingsPage = element("remote.controls.page", in: app)
        let settingsDone = app.buttons["remote.controls.page.done"].firstMatch
        XCTAssertTrue(wait { settingsPage.exists && settingsDone.isHittable },
                      "Wait for the presented Settings page and its own Done action, not the covered More action")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(settingsDone.frame))
        XCTAssertFalse(app.buttons["remote.navigation.openApp"].firstMatch.isHittable,
                       "Covered navigation must not be reachable through Settings")
        record("Open app More retains reachable Settings and Done", app)
        settingsDone.tap()
        XCTAssertTrue(wait { !settingsPage.exists && !settingsDone.exists && !panel.isHittable })
        XCTAssertFalse(probeText(app).contains("key space command"))
        XCTAssertFalse(app.buttons["Voice input"].exists)
    }

    @MainActor
    private func revealInControls(_ target: XCUIElement, _ app: XCUIApplication, towardTop: Bool = false) {
        let scroll = app.scrollViews["remote.controls.scroll"].firstMatch
        for _ in 0..<4 where !target.isHittable || !app.windows.firstMatch.frame.contains(target.frame) {
            XCTAssertTrue(scroll.exists, "Overflow must have a real scroll container")
            if towardTop { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        XCTAssertTrue(target.isHittable)
    }

    @MainActor
    private func probeText(_ app: XCUIApplication) -> String {
        element("remote.inputProbe", in: app).value as? String ?? ""
    }

    @MainActor
    private func assertSingleSpotlightCommand(_ app: XCUIApplication) {
        XCTAssertTrue(wait { self.probeText(app).contains("key space command") })
        let semantic = probeText(app).components(separatedBy: " | ").filter {
            $0.contains(" key ") || $0.contains(" text") || $0.contains(" clipboard")
        }
        XCTAssertEqual(semantic.count, 1, "Open app emits only one shortcut, never text, Return or clipboard")
        XCTAssertTrue(semantic.first?.hasSuffix("key space command") == true)
    }

    @MainActor
    private func assertKeyboardStaysClosed(_ app: XCUIApplication) {
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.keyboards.firstMatch.exists || app.textViews["remote.text"].exists || app.buttons["remote.keyboard.hide"].exists
        }, object: nil)
        unexpected.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: 1.5), .completed,
                       "Spotlight cannot automatically open the local editor")
    }

    @MainActor
    private func launchPreview(extra: [String] = [], explicitManualKeyboard: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-layout-check", "--ui-viewport-fill", "--ui-input-probe", "--ui-probe-quiet",
                               "-FarsideBottomControls", "YES"]
            + (explicitManualKeyboard ? ["-FarsideAutoKeyboard", "NO"] : ["--ui-auto-keyboard-default-check"]) + extra
        app.launch()
        let handle = app.buttons["Show controls"].firstMatch
        if !handle.waitForExistence(timeout: 3) {
            let recover = app.buttons["Return to Farside"].firstMatch
            XCTAssertTrue(recover.waitForExistence(timeout: 5))
            recover.tap()
            XCTAssertTrue(handle.waitForExistence(timeout: 5))
        }
        return app
    }

    @MainActor
    private func openDock(_ app: XCUIApplication) {
        // Use the handle's real single-tap action; landscape has little room for a long swipe.
        app.buttons["Show controls"].firstMatch.tap()
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertSimpleTiles(_ app: XCUIApplication) {
        for title in ["Keyboard", "More"] { XCTAssertTrue(app.buttons[title].firstMatch.isHittable, title) }
        XCTAssertTrue(app.buttons["Files"].exists || app.buttons["Clipboard"].exists)
        XCTAssertFalse(app.buttons["Voice input"].exists)
        XCTAssertFalse(app.buttons["Dictate"].exists)
        XCTAssertFalse(app.buttons["Controls"].exists)
    }

    @MainActor
    private func assertBetaViewChrome(_ app: XCUIApplication) {
        #if FARSIDE_WORKSPACE_BETA
        let bar = element("remote.beta.smartZoom", in: app)
        let workspace = element("remote.beta.workspace", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5) && workspace.exists)
        let titles = ["Zoom in", "View options", "Control desktop"]
        for title in titles {
            let button = bar.buttons[title].firstMatch
            assertVisibleTarget(button, inside: bar, window: app.windows.firstMatch, name: title)
        }
        for first in titles.indices {
            for second in titles.indices where second > first {
                XCTAssertFalse(bar.buttons[titles[first]].firstMatch.frame.intersects(bar.buttons[titles[second]].firstMatch.frame),
                               "View actions must have separate hit regions")
            }
        }
        let options = workspace.buttons["Beta Workspace options"].firstMatch
        assertVisibleTarget(options, inside: workspace, window: app.windows.firstMatch, name: "Workspace options")
        XCTAssertEqual(options.value as? String, "Workspace unavailable on this Mac", "Full truthful status remains available to accessibility")
        XCTAssertFalse(app.staticTexts["Workspace ready"].exists, "The offline fixture has no admitted Workspace source")
        XCTAssertFalse(app.staticTexts["View · drag or pinch"].exists, "View status and Control escape share the zoom chrome")
        XCTAssertTrue(bar.staticTexts["View mode. Drag or pinch to look around."].exists, "Current mode stays explicit")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Control desktop")).count, 1)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(bar.frame), "View chrome must fit the visible window")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(workspace.frame), "Workspace chrome must fit the visible window")
        XCTAssertGreaterThanOrEqual(bar.frame.minY, workspace.frame.maxY, "Zoom chrome must not cover Workspace status")
        let window = app.windows.firstMatch.frame
        let maximumFraction = window.width > window.height ? 0.5 : 0.38
        XCTAssertLessThan(bar.frame.maxY - workspace.frame.minY, window.height * maximumFraction,
                          "Resting beta chrome must leave most of the picture available at this text size")
        #endif
    }

    @MainActor
    private func assertVisibleTarget(_ target: XCUIElement, inside container: XCUIElement,
                                     window: XCUIElement, name: String) {
        XCTAssertTrue(target.isHittable, name)
        XCTAssertGreaterThanOrEqual(target.frame.width, 44 - 0.01, name + " width")
        XCTAssertGreaterThanOrEqual(target.frame.height, 44 - 0.01, name + " height")
        XCTAssertTrue(container.frame.contains(target.frame), name + " belongs inside its chrome")
        XCTAssertTrue(window.frame.contains(target.frame), name + " stays inside the window")
    }

    @MainActor
    private func assertViewLayout(category: String, orientation: UIDeviceOrientation, title: String,
                                  inspectOptions: Bool = false) {
        XCUIDevice.shared.orientation = orientation
        let app = launchPreview(extra: ["-UIPreferredContentSizeCategoryName", category])
        defer { app.terminate() }
        openDock(app)
        app.buttons["More"].firstMatch.tap()
        let panel = element("remote.controls.content", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let view = panel.buttons["Move view"].firstMatch
        XCTAssertTrue(view.isHittable)
        view.tap()
        let canvas = element("remote.canvas", in: app)
        XCTAssertTrue(wait { canvas.label == "Remote desktop view" && !app.buttons["Done"].firstMatch.isHittable })
        record(title, app)
        assertBetaViewChrome(app)
        #if FARSIDE_WORKSPACE_BETA
        if inspectOptions {
            let workspace = element("remote.beta.workspace", in: app)
            let bar = element("remote.beta.smartZoom", in: app)
            let workspaceFrame = workspace.frame
            let zoomFrame = bar.frame
            bar.buttons["View options"].firstMatch.tap()
            record("Simple Accessibility XXXL landscape View options before traversal", app)
            for name in ["Fit desktop", "Pan left", "Pan right", "Pan up", "Pan down"] {
                let action = app.buttons[name].firstMatch
                // UIKit may scroll its native menu at accessibility sizes in short landscape.
                // Verify every action is actually reachable instead of requiring all five onscreen.
                for _ in 0..<2 where !action.exists || !action.isHittable {
                    // The captured native menu exposes a CollectionView and a three-page
                    // vertical scroll bar; use that menu rather than the remote canvas.
                    let scroll = app.collectionViews.firstMatch
                    guard scroll.exists else { break }
                    scroll.swipeUp()
                }
                XCTAssertTrue(action.waitForExistence(timeout: 3), name)
                XCTAssertTrue(action.isHittable, name)
            }
            record("Simple Accessibility XXXL landscape View options", app)
            // Local offline View canvas: dismiss the menu without invoking a camera action.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.9)).tap()
            XCTAssertTrue(wait { !app.collectionViews.firstMatch.exists })
            XCTAssertEqual(workspace.frame, workspaceFrame, "Secondary menu dismissal cannot reflow Workspace chrome")
            XCTAssertEqual(bar.frame, zoomFrame, "Secondary menu dismissal cannot reflow View chrome")
            workspace.buttons["Beta Workspace options"].firstMatch.tap()
            let entry = app.buttons["Try experimental Workspace"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            XCTAssertFalse(entry.isEnabled, "Unavailable Workspace stays unavailable in this local preview")
            record("Simple Accessibility XXXL landscape Workspace details before traversal", app)
            let menu = app.collectionViews.firstMatch
            let end = menu.buttons["End session"].firstMatch
            for _ in 0..<5 where !end.exists || !end.isHittable {
                guard menu.exists else { break }
                // UIKit reports a collection taller than its clipped native-menu viewport.
                // Start a deliberate drag inside the visible rows, rather than flinging from
                // the clipped collection's edge or an unrelated underlying End button.
                let visible = menu.frame.intersection(app.windows.firstMatch.frame)
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.65))
                let finish = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.3))
                start.press(forDuration: 0.1, thenDragTo: finish)
            }
            record("Simple Accessibility XXXL landscape Workspace details after traversal", app)
            XCTAssertTrue(end.isHittable)
            record("Simple Accessibility XXXL landscape Workspace details", app)
        }
        #endif
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func record(_ title: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = title + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
