import SwiftUI
import Combine
import CoreGraphics

/// Luminance layers a halftone scene paints into, in points of `size`, origin top-left.
/// Paint with white: brightness becomes dot size in `bone`, contact glow in `ember`.
struct HalftoneLayers {
    let bone: CGContext
    let ember: CGContext
    let size: CGSize

    func glow(at point: CGPoint, radius: CGFloat, intensity: CGFloat) {
        FarsideArt.radial(ember, at: point, radius: radius, from: min(1, max(0, intensity)), to: 0)
    }
}

/// An expanding ring of brighter, ember-tinted dots, dated so it animates on the field's clock.
struct HalftoneRipple: Equatable {
    var center: CGPoint
    var date: Date
    var strength: Double = 1.2
    var speed: Double = 700
    var width: Double = 48
    var life: Double = 1.6
}

struct HalftoneStyle {
    /// Grid pitch in points.
    var cell: CGFloat = 6
    /// Largest dot radius as a fraction of half a cell.
    var dotScale: CGFloat = 1.1
    /// Share of empty cells that carry a faint twinkle.
    var dust: Double = 0.05
    var bone: Color = Farside.Palette.bone
    var ember: Color = Farside.Palette.ember
    var emberMid = Color(red: 0.97, green: 0.65, blue: 0.5)
}

/// Halftone art for heroes, illustrations and errors. Never for the streamed Mac picture,
/// text or controls. Animates at up to 30 fps only while visible and active; Reduce Motion
/// and Low Power Mode get a still frame.
struct FarsideHalftone: View {
    var style = HalftoneStyle()
    var animated = true
    /// Pass false while something covers the art (a sheet, another screen).
    var active = true
    var stillTime: TimeInterval = 2
    var ripples: [HalftoneRipple] = []
    let scene: (HalftoneLayers, TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var scrolledIntoView = true
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var origin = Date()

    private var running: Bool {
        animated && active && onScreen && scrolledIntoView && !reduceMotion && !lowPower && scenePhase != .background
    }

    var body: some View {
        let running = running
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { timeline in
            let now = running ? timeline.date : origin
            let time = running ? now.timeIntervalSince(origin) : stillTime
            Canvas { context, size in
                HalftoneRenderer.draw(in: &context, size: size, time: time, now: now,
                                      style: style, ripples: running ? ripples : [], scene: scene)
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onScrollVisibilityChange(threshold: 0.01) { scrolledIntoView = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityHidden(true)
    }
}

enum HalftoneRenderer {
    static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, now: Date,
                     style: HalftoneStyle, ripples: [HalftoneRipple],
                     scene: (HalftoneLayers, TimeInterval) -> Void) {
        let cell = max(2, style.cell)
        let columns = Int((size.width / cell).rounded(.up))
        let rows = Int((size.height / cell).rounded(.up))
        guard columns > 0, rows > 0, columns * rows <= 250_000,
              let bone = grayContext(columns, rows, size),
              let ember = grayContext(columns, rows, size) else { return }
        scene(HalftoneLayers(bone: bone, ember: ember, size: size), time)
        guard let boneData = bone.data?.assumingMemoryBound(to: UInt8.self),
              let emberData = ember.data?.assumingMemoryBound(to: UInt8.self) else { return }

        let live = ripples.compactMap { ripple -> (HalftoneRipple, Double)? in
            let age = now.timeIntervalSince(ripple.date)
            return age >= 0 && age < ripple.life ? (ripple, age) : nil
        }
        let maxRadius = cell * 0.5 * style.dotScale
        var bonePath = Path(), midPath = Path(), emberPath = Path()
        for y in 0..<rows {
            for x in 0..<columns {
                let index = y * columns + x
                var light = Double(boneData[y * bone.bytesPerRow + x]) / 255
                var glow = Double(emberData[y * ember.bytesPerRow + x]) / 255
                let cx = (CGFloat(x) + 0.5) * cell, cy = (CGFloat(y) + 0.5) * cell
                if light < 0.03 && style.dust > 0 {
                    let seed = hash(x, y)
                    light = seed < style.dust ? (0.4 + 0.6 * seed / style.dust) * 0.09 * (0.55 + 0.45 * sin(time * 1.7 + Double(index) * 0.7)) : 0
                }
                var offset = CGSize.zero
                for (ripple, age) in live {
                    let dx = Double(cx - ripple.center.x), dy = Double(cy - ripple.center.y)
                    let distance = max(0.001, (dx * dx + dy * dy).squareRoot())
                    let band = (distance - age * ripple.speed) / ripple.width
                    let bump = exp(-band * band) * ripple.strength * (1 - age / ripple.life)
                    guard bump > 0.02 else { continue }
                    light += bump * (light > 0.05 ? 0.4 : 0.26)
                    glow += bump * 0.9
                    offset.width += CGFloat(dx / distance * bump * 4)
                    offset.height += CGFloat(dy / distance * bump * 4)
                }
                var level = light
                if glow > 0.05 { level = max(level, glow * 0.62) }
                let radius = maxRadius * CGFloat(min(1, level).squareRoot())
                guard radius >= 0.38 else { continue }
                let rect = CGRect(x: cx + offset.width - radius, y: cy + offset.height - radius,
                                  width: radius * 2, height: radius * 2)
                if glow > 0.5 { emberPath.addEllipse(in: rect) }
                else if glow > 0.18 { midPath.addEllipse(in: rect) }
                else { bonePath.addEllipse(in: rect) }
            }
        }
        context.fill(bonePath, with: .color(style.bone))
        context.fill(midPath, with: .color(style.emberMid))
        context.fill(emberPath, with: .color(style.ember))
    }

    /// One byte per cell, drawn in points with a top-left origin.
    private static func grayContext(_ columns: Int, _ rows: Int, _ size: CGSize) -> CGContext? {
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: columns, height: rows))
        context.translateBy(x: 0, y: CGFloat(rows))
        context.scaleBy(x: CGFloat(columns) / size.width, y: -CGFloat(rows) / size.height)
        return context
    }

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h % 10_000) / 10_000
    }
}

