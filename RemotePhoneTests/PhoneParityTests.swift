import XCTest
import UIKit
@testable import PocketDeskRemote

final class SessionWindowLayoutTests: XCTestCase {
    private let mac = CGSize(width: 1440, height: 900)

    func testCompactWindowsAlwaysKeepThePhoneLayout() {
        for window in [CGSize(width: 390, height: 844), CGSize(width: 600, height: 834)] {
            XCTAssertFalse(SessionWindowLayout.stacked(regular: false, window: window, source: mac, wasStacked: true))
        }
    }

    func testRegularWindowBandsFollowPictureCoverage() {
        for window in [CGSize(width: 744, height: 1133), CGSize(width: 834, height: 1210),
                       CGSize(width: 1032, height: 1376), CGSize(width: 683, height: 1032),
                       CGSize(width: 680, height: 834)] {
            XCTAssertTrue(SessionWindowLayout.stacked(regular: true, window: window, source: mac, wasStacked: false))
            XCTAssertEqual(SessionWindowLayout.pictureSize(window: window, source: mac, stacked: true).height,
                           window.width / 1.6, accuracy: 0.01)
        }
        for window in [CGSize(width: 1210, height: 834), CGSize(width: 1376, height: 1032),
                       CGSize(width: 808, height: 834), CGSize(width: 900, height: 834),
                       CGSize(width: 1920, height: 1080)] {
            XCTAssertFalse(SessionWindowLayout.stacked(regular: true, window: window, source: mac, wasStacked: false))
        }
    }

    func testResizingKeepsHysteresisAtBothBoundaries() {
        func window(_ coverage: CGFloat) -> CGSize { CGSize(width: coverage * 1600, height: 1000) }
        XCTAssertTrue(SessionWindowLayout.stacked(regular: true, window: window(0.599), source: mac, wasStacked: false))
        XCTAssertFalse(SessionWindowLayout.stacked(regular: true, window: window(0.60), source: mac, wasStacked: false))
        XCTAssertTrue(SessionWindowLayout.stacked(regular: true, window: window(0.63), source: mac, wasStacked: true))
        XCTAssertFalse(SessionWindowLayout.stacked(regular: true, window: window(0.63), source: mac, wasStacked: false))
        XCTAssertTrue(SessionWindowLayout.stacked(regular: true, window: window(0.66), source: mac, wasStacked: true))
        XCTAssertFalse(SessionWindowLayout.stacked(regular: true, window: window(0.661), source: mac, wasStacked: true))
    }

    func testBigTextAspectAndInvalidGeometry() {
        XCTAssertTrue(SessionWindowLayout.stacked(regular: true, window: CGSize(width: 834, height: 1210),
                                                   source: CGSize(width: 1280, height: 832), wasStacked: false))
        XCTAssertFalse(SessionWindowLayout.stacked(regular: true, window: .zero, source: mac, wasStacked: true))
        XCTAssertFalse(SessionWindowLayout.stacked(regular: true, window: CGSize(width: 834, height: 1210), source: .zero, wasStacked: true))
    }

    func testPadZoomAnchorsClampToThePicture() {
        XCTAssertEqual(SessionWindowLayout.zoomAnchor(CGPoint(x: 400, y: 1000), picture: CGSize(width: 834, height: 521)),
                       CGPoint(x: 400, y: 521))
        XCTAssertEqual(SessionWindowLayout.zoomAnchor(CGPoint(x: -10, y: 40), picture: CGSize(width: 834, height: 521)),
                       CGPoint(x: 0, y: 40))
    }

    func testTopDockLeavesThePictureBelowItAvailableForPointerFollow() {
        let safe = CGRect(x: 0, y: 0, width: 834, height: 521)
        let canvas = CGRect(x: 0, y: 20, width: 834, height: 1210)
        let dock = CGRect(x: 137, y: 60, width: 560, height: 250)
        let usable = PointerFollowLayout.usableRect(safeRect: safe, canvasFrame: canvas, dockFrame: dock, topAnchor: true)
        XCTAssertEqual(usable.minY, 302)
        XCTAssertEqual(usable.maxY, safe.maxY)
        XCTAssertEqual(PointerFollowLayout.usableRect(safeRect: safe, canvasFrame: canvas, dockFrame: .zero, topAnchor: true), safe)
        let bottomDock = CGRect(x: 0, y: 400, width: 834, height: 200)
        let phone = PointerFollowLayout.usableRect(safeRect: safe, canvasFrame: canvas, dockFrame: bottomDock)
        XCTAssertEqual(phone.minY, 0)
        XCTAssertEqual(phone.maxY, 368)
    }
}

