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
    static func moves(before: [WindowRef: CGRect], after: [WindowRef: CGRect], now: [WindowRef: CGRect]) -> [(WindowRef, CGRect)] { [] }
}

protocol BigTextWindowKeeping: AnyObject {
    var hasSnapshot: Bool { get }
    func snapshot(within bounds: CGRect, pids: [pid_t]) async
    func recordSettled() async
    @discardableResult func restore() async -> Int
    func discard()
}
