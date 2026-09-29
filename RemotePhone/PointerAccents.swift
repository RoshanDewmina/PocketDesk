import SwiftUI

/// Decoration for the phone-drawn pointer: an ember contact dot and ripple when a click lands,
/// and a halftone settle-halo when the pointer comes to rest (solid while a drag is held).
/// It draws only where the pointer is known and never over or into the streamed picture's pixels.
struct PointerAccentView: View {
    @ObservedObject var model: PointerOverlayModel
    let viewport: ViewportTransform
    let size: PointerSizePreference
    let acceptedClicks: UInt64
    var clickKind = ContactRipple.Kind.click
    let holding: Bool
    var preview = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = SettleClock()
    @State private var haloVisible = false
    @State private var contact: (source: CGPoint, serial: Int, kind: ContactRipple.Kind)?
    @State private var contactSerial = 0

    var body: some View {
        ZStack {
            if let render = model.render {
                let tip = viewport.viewPoint(fromSource: render.point)
                if haloVisible || holding || preview {
                    SettleHalo(diameter: size.arrowHeight * 1.9, solid: holding)
                        .position(tip)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                }
                if let contact {
                    ContactRipple(serial: contact.serial, kind: contact.kind)
                        .position(viewport.viewPoint(fromSource: contact.source))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: model.render?.point) { _, point in
            guard point != nil else { haloVisible = false; return }
            pointerMoved()
        }
        .onChange(of: acceptedClicks) { _, _ in
            guard let point = model.render?.point else { return }
            contactSerial &+= 1
            contact = (point, contactSerial, clickKind)
        }
        .onAppear {
            if preview, let point = model.render?.point {
                contactSerial = 1
                contact = (point, 1, .secondary)
            }
        }
    }

    private func pointerMoved() {
        clock.lastMove = ProcessInfo.processInfo.systemUptime
        clock.generation &+= 1
        if haloVisible {
            withAnimation(.easeOut(duration: 0.12)) { haloVisible = false }
        }
        guard !clock.waiting else { return }
        waitForRest(after: SettleClock.restDelay)
    }

    private func waitForRest(after delay: TimeInterval) {
        clock.waiting = true
        let clock = clock
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let idle = ProcessInfo.processInfo.systemUptime - clock.lastMove
            guard idle >= SettleClock.restDelay else {
                waitForRest(after: SettleClock.restDelay - idle + 0.01)
                return
            }
            clock.waiting = false
            guard model.render != nil else { return }
            let generation = clock.generation
            withAnimation(reduceMotion ? .easeIn(duration: 0.2) : Farside.Motion.easeOut(Farside.Motion.standard)) {
                haloVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                guard clock.generation == generation else { return }
                withAnimation(.easeOut(duration: 0.4)) { haloVisible = false }
            }
        }
    }

    /// Timing kept outside view state so pointer motion does not re-render anything.
    @MainActor
    final class SettleClock {
        static let restDelay: TimeInterval = 0.22
        var lastMove: TimeInterval = 0
        var generation: UInt64 = 0
        var waiting = false
    }
}

/// A ring of dots at a fixed on-screen size, readable on light and dark desktops.
struct SettleHalo: View {
    let diameter: CGFloat
    var solid = false

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = size.width / 2
            let pitch = max(4.5, diameter / 13)
            var shade = Path()
            var dots = Path()
            for y in stride(from: pitch / 2, to: size.height, by: pitch) {
                for x in stride(from: pitch / 2, to: size.width, by: pitch) {
                    let distance = hypot(x - center.x, y - center.y) / outer
                    guard distance > 0.5, distance < 1 else { continue }
                    let band = 1 - abs(distance - 0.76) / 0.26
                    let radius = pitch * 0.34 * max(0.35, band)
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    let halo = radius + 0.9
                    shade.addEllipse(in: CGRect(x: x - halo, y: y - halo, width: halo * 2, height: halo * 2))
                }
            }
            context.fill(shade, with: .color(Farside.Palette.void.opacity(0.55)))
            context.fill(dots, with: .color(solid ? Farside.Palette.ember : Farside.Palette.bone))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The ember contact at the pointer tip: a dot and an expanding ring for a click, two concentric
/// rings for a right-click, and two quick rings for a double-click.
struct ContactRipple: View {
    enum Kind {
        case click, secondary, double

        init(action: String) {
            switch action {
            case "right": self = .secondary
            case "double": self = .double
            default: self = .click
            }
        }
    }

    let serial: Int
    var kind: Kind = .click
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var first = false
    @State private var second = false

    var body: some View {
        ZStack {
            ring(expanded: first, size: 110)
            if kind != .click {
                ring(expanded: second, size: kind == .secondary ? 70 : 110)
            }
            Circle()
                .fill(Farside.Palette.ember)
                .frame(width: 9, height: 9)
                .shadow(color: Farside.Palette.ember, radius: 6)
                .scaleEffect(first ? 1 : 1.5)
                .opacity(first ? 0 : 1)
        }
        .frame(width: 120, height: 120)
        .id(serial)
        .onAppear(perform: play)
        .accessibilityHidden(true)
    }

    private func ring(expanded: Bool, size: CGFloat) -> some View {
        Circle()
            .strokeBorder(Farside.Palette.ember, lineWidth: 2)
            .frame(width: expanded ? size : 12, height: expanded ? size : 12)
            .opacity(expanded ? 0 : 1)
    }

    private func play() {
        first = false
        second = false
        let motion = reduceMotion ? Animation.easeOut(duration: 0.45) : Farside.Motion.easeOut(0.7)
        withAnimation(motion) { first = true }
        guard kind != .click else { return }
        withAnimation(motion.delay(kind == .secondary ? 0.06 : 0.16)) { second = true }
    }
}