/// A dot-screen dim for UI texture, such as dimming the desktop behind the dock sheet.
/// It darkens through a fixed screen of dots; it never alters the picture underneath.
struct FarsideDotScreen: View {
    var wash: ClosedRange<Double> = 0.2...0.72
    private let tile: Image?

    init(pitch: CGFloat = 5, dotRadius: CGFloat = 1.6, dotOpacity: Double = 0.92,
         wash: ClosedRange<Double> = 0.3...0.78) {
        self.wash = wash
        tile = Self.tile(pitch: pitch, radius: dotRadius, opacity: dotOpacity)
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Farside.Palette.void.opacity(wash.lowerBound),
                                  Farside.Palette.void.opacity(wash.upperBound)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if let tile { context.fill(Path(rect), with: .tiledImage(tile)) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let tileScale: CGFloat = 3

    private static func tile(pitch: CGFloat, radius: CGFloat, opacity: Double) -> Image? {
        let pixels = max(2, Int((pitch * tileScale).rounded()))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let center = CGFloat(pixels) / 2, r = radius * tileScale
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: opacity)
        context.fillEllipse(in: CGRect(x: center - r, y: center - r, width: r * 2, height: r * 2))
        guard let image = context.makeImage() else { return nil }
        return Image(decorative: image, scale: tileScale)
    }
}

/// Reusable Reach drawings for halftone scenes: the reaching hand, the Mac pointer and glows.
/// All geometry is in points of the scene; the hand points along +x with its fingertip at the origin.
enum FarsideArt {
    /// A finger reaching for a pointer across `gap` points, with an ember glow of `contact` strength.
    static func reach(gap: CGFloat, contact: CGFloat, float: CGFloat = 1, handScale: CGFloat = 1,
                      handAngle: CGFloat = -0.12) -> (HalftoneLayers, TimeInterval) -> Void {
        { layers, time in
            let w = layers.size.width, h = layers.size.height
            let unit = min(w, h * 1.95) / 390
            let meet = CGPoint(x: w * 0.52, y: h * 0.42)
            let drift = sin(time * 0.7) * 3 * float
            radial(layers.bone, at: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.5, from: 0.07, to: 0)
            pointer(layers.bone, tip: CGPoint(x: meet.x + 4 * unit, y: meet.y - 6 * unit + drift * 0.4),
                    scale: 0.28 * unit, angle: -0.05)
            hand(layers.bone, tip: CGPoint(x: meet.x - gap * unit * cos(handAngle),
                                           y: meet.y + drift - gap * unit * sin(handAngle)),
                 scale: 0.34 * unit * handScale, angle: handAngle)
            if contact > 0 {
                layers.glow(at: CGPoint(x: meet.x, y: meet.y + drift * 0.5), radius: (18 + 18 * contact) * unit,
                            intensity: 0.35 + 0.65 * contact)
            }
        }
    }

