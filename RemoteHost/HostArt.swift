import SwiftUI
import AppKit
import CoreGraphics

/// The host's two pieces of halftone art, drawn by the shared `FarsideHalftone` renderer.
enum HostArtScene: Hashable {
    /// A signal line across the popover's top strip; it peaks in ember while a phone is connected,
    /// lies flat while paused and breaks when sharing needs attention.
    case popoverStrip(HostPopoverPresentation.Mood)
    /// A fingertip reaching for the pointer. `reach` 0…3 closes the gap as setup advances;
    /// `contact` adds the ember dot where they meet and is used only while a phone is connected.
    case setupRail(reach: Int, contact: Bool)

    /// The 2 pt pitch of the still art this replaces, so the look carries over.
    var style: HalftoneStyle { HalftoneStyle(cell: 2, dotScale: HostArtScenes.dotScale, dust: 0) }

    /// Only a live or waiting strip moves. The rest is one still frame, which costs nothing while it is shown:
    /// the rail is too many dots to redraw 30 times a second.
    var animated: Bool {
        switch self {
        case .popoverStrip(let mood): mood == .live || mood == .calm
        case .setupRail: false
        }
    }

    var draw: (HalftoneLayers, TimeInterval) -> Void {
        switch self {
        case .popoverStrip(let mood): { HostArtScenes.strip($0, time: $1, mood: mood) }
        case .setupRail(let reach, let contact): { layers, _ in HostArtScenes.rail(layers, reach: reach, contact: contact) }
        }
    }
}

/// Halftone art for the host's windows. Animated art draws at most 30 frames a second (in the renderer) and
/// only while its window can be seen; Reduce Motion, Low Power Mode and a hidden window get the still frame,
/// drawn at time 0. Text never sits on it without a solid plate.
struct HostArt: View {
    private let style: HalftoneStyle
    private let animated: Bool
    private let draw: (HalftoneLayers, TimeInterval) -> Void
    private let ripples: [HalftoneRipple]
    @State private var windowVisible = false

    init(_ scene: HostArtScene, ripples: [HalftoneRipple] = []) {
        self.init(style: scene.style, animated: scene.animated, ripples: ripples, draw: scene.draw)
    }

    init(style: HalftoneStyle, animated: Bool = true, ripples: [HalftoneRipple] = [],
         draw: @escaping (HalftoneLayers, TimeInterval) -> Void) {
        self.style = style
        self.animated = animated
        self.ripples = ripples
        self.draw = draw
    }

    var body: some View {
        FarsideHalftone(style: style, animated: animated, active: windowVisible, stillTime: 0, ripples: ripples, scene: draw)
            .background {
                if animated { HostWindowVisibility(isVisible: $windowVisible) }
            }
    }
}

/// Reports whether any part of the enclosing window is on screen. A menu-bar popover is ordered out
/// rather than removed, so `onDisappear` never says it went away; the window's occlusion state does.
struct HostWindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        view.report()
    }

    static func isVisible(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    final class Watcher: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [any NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.report()
                    })
                }
            }
            report()
        }

        func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange(HostWindowVisibility.isVisible(window))
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// The scenes, drawn in points with y pointing down into the renderer's luminance layers: brightness
/// becomes dot size in bone, `ember` is contact glow. At `time` 0 they are the still frame.
enum HostArtScenes {
    static let dotScale: CGFloat = 1.1

