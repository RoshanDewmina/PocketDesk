import AppKit
import ApplicationServices

/// Public AX references remain host-only and die with their catalog generation.
@MainActor
final class HostWindowWorkspace {
    private final class Target: @unchecked Sendable {
        let app: NSRunningApplication
        let launch: Date?
        let window: AXUIElement?
        let row: WindowWorkspaceEntry
        init(app: NSRunningApplication, window: AXUIElement?, title: String?) {
            self.app = app; launch = app.launchDate; self.window = window
            row = .init(id: InputCausalEnvelope.identity(), app: WindowWorkspaceReply.label(app.localizedName ?? "Mac app"),
                        title: title.map(WindowWorkspaceReply.label), exactWindow: window != nil)
        }
    }
    private var expiry: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var targets: [String: Target] = [:]
    private var revision: String?
    private var lifetime: WindowWorkspaceLifetime?
    func retire() { expiry?.cancel(); expiry = nil; generation &+= 1; targets = [:]; revision = nil; lifetime = nil }
    var currentGeneration: UInt64 { generation }

    func list(session: UUID, epoch: UInt64, display: UInt32, frame: CGRect) async -> WindowWorkspaceReply? {
        retire()
        let started = generation
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.prefix(40)
        let result = await Task.detached(priority: .userInitiated) { Self.catalog(Array(apps), displayFrame: frame) }.value
        guard started == generation else { return nil }
        let revision = InputCausalEnvelope.identity()
        guard let reply = WindowWorkspaceReply.boundedCatalog(revision: revision, entries: result.map(\.row)) else { return nil }
        let admitted = Set(reply.entries.map(\.id))
        self.revision = revision; targets = Dictionary(uniqueKeysWithValues: result.filter { admitted.contains($0.row.id) }.map { ($0.row.id, $0) })
        lifetime = .init(session: session, epoch: epoch, display: display, generation: generation, issuedAt: ProcessInfo.processInfo.systemUptime)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.generation == started else { return }
            self.retire()
        }
        return reply
    }

    func activate(_ request: WindowWorkspaceRequest, session: UUID, epoch: UInt64, display: UInt32, displayFrame: CGRect, allowed: Bool, authority: () -> Bool) -> WindowWorkspaceReply {
        guard let lifetime, lifetime.permits(session: session, epoch: epoch, display: display, generation: generation,
             now: ProcessInfo.processInfo.systemUptime, allowed: allowed), request.revision == revision,
              let handle = request.handle, let target = targets[handle], Self.live(target) else {
            return .init(operation: .activate, outcome: allowed ? .stale : .notAllowed)
        }
        if let window = target.window {
            guard let current = Self.windows(target.app),
                  WindowWorkspaceLifetime.currentWindow(retainedMember: current.contains(where: { CFEqual($0, window) }),
                    minimized: Self.bool(window, kAXMinimizedAttribute) != false, frame: Self.frame(window), displayFrame: displayFrame)
            else { return .init(operation: .activate, outcome: .stale) }
        }
        // The caller checks owner authority immediately before this synchronous, bounded effect.
        guard authority(), Self.live(target) else { return .init(operation: .activate, outcome: .notAllowed) }
        let appRequested = target.app.activate(options: [])
        guard authority() else { return .init(operation: .activate, outcome: .notAllowed) }
        let raised = target.window.map { AXUIElementPerformAction($0, kAXRaiseAction as CFString) == .success } ?? true
        guard appRequested else { return .init(operation: .activate, outcome: .unsupported) }
        let front = NSWorkspace.shared.frontmostApplication
        let appConfirmed = front?.processIdentifier == target.app.processIdentifier && front?.launchDate == target.launch
        let windowConfirmed = target.window.map { window in
            let appAX = AXUIElementCreateApplication(target.app.processIdentifier)
            Self.timeout(appAX)
            return Self.element(appAX, kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
        } ?? true
        return .init(operation: .activate, outcome: appConfirmed && windowConfirmed && raised ? .confirmed : .requested)
    }

    func focusedGeometry(displayFrame: CGRect) async -> FocusGeometry? {
        let started = generation
        guard let app = NSWorkspace.shared.frontmostApplication, let launch = app.launchDate else { return nil }
        let snapshot = await Task.detached(priority: .userInitiated) {
            let element = AXUIElementCreateApplication(app.processIdentifier); Self.timeout(element)
            guard let window = Self.element(element, kAXFocusedWindowAttribute), Self.frame(window) != nil else { return nil as Target? }
            return Target(app: app, window: window, title: nil)

        }.value
        guard started == generation, !app.isTerminated, app.launchDate == launch,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, let snapshot,
              let window = snapshot.window, let focused = Self.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              CFEqual(window, focused), let rect = Self.frame(window) else { return nil }
        return FocusGeometry.make(field: rect, anchor: nil, displayFrame: displayFrame, geometrySize: displayFrame.size)
    }

    nonisolated private static func catalog(_ apps: [NSRunningApplication], displayFrame: CGRect) -> [Target] {
        var result: [Target] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        for app in apps {
            guard result.count < 24, ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard !app.isTerminated, app.launchDate != nil else { continue }
            // Always offer the deliberate app fallback, including unsupported AX applications.
            result.append(Target(app: app, window: nil, title: nil))
            for window in (windows(app) ?? []).prefix(12) {
                guard result.count < 24, ProcessInfo.processInfo.systemUptime < deadline else { break }
                guard string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      bool(window, kAXMinimizedAttribute) == false, let frame = frame(window),
                      !frame.intersection(displayFrame).isNull, supportsRaise(window) else { continue }
                result.append(Target(app: app, window: window, title: string(window, kAXTitleAttribute)))
            }
        }
        return result
    }
    nonisolated private static func supportsRaise(_ window: AXUIElement) -> Bool {
        timeout(window); var actions: CFArray?
        guard AXUIElementCopyActionNames(window, &actions) == .success else { return false }
        return (actions as? [String])?.contains(kAXRaiseAction as String) == true
    }
    nonisolated private static func live(_ target: Target) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: target.app.processIdentifier) else { return false }
        return WindowWorkspaceLifetime.sameProcess(pid: target.app.processIdentifier, launch: target.launch,
            currentPID: current.processIdentifier, currentLaunch: current.launchDate, terminated: target.app.isTerminated || current.isTerminated)
    }
    nonisolated private static func timeout(_ element: AXUIElement) { _ = AXUIElementSetMessagingTimeout(element, 0.05) }
    nonisolated private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        timeout(element); var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    nonisolated private static func windows(_ app: NSRunningApplication) -> [AXUIElement]? {
        value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]
    }
    nonisolated private static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let result = value(element, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    nonisolated private static func string(_ element: AXUIElement, _ key: String) -> String? { value(element, key) as? String }
    nonisolated private static func bool(_ element: AXUIElement, _ key: String) -> Bool? { value(element, key) as? Bool }
    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
