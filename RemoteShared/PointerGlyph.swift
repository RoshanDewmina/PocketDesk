import Foundation
import CoreGraphics

/// Resolution-independent pointer artwork in Mac cursor points, hot spot at the origin.
/// Each layer is drawn as an outline pass then a body pass, so one layer (a badge) can sit
/// cleanly on top of another (the arrow).
struct PointerGlyph {
    enum Tone: Equatable {
        case dark, light, copy
        /// sRGB body colour; the outline uses the contrasting colour.
        var body: (r: CGFloat, g: CGFloat, b: CGFloat) {
            switch self {
            case .dark: (0.04, 0.04, 0.05)
            case .light: (1, 1, 1)
            case .copy: (0.16, 0.72, 0.30)
            }
        }
        var outline: (r: CGFloat, g: CGFloat, b: CGFloat) {
            self == .light ? Tone.dark.body : Tone.light.body
        }
    }

    enum Kind: Equatable {
        case fill
        case stroke(width: CGFloat)
    }

    struct Part {
        let path: CGPath
        let tone: Tone
        let kind: Kind
    }

    struct Layer {
        var parts: [Part]
        /// Interior lines drawn after the bodies, without an outline.
        var details: [Part] = []
    }

    let layers: [Layer]
    let outline: CGFloat

    /// Height of the arrow artwork including its outline. Pointer sizes are expressed as the
    /// on-screen height of the arrow; every other shape keeps its proportion to it.
    static let nominalHeight: CGFloat = PointerGlyph.glyph(for: .arrow).bounds.height

    /// Design-space bounds including outlines and stroke widths.
    var bounds: CGRect {
        var result = CGRect.null
        for layer in layers {
            for part in layer.parts {
                let inset: CGFloat
                switch part.kind {
                case .fill: inset = outline
                case .stroke(let width): inset = width / 2 + outline
                }
                result = result.union(part.path.boundingBoxOfPath.insetBy(dx: -inset, dy: -inset))
            }
        }
        return result
    }

    static func glyph(for shape: PointerShape) -> PointerGlyph {
        switch shape {
        case .arrow, .unknown, .disappearingItem:
            return PointerGlyph(layers: [arrowLayer], outline: 1.25)
        case .iBeam:
            return PointerGlyph(layers: [iBeamLayer(rotated: false)], outline: 1.1)
        case .iBeamVertical:
            return PointerGlyph(layers: [iBeamLayer(rotated: true)], outline: 1.1)
        case .crosshair:
            let lines = CGMutablePath()
            lines.addLines(between: [CGPoint(x: -8, y: 0), CGPoint(x: 8, y: 0)])
            lines.addLines(between: [CGPoint(x: 0, y: -8), CGPoint(x: 0, y: 8)])
            return PointerGlyph(layers: [Layer(parts: [Part(path: lines, tone: .dark, kind: .stroke(width: 1.3))])],
                                outline: 1.1)
        case .resizeLeftRight:
            return PointerGlyph(layers: [dividerResizeLayer(angle: 0)], outline: 1.2)
        case .resizeUpDown:
            return PointerGlyph(layers: [dividerResizeLayer(angle: .pi / 2)], outline: 1.2)
        case .resizeNorthWestSouthEast:
            return PointerGlyph(layers: [doubleArrowLayer(angle: .pi / 4)], outline: 1.2)
        case .resizeNorthEastSouthWest:
            return PointerGlyph(layers: [doubleArrowLayer(angle: -.pi / 4)], outline: 1.2)
        case .pointingHand:
            return PointerGlyph(layers: [pointingHandLayer], outline: 1.05)
        case .openHand:
            return PointerGlyph(layers: [openHandLayer], outline: 1.05)
        case .closedHand:
            return PointerGlyph(layers: [closedHandLayer], outline: 1.05)
        case .notAllowed:
            return PointerGlyph(layers: [arrowLayer, notAllowedBadge], outline: 1.25)
        case .contextualMenu:
            return PointerGlyph(layers: [arrowLayer, menuBadge], outline: 1.25)
        case .dragCopy:
            return PointerGlyph(layers: [arrowLayer, copyBadge], outline: 1.25)
        case .dragLink:
            return PointerGlyph(layers: [arrowLayer, linkBadge], outline: 1.25)
        case .zoomIn:
            return PointerGlyph(layers: [magnifierLayer(plus: true)], outline: 1.1)
        case .zoomOut:
            return PointerGlyph(layers: [magnifierLayer(plus: false)], outline: 1.1)
        }
    }

    // MARK: - Artwork

