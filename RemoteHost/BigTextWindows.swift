import AppKit
import ApplicationServices

final class WindowRef: Hashable, @unchecked Sendable {
    let pid: pid_t
    let element: AnyObject

    init(pid: pid_t, element: AnyObject) {
        self.pid = pid
        self.element = element
    }

    static func == (lhs: WindowRef, rhs: WindowRef) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

protocol WindowAccess: AnyObject, Sendable {
    func standardWindows(within bounds: CGRect, pids: [pid_t]) -> [WindowRef]
    func frame(of window: WindowRef) -> CGRect?
    func setFrame(_ frame: CGRect, of window: WindowRef) -> Bool
    var stageManagerEnabled: Bool { get }
}

enum WindowRestorePlan {
    static let tolerance: CGFloat = 2

    static func moves(before: [WindowRef: CGRect], after: [WindowRef: CGRect], now: [WindowRef: CGRect]) -> [(WindowRef, CGRect)] {
        before.compactMap { window, original -> (WindowRef, CGRect)? in
            guard let settled = after[window], let current = now[window],
                  close(settled, current), !close(original, current) else { return nil }
            return (window, original)
        }
        .sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

protocol BigTextWindowKeeping: AnyObject {
    var hasSnapshot: Bool { get }
    func snapshot(within bounds: CGRect, pids: [pid_t]) async
    func recordSettled() async
    @discardableResult func restore() async -> Int
    func discard()
}

final class BigTextWindowKeeper: BigTextWindowKeeping, @unchecked Sendable {
    private let access: WindowAccess
    private let queue: DispatchQueue
    // State sits behind its own lock, not the work queue, so hasSnapshot and discard never wait
    // on Accessibility calls to a slow app.
    private let lock = NSLock()
    private var before: [WindowRef: CGRect] = [:]
    private var after: [WindowRef: CGRect] = [:]
    private var generation = 0

    init(access: WindowAccess, queue: DispatchQueue = DispatchQueue(label: "farside.bigtext.windows", qos: .userInitiated)) {
        self.access = access
        self.queue = queue
    }

    var hasSnapshot: Bool { lock.withLock { !before.isEmpty } }

    func snapshot(within bounds: CGRect, pids: [pid_t]) async {
        let started = lock.withLock { generation }
        await run {
            let frames = self.frames(of: self.access.standardWindows(within: bounds, pids: pids))
            self.lock.withLock {
                guard self.generation == started else { return }
                self.before = frames
                self.after = [:]
            }
        }
    }

    func recordSettled() async {
        let started = lock.withLock { generation }
        await run {
            let windows = self.lock.withLock { Array(self.before.keys) }
            let frames = self.frames(of: windows)
            self.lock.withLock {
                guard self.generation == started else { return }
                self.after = frames
            }
        }
    }

    @discardableResult
    func restore() async -> Int {
        await run {
            let (before, after): ([WindowRef: CGRect], [WindowRef: CGRect]) = self.lock.withLock {
                defer { self.clear() }
                return (self.before, self.after)
            }
            guard !before.isEmpty, !self.access.stageManagerEnabled else { return 0 }
            let now = self.frames(of: Array(before.keys))
            return WindowRestorePlan.moves(before: before, after: after, now: now)
                .filter { self.access.setFrame($0.1, of: $0.0) }.count
        }
    }

    func discard() {
        lock.withLock {
            clear()
            generation += 1
        }
    }

    private func clear() {
        before = [:]
        after = [:]
    }

    private func frames(of windows: [WindowRef]) -> [WindowRef: CGRect] {
        Dictionary(uniqueKeysWithValues: windows.compactMap { window in access.frame(of: window).map { (window, $0) } })
    }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }
}

final class LiveWindowAccess: WindowAccess, @unchecked Sendable {
    private static let timeout: Float = 0.1

    var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    func standardWindows(within bounds: CGRect, pids: [pid_t]) -> [WindowRef] {
        pids.flatMap { pid -> [WindowRef] in
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(app, Self.timeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                _ = AXUIElementSetMessagingTimeout(window, Self.timeout)
                guard Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      Self.bool(window, kAXMinimizedAttribute) != true, Self.bool(window, "AXFullScreen") != true,
                      let frame = Self.frame(window), bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                else { return nil }
                return WindowRef(pid: pid, element: window)
            }
        }
    }

    func frame(of window: WindowRef) -> CGRect? { Self.frame(window.element as! AXUIElement) }

    func setFrame(_ frame: CGRect, of window: WindowRef) -> Bool {
        let element = window.element as! AXUIElement
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return false }
        let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        return sized == .success && moved == .success
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
