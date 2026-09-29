import SwiftUI
import AppKit

/// The Farside mark: a dot-matrix pointer whose tip dot is the point of contact.
enum HostMark {
    /// For small sizes, including the menu bar.
    static let compact = ["#", "##", "###", "####", "#####", "######", "###", "#.##", "...#"]
    static let full = ["#", "##", "###", "####", "#####", "######", "#######", "########", "#########",
                       "##########", "######", "##.##", "#...##", "....##", ".....##", ".....##"]

    struct Dot: Equatable {
        let column: Int
        let row: Int
        var isTip: Bool { column == 0 && row == 0 }
    }

    static func dots(_ rows: [String]) -> [Dot] {
        rows.enumerated().flatMap { row, line in
            line.enumerated().compactMap { column, cell in cell == "#" ? Dot(column: column, row: row) : nil }
        }
    }

    static func columns(_ rows: [String]) -> Int { rows.map(\.count).max() ?? 0 }
}

/// The mark inside the app. The tip is ember only when it stands for a live connection.
struct HostMarkView: View {
    var height: CGFloat = 18
    var tipLit = false

    var body: some View {
        let rows = height < 30 ? HostMark.compact : HostMark.full
        let pitch = height / CGFloat(rows.count)
        Canvas { context, _ in
            for dot in HostMark.dots(rows) {
                let radius = pitch * (dot.isTip ? 0.5 : 0.42)
                let rect = CGRect(x: (CGFloat(dot.column) + 0.5) * pitch - radius,
                                  y: (CGFloat(dot.row) + 0.5) * pitch - radius,
                                  width: radius * 2, height: radius * 2)
                let color = dot.isTip && tipLit ? Farside.Palette.ember : Farside.Palette.bone
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: CGFloat(HostMark.columns(rows)) * pitch, height: height)
        .accessibilityHidden(true)
    }
}

/// Lowercase "farside" in Doto.
struct HostWordmark: View {
    var height: CGFloat = 14

    var body: some View {
        Text(verbatim: "farside")
            .font(HostType.display(height * 1.6))
            .foregroundStyle(Farside.Palette.bone)
            .accessibilityElement()
            .accessibilityLabel("Farside")
    }
}

/// Menu-bar images of the mark. Idle, paused and attention are template images so macOS tints
/// them with the menu bar; while live the tip is drawn ember and the body follows the menu bar's
/// label color at draw time.
enum HostMenuBarIcon {
    static let size = NSSize(width: 14, height: 20)
    private static let pitch: CGFloat = 2
    private static let inset: CGFloat = 2

    static func image(for state: HostMarkState, accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            draw(state)
            return true
        }
        image.isTemplate = state != .live
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func draw(_ state: HostMarkState) {
        let body: NSColor = switch state {
        case .live: .labelColor
        case .paused: NSColor.black.withAlphaComponent(0.42)
        case .idle, .attention: .black
        }
        for dot in HostMark.dots(HostMark.compact) {
            let center = NSPoint(x: inset + CGFloat(dot.column) * pitch, y: inset + CGFloat(dot.row) * pitch)
            if dot.isTip {
                drawTip(at: center, state: state, body: body)
            } else {
                body.setFill()
                circle(center, radius: 0.84).fill()
            }
        }
    }

    private static func drawTip(at center: NSPoint, state: HostMarkState, body: NSColor) {
        switch state {
        case .live:
            NSColor(Farside.Palette.ember).withAlphaComponent(0.35).setFill()
            circle(center, radius: 2.1).fill()
            NSColor(Farside.Palette.ember).setFill()
            circle(center, radius: 1.2).fill()
        case .attention:
            body.setStroke()
            let ring = circle(center, radius: 1.3)
            ring.lineWidth = 0.8
            ring.stroke()
        case .idle, .paused:
            body.setFill()
            circle(center, radius: 1).fill()
        }
    }

    private static func circle(_ center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
