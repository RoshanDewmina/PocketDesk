#if DEBUG
import AppKit
import CoreGraphics

/// Inputs for one fence decision, gathered from the window server or supplied by tests.
struct HostE2EFenceEnvironment {
    var testPadRunning: Bool
    var testPadFrontmost: Bool
    /// Test Pad content area in global CoreGraphics points (top-left origin).
    var testPadContent: CGRect?
    var pointer: CGPoint
    /// Owner of the topmost visible window under the pointer; nil when it is the Test Pad.
    var coveringOwner: String?

    @MainActor
    static func live(testPad: E2ETestPadGeometry) -> Self {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: E2E.testPadBundleID).first else {
            return Self(testPadRunning: false, testPadFrontmost: false, testPadContent: nil, pointer: pointer, coveringOwner: nil)
        }
        let pid = app.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                       as? [[String: Any]]) ?? []
        func bounds(_ window: [String: Any]) -> CGRect? {
            (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        let padWindow = windows
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap(bounds)
            .max { $0.width * $0.height < $1.width * $1.height }
        var content = padWindow
        if let padWindow, let published = testPad.snapshot()?.window {
            let intersection = padWindow.intersection(published)
            content = intersection.isNull || intersection.isEmpty ? nil : intersection
        }
        var covering: String?
        for window in windows {
            guard let frame = bounds(window), frame.contains(pointer),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            if (window[kCGWindowOwnerPID as String] as? Int32) != pid {
                covering = window[kCGWindowOwnerName as String] as? String ?? "another window"
            }
            break
        }
        return Self(testPadRunning: true, testPadFrontmost: frontmost, testPadContent: content,
                    pointer: pointer, coveringOwner: covering)
    }
}

/// Pure E2E input interlock: the harness may only drive the Farside Test Pad.
enum HostE2EInputFence {
    enum Verdict: Equatable {
        case allow
        case adjust(dx: Double, dy: Double)
        case reject(String)
    }

    static let edgeInset: CGFloat = 4
    static let plainKeys: Set<String> = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        .union(["return", "tab", "space", "delete", "escape", "left", "right", "up", "down"])
    static let commandKeys: Set<String> = ["a", "c", "v", "x", "z"]
    static let spaceKeys: Set<String> = ["left", "right"]

    static func decide(_ action: RemoteAction, held: Bool, allowSpaceKeys: Bool,
                       environment: HostE2EFenceEnvironment) -> Verdict {
        switch action.action {
        case "release", "dragUp", "holdRenew":
            return .allow
        case "key":
            return decideKey(action, allowSpaceKeys: allowSpaceKeys, environment: environment)
        default:
            break
        }
        guard environment.testPadRunning else { return .reject("Test Pad is not running") }
        guard environment.testPadFrontmost else { return .reject("Test Pad is not frontmost") }
        guard let content = environment.testPadContent?.insetBy(dx: edgeInset, dy: edgeInset),
              !content.isNull, content.width > 0, content.height > 0 else {
            return .reject("Test Pad window is not on screen")
        }
        switch action.action {
        case "move":
            let pointer = environment.pointer
            let target = CGPoint(x: pointer.x + action.x, y: pointer.y + action.y)
            let clamped = CGPoint(x: min(content.maxX, max(content.minX, target.x)),
                                  y: min(content.maxY, max(content.minY, target.y)))
            if clamped == target { return .allow }
            return .adjust(dx: Double(clamped.x - pointer.x), dy: Double(clamped.y - pointer.y))
        case "click", "right", "double", "dragDown", "scroll":
            guard content.contains(environment.pointer) else { return .reject("pointer is outside the Test Pad") }
            if let owner = environment.coveringOwner { return .reject("pointer is over \(owner)") }
            return .allow
        case "text":
            return .allow
        default:
            return .reject("action \(action.action) is not allowed in E2E mode")
        }
    }

    private static func decideKey(_ action: RemoteAction, allowSpaceKeys: Bool,
                                  environment: HostE2EFenceEnvironment) -> Verdict {
        let modifiers = Set(action.modifiers)
        if modifiers == ["control"], spaceKeys.contains(action.key) {
            // Mission Control's "Move left/right a space" are system hotkeys; the harness only
            // enables this after confirming they are on, so they never reach another app.
            return environment.testPadFrontmost || allowSpaceKeys ? .allow : .reject("Test Pad is not frontmost")
        }
        guard environment.testPadRunning, environment.testPadFrontmost else { return .reject("Test Pad is not frontmost") }
        if modifiers.isEmpty || modifiers == ["shift"] {
            return plainKeys.contains(action.key) ? .allow : .reject("key \(action.key) is not allowlisted")
        }
        if modifiers == ["command"], commandKeys.contains(action.key) { return .allow }
        return .reject("shortcut \(action.modifiers.joined(separator: "+"))+\(action.key) is not allowlisted")
    }
}
#endif