/// Phone-side glue for hardware keyboards, direct touch and the display picker. The shared
/// logic behind these (key map, remaps, repeat, pointer router, mapping) is tested on macOS.
@MainActor
final class HardwareKeyboardRouterTests: XCTestCase {
    private var sent: [String] = []
    private var modifiers: [[String]] = []

    private func makeRouter(remap: Bool = true) -> HardwareKeyboardRouter {
        let router = HardwareKeyboardRouter()
        router.send = { [unowned self] key, mods in
            self.sent.append(([key] + mods).joined(separator: " "))
            return true
        }
        router.modifiersChanged = { [unowned self] in self.modifiers.append($0) }
        router.remapEnabled = { remap }
        return router
    }

    func testKeysTravelByPositionWithTheirModifiers() {
        let router = makeRouter()
        XCTAssertTrue(router.pressBegan(usage: 0x06, flags: .command, at: 1))
        XCTAssertTrue(router.pressEnded(usage: 0x06, flags: []))
        XCTAssertTrue(router.pressBegan(usage: 0x50, flags: [.shift, .alternate], at: 2))
        XCTAssertTrue(router.pressEnded(usage: 0x50, flags: []))
        XCTAssertEqual(sent, ["c command", "left shift option"])
    }

    func testModifierKeysAloneSendNothingButAreTrackedForClicks() {
        let router = makeRouter()
        XCTAssertTrue(router.pressBegan(usage: 0xE3, flags: .command, at: 1))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(router.heldModifiers, ["command"])
        XCTAssertEqual(modifiers.last, ["command"])
        _ = router.pressEnded(usage: 0xE3, flags: [])
        XCTAssertEqual(router.heldModifiers, [])
    }

    func testCapsLockShiftsLettersAndRemapsReservedShortcuts() {
        let router = makeRouter()
        _ = router.pressBegan(usage: 0x04, flags: .alphaShift, at: 1)
        _ = router.pressEnded(usage: 0x04, flags: .alphaShift)
        _ = router.pressBegan(usage: 0x2B, flags: [.control, .alternate], at: 2)
        _ = router.pressEnded(usage: 0x2B, flags: [])
        XCTAssertEqual(sent, ["a shift", "tab command"])

        let plain = makeRouter(remap: false)
        sent = []
        _ = plain.pressBegan(usage: 0x2B, flags: [.control, .alternate], at: 3)
        XCTAssertEqual(sent, ["tab option control"])
    }

    func testUnknownKeysGoBackToUIKitAndEscapeCommandsSendOnce() {
        let router = makeRouter()
        XCTAssertFalse(router.pressBegan(usage: 0x65, flags: [], at: 1), "Menu key: not for the Mac")
        router.commandPressed(usage: HardwareKeyMap.escape, flags: .shift)
        XCTAssertEqual(sent, ["escape shift"])
    }

    func testARepeatStopsWhenTheModifiersChangeAndShortcutsNeverRepeat() {
        let router = makeRouter()
        _ = router.pressBegan(usage: 0xE1, flags: .shift, at: 1)
        _ = router.pressBegan(usage: 0x4F, flags: .shift, at: 1)
        XCTAssertEqual(sent, ["right shift"])
        _ = router.pressEnded(usage: 0xE1, flags: [])
        let stopped = expectation(description: "no stale shift+right after shift is released")
        stopped.isInverted = true
        let watcher = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { if self.sent.count > 1 { stopped.fulfill() } }
        }
        wait(for: [stopped], timeout: 0.8)
        watcher.invalidate()
        XCTAssertEqual(sent, ["right shift"])

