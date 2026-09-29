import XCTest
import UIKit
@testable import PocketDeskRemote

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
