import SwiftUI
import CoreGraphics

/// The popover strip's mood. Ember appears only for `.live`.
enum HostHalftoneMood: Hashable {
    case live, calm, paused, attention
}

enum HostHalftoneScene: Hashable {
    /// A signal line across the popover's top strip; it peaks in ember while a phone is connected,
    /// lies flat while paused and breaks when sharing needs attention.
    case popoverStrip(HostHalftoneMood)
    /// A fingertip reaching for the pointer. `reach` 0…3 closes the gap as setup advances;
    /// `contact` adds the ember dot where they meet and is used only while a phone is connected.
    case setupRail(reach: Int, contact: Bool)
}

/// Host-local stand-in for the shared halftone renderer the phone work is adding: a still,
/// ordered-dither dot field, drawn once per scene and size and cached. A still frame already
/// meets the Reduce Motion and low-power rules. Text never sits on it without a solid plate.
struct HostHalftoneArt: View {
    let scene: HostHalftoneScene
    var cell: CGFloat = 2

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            if let image = HostHalftoneRenderer.image(scene: scene, size: proxy.size, cell: cell, scale: displayScale) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityHidden(true)
    }
}

enum HostHalftoneRenderer {
    private struct Key: Hashable {
        let scene: HostHalftoneScene
        let width: Int
        let height: Int
        let cell: Int
        let scale: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CGImage] = [:]

    static func image(scene: HostHalftoneScene, size: CGSize, cell: CGFloat, scale: CGFloat) -> CGImage? {
        guard size.width >= 1, size.height >= 1, cell >= 1, scale > 0 else { return nil }
        let key = Key(scene: scene, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                      cell: Int((cell * 100).rounded()), scale: Int((scale * 100).rounded()))
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let pointSize = CGSize(width: key.width, height: key.height)
        guard let image = HostHalftoneField(scene: scene, size: pointSize, cell: cell)
            .render(size: pointSize, scale: scale) else { return nil }
        lock.withLock {
            if cache.count >= 24 { cache.removeAll() }
            cache[key] = image
        }
        return image
    }
}

/// Bone luminance and ember intensity sampled one pixel per dot cell, then ordered-dithered
/// with an 8 × 8 Bayer matrix, as in the Reach concept.
struct HostHalftoneField {
    enum Ink: Equatable { case none, bone, ember }

    let columns: Int
    let rows: Int
    let cell: CGFloat
    private let luminance: [UInt8]
    private let emberLevels: [UInt8]

    private static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21
    ]

    init(scene: HostHalftoneScene, size: CGSize, cell: CGFloat) {
        let columns = max(1, Int((size.width / cell).rounded(.up)))
        let rows = max(1, Int((size.height / cell).rounded(.up)))
        self.columns = columns
        self.rows = rows
        self.cell = cell
        luminance = Self.sample(columns: columns, rows: rows, cell: cell) { context in
            switch scene {
            case .popoverStrip(let mood): HostHalftoneSketch.strip(context, size: size, mood: mood)
            case .setupRail(let reach, let contact): HostHalftoneSketch.rail(context, size: size, reach: reach, contact: contact)
            }
        }
        emberLevels = Self.sample(columns: columns, rows: rows, cell: cell) { context in
            switch scene {
            case .popoverStrip(let mood): HostHalftoneSketch.stripEmber(context, size: size, mood: mood)
            case .setupRail(let reach, let contact): HostHalftoneSketch.railEmber(context, size: size, reach: reach, contact: contact)
            }
        }
    }

    func ink(column: Int, row: Int) -> Ink {
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return .none }
        let index = row * columns + column
        let threshold = (Int(Self.bayer[(row % 8) * 8 + column % 8]) * 4 + 2)
        if Int(emberLevels[index]) > threshold { return .ember }
        if Int(luminance[index]) > threshold { return .bone }
        return .none
    }

    /// Dots at their cell centers on a transparent ground, at the display's scale.
    func render(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let radius = cell * 0.4
        let bone = CGMutablePath()
        let ember = CGMutablePath()
        for row in 0..<rows {
            for column in 0..<columns {
                let ink = ink(column: column, row: row)
                guard ink != .none else { continue }
                let rect = CGRect(x: (CGFloat(column) + 0.5) * cell - radius, y: (CGFloat(row) + 0.5) * cell - radius,
                                  width: radius * 2, height: radius * 2)
                if ink == .ember { ember.addEllipse(in: rect) } else { bone.addEllipse(in: rect) }
            }
        }
        context.addPath(bone)
        context.setFillColor(CGColor(srgbRed: 237 / 255, green: 232 / 255, blue: 223 / 255, alpha: 1))
        context.fillPath()
        context.addPath(ember)
        context.setFillColor(CGColor(srgbRed: 1, green: 91 / 255, blue: 31 / 255, alpha: 1))
        context.fillPath()
        return context.makeImage()
    }

    private static func sample(columns: Int, rows: Int, cell: CGFloat, draw: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(rows))
            context.scaleBy(x: 1 / cell, y: -1 / cell)
            draw(context)
        }
        return pixels
    }
}

