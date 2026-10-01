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
        let testProcess = env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #if DEBUG
        return testProcess || env["FARSIDE_AWAY_LOCK_DISABLED"] == "1"
        #else
        return testProcess
        #endif
    }

    /// Also used by the watchdog thread when the main actor cannot answer.
    static func post() -> Bool {
        guard !postingRefused, CGPreflightPostEventAccess() else { return false }
        let events = events(source: CGEventSource(stateID: .hidSystemState))
        guard events.count == 2 else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }
}

@MainActor
final class SystemScreenLocker: HostScreenLocking {
    // The public ⌃⌘Q shortcut instead of the private SACLockScreenImmediate: private
    // login-framework symbols can vanish in any macOS update and would fail silently.
    func requestLock() -> Bool {
        HostLockShortcut.post()
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
    struct Backend {
        var global: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
        var local: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
        var remove: (Any) -> Void

        static let system = Backend(
            global: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
            local: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
            remove: { NSEvent.removeMonitor($0) })
    }

    private(set) var isRunning = false
    private let backend: Backend
    private var monitors: [Any] = []
    private var generation: UInt64 = 0

    init(backend: Backend = .system) { self.backend = backend }

    func start(onLocalInput: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        generation &+= 1
        let token = generation
        let report: (NSEvent) -> Void = { [weak self] event in
            guard Self.isLocal(event) else { return }
            MainActor.assumeIsolated {
                // AppKit invokes these on main. Only our local monitor is before our own dispatch;
                // the global observer cannot suppress another app's event (physical S1 gate).
                guard let self, self.isRunning, self.generation == token else { return }
                onLocalInput()
            }
        }
        // Input aimed at other apps; keys need Accessibility, which Away mode requires anyway.
        if let global = backend.global(AwayInputClassifier.eventMask, report) {
            monitors.append(global)
        }
        // Input aimed at Farside's own windows, which the global monitor never sees.
        if let local = backend.local(AwayInputClassifier.eventMask, { event in
            report(event)
            return event
        }) {
            monitors.append(local)
        }
        isRunning = monitors.count == 2
        if !isRunning {
            for monitor in monitors { backend.remove(monitor) }
            monitors.removeAll()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        for monitor in monitors { backend.remove(monitor) }
        monitors.removeAll()
    }

    private nonisolated static func isLocal(_ event: NSEvent) -> Bool {
        guard let kind = AwayInputClassifier.kind(of: event.type) else { return false }
        return AwayInputClassifier.isLocal(AwayInputEvent(kind: kind, injected: RemoteInputTag.isInjected(event.cgEvent)))
    }
}

#if DEBUG
/// An explicit E2E process must never post a system lock request.
@MainActor
final class InertAwayLocker: HostScreenLocking {
    func requestLock() -> Bool { false }
    func isScreenLocked() -> Bool { false }
}
#endif
