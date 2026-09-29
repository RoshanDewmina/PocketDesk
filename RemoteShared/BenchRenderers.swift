import Foundation
import CoreGraphics
import CoreText

/// Draws the bench marker strip into a flipped CoreGraphics context (top-left origin, y down):
/// a flipped NSView's context on the Mac, a UIKit context, or a test bitmap flipped by hand.
enum BenchMarkerRenderer {
    static func draw(_ marker: BenchMarker, layout: BenchMarker.Layout, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(false)
        for (row, blocks) in marker.rows.enumerated() {
            for (index, white) in blocks.enumerated() {
                context.setFillColor(gray: white ? 1 : 0, alpha: 1)
                context.fill(layout.rect(row: row, block: index))
            }
        }
        context.restoreGState()
    }
}

/// Draws the legibility chart with CoreText into a flipped context, in display points; the
/// caller's CTM supplies the backing scale. The Test Pad, the stub host and the tests share it so
/// the phone always scores the same rendering.
enum LegibilityChartRenderer {
    struct Colours {
        var background: CGColor
        var text: CGColor
    }

    static func colours(for colourway: LegibilityChart.Colourway) -> Colours {
        let space = CGColorSpaceCreateDeviceRGB()
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, 1]) ?? CGColor(gray: 0, alpha: 1)
        }
        switch colourway {
        case .blackOnWhite: return Colours(background: rgb(1, 1, 1), text: rgb(0, 0, 0))
        case .whiteOnDark: return Colours(background: rgb(0.12, 0.12, 0.13), text: rgb(1, 1, 1))
        case .blueOnWhite: return Colours(background: rgb(1, 1, 1), text: rgb(0, 0.35, 0.85))
        case .redOnWhite: return Colours(background: rgb(1, 1, 1), text: rgb(0.8, 0.1, 0.1))
        }
    }

    static func font(for face: LegibilityChart.Face, pointSize: Double) -> CTFont {
        switch face {
        case .system: return CTFontCreateUIFontForLanguage(.system, pointSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        case .mono: return CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
        }
    }

    static func draw(cells: [LegibilityChart.Cell], layout: LegibilityChart.Layout, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSmoothing(true)
        for cell in cells {
            let rect = layout.rect(for: cell)
            let colours = colours(for: cell.colourway)
            context.setFillColor(colours.background)
            context.fill(rect)
            let font = font(for: cell.face, pointSize: cell.pointSize)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colours.text
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: attributes))
            let capHeight = CTFontGetCapHeight(font)
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: rect.minX + LegibilityChart.textInsetPt, y: rect.midY + capHeight / 2)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