    /// The macOS arrow drawn as a bright outline with a dark body, tip at `tip`.
    static func pointer(_ context: CGContext, tip: CGPoint, scale: CGFloat, angle: CGFloat, outline: CGFloat = 1) {
        let points: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 250), .init(x: 60, y: 196), .init(x: 98, y: 284),
                                 .init(x: 134, y: 268), .init(x: 96, y: 180), .init(x: 176, y: 180)]
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.rotate(by: angle)
        context.scaleBy(x: scale, y: scale)
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(gray: 0.13, alpha: 1)
        context.fillPath()
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(13)
        context.setStrokeColor(gray: outline, alpha: 1)
        context.strokePath()
        context.restoreGState()
    }

    /// A pointing hand: index finger along +x, tip at `tip`, curled fingers and thumb, fading up the arm.
    static func hand(_ context: CGContext, tip: CGPoint, scale: CGFloat, angle: CGFloat) {
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.rotate(by: angle)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func stroke(_ points: [CGPoint], _ width: CGFloat, _ gray: CGFloat, outlined: Bool = false) {
            let path = CGMutablePath()
            path.addLines(between: points)
            if outlined {
                context.addPath(path)
                context.setStrokeColor(gray: 0.04, alpha: 1)
                context.setLineWidth(width + 8)
                context.strokePath()
            }
            context.addPath(path)
            context.setStrokeColor(gray: gray, alpha: 1)
            context.setLineWidth(width)
            context.strokePath()
        }
        stroke([.init(x: -440, y: 142), .init(x: -1000, y: 360)], 150, 0.2)
        stroke([.init(x: -240, y: 66), .init(x: -470, y: 150)], 106, 0.62)
        stroke([.init(x: -414, y: 210), .init(x: -466, y: 74)], 5, 0.5)
        context.saveGState()
        context.translateBy(x: -206, y: 64)
        context.rotate(by: -0.14)
        context.setFillColor(gray: 0.78, alpha: 1)
        context.fillEllipse(in: CGRect(x: -66, y: -55, width: 132, height: 110))
        context.restoreGState()
        stroke([.init(x: -188, y: 86), .init(x: -150, y: 98), .init(x: -136, y: 113), .init(x: -150, y: 125)], 28, 0.6, outlined: true)
        stroke([.init(x: -182, y: 60), .init(x: -134, y: 70), .init(x: -116, y: 90), .init(x: -132, y: 106)], 33, 0.66, outlined: true)
        stroke([.init(x: -176, y: 34), .init(x: -120, y: 42), .init(x: -98, y: 64), .init(x: -114, y: 82)], 36, 0.7, outlined: true)
        stroke([.init(x: -176, y: 8), .init(x: -94, y: 4), .init(x: -17, y: 0)], 34, 1, outlined: true)
        context.setStrokeColor(gray: 0.16, alpha: 1)
        context.setLineWidth(2.4)
        context.addArc(center: CGPoint(x: -94, y: 4), radius: 10, startAngle: -1.2, endAngle: 1.2, clockwise: false)
        context.strokePath()
        context.addArc(center: CGPoint(x: -46, y: 2), radius: 8, startAngle: -1.1, endAngle: 1.1, clockwise: false)
        context.strokePath()
        stroke([.init(x: -250, y: 74), .init(x: -202, y: 66), .init(x: -156, y: 54), .init(x: -128, y: 52)], 30, 0.86, outlined: true)

        // Fade toward the wrist so the fingertip reads first.
        let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                              colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.82, alpha: 1),
                                       CGColor(gray: 0.46, alpha: 1), CGColor(gray: 0.18, alpha: 1)] as CFArray,
                              locations: [0, 0.28, 0.6, 1])
        if let fade {
            context.setBlendMode(.multiply)
            context.clip(to: CGRect(x: -1100, y: -200, width: 1120, height: 700))
            context.drawLinearGradient(fade, start: .zero, end: CGPoint(x: -640, y: 230),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    static func radial(_ context: CGContext, at point: CGPoint, radius: CGFloat, from inner: CGFloat, to outer: CGFloat) {
        guard radius > 0, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                                     colors: [CGColor(gray: 1, alpha: inner),
                                                              CGColor(gray: 1, alpha: outer)] as CFArray,
                                                     locations: [0, 1]) else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point,
                                   endRadius: radius, options: [])
        context.restoreGState()
    }
}