    /// The popover caption's plate sits bottom-left; keep that corner free of dots.
    static func captionPlate(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: size.height * 0.6, width: size.width * 0.76, height: size.height * 0.4)
    }

    static func strip(_ layers: HalftoneLayers, time: TimeInterval, mood: HostPopoverPresentation.Mood) {
        let size = layers.size
        let context = layers.bone
        let cell = size.width / CGFloat(context.width)
        let phase = mood == .live || mood == .calm ? CGFloat(time) : 0

        let strength: CGFloat = switch mood {
        case .paused: 0.26
        case .attention: 0.4
        case .live, .calm: 0.5
        }
        stippleGlow(layers, center: CGPoint(x: size.width * 0.92, y: size.height * 0.02),
                    radius: size.width * 0.6, strength: strength)

        let line = CGMutablePath()
        var x: CGFloat = 0
        while x <= size.width + 2 {
            let point = CGPoint(x: x, y: signalY(x, size: size, mood: mood, phase: phase))
            if x == 0 { line.move(to: point) } else { line.addLine(to: point) }
            x += 2
        }
        context.saveGState()
        if mood == .attention {
            context.addRect(CGRect(origin: .zero, size: size))
            context.addRect(CGRect(x: size.width * 0.3, y: 0, width: size.width * 0.16, height: size.height))
            context.clip(using: .evenOdd)
        }
        context.addPath(line)
        context.setLineWidth(max(1.4, cell * 0.55))
        context.setLineJoin(.round)
        context.setStrokeColor(gray: mood == .paused ? 0.5 : 0.8, alpha: 1)
        context.strokePath()
        context.restoreGState()

        let plate = captionPlate(in: size)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: (plate.minY / cell).rounded(.down) * cell,
                            width: (plate.maxX / cell).rounded(.up) * cell, height: size.height))

        if mood == .live {
            let peakX = size.width * 0.66
            let breath = 1 - 0.06 * (1 - cos(phase * 2))
            layers.glow(at: CGPoint(x: peakX, y: signalY(peakX, size: size, mood: mood, phase: 0)),
                        radius: 20, intensity: 0.95 * breath)
        }
    }

    /// The signal: flat when paused, otherwise a swell around the peak with a fine ripple that drifts with `phase`.
    static func signalY(_ x: CGFloat, size: CGSize, mood: HostPopoverPresentation.Mood, phase: CGFloat) -> CGFloat {
        let base = size.height * 0.42
        guard mood != .paused else { return base }
        let peakX = size.width * 0.66
        return base + sin(x * 0.05) * 11 * exp(-pow((x - peakX) / 70, 2)) + sin(x * 0.21 - phase * 1.6) * 1.2
    }

    static func rail(_ layers: HalftoneLayers, reach: Int, contact: Bool) {
        let size = layers.size
        let geometry = railGeometry(size: size, reach: reach, contact: contact)
        FarsideArt.pointer(layers.bone, tip: geometry.cursorTip, scale: geometry.scale * 0.36, angle: -0.04)
        FarsideArt.hand(layers.bone, tip: geometry.fingertip, scale: geometry.scale * 0.4, angle: -0.5)
        // The hand's fade toward the wrist multiplies everything drawn before it, so the glow goes last.
        stippleGlow(layers, center: CGPoint(x: size.width * 0.5, y: size.height * 0.42),
                    radius: size.width * 0.9, strength: 0.16)
        if contact {
            layers.glow(at: CGPoint(x: (geometry.cursorTip.x + geometry.fingertip.x) / 2,
                                    y: (geometry.cursorTip.y + geometry.fingertip.y) / 2),
                        radius: 30 * geometry.scale, intensity: 0.8)
        }
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

    /// A soft glow of same-size dots that thin out on an 8 × 8 Bayer screen, laid under whatever is
    /// already drawn (the brighter value wins). Dots that only change size would end in a hard edge
    /// where they drop below the renderer's smallest dot; thinning them fades out like the old still art.
    static func stippleGlow(_ layers: HalftoneLayers, center: CGPoint, radius: CGFloat, strength: CGFloat,
                            dotRadius: CGFloat = 0.85) {
        let context = layers.bone
        guard radius > 0, let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let columns = context.width, rows = context.height, stride = context.bytesPerRow
        let cellWidth = layers.size.width / CGFloat(columns), cellHeight = layers.size.height / CGFloat(rows)
        let fullDot = min(cellWidth, cellHeight) * 0.5 * dotScale
        let level = min(1, (dotRadius / fullDot) * (dotRadius / fullDot))
        let value = UInt8((level * 255).rounded())
        for row in 0..<rows {
            let dy = (CGFloat(row) + 0.5) * cellHeight - center.y
            for column in 0..<columns {
                let dx = (CGFloat(column) + 0.5) * cellWidth - center.x
                let density = strength * max(0, 1 - (dx * dx + dy * dy).squareRoot() / radius)
                guard density > bayer[(row & 7) * 8 + (column & 7)] else { continue }
                let index = row * stride + column
                data[index] = max(data[index], value)
            }
        }
    }

    /// The 8 × 8 Bayer matrix as thresholds in 0…1, the ordered dither of the Reach concept.
    private static let bayer: [CGFloat] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21
    ].map { ($0 + 0.5) / 64 }
}