        sent = []
        _ = router.pressBegan(usage: 0x14, flags: [.control, .alternate], at: ProcessInfo.processInfo.systemUptime)
        let once = expectation(description: "⌃⌥Q (⌘Q) is sent once however long it is held")
        once.isInverted = true
        let quitWatcher = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { if self.sent.count > 1 { once.fulfill() } }
        }
        wait(for: [once], timeout: 0.8)
        quitWatcher.invalidate()
        XCTAssertEqual(sent, ["q command"])
    }

    func testReleaseAllClearsModifiers() {
        let router = makeRouter()
        _ = router.pressBegan(usage: 0xE1, flags: .shift, at: 1)
        router.releaseAll()
        XCTAssertEqual(router.heldModifiers, [])
        XCTAssertEqual(modifiers.last, [])
    }
}

@MainActor
final class CanvasKeyCommandTests: XCTestCase {
    func testEscapeHasPriorityKeyCommandsOnlyWhileKeysGoToTheMac() {
        let view = NativeTrackpadInputView()
        XCTAssertTrue(view.canBecomeFirstResponder, "The canvas takes key presses without a text field")
        XCTAssertNil(view.keyCommands, "No commands while hardware keys are off")
        view.hardwareKeys = true
        let commands = view.keyCommands ?? []
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        XCTAssertTrue(commands.allSatisfy { $0.discoverabilityTitle == nil }, "Never listed in the shortcut overlay")
        let escape = commands.filter { $0.input == UIKeyCommand.inputEscape }
        XCTAssertEqual(escape.count, 16, "Escape with every combination of ⌘⇧⌥⌃")
        XCTAssertEqual(Set(escape.map(\.modifierFlags.rawValue)).count, 16)
        for input in ["w", "m", "q", "n", ","] {
            XCTAssertTrue(commands.contains { $0.input == input && $0.modifierFlags == .command },
                          "⌘\(input) goes to the Mac, not to Farside's window")
        }
        XCTAssertEqual(HardwareKeyMap.usage(forCharacter: "w"), 0x1A)
        XCTAssertEqual(HardwareKeyMap.usage(forCharacter: ","), 0x36)
        XCTAssertEqual(HardwareKeyMap.name(forHIDUsage: HardwareKeyMap.usage(forCharacter: "q")!), "q")
    }

    func testCanvasOptsOutOfIOSThreeFingerEditingGestures() {
        let view = NativeTrackpadInputView()
        XCTAssertEqual(view.editingInteractionConfiguration, .none,
                       "iOS undo/redo swipes and copy/paste pinches must not take the Mac's three-finger gestures")
    }

    func testCloseWindowClosesTheMacWindowOnlyWhileKeysGoToTheMac() {
        let view = NativeTrackpadInputView()
        var sent: [String] = []
        view.keyboard.send = { key, modifiers in sent.append(([key] + modifiers).joined(separator: " ")); return true }
        let close = #selector(UIResponderStandardEditActions.performClose(_:))
        XCTAssertFalse(view.canPerformAction(close, withSender: nil), "Outside a session ⌘W closes Farside's window")

        view.hardwareKeys = true
        XCTAssertTrue(view.canPerformAction(close, withSender: nil))
        view.performClose(UIKeyCommand(input: "w", modifierFlags: .command, action: close))
        XCTAssertEqual(sent, ["w command"])
        let command = UICommand(title: "Close Window", action: close)
        view.validate(command)
        XCTAssertEqual(command.title, "Close Mac Window")

        view.hardwareKeys = false
        view.performClose(nil)
        XCTAssertEqual(sent, ["w command"], "Nothing reaches the Mac once keys stop going there")
    }
}

