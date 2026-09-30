import AppKit
import SwiftUI

@MainActor
final class CouchHUD {
    static let duration: TimeInterval = 3

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show() {
        hideTask?.cancel()
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, on: NSScreen.main))
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: CouchCopy.hud,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.orderOut()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        orderOut()
    }

    private func orderOut() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let content = NSHostingView(rootView: CouchHUDView())
        let size = content.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.title = "Farside Couch mode"
        panel.contentView = content
        panel.setContentSize(size)
        return panel
    }

    private static func origin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        guard let frame = screen?.frame else { return .zero }
        return NSPoint(x: frame.midX - size.width / 2,
                       y: frame.maxY - frame.height * 0.15 - size.height)
    }
}

struct CouchHUDView: View {
    var body: some View {
        HStack(spacing: Farside.Space.s) {
            HostLiveDot(size: 8)
            Text(CouchCopy.hud)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Farside.Space.l)
        .padding(.vertical, Farside.Space.m)
        .background(HostTheme.popoverBackground,
                    in: RoundedRectangle(cornerRadius: Farside.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Farside.Radius.card, style: .continuous)
            .strokeBorder(Farside.Palette.line2, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
