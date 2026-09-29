import SwiftUI
import CoreGraphics

/// Phone illustrations for the halftone renderer. Brightness is dot size; `ember` is contact glow.
extension FarsideArt {
    typealias Scene = (HalftoneLayers, TimeInterval) -> Void

    /// An abstract, never-real Mac screen for the Home card: two windows, a menu bar, a glow.
    static let macThumbnail: Scene = { layers, _ in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        fill(c, CGRect(x: 0, y: 0, width: w, height: h), 0.06)
        fill(c, CGRect(x: w * 0.04, y: h * 0.12, width: w * 0.52, height: h * 0.66), 0.3)
        fill(c, CGRect(x: w * 0.44, y: h * 0.22, width: w * 0.52, height: h * 0.66), 0.62)
        fill(c, CGRect(x: w * 0.44, y: h * 0.22, width: w * 0.52, height: h * 0.09), 0.2)
        for row in 0..<5 {
            fill(c, CGRect(x: w * 0.08, y: h * (0.24 + CGFloat(row) * 0.09), width: w * (0.18 + CGFloat((row * 13) % 22) / 100), height: h * 0.03), 0.16)
            fill(c, CGRect(x: w * 0.5, y: h * (0.4 + CGFloat(row) * 0.08), width: w * (0.3 + CGFloat((row * 7) % 12) / 100), height: h * 0.025), 0.3)
        }
        fill(c, CGRect(x: 0, y: 0, width: w, height: h * 0.06), 0)
        fill(c, CGRect(x: w * 0.3, y: h * 0.9, width: w * 0.42, height: h * 0.05), 0.24)
    }

    /// The Mac went to sleep: a closed laptop, a moon and a trail of z's.
    static let nap: Scene = { layers, time in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        radial(c, at: CGPoint(x: w * 0.5, y: h * 0.72), radius: w * 0.5, from: 0.09, to: 0)
        // Crescent moon.
        c.setFillColor(gray: 0.8, alpha: 1)
        c.fillEllipse(in: CGRect(x: w * 0.78 - 26, y: h * 0.2 - 26, width: 52, height: 52))
        c.setFillColor(gray: 0, alpha: 1)
        c.fillEllipse(in: CGRect(x: w * 0.78 - 11 - 24, y: h * 0.2 - 6 - 24, width: 48, height: 48))
        // Closed laptop: base, lid, and a sliver of light at the hinge.
        let base = CGPoint(x: w * 0.5, y: h * 0.78)
        let lidPath = CGMutablePath()
        lidPath.addLines(between: [CGPoint(x: base.x - 142, y: base.y - 3), CGPoint(x: base.x + 132, y: base.y - 26),
                                   CGPoint(x: base.x + 134, y: base.y - 17), CGPoint(x: base.x - 140, y: base.y + 3)])
        lidPath.closeSubpath()
        let basePath = CGMutablePath()
        basePath.addLines(between: [CGPoint(x: base.x - 140, y: base.y), CGPoint(x: base.x + 140, y: base.y),
                                    CGPoint(x: base.x + 150, y: base.y + 14), CGPoint(x: base.x - 150, y: base.y + 14)])
        basePath.closeSubpath()
        c.addPath(basePath); c.setFillColor(gray: 0.55, alpha: 1); c.fillPath()
        c.setFillColor(gray: 0.18, alpha: 1); c.fill(CGRect(x: base.x - 150, y: base.y + 14, width: 300, height: 6))
        c.addPath(lidPath); c.setFillColor(gray: 0.85, alpha: 1); c.fillPath()
        layers.glow(at: CGPoint(x: base.x + 90, y: base.y - 8), radius: 46, intensity: 0.3)
        // Drifting z's, rising away from the lid.
        let drift = CGFloat(sin(time * 0.9)) * 3
        zee(c, at: CGPoint(x: w * 0.52, y: h * 0.5 + drift), size: 34)
        zee(c, at: CGPoint(x: w * 0.62, y: h * 0.32 - drift), size: 25)
        zee(c, at: CGPoint(x: w * 0.7, y: h * 0.17 + drift * 0.5), size: 17)
    }