@MainActor
final class MacShortcutMenuTests: XCTestCase {
    func testMacShortcutsLeaveTheMenuBarButTheCommandsStay() throws {
        let closeAction = NSSelectorFromString("performClose:")
        let close = UIKeyCommand(title: "Close Window", action: closeAction, input: "w", modifierFlags: .command)
        let closeAll = UIKeyCommand(title: "Close All", action: closeAction, input: "W", modifierFlags: [.command, .alternate])
        let minimize = UIKeyCommand(title: "Minimize", action: NSSelectorFromString("performMiniaturize:"),
                                    input: "m", modifierFlags: .command)
        let copy = UIKeyCommand(title: "Copy", action: #selector(UIResponderStandardEditActions.copy(_:)),
                                input: "c", modifierFlags: .command)
        let other = UIKeyCommand(title: "Other", action: closeAction, input: "w", modifierFlags: [.command, .control])
        let menu = UIMenu(title: "File", children: [
            UIMenu(title: "", options: .displayInline, children: [close, closeAll]), minimize, copy, other
        ])

        let released = try XCTUnwrap(MacShortcutMenu.releasing(menu) as? UIMenu)
        XCTAssertEqual(released.title, "File")
        XCTAssertEqual(released.children.count, 4)
        let inline = try XCTUnwrap(released.children.first as? UIMenu)
        XCTAssertEqual(inline.options, .displayInline)
        for (element, title) in zip(inline.children, ["Close Window", "Close All"]) {
            let command = try XCTUnwrap(element as? UICommand)
            XCTAssertFalse(command is UIKeyCommand, "\(title) keeps its menu item but not ⌘W")
            XCTAssertEqual(command.title, title)
            XCTAssertEqual(command.action, closeAction)
        }
        XCTAssertFalse(released.children[1] is UIKeyCommand, "⌘M goes to the Mac")
        XCTAssertEqual((released.children[2] as? UIKeyCommand)?.input, "c", "Other shortcuts are untouched")
        XCTAssertEqual((released.children[3] as? UIKeyCommand)?.modifierFlags, [.command, .control])
    }
}

@MainActor
final class DirectTouchModelTests: XCTestCase {
    func testDirectTouchNeedsAbsolutePointerFromTheMac() {
        let model = PhoneRemoteModel()
        XCTAssertFalse(model.absolutePointerSupported)
        XCTAssertFalse(model.pointTo(CGPoint(x: 10, y: 10)), "An older Mac never receives moveTo")
        XCTAssertFalse(model.middleClick())
        XCTAssertFalse(model.hardwareKey("a", modifiers: []), "No session, nothing is sent")
        XCTAssertFalse(model.gesture(.pointTo(CGPoint(x: 1, y: 1))), "Canvas points must be mapped by the session first")
        XCTAssertTrue(model.displays.isEmpty)
        XCTAssertFalse(model.selectDisplay(2))
    }

    func testHiddenSettingsLandOnTheirDefaultsOnceAndLaterWritesStick() {
        let suite = "hidden-surface-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("direct", forKey: TouchInputMode.key)
        defaults.set("extraLarge", forKey: PointerSizePreference.key)
        defaults.set("off", forKey: PointerFollowStyle.key)
        HiddenSettingsMigration.run(defaults)
        for key in HiddenSettingsMigration.hiddenKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertTrue(defaults.bool(forKey: HiddenSettingsMigration.key))
        defaults.set("direct", forKey: TouchInputMode.key)
        HiddenSettingsMigration.run(defaults)
        XCTAssertEqual(defaults.string(forKey: TouchInputMode.key), "direct", "A later `defaults write` is kept")
    }

    func testTouchModeDefaultsToTrackpad() {
        UserDefaults.standard.removeObject(forKey: TouchInputMode.key)
        XCTAssertEqual(TouchInputMode(rawValue: UserDefaults.standard.string(forKey: TouchInputMode.key) ?? "trackpad"), .trackpad)
        XCTAssertEqual(TouchInputMode.allCases.map(\.title), ["Trackpad", "Direct"])
    }

    func testPointerWarpJumpsTheDrawnPointer() {
        var now: TimeInterval = 50
        let overlay = PointerOverlayModel(clock: { now })
        overlay.reset(sourceSize: CGSize(width: 1440, height: 900))
        overlay.hostCapability(PointerSync(videoCursor: true))
        overlay.receive(PointerSync(videoCursor: false, x: 100, y: 100, visible: true, shape: "arrow", applied: 0, sample: 1))
        now += 0.01
        let ordinal = overlay.reserveMoveOrdinal()
        XCTAssertNotNil(ordinal)
        overlay.localWarp(ordinal: ordinal, to: CGPoint(x: 700, y: 420))
        XCTAssertEqual(overlay.render?.point, CGPoint(x: 700, y: 420))
    }
}


