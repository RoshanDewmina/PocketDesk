import AppKit
import ApplicationServices

/// The scroll area under the Mac pointer, for a phone that slides its own picture while a finger
/// scrolls (`SessionFeature.localScroll`). Queries run on their own Accessibility lane, so a slow app
/// never holds the lane a tap's focus probe needs, and they message only the application element of
/// the window under the pointer, whose timeout is per element rather than process-wide. A move asks
/// Accessibility again only when the pointer reaches another window or leaves the last area; a scroll's
/// start always asks. At most one query every `minimumInterval`, with one trailing query for where the
/// pointer stopped, and at most one status every `minimumSendInterval`.
@MainActor
final class HostScrollRegionProbe {
    static let minimumInterval: TimeInterval = 0.15
    static let minimumSendInterval: TimeInterval = 0.25
    static let budget: TimeInterval = 0.2
    nonisolated static let maximumAncestors = 16
    /// The window fallback leaves out a standard title bar, so the title never slides.
    nonisolated static let titleBarHeight: CGFloat = 28

    enum Answer: Sendable, Equatable {
        /// Same window and still inside the last area: nothing was asked.
        case unchanged
        case found(CGRect?, window: CGWindowID?)
    }

    private struct Last { var window: CGWindowID?; var global: CGRect? }

    private let broker = HostAXBroker(label: "com.roshan.farside.ax-scroll-region")
    private var lastQueryAt: TimeInterval = -.infinity
    private var running = false
    private var trailing: (point: CGPoint, display: CGRect, force: Bool)?
    private var trailingTask: Task<Void, Never>?
    private var last = Last()
    private var current: (frame: ScrollRegionFrame, display: CGRect)?
    private var lastSentAt: TimeInterval = -.infinity
    private var sendTask: Task<Void, Never>?
    var onChange: (() -> Void)?

    /// The region last found on `display`; nil for another display or none found.
    func region(on display: CGRect?) -> ScrollRegionFrame? {
        guard let current, current.display == display else { return nil }
        return current.frame
    }

    /// Movement actions whose resulting pointer position may sit over another scroll area.
    static func refreshes(after action: RemoteAction) -> Bool {
        switch action.action {
        case "move", "moveTo": return true
        case "scroll": return startsScroll(action)
        default: return false
        }
    }

    static func startsScroll(_ action: RemoteAction) -> Bool {
        action.action == "scroll" && (action.interaction?.phase == nil || action.interaction?.phase == "began")
    }

    func pointerMoved(to point: CGPoint, display: CGRect?, force: Bool = false,
                      at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let display, point.x.isFinite, point.y.isFinite, display.width > 0, display.height > 0 else { return }
        guard !running, now - lastQueryAt >= Self.minimumInterval else {
            trailing = (point, display, force || trailing?.force == true)
            scheduleTrailing()
            return
        }
        query(point, display: display, force: force, at: now)
    }

    private func scheduleTrailing() {
        guard trailingTask == nil, !running else { return }
        let wait = max(0.01, lastQueryAt + Self.minimumInterval - ProcessInfo.processInfo.systemUptime)
        trailingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.trailingTask = nil
            guard let next = self.trailing else { return }
            self.trailing = nil
            self.pointerMoved(to: next.point, display: next.display, force: next.force)
        }
    }

    private func query(_ point: CGPoint, display: CGRect, force: Bool, at now: TimeInterval) {
        running = true
        lastQueryAt = now
        trailing = nil
        let known = force ? Last() : last
        let own = ProcessInfo.processInfo.processIdentifier
        Task { @MainActor [weak self, broker] in
            let answer = await broker.run(budget: Self.budget) { budget in
                Self.answer(at: point, lastWindow: known.window, lastArea: known.global, excluding: own, budget: budget)
            }
            guard let self else { return }
            self.running = false
            // A dropped or timed-out query says nothing; keep the last answer.
            if case .found(let global, let window) = answer {
                self.last = Last(window: window, global: global)
                let frame = global.flatMap { ScrollRegionFrame.displayLocal($0, display: display) }
                let next = frame.map { (frame: $0, display: display) }
                if next?.frame != self.current?.frame || next?.display != self.current?.display {
                    self.current = next
                    self.deliver()
                }
            }
            if self.trailing != nil { self.scheduleTrailing() }
        }
    }

    private func deliver() {
        guard sendTask == nil else { return }
        let wait = lastSentAt + Self.minimumSendInterval - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else {
            lastSentAt = ProcessInfo.processInfo.systemUptime
            onChange?()
            return
        }
        sendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.sendTask = nil
            self.lastSentAt = ProcessInfo.processInfo.systemUptime
            self.onChange?()
        }
    }

    /// The topmost other-process window under the point, front to back, below the menu bar and Dock levels.
    nonisolated static func window(at point: CGPoint, excluding own: pid_t) -> (id: CGWindowID, pid: pid_t)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = info[kCGWindowLayer as String] as? Int, layer < Int(CGWindowLevelForKey(.dockWindow)),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (id, pid)
        }
        return nil
    }

    nonisolated static func answer(at point: CGPoint, lastWindow: CGWindowID?, lastArea: CGRect?, excluding own: pid_t,
                                   budget: HostAXBudget) -> Answer? {
        guard AXIsProcessTrusted() else { return nil }
        guard let window = window(at: point, excluding: own) else { return .found(nil, window: nil) }
        if window.id == lastWindow, let lastArea, lastArea.contains(point) { return .unchanged }
        return scrollArea(at: point, pid: window.pid, budget: budget).map { .found($0, window: window.id) }
    }

    /// The nearest scroll area above the element under the point, else its web area, else its window
    /// below the title bar. Global top-left points; an inner nil means none, an outer nil no answer.
    nonisolated static func scrollArea(at point: CGPoint, pid: pid_t, budget: HostAXBudget) -> CGRect?? {
        let app = AXUIElementCreateApplication(pid)
        guard budget.arm(app) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return .some(nil) }
        var web: CGRect?
        for _ in 0..<maximumAncestors {
            guard budget.arm(element) else { return nil }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXScrollAreaRole, budget.arm(element), let frame = frame(of: element) { return frame }
            if role == "AXWebArea", web == nil, budget.arm(element) { web = frame(of: element) }
            if role == kAXWindowRole {
                if let web { return web }
                guard budget.arm(element), let window = frame(of: element), window.height > titleBarHeight else { return .some(nil) }
                return CGRect(x: window.minX, y: window.minY + titleBarHeight,
                              width: window.width, height: window.height - titleBarHeight)
            }
            guard budget.arm(element), let value = attribute(element, kAXParentAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { break }
            element = value as! AXUIElement
        }
        return .some(web)
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = attribute(element, kAXPositionAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              let extent = attribute(element, kAXSizeAttribute),
              CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(extent as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
