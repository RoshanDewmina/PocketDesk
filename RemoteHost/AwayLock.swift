import AppKit
import CoreGraphics

@MainActor
protocol HostScreenLocking: AnyObject {
    /// Posts the system Lock Screen shortcut. False when the events could not be made or posting is refused.
    func requestLock() -> Bool
    func isScreenLocked() -> Bool
}

/// The system Lock Screen shortcut, ⌃⌘Q. S2 in Docs/plans/AWAY-MODE-FEASIBILITY-TESTS.md checks it on real hardware.
enum HostLockShortcut {
    static let keyCode: CGKeyCode = 12
    static let flags: CGEventFlags = [.maskControl, .maskCommand]

    static func events(source: CGEventSource?) -> [CGEvent] {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return [] }
        for event in [down, up] {
            event.flags = flags
            RemoteInputTag.mark(event)
        }
        return [down, up]
    }

    /// A test process must never lock the Mac.
    static var postingRefused: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["FARSIDE_AWAY_LOCK_DISABLED"] == "1"
            || NSClassFromString("XCTestCase") != nil
    }
}

@MainActor
final class SystemScreenLocker: HostScreenLocking {
    // The public ⌃⌘Q shortcut instead of the private SACLockScreenImmediate: private
    // login-framework symbols can vanish in any macOS update and would fail silently.
    func requestLock() -> Bool {
        guard !HostLockShortcut.postingRefused else { return false }
        let events = HostLockShortcut.events(source: CGEventSource(stateID: .hidSystemState))
        guard events.count == 2 else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    func isScreenLocked() -> Bool { HostScreenLock.isLocked() }
}

struct AwayInputEvent: Equatable {
    enum Kind: Equatable { case key, modifier, pointerMove, click, scroll, gesture }
    var kind: Kind
    var injected: Bool
}

enum AwayInputClassifier {
    static let eventMask: NSEvent.EventTypeMask = [
        .keyDown, .flagsChanged,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .scrollWheel, .magnify, .swipe, .rotate, .smartMagnify
    ]

    static func kind(of type: NSEvent.EventType) -> AwayInputEvent.Kind? {
        switch type {
        case .keyDown: .key
        case .flagsChanged: .modifier
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .pointerMove
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: .click
        case .scrollWheel: .scroll
        case .magnify, .swipe, .rotate, .smartMagnify: .gesture
        default: nil
        }
    }

    static func isLocal(_ event: AwayInputEvent) -> Bool { !event.injected }
}

@MainActor
protocol AwayInputMonitoring: AnyObject {
    var isRunning: Bool { get }
    func start(onLocalInput: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class SystemAwayInputMonitor: AwayInputMonitoring {
    private(set) var isRunning = false
    private var monitors: [Any] = []
    private var generation: UInt64 = 0

    func start(onLocalInput: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let token = generation
        let report: (NSEvent) -> Void = { [weak self] event in
            guard Self.isLocal(event) else { return }
            Task { @MainActor in
                // A hop queued just before stop() must not reach a disarmed caller.
                guard let self, self.isRunning, self.generation == token else { return }
                onLocalInput()
            }
        }
        // Input aimed at other apps; keys need Accessibility, which Away mode requires anyway.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: AwayInputClassifier.eventMask, handler: report) {
            monitors.append(global)
        }
        // Input aimed at Farside's own windows, which the global monitor never sees.
        if let local = NSEvent.addLocalMonitorForEvents(matching: AwayInputClassifier.eventMask, handler: { event in
            report(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private nonisolated static func isLocal(_ event: NSEvent) -> Bool {
        guard let kind = AwayInputClassifier.kind(of: event.type) else { return false }
        return AwayInputClassifier.isLocal(AwayInputEvent(kind: kind, injected: RemoteInputTag.isInjected(event.cgEvent)))
    }
}
