import AppKit
import XCTest

@MainActor
final class AwayLockTests: XCTestCase {
    func testTestProcessesCanNeverLockTheMac() {
        guard HostLockShortcut.postingRefused else { return XCTFail("Safety: XCTest must never post the lock shortcut") }
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
        let monitor = SystemAwayInputMonitor(backend: .init(global: { _, _ in NSObject() },
                                                           local: { _, _ in NSObject() }, remove: { _ in }))
        monitor.start { }
        monitor.start { }
        XCTAssertTrue(monitor.isRunning)
        monitor.stop(); monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    func testPartialMonitorInstallationIsNotReadyAndIsRemoved() {
        for failGlobal in [false, true] {
            var removed = 0
            let monitor = SystemAwayInputMonitor(backend: .init(
                global: { _, _ in failGlobal ? nil : NSObject() },
                local: { _, _ in failGlobal ? NSObject() : nil },
                remove: { _ in removed += 1 }))
            monitor.start { XCTFail("No partial observer may report input") }
            XCTAssertFalse(monitor.isRunning)
            XCTAssertEqual(removed, 1)
        }
    }

    func testLocalInputActsSynchronouslyBeforeTheTargetActionAndStaleCallbacksAreIgnored() throws {
        var callback: ((NSEvent) -> NSEvent?)?
        let monitor = SystemAwayInputMonitor(backend: .init(global: { _, _ in NSObject() },
            local: { _, report in callback = report; return NSObject() }, remove: { _ in }))
        var events: [String] = []
        monitor.start { events.append("lock") }
        let cgEvent = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState),
                                           virtualKey: 7, keyDown: true))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        cgEvent.setIntegerValueField(.eventSourceUserData, value: 0)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        _ = callback?(event)
        events.append("target action")
        XCTAssertEqual(events, ["lock", "target action"])
        monitor.stop()
        _ = callback?(event)
        XCTAssertEqual(events, ["lock", "target action"])
    }
}
