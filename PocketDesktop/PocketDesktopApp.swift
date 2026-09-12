import SwiftUI

@main
struct PocketDesktopApp: App {
    var body: some Scene {
        WindowGroup { PocketDesktopView().preferredColorScheme(.dark) }
    }
}

enum DesktopScale: String, CaseIterable, Identifiable {
    case comfortable = "Comfortable", balanced = "Balanced", space = "More Space"
    var id: Self { self }
    var width: CGFloat {
        switch self { case .comfortable: 800; case .balanced: 1040; case .space: 1280 }
    }
}

@Observable
final class DemoSession {
    var cursor = CGPoint(x: 0.50, y: 0.48)
    var scale: DesktopScale = .comfortable
    var keyboard = false
    var unfolded = false
    var focusWindow = false
    var shift = false
    var command = false
    var selectAll = false
    var selected = "Welcome"
    var document = "A little Mac.\nA lot of possibility.\n\nMove on the trackpad below.\nTap to select a file, or open the keyboard to write here."
    var event = "Ready to explore"
    var scroll: CGFloat = 0
    var maxScroll: CGFloat = 0
    var contextMenu = false
    var clickCount = 0
    var viewport = CGSize(width: 600, height: 400)
    var targets: [String: CGRect] = [:]

    func move(_ delta: CGSize) {
        cursor.x = min(0.985, max(0.015, cursor.x + delta.width / max(viewport.width, 1) * 1.2))
        cursor.y = min(0.975, max(0.025, cursor.y + delta.height / max(viewport.height, 1) * 1.2))
        event = "Pointer \(Int(cursor.x * 100)), \(Int(cursor.y * 100))"
    }
    func click() {
        clickCount += 1
        let point = CGPoint(x: cursor.x * viewport.width, y: cursor.y * viewport.height)
        if contextMenu {
            let target = targets.first(where: { $0.key.hasPrefix("menu-") && $0.value.contains(point) })?.key
            contextMenu = false
            if let target { activate(target) }
            return
        }
        if let target = targets.first(where: { !$0.key.hasPrefix("menu-") && $0.value.contains(point) })?.key { activate(target) }
        else { event = "Click \(clickCount)" }
    }
    func activate(_ target: String) {
        switch target {
        case "Welcome", "Ideas", "Read me": selected = target; scroll = 0; event = "Opened \(target)"
        case "menu-welcome": selected = "Welcome"; scroll = 0; event = "Opened Welcome"
        case "menu-centre": reset()
        case "focus", "menu-focus": focusWindow.toggle(); event = focusWindow ? "Window focused" : "Desktop restored"
        default: break
        }
    }
    func insert(_ text: String) {
        selected = "Welcome"
        if command {
            command = false
            if text.lowercased() == "a" { selectAll = true; event = "All text selected" }
            else { event = "Only Command-A is available in this demo" }
            return
        }
        if selectAll { document = ""; selectAll = false }
        document += shift ? text.uppercased() : text
        event = "Typing into Welcome"
    }
    func delete() {
        if selectAll { document = ""; selectAll = false }
        else if !document.isEmpty { document.removeLast() }
        event = "Deleted character"
    }
    func reset() {
        cursor = CGPoint(x: 0.5, y: 0.48); scroll = 0; contextMenu = false
        event = "Pointer centred"
    }
}

struct HitTargets: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func desktopTarget(_ id: String) -> some View {
        anchorPreference(key: HitTargets.self, value: .bounds) { [id: $0] }
    }
}
