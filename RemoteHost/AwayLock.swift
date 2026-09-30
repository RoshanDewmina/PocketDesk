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

    static func events(source: CGEventSource?) -> [CGEvent] { [] }

    /// A test process must never lock the Mac.
    static var postingRefused: Bool { true }
}

@MainActor
final class SystemScreenLocker: HostScreenLocking {
    func requestLock() -> Bool { false }
    func isScreenLocked() -> Bool { HostScreenLock.isLocked() }
}

struct AwayInputEvent: Equatable {
    enum Kind: Equatable { case key, modifier, pointerMove, click, scroll, gesture }
    var kind: Kind
    var injected: Bool
}

enum AwayInputClassifier {
    static let eventMask: NSEvent.EventTypeMask = []

    static func kind(of type: NSEvent.EventType) -> AwayInputEvent.Kind? { nil }
    static func isLocal(_ event: AwayInputEvent) -> Bool { false }
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

    func start(onLocalInput: @escaping @MainActor () -> Void) {}
    func stop() {}
}