/// The actual chrome branches use this policy so narrow windows retain their phone behavior.
final class SessionChromePolicyTests: XCTestCase {
    @MainActor
    func testLocalActivityExtendsTheExactIdleDeadline() {
        let clock = SessionPillActivityClock()
        clock.note(at: 10)
        XCTAssertEqual(clock.remaining(at: 11), 1)
        clock.note(at: 11.5)
        XCTAssertEqual(clock.remaining(at: 12.2), 1.3, accuracy: 0.0001)
        XCTAssertEqual(clock.remaining(at: 13.5), 0)
        XCTAssertEqual(clock.remaining(at: 15), 0)
    }
    func testFormsAndCameraCapRespectWidthAndRollback() {
        for regular in [false, true] {
            for enabled in [false, true] {
                let form = regular && enabled
                XCTAssertEqual(SessionChromePolicy.form(regular: regular, enabled: enabled), form)
                XCTAssertEqual(SessionChromePolicy.cameraMaxHeight(regular: regular, enabled: enabled), form ? nil : 340)
            }
        }
    }

    func testOnlyRegularHardwareKeyboardsHideTheKeyBar() {
        XCTAssertTrue(SessionChromePolicy.keyboardBar(regular: false, hardware: false))
        XCTAssertTrue(SessionChromePolicy.keyboardBar(regular: false, hardware: true), "Compact windows keep the phone key bar")
        XCTAssertTrue(SessionChromePolicy.keyboardBar(regular: true, hardware: false))
        XCTAssertFalse(SessionChromePolicy.keyboardBar(regular: true, hardware: true), "The text field remains; only the keys hide")
    }

    func testKeyboardRefitsOnlyTheRegularFullBleedPicture() {
        let canvas = CGRect(x: 0, y: 20, width: 1210, height: 834)
        let bar = CGRect(x: 0, y: 554, width: 1210, height: 80)
        for regular in [false, true] {
            for stacked in [false, true] {
                for couch in [false, true] {
                    for open in [false, true] {
                        let expected: CGFloat = regular && !stacked && !couch && open ? 300 : 0
                        XCTAssertEqual(SessionChromePolicy.keyboardBottom(regular: regular, stacked: stacked, couch: couch,
                                                                          keyboardOpen: open, barFrame: bar, canvas: canvas), expected)
                    }
                }
            }
        }
        XCTAssertEqual(SessionChromePolicy.keyboardBottom(regular: true, stacked: false, couch: false,
                                                          keyboardOpen: true, barFrame: .zero, canvas: canvas), 0)
        XCTAssertEqual(SessionChromePolicy.keyboardBottom(regular: true, stacked: false, couch: false, keyboardOpen: true,
                                                          barFrame: CGRect(x: 0, y: 900, width: 1210, height: 80), canvas: canvas), 0)
    }

    func testStatePillsRemainVisibleAndCoveredRequiresConnection() {
        func persistent(_ state: Int?, connected: Bool = true) -> Bool {
            SessionChromePolicy.persistent(reconnecting: state == 0, reconnectBack: state == 1, busy: state == 2,
                                           bigText: state == 3, notice: state == 4, pan: state == 5,
                                           viewOnly: state == 6, connected: connected, covered: state == 7)
        }
        XCTAssertFalse(persistent(nil))
        for state in 0...7 { XCTAssertTrue(persistent(state), "State \(state) must never collapse") }
        XCTAssertFalse(persistent(7, connected: false), "A stale curtain state alone is not a live session state")
        XCTAssertTrue(persistent(0, connected: false), "Reconnect status stays visible without a connection")
    }

    func testIdleCollapseNeedsAnUnobstructedConnectedPillAndUsesTwoSeconds() {
        XCTAssertEqual(SessionChromePolicy.idleInterval, 2)
        for regular in [false, true] {
            for controlsCollapsed in [false, true] {
                for showControls in [false, true] {
                    for keyboardOpen in [false, true] {
                        for persistent in [false, true] {
                            XCTAssertEqual(SessionChromePolicy.mayCollapse(regular: regular, controlsCollapsed: controlsCollapsed,
                                                                          showControls: showControls, keyboardOpen: keyboardOpen,
                                                                          persistent: persistent),
                                           regular && controlsCollapsed && !showControls && !keyboardOpen && !persistent)
                        }
                    }
                }
            }
        }
    }
}
