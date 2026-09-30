import AppKit
import XCTest

@MainActor
final class AwayLockTests: XCTestCase {
    func testTestProcessesCanNeverLockTheMac() {
        XCTAssertTrue(HostLockShortcut.postingRefused, "Safety: XCTest must never post the lock shortcut")
        XCTAssertFalse(SystemScreenLocker().requestLock(), "Refused before any event is created")
    }

    func testShortcutIsControlCommandQTaggedAsOurs() throws {
        let events = HostLockShortcut.events(source: CGEventSource(stateID: .privateState))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map { $0.type }, [.keyDown, .keyUp])
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 12)
            XCTAssertTrue(event.flags.contains(.maskControl) && event.flags.contains(.maskCommand))
            XCTAssertFalse(event.flags.contains(.maskShift) || event.flags.contains(.maskAlternate))
            XCTAssertTrue(RemoteInputTag.isInjected(event), "Our own monitor must not read the lock keystroke as a touch")
        }
    }

    func testEveryKindOfLocalInputIsWatched() {
        let expected: [(NSEvent.EventType, AwayInputEvent.Kind)] = [
            (.keyDown, .key), (.flagsChanged, .modifier), (.mouseMoved, .pointerMove),
            (.leftMouseDragged, .pointerMove), (.rightMouseDragged, .pointerMove), (.otherMouseDragged, .pointerMove),
            (.leftMouseDown, .click), (.rightMouseDown, .click), (.otherMouseDown, .click),
            (.scrollWheel, .scroll), (.magnify, .gesture), (.swipe, .gesture), (.rotate, .gesture), (.smartMagnify, .gesture)
        ]
        for (type, kind) in expected {
            XCTAssertEqual(AwayInputClassifier.kind(of: type), kind, "\(type)")
            XCTAssertTrue(AwayInputClassifier.eventMask.contains(NSEvent.EventTypeMask(type: type)), "\(type)")
        }
        XCTAssertNil(AwayInputClassifier.kind(of: .appKitDefined))
    }

    func testInjectedEventsAreNeverLocal() {
        for kind in [AwayInputEvent.Kind.key, .modifier, .pointerMove, .click, .scroll, .gesture] {
            XCTAssertFalse(AwayInputClassifier.isLocal(AwayInputEvent(kind: kind, injected: true)))
            XCTAssertTrue(AwayInputClassifier.isLocal(AwayInputEvent(kind: kind, injected: false)))
        }
    }

    func testMonitorStartStopIsIdempotent() {
        let monitor = SystemAwayInputMonitor()
        monitor.start { }
        monitor.start { }
        XCTAssertTrue(monitor.isRunning)
        monitor.stop(); monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }
}