    private static var arrowLayer: Layer {
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.2), CGPoint(x: 3.75, y: 12.75),
            CGPoint(x: 6.05, y: 18.1), CGPoint(x: 8.35, y: 17.1), CGPoint(x: 6.1, y: 11.85),
            CGPoint(x: 11.25, y: 11.85)
        ])
        path.closeSubpath()
        return Layer(parts: [Part(path: path, tone: .dark, kind: .fill)])
    }

    private static func iBeamLayer(rotated: Bool) -> Layer {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -3.1, y: -8.9))
        path.addQuadCurve(to: CGPoint(x: 0, y: -8.0), control: CGPoint(x: -1.0, y: -8.9))
        path.addQuadCurve(to: CGPoint(x: 3.1, y: -8.9), control: CGPoint(x: 1.0, y: -8.9))
        path.move(to: CGPoint(x: -3.1, y: 8.9))
        path.addQuadCurve(to: CGPoint(x: 0, y: 8.0), control: CGPoint(x: -1.0, y: 8.9))
        path.addQuadCurve(to: CGPoint(x: 3.1, y: 8.9), control: CGPoint(x: 1.0, y: 8.9))
        path.move(to: CGPoint(x: 0, y: -8.0))
        path.addLine(to: CGPoint(x: 0, y: 8.0))
        path.move(to: CGPoint(x: -1.7, y: 3.4))
        path.addLine(to: CGPoint(x: 1.7, y: 3.4))
        let final = rotated ? transformed(path, CGAffineTransform(rotationAngle: .pi / 2)) : path
        return Layer(parts: [Part(path: final, tone: .dark, kind: .stroke(width: 1.35))])
    }

    private static func arrowHead(tip: CGFloat, base: CGFloat, halfWidth: CGFloat, shaft: CGFloat, inner: CGFloat) -> [CGPoint] {
        [
            CGPoint(x: tip, y: 0), CGPoint(x: base, y: -halfWidth), CGPoint(x: base, y: -shaft),
            CGPoint(x: inner, y: -shaft), CGPoint(x: inner, y: shaft), CGPoint(x: base, y: shaft),
            CGPoint(x: base, y: halfWidth)
        ]
    }

    private static func dividerResizeLayer(angle: CGFloat) -> Layer {
        let path = CGMutablePath()
        path.addLines(between: arrowHead(tip: -9.6, base: -5.2, halfWidth: 4.3, shaft: 1.3, inner: -2.1))
        path.closeSubpath()
        path.addLines(between: arrowHead(tip: 9.6, base: 5.2, halfWidth: 4.3, shaft: 1.3, inner: 2.1))
        path.closeSubpath()
        path.addRect(CGRect(x: -0.95, y: -7.3, width: 1.9, height: 14.6))
        return Layer(parts: [Part(path: transformed(path, CGAffineTransform(rotationAngle: angle)),
                                  tone: .dark, kind: .fill)])
    }

    private static func doubleArrowLayer(angle: CGFloat) -> Layer {
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: -9.6, y: 0), CGPoint(x: -5.1, y: -4.3), CGPoint(x: -5.1, y: -1.3),
            CGPoint(x: 5.1, y: -1.3), CGPoint(x: 5.1, y: -4.3), CGPoint(x: 9.6, y: 0),
            CGPoint(x: 5.1, y: 4.3), CGPoint(x: 5.1, y: 1.3), CGPoint(x: -5.1, y: 1.3),
            CGPoint(x: -5.1, y: 4.3)
        ])
        path.closeSubpath()
        return Layer(parts: [Part(path: transformed(path, CGAffineTransform(rotationAngle: angle)),
                                  tone: .dark, kind: .fill)])
    }

    private static func capsule(from start: CGPoint, to end: CGPoint, thickness: CGFloat) -> CGPath {
        let length = hypot(end.x - start.x, end.y - start.y)
        let rect = CGRect(x: -length / 2 - thickness / 2, y: -thickness / 2,
                          width: length + thickness, height: thickness)
        let base = CGPath(roundedRect: rect, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil)
        let transform = CGAffineTransform(translationX: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            .rotated(by: atan2(end.y - start.y, end.x - start.x))
        return transformed(base, transform)
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func lines(_ segments: [(CGPoint, CGPoint)]) -> CGPath {
        let path = CGMutablePath()
        for (start, end) in segments { path.addLines(between: [start, end]) }
        return path
    }

    private static var pointingHandLayer: Layer {
        let palm = CGMutablePath()
        palm.move(to: CGPoint(x: -1.75, y: 9.5))
        palm.addLine(to: CGPoint(x: -1.75, y: 14.6))
        palm.addQuadCurve(to: CGPoint(x: 1.9, y: 19.6), control: CGPoint(x: -1.4, y: 18.4))
        palm.addLine(to: CGPoint(x: 8.2, y: 19.6))
        palm.addQuadCurve(to: CGPoint(x: 11.0, y: 15.6), control: CGPoint(x: 10.8, y: 18.6))
        palm.addLine(to: CGPoint(x: 11.0, y: 10.8))
        palm.closeSubpath()
        let parts = [
            Part(path: capsule(from: CGPoint(x: -0.4, y: 15.2), to: CGPoint(x: -4.2, y: 11.3), thickness: 3.2),
                 tone: .light, kind: .fill),
            Part(path: roundedRect(CGRect(x: -1.75, y: 0, width: 3.5, height: 12), radius: 1.75),
                 tone: .light, kind: .fill),
            Part(path: roundedRect(CGRect(x: 1.75, y: 6.6, width: 3.2, height: 6.4), radius: 1.6),
                 tone: .light, kind: .fill),
            Part(path: roundedRect(CGRect(x: 4.95, y: 7.4, width: 3.1, height: 6.2), radius: 1.55),
                 tone: .light, kind: .fill),
            Part(path: roundedRect(CGRect(x: 8.05, y: 8.6, width: 2.95, height: 5.6), radius: 1.45),
                 tone: .light, kind: .fill),
            Part(path: palm, tone: .light, kind: .fill)
        ]
        let details = lines([
            (CGPoint(x: 1.75, y: 9.2), CGPoint(x: 1.75, y: 12.4)),
            (CGPoint(x: 4.95, y: 10.0), CGPoint(x: 4.95, y: 12.8)),
            (CGPoint(x: 8.05, y: 11.0), CGPoint(x: 8.05, y: 13.2))
        ])
        return Layer(parts: parts, details: [Part(path: details, tone: .dark, kind: .stroke(width: 0.85))])
    }

    private static var openHandLayer: Layer {
        let fingers: [(x: CGFloat, top: CGFloat, width: CGFloat)] = [
            (-5.6, -8.6, 2.9), (-2.6, -10.0, 3.0), (0.5, -9.4, 2.9), (3.5, -7.2, 2.7)
        ]
        var parts = [Part(path: capsule(from: CGPoint(x: -4.6, y: 4.2), to: CGPoint(x: -9.0, y: -0.6), thickness: 3.1),
                          tone: .light, kind: .fill)]
        for finger in fingers {
            parts.append(Part(path: roundedRect(CGRect(x: finger.x, y: finger.top, width: finger.width,
                                                       height: 3 - finger.top), radius: finger.width / 2),
                              tone: .light, kind: .fill))
        }
        parts.append(Part(path: roundedRect(CGRect(x: -5.6, y: -1.6, width: 11.8, height: 10.4), radius: 4.2),
                          tone: .light, kind: .fill))
        let details = lines([
            (CGPoint(x: -2.6, y: -2.6), CGPoint(x: -2.6, y: 0.8)),
            (CGPoint(x: 0.5, y: -2.6), CGPoint(x: 0.5, y: 0.8)),
            (CGPoint(x: 3.5, y: -2.2), CGPoint(x: 3.5, y: 0.8))
        ])
        return Layer(parts: parts, details: [Part(path: details, tone: .dark, kind: .stroke(width: 0.85))])
    }

    private static var closedHandLayer: Layer {
        var parts: [Part] = []
        for index in 0..<4 {
            let x = -5.6 + CGFloat(index) * 2.95
            parts.append(Part(path: roundedRect(CGRect(x: x, y: -4.4, width: 2.95, height: 6.2), radius: 1.45),
                              tone: .light, kind: .fill))
        }
        parts.append(Part(path: roundedRect(CGRect(x: -5.9, y: -1.6, width: 12.1, height: 9.4), radius: 4.0),
                          tone: .light, kind: .fill))
        parts.append(Part(path: capsule(from: CGPoint(x: -6.4, y: 2.2), to: CGPoint(x: -2.2, y: 4.2), thickness: 2.9),
                          tone: .light, kind: .fill))
        let details = lines([
            (CGPoint(x: -2.65, y: -2.4), CGPoint(x: -2.65, y: 0.4)),
            (CGPoint(x: 0.3, y: -2.4), CGPoint(x: 0.3, y: 0.4)),
            (CGPoint(x: 3.25, y: -2.4), CGPoint(x: 3.25, y: 0.4))
        ])
        return Layer(parts: parts, details: [Part(path: details, tone: .dark, kind: .stroke(width: 0.85))])
    }

    private static let badgeCenter = CGPoint(x: 13.6, y: 17.2)

    private static var notAllowedBadge: Layer {
        let c = badgeCenter
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
        ring.move(to: CGPoint(x: c.x - 2.45, y: c.y - 2.45))
        ring.addLine(to: CGPoint(x: c.x + 2.45, y: c.y + 2.45))
        let disc = CGPath(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7), transform: nil)
        return Layer(parts: [Part(path: disc, tone: .light, kind: .fill),
                             Part(path: ring, tone: .dark, kind: .stroke(width: 1.35))])
    }

    private static var menuBadge: Layer {
        let c = badgeCenter
        let card = roundedRect(CGRect(x: c.x - 3.6, y: c.y - 3.4, width: 7.2, height: 6.8), radius: 1.2)
        let rows = lines([-1.6, 0, 1.6].map { dy in
            (CGPoint(x: c.x - 2.1, y: c.y + dy), CGPoint(x: c.x + 2.1, y: c.y + dy))
        })
        return Layer(parts: [Part(path: card, tone: .light, kind: .fill)],
                     details: [Part(path: rows, tone: .dark, kind: .stroke(width: 0.8))])
    }

    private static var copyBadge: Layer {
        let c = badgeCenter
        let disc = CGPath(ellipseIn: CGRect(x: c.x - 3.8, y: c.y - 3.8, width: 7.6, height: 7.6), transform: nil)
        let plus = lines([
            (CGPoint(x: c.x - 2.1, y: c.y), CGPoint(x: c.x + 2.1, y: c.y)),
            (CGPoint(x: c.x, y: c.y - 2.1), CGPoint(x: c.x, y: c.y + 2.1))
        ])
        return Layer(parts: [Part(path: disc, tone: .copy, kind: .fill)],
                     details: [Part(path: plus, tone: .light, kind: .stroke(width: 1.3))])
    }

    private static var linkBadge: Layer {
        let c = badgeCenter
        let disc = CGPath(ellipseIn: CGRect(x: c.x - 3.6, y: c.y - 3.6, width: 7.2, height: 7.2), transform: nil)
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: c.x - 1.8, y: c.y + 1.8))
        arrow.addLine(to: CGPoint(x: c.x + 1.7, y: c.y - 1.7))
        arrow.move(to: CGPoint(x: c.x - 0.6, y: c.y - 1.8))
        arrow.addLine(to: CGPoint(x: c.x + 1.8, y: c.y - 1.8))
        arrow.addLine(to: CGPoint(x: c.x + 1.8, y: c.y + 0.6))
        return Layer(parts: [Part(path: disc, tone: .light, kind: .fill)],
                     details: [Part(path: arrow, tone: .dark, kind: .stroke(width: 1.0))])
    }

    private static func magnifierLayer(plus: Bool) -> Layer {
        let lens = CGPath(ellipseIn: CGRect(x: -5.2, y: -5.2, width: 10.4, height: 10.4), transform: nil)
        let rim = CGPath(ellipseIn: CGRect(x: -5.2, y: -5.2, width: 10.4, height: 10.4), transform: nil)
        let handle = lines([(CGPoint(x: 4.0, y: 4.0), CGPoint(x: 8.6, y: 8.6))])
        var marks = [(CGPoint(x: -2.4, y: 0), CGPoint(x: 2.4, y: 0))]
        if plus { marks.append((CGPoint(x: 0, y: -2.4), CGPoint(x: 0, y: 2.4))) }
        return Layer(parts: [Part(path: lens, tone: .light, kind: .fill),
                             Part(path: handle, tone: .dark, kind: .stroke(width: 2.6)),
                             Part(path: rim, tone: .dark, kind: .stroke(width: 1.3))],
                     details: [Part(path: lines(marks), tone: .dark, kind: .stroke(width: 1.2))])
    }

    private static func transformed(_ path: CGPath, _ transform: CGAffineTransform) -> CGPath {
        var transform = transform
        return path.copy(using: &transform) ?? path
    }
}

/// Draws a glyph into any CoreGraphics context whose user space is already positioned with the
/// hot spot at the origin and scaled to design units. Shared by the phone overlay and previews.
enum PointerGlyphRenderer {
    static func draw(_ glyph: PointerGlyph, in context: CGContext) {
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for layer in glyph.layers {
            for part in layer.parts {
                let outline = part.tone.outline
                context.setStrokeColor(red: outline.r, green: outline.g, blue: outline.b, alpha: 1)
                context.addPath(part.path)
                switch part.kind {
                case .fill:
                    context.setLineWidth(glyph.outline * 2)
                case .stroke(let width):
                    context.setLineWidth(width + glyph.outline * 2)
                }
                context.strokePath()
            }
            for part in layer.parts + layer.details {
                let body = part.tone.body
                context.addPath(part.path)
                switch part.kind {
                case .fill:
                    context.setFillColor(red: body.r, green: body.g, blue: body.b, alpha: 1)
                    context.fillPath()
                case .stroke(let width):
                    context.setStrokeColor(red: body.r, green: body.g, blue: body.b, alpha: 1)
                    context.setLineWidth(width)
                    context.strokePath()
                }
            }
        }
    }
}
