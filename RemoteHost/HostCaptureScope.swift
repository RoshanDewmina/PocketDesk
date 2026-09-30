import AppKit
import ScreenCaptureKit

/// Owner-local handle: retain the actual application instance, not just its recyclable PID.
struct HostCaptureTarget {
    let id: String
    let kind: CaptureScopeFrame.Kind
    let displayID: CGDirectDisplayID
    let windowID: CGWindowID?
    let application: NSRunningApplication
    let launchDate: Date?
    let name: String

    var processIsAlive: Bool { !application.isTerminated && application.processIdentifier > 0 }

    func matches(_ app: SCRunningApplication) -> Bool {
        guard processIsAlive, app.processID == application.processIdentifier,
              let current = NSRunningApplication(processIdentifier: app.processID),
              current.isEqual(application), current.launchDate == launchDate else { return false }
        return true
    }
}

struct HostResolvedCaptureScope {
    let display: SCDisplay
    let filter: SCContentFilter
    let target: HostCaptureTarget?
}

enum HostCaptureScopeError: Error { case targetUnavailable }

@MainActor
final class HostCaptureScope {
    static let displayID = "display"
    private(set) var targets: [HostCaptureTarget] = []
    private var refreshGeneration: UInt64 = 0

    var options: [HostCaptureScopeOption] {
        [HostCaptureScopeOption(id: Self.displayID, name: "Entire display")] + targets.map {
            HostCaptureScopeOption(id: $0.id, name: $0.kind == .application ? "App: \($0.name)" : "Window: \($0.name)")
        }
    }

    /// A refresh cannot change an existing selection into a new process with the same PID.
    func refresh(displayID: CGDirectDisplayID) async throws {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard generation == refreshGeneration else { return }
        guard content.displays.contains(where: { $0.displayID == displayID }) else { throw HostCaptureScopeError.targetUnavailable }
        let old = targets
        var next: [HostCaptureTarget] = []
        for app in content.applications {
            guard app.processID != ProcessInfo.processInfo.processIdentifier,
                  let instance = NSRunningApplication(processIdentifier: app.processID),
                  !instance.isTerminated, instance.activationPolicy == .regular else { continue }
            let appWindows = content.windows.filter { $0.owningApplication?.processID == app.processID && $0.windowLayer == 0 }
            guard !appWindows.isEmpty else { continue }
            func target(kind: CaptureScopeFrame.Kind, window: SCWindow?) -> HostCaptureTarget {
                let retained = old.first { $0.kind == kind && $0.displayID == displayID && $0.windowID == window?.windowID && $0.application.isEqual(instance) }
                let name = window?.title.flatMap { $0.isEmpty ? nil : $0 } ?? app.applicationName
                return HostCaptureTarget(id: retained?.id ?? UUID().uuidString, kind: kind,
                    displayID: displayID, windowID: window?.windowID, application: instance,
                    launchDate: instance.launchDate, name: name)
            }
            next.append(target(kind: .application, window: nil))
            next += appWindows.map { target(kind: .window, window: $0) }
        }
        targets = next
    }

    func target(id: String) -> HostCaptureTarget? { targets.first { $0.id == id } }

    /// Always enumerate again before constructing a filter, including on background resume/restart.
    /// A vanished target is an error; there is deliberately no full-display fallback here.
    static func resolve(_ target: HostCaptureTarget, content: SCShareableContent) throws -> HostResolvedCaptureScope {
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }),
              let app = content.applications.first(where: { target.matches($0) }) else {
            throw HostCaptureScopeError.targetUnavailable
        }
        let window = content.windows.first {
            $0.windowLayer == 0 && $0.owningApplication.map(target.matches) == true &&
                (target.kind != .window || $0.windowID == target.windowID)
        }
        guard SharedCaptureScopePolicy.targetIsAvailable(kind: target.kind, displayPresent: true,
            exactProcessInstance: target.matches(app), selectedWindowPresent: window != nil)
        else { throw HostCaptureScopeError.targetUnavailable }
        let filter: SCContentFilter
        if target.kind == .window, let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            guard target.kind == .application else { throw HostCaptureScopeError.targetUnavailable }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            filter.includeMenuBar = false
        }
        return HostResolvedCaptureScope(display: display, filter: filter, target: target)
    }

    static func resolve(_ target: HostCaptureTarget) async throws -> HostResolvedCaptureScope {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        return try resolve(target, content: content)
    }
}
