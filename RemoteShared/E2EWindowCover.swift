#if os(macOS)
import CoreGraphics
import Foundation

/// E2E harness support: which on-screen windows would take a click instead of the Farside Test Pad.
/// macOS keeps full-screen, mostly transparent system containers above every app (the Dock at
/// layer 20, Notification Centre at 21, the Screenshot overlay and menu bar at 24) and a cursor
/// window; those are backdrops, not obstructions. Alerts (UserNotificationCenter, layer 8), crash
/// reports, other apps' windows and notification banners are obstructions.
enum E2EWindowCover {
    struct Window: Equatable {
        var owner: String
        var pid: Int32
        var layer: Int
        var alpha: Double
        var bounds: CGRect
    }

    /// On-screen windows, front to back (optionally only those above `windowID`).
    static func onScreen(above windowID: CGWindowID? = nil) -> [Window] {
        let options: CGWindowListOption = windowID == nil
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionOnScreenAboveWindow, .excludeDesktopElements]
        let list = (CGWindowListCopyWindowInfo(options, windowID ?? kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            guard let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return Window(owner: entry[kCGWindowOwnerName as String] as? String ?? "another window",
                          pid: entry[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                          layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                          alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                          bounds: bounds)
        }
    }

    static func isBackdrop(_ window: Window, display: CGRect) -> Bool {
        if window.alpha <= 0.01 { return true }
        if window.layer >= Int(CGWindowLevelForKey(.cursorWindow)) { return true }
        let fullScreen = window.bounds.width >= display.width - 2 && window.bounds.height >= display.height - 2
        if fullScreen && window.layer >= Int(CGWindowLevelForKey(.dockWindow)) { return true }
        // The menu bar strip along the top edge.
        if window.layer >= Int(CGWindowLevelForKey(.mainMenuWindow)) && window.bounds.height <= 60
            && abs(window.bounds.minY - display.minY) <= 1 { return true }
        return false
    }

    /// The first real window under `point` (front to back), or nil when only backdrops are there.
    static func topmost(at point: CGPoint, in windows: [Window], display: CGRect) -> Window? {
        windows.first { $0.bounds.contains(point) && !isBackdrop($0, display: display) }
    }

    /// Owners of real windows (other than `ownPID`) overlapping `region`.
    static func covering(_ region: CGRect, windows: [Window], ownPID: Int32, display: CGRect) -> [String] {
        var owners: [String] = []
        for window in windows where window.pid != ownPID && !isBackdrop(window, display: display) {
            let overlap = window.bounds.intersection(region)
            if !overlap.isNull, overlap.width > 2, overlap.height > 2, !owners.contains(window.owner) {
                owners.append(window.owner)
            }
        }
        return owners
    }
}
#endif