/// The scenes, drawn in points with y pointing down: gray is bone luminance in one pass and ember
/// intensity in the other. Shapes follow the Reach concept's hand and pointer.
enum HostHalftoneSketch {
    static func strip(_ context: CGContext, size: CGSize, mood: HostHalftoneMood) {
        let width = size.width, height = size.height
        let strength: CGFloat = switch mood {
        case .paused: 0.26
        case .attention: 0.4
        case .live, .calm: 0.5
        }
        radial(context, center: CGPoint(x: width * 0.92, y: height * 0.02), radius: width * 0.6, from: strength)

        let line = CGMutablePath()
        var x: CGFloat = 0
        while x <= width + 2 {
            let point = CGPoint(x: x, y: signalY(x, size: size, mood: mood))
            if x == 0 { line.move(to: point) } else { line.addLine(to: point) }
            x += 2
        }
        context.saveGState()
        if mood == .attention {
            // Signal lost: a clean break where the line is easiest to read.
            context.addRect(CGRect(origin: .zero, size: size))
            context.addRect(CGRect(x: width * 0.3, y: 0, width: width * 0.16, height: height))
            context.clip(using: .evenOdd)
        }
        context.addPath(line)
        context.setLineWidth(1.6)
        context.setStrokeColor(gray: mood == .paused ? 0.5 : 0.8, alpha: 1)
        context.strokePath()
        context.restoreGState()

        // The caption's plate sits bottom-left; keep that corner free of dots.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height * 0.6, width: width * 0.76, height: height * 0.4))
    }

    static func stripEmber(_ context: CGContext, size: CGSize, mood: HostHalftoneMood) {
        guard mood == .live else { return }
        let peakX = size.width * 0.66
        glow(context, center: CGPoint(x: peakX, y: signalY(peakX, size: size, mood: mood)), radius: 20, intensity: 0.95)
    }

    private static func signalY(_ x: CGFloat, size: CGSize, mood: HostHalftoneMood) -> CGFloat {
        let base = size.height * 0.42
        guard mood != .paused else { return base }
        let peakX = size.width * 0.66
        return base + sin(x * 0.05) * 11 * exp(-pow((x - peakX) / 70, 2)) + sin(x * 0.21) * 1.2
    }

    static func rail(_ context: CGContext, size: CGSize, reach: Int, contact: Bool) {
        radial(context, center: CGPoint(x: size.width * 0.5, y: size.height * 0.42), radius: size.width * 0.9, from: 0.16)
        let geometry = railGeometry(size: size, reach: reach, contact: contact)
        cursor(context, tip: geometry.cursorTip, scale: geometry.scale * 0.36, angle: -0.04)
        hand(context, tip: geometry.fingertip, scale: geometry.scale * 0.4, angle: -0.5)
    }

    static func railEmber(_ context: CGContext, size: CGSize, reach: Int, contact: Bool) {
        guard contact else { return }
        let geometry = railGeometry(size: size, reach: reach, contact: contact)
        let meeting = CGPoint(x: (geometry.cursorTip.x + geometry.fingertip.x) / 2,
                              y: (geometry.cursorTip.y + geometry.fingertip.y) / 2)
        glow(context, center: meeting, radius: 30 * geometry.scale, intensity: 0.8)
    }

    static func railGeometry(size: CGSize, reach: Int, contact: Bool)
        -> (cursorTip: CGPoint, fingertip: CGPoint, scale: CGFloat) {
        let scale = size.width / 280
        let cursorTip = CGPoint(x: size.width * 0.58, y: size.height * 0.28)
        let far = CGPoint(x: size.width * 0.3, y: size.height * 0.46)
        let gap: CGFloat = (contact ? 3 : 10) * scale
        let near = CGPoint(x: cursorTip.x - gap, y: cursorTip.y + gap * 0.9)
        let progress = CGFloat(min(3, max(0, reach))) / 3
        let eased = 1 - (1 - progress) * (1 - progress)
        let fingertip = CGPoint(x: far.x + (near.x - far.x) * eased, y: far.y + (near.y - far.y) * eased)
        return (cursorTip, fingertip, scale)
    }

    // MARK: Shapes

