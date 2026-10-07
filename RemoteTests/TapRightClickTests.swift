import XCTest
import CoreGraphics

/// "A single tap opens the right-click menu" (device report, build 20261007.2). The phone's gesture
/// engine and the host driver never turn a tap or a hold into a secondary click; the Mac turned the
/// left press into a ⌃-click because the event inherited ⌃ left in the private event source by an
/// earlier ⌃-chord.
final class TapRightClickTests: XCTestCase {
    func testDirectTapAndHoldNeverSecondaryClick() {
        let tap = CommandLog()
        let a = engine(tap)
        a.update([touch(1, 300, 400)], at: 1)
        a.tick(at: 1.05)
        a.update([], at: 1.1)
        XCTAssertEqual(tap.trace, ["pointTo", "click1"])

        let hold = CommandLog()
        let b = engine(hold)
        b.update([touch(1, 300, 400)], at: 1)
        b.tick(at: 1.51)
        b.tick(at: 2.5)
        b.update([], at: 2.6)
        XCTAssertEqual(hold.trace, ["pointTo", "dragBegan1", "dragEnded"], "A hold is a left press, never a right click")
    }

    func testRestingFingerRightClicksOnlyInsideTheTwoFingerTapWindow() {
        let quick = CommandLog()
        let a = engine(quick)
        a.update([touch(1, 300, 400)], at: 1)
        a.update([touch(1, 300, 400), touch(2, 340, 400)], at: 1.2)
        a.update([], at: 1.3)
        XCTAssertEqual(quick.secondary, 1, "Two fingers down and up within 0.55 s is the two-finger tap")

        let resting = CommandLog()
        let b = engine(resting)
        b.update([touch(1, 300, 400)], at: 1)
        b.tick(at: 1.51)
        b.update([touch(1, 300, 400), touch(2, 340, 400)], at: 1.6)
        b.update([touch(1, 300, 400)], at: 1.7)
        b.update([], at: 1.8)
        XCTAssertEqual(resting.secondary, 0, "A finger resting long enough to hold cannot make a tap a right click")
        XCTAssertEqual(resting.dragBegins, 1)
        XCTAssertEqual(resting.dragEnds, 1)
    }

    func testDriverPostsAPlainLeftPressForTapsAndHolds() {
        var posted: [RemoteInputEventSink.MouseEvent] = []
        let sink = RemoteInputEventSink(
            pointerLocation: { CGPoint(x: 50, y: 50) },
            mouseSequence: { posted += $0; return true },
            scroll: { _, _, _ in true },
            text: { _ in true },
            key: { _, _ in true })
        let driver = RemoteInputDriver(eventSink: sink, isTrusted: { true })
        driver.enabled = true
        driver.configure(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(driver.handle(RemoteAction(action: "key", key: "down", modifiers: ["control"]), upgraded: false).accepted)
        XCTAssertTrue(driver.handle(RemoteAction(action: "click"), upgraded: false).accepted)
        XCTAssertTrue(driver.handle(RemoteAction(action: "dragDown"), upgraded: false).accepted)
        XCTAssertTrue(driver.handle(RemoteAction(action: "dragUp"), upgraded: false).accepted)
        XCTAssertEqual(posted.map(\.type), [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertTrue(posted.allSatisfy { $0.flags.isEmpty && $0.pencil == nil },
                      "No modifier, pressure or tablet field rides on a finger press")
    }

    func testEventsTakeOnlyThePhoneModifiersNotTheSourceState() throws {
        let latched: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                          mouseCursorPosition: .zero, mouseButton: .left))
        event.flags = latched
        RemoteInputEventSink.applyFlags([], to: event, explicit: true)
        XCTAssertEqual(event.flags, [], "A ⌃ left behind by a ⌃↓ chord must not turn a tap into a ⌃-click")

        event.flags = latched.union(.maskNonCoalesced)
        RemoteInputEventSink.applyFlags([], to: event, explicit: true)
        XCTAssertEqual(event.flags, .maskNonCoalesced, "Only modifier state is replaced")

        event.flags = latched
        RemoteInputEventSink.applyFlags([.maskCommand], to: event, explicit: true)
        XCTAssertEqual(event.flags, .maskCommand)

        event.flags = latched
        RemoteInputEventSink.applyFlags([], to: event, explicit: false)
        XCTAssertEqual(event.flags, latched, "Switch off: the previous inheriting behaviour")

        let modifiers: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate, .maskControl]
        let down = try XCTUnwrap(RemoteInputEventSink.makeMouseEvent(
            .init(type: .leftMouseDown, point: CGPoint(x: 5, y: 5), button: .left, count: 1)))
        XCTAssertTrue(down.flags.isDisjoint(with: modifiers))
        let text = try XCTUnwrap(RemoteInputEventSink.makeTextEvents(Array("Calculator".utf16)))
        XCTAssertEqual(text.count, 2)
        XCTAssertTrue(text.allSatisfy { $0.flags.isDisjoint(with: modifiers) && RemoteInputTag.isInjected($0, ownPID: 1) })
        XCTAssertEqual(RemoteInputEventSink.explicitFlagsKey, "input.explicitFlags")
    }

    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ log: CommandLog) -> NativeGestureEngine {
        NativeGestureEngine(enabled: true, panMode: false, revision: 1, sensitivity: 1,
                            pointerScale: 1, doubleClickInterval: 0.5, direct: true,
                            onCommand: { log.record($0) })
    }
}