    /// Nobody answered: the hand reaches, the pointer is far off and a dotted signal falls short.
    static let unreachable: Scene = { layers, time in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        radial(c, at: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.55, from: 0.08, to: 0)
        let drift = CGFloat(sin(time * 0.7)) * 3
        pointer(c, tip: CGPoint(x: w * 0.8, y: h * 0.3 + drift * 0.5), scale: 0.24 * w / 390, angle: -0.05, outline: 0.55)
        hand(c, tip: CGPoint(x: w * 0.36, y: h * 0.56 + drift), scale: 0.32 * w / 390, angle: -0.2)
        c.setFillColor(gray: 0.7, alpha: 1)
        for step in 0..<5 {
            let t = CGFloat(step) / 5
            let x = w * (0.42 + 0.3 * t), y = h * (0.52 - 0.18 * t) - sin(t * .pi) * 18
            let r = 5 * (1 - t) + 1
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    /// The Mac is locked, or someone else is using it.
    static let locked: Scene = { layers, _ in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        radial(c, at: CGPoint(x: w * 0.5, y: h * 0.55), radius: w * 0.45, from: 0.1, to: 0)
        let body = CGRect(x: w * 0.5 - 62, y: h * 0.46, width: 124, height: 96)
        c.setStrokeColor(gray: 0.8, alpha: 1)
        c.setLineWidth(18)
        c.addArc(center: CGPoint(x: w * 0.5, y: body.minY), radius: 40, startAngle: .pi, endAngle: 0, clockwise: false)
        c.strokePath()
        c.addPath(CGPath(roundedRect: body, cornerWidth: 18, cornerHeight: 18, transform: nil))
        c.setFillColor(gray: 0.92, alpha: 1)
        c.fillPath()
        c.setFillColor(gray: 0.1, alpha: 1)
        c.fillEllipse(in: CGRect(x: w * 0.5 - 11, y: body.midY - 16, width: 22, height: 22))
        c.fill(CGRect(x: w * 0.5 - 5, y: body.midY, width: 10, height: 26))
    }

    /// A pairing code that no longer works.
    static let staleCode: Scene = { layers, _ in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        radial(c, at: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.45, from: 0.12, to: 0)
        let cell: CGFloat = 12, origin = CGPoint(x: w * 0.5 - 54, y: h * 0.5 - 54)
        for y in 0..<9 {
            for x in 0..<9 {
                let finder = (x < 3 && y < 3) || (x > 5 && y < 3) || (x < 3 && y > 5)
                let on = finder || ((x * 7 + y * 13 + x * y) % 5) < 2
                if on { fill(c, CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell - 1, height: cell - 1), 0.85) }
            }
        }
        c.setStrokeColor(gray: 0.55, alpha: 1)
        c.setLineWidth(3)
        c.stroke(CGRect(x: origin.x - 16, y: origin.y - 16, width: 9 * cell + 32, height: 9 * cell + 32))
        layers.glow(at: CGPoint(x: origin.x + 9 * cell + 12, y: origin.y + 9 * cell + 12), radius: 24, intensity: 0.8)
    }

    /// Screen sharing or a permission is missing on the Mac.
    static let screenOff: Scene = { layers, _ in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        radial(c, at: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.5, from: 0.08, to: 0)
        let screen = CGRect(x: w * 0.5 - 110, y: h * 0.28, width: 220, height: 138)
        c.addPath(CGPath(roundedRect: screen, cornerWidth: 12, cornerHeight: 12, transform: nil))
        c.setStrokeColor(gray: 0.85, alpha: 1)
        c.setLineWidth(10)
        c.strokePath()
        fill(c, CGRect(x: w * 0.5 - 40, y: screen.maxY + 14, width: 80, height: 10), 0.6)
        c.setStrokeColor(gray: 0.95, alpha: 1)
        c.setLineWidth(12)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: screen.minX + 28, y: screen.maxY - 22))
        c.addLine(to: CGPoint(x: screen.maxX - 28, y: screen.minY + 22))
        c.strokePath()
    }

    /// Reaching the Mac from another network: a globe with an orbiting contact.
    static let anywhere: Scene = { layers, time in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        let center = CGPoint(x: w * 0.5, y: h * 0.5)
        FarsideArt.radial(c, at: center, radius: 96, from: 0.5, to: 0.18)
        c.setStrokeColor(gray: 0.9, alpha: 1)
        c.setLineWidth(6)
        c.strokeEllipse(in: CGRect(x: center.x - 92, y: center.y - 92, width: 184, height: 184))
        c.strokeEllipse(in: CGRect(x: center.x - 40, y: center.y - 92, width: 80, height: 184))
        c.move(to: CGPoint(x: center.x - 92, y: center.y)); c.addLine(to: CGPoint(x: center.x + 92, y: center.y))
        c.strokePath()
        let angle = time * 0.6
        layers.glow(at: CGPoint(x: center.x + cos(angle) * 128, y: center.y + sin(angle) * 44), radius: 22, intensity: 0.9)
    }

    /// Permission priming: a device glyph with the thing being asked for.
    static func priming(_ kind: PermissionKind) -> Scene {
        { layers, time in
            let w = layers.size.width, h = layers.size.height
            let c = layers.bone
            let center = CGPoint(x: w * 0.5, y: h * 0.54)
            radial(c, at: center, radius: w * 0.45, from: 0.1, to: 0)
            switch kind {
            case .camera:
                c.addPath(CGPath(roundedRect: CGRect(x: center.x - 96, y: center.y - 58, width: 192, height: 124),
                                 cornerWidth: 24, cornerHeight: 24, transform: nil))
                c.setFillColor(gray: 0.72, alpha: 1); c.fillPath()
                c.setFillColor(gray: 0.04, alpha: 1)
                c.fillEllipse(in: CGRect(x: center.x - 44, y: center.y - 40, width: 88, height: 88))
                c.setFillColor(gray: 0.95, alpha: 1)
                c.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 22, width: 52, height: 52))
                fill(c, CGRect(x: center.x - 40, y: center.y - 76, width: 80, height: 22), 0.72)
            case .localNetwork:
                c.setStrokeColor(gray: 0.9, alpha: 1)
                c.setLineCap(.round)
                for (index, radius) in [36.0, 72.0, 108.0].enumerated() {
                    c.setLineWidth(12)
                    c.setStrokeColor(gray: 0.95 - CGFloat(index) * 0.18, alpha: 1)
                    c.addArc(center: CGPoint(x: center.x, y: center.y + 40), radius: CGFloat(radius),
                             startAngle: -.pi * 0.78, endAngle: -.pi * 0.22, clockwise: false)
                    c.strokePath()
                }
                c.setFillColor(gray: 1, alpha: 1)
                c.fillEllipse(in: CGRect(x: center.x - 12, y: center.y + 28, width: 24, height: 24))
            case .microphone:
                c.addPath(CGPath(roundedRect: CGRect(x: center.x - 30, y: center.y - 84, width: 60, height: 112),
                                 cornerWidth: 30, cornerHeight: 30, transform: nil))
                c.setFillColor(gray: 0.9, alpha: 1); c.fillPath()
                c.setStrokeColor(gray: 0.7, alpha: 1)
                c.setLineWidth(10)
                c.addArc(center: CGPoint(x: center.x, y: center.y - 8), radius: 58, startAngle: 0, endAngle: .pi, clockwise: false)
                c.strokePath()
                c.move(to: CGPoint(x: center.x, y: center.y + 50)); c.addLine(to: CGPoint(x: center.x, y: center.y + 76))
                c.strokePath()
                for bar in 0..<5 {
                    let x = center.x + 110 + CGFloat(bar) * 16
                    let height = 18 + 30 * abs(sin(time * 2.2 + Double(bar)))
                    fill(c, CGRect(x: x, y: center.y - height / 2 - 8, width: 7, height: height), 0.7)
                }
            }
            layers.glow(at: CGPoint(x: center.x + 70, y: center.y - 70), radius: 20, intensity: 0.7)
        }
    }

    /// The screen was hidden while Farside was in the background.
    static let hidden: Scene = { layers, _ in
        let w = layers.size.width, h = layers.size.height
        let c = layers.bone
        radial(c, at: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.5, from: 0.1, to: 0)
        let center = CGPoint(x: w * 0.5, y: h * 0.52)
        c.setStrokeColor(gray: 0.88, alpha: 1)
        c.setLineWidth(12)
        c.setLineCap(.round)
        c.addArc(center: CGPoint(x: center.x, y: center.y - 70), radius: 120, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
        c.strokePath()
        for index in -2...2 {
            let x = center.x + CGFloat(index) * 38
            c.move(to: CGPoint(x: x, y: center.y + 46 - abs(CGFloat(index)) * 8))
            c.addLine(to: CGPoint(x: x + CGFloat(index) * 6, y: center.y + 66 - abs(CGFloat(index)) * 8))
            c.strokePath()
        }
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, _ gray: CGFloat) {
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(rect)
    }

    private static func zee(_ context: CGContext, at origin: CGPoint, size: CGFloat) {
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(max(4, size * 0.26))
        context.setLineCap(.square)
        context.setLineJoin(.miter)
        context.move(to: origin)
        context.addLine(to: CGPoint(x: origin.x + size, y: origin.y))
        context.addLine(to: CGPoint(x: origin.x, y: origin.y + size))
        context.addLine(to: CGPoint(x: origin.x + size, y: origin.y + size))
        context.strokePath()
    }
}

enum PermissionKind: String {
    case camera, localNetwork, microphone
}