    private static let pointerOutline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 250), CGPoint(x: 60, y: 196), CGPoint(x: 98, y: 284),
        CGPoint(x: 134, y: 268), CGPoint(x: 96, y: 180), CGPoint(x: 176, y: 180)
    ]

    static func cursor(_ context: CGContext, tip: CGPoint, scale: CGFloat, angle: CGFloat) {
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.rotate(by: angle)
        context.scaleBy(x: scale, y: scale)
        let outline = CGMutablePath()
        outline.addLines(between: pointerOutline)
        outline.closeSubpath()
        context.addPath(outline)
        context.setFillColor(gray: 0.13, alpha: 1)
        context.fillPath()
        context.addPath(outline)
        context.setLineWidth(13)
        context.setLineJoin(.round)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.strokePath()
        context.restoreGState()
    }

    /// An index finger pointing along +x, the hand behind it to the left and below.
    static func hand(_ context: CGContext, tip: CGPoint, scale: CGFloat, angle: CGFloat) {
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.rotate(by: angle)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let skin = Shade(stops: [(0, 1), (0.28, 0.82), (0.6, 0.46), (1, 0.18)], end: CGPoint(x: -640, y: 230))
        let curled = Shade(stops: [(0, 0.78), (0.35, 0.6), (1, 0.16)], end: CGPoint(x: -560, y: 200))

        stroke(context, [(-440, 142), (-1000, 360)], width: 150, gray: 0.2)
        stroke(context, [(-240, 66), (-470, 150)], width: 106, shade: skin)
        stroke(context, [(-414, 210), (-466, 74)], width: 5, gray: 0.62)

        var palm = CGAffineTransform(translationX: -206, y: 64).rotated(by: -0.14)
        let palmPath = CGPath(ellipseIn: CGRect(x: -66, y: -55, width: 132, height: 110), transform: &palm)
        context.saveGState()
        context.addPath(palmPath)
        context.clip()
        skin.fill(context)
        context.restoreGState()

        stroke(context, [(-188, 86), (-150, 98), (-136, 113), (-150, 125)], width: 28, shade: curled, outlined: true)
        stroke(context, [(-182, 60), (-134, 70), (-116, 90), (-132, 106)], width: 33, shade: curled, outlined: true)
        stroke(context, [(-176, 34), (-120, 42), (-98, 64), (-114, 82)], width: 36, shade: curled, outlined: true)
        stroke(context, [(-176, 8), (-94, 4), (-17, 0)], width: 34, shade: skin, outlined: true)

        context.setStrokeColor(gray: 40 / 255, alpha: 1)
        context.setLineWidth(2.4)
        context.addArc(center: CGPoint(x: -94, y: 4), radius: 10, startAngle: -1.2, endAngle: 1.2, clockwise: false)
        context.strokePath()
        context.addArc(center: CGPoint(x: -46, y: 2), radius: 8, startAngle: -1.1, endAngle: 1.1, clockwise: false)
        context.strokePath()

        stroke(context, [(-250, 74), (-202, 66), (-156, 54), (-128, 52)], width: 30, shade: skin, outlined: true)
        context.restoreGState()
    }

    private struct Shade {
        let stops: [(CGFloat, CGFloat)]
        let end: CGPoint

        func fill(_ context: CGContext) {
            let components: [CGFloat] = stops.flatMap { stop -> [CGFloat] in [stop.1, 1] }
            guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components,
                                            locations: stops.map(\.0), count: stops.count) else { return }
            context.drawLinearGradient(gradient, start: .zero, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    private static func path(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        return path
    }

    private static func stroke(_ context: CGContext, _ points: [(CGFloat, CGFloat)], width: CGFloat, gray: CGFloat) {
        context.addPath(path(points))
        context.setLineWidth(width)
        context.setStrokeColor(gray: gray, alpha: 1)
        context.strokePath()
    }

    private static func stroke(_ context: CGContext, _ points: [(CGFloat, CGFloat)], width: CGFloat, shade: Shade,
                               outlined: Bool = false) {
        if outlined { stroke(context, points, width: width + 8, gray: 10 / 255) }
        context.saveGState()
        context.addPath(path(points))
        context.setLineWidth(width)
        context.replacePathWithStrokedPath()
        context.clip()
        shade.fill(context)
        context.restoreGState()
    }

    private static func radial(_ context: CGContext, center: CGPoint, radius: CGFloat, from level: CGFloat) {
        guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [level, 1, 0, 1],
                                        locations: [0, 1], count: 2) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: radius, options: [])
    }

    private static func glow(_ context: CGContext, center: CGPoint, radius: CGFloat, intensity: CGFloat) {
        context.saveGState()
        context.setBlendMode(.plusLighter)
        radial(context, center: center, radius: radius, from: intensity)
        context.restoreGState()
    }
}
