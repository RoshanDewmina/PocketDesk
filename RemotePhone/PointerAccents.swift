import SwiftUI

/// Decoration for the phone-drawn pointer: an ember contact dot and ripple when a click lands.
/// The halftone settle-halo (a dotted ring when the pointer rests, solid while a drag is held) is off:
/// the pointer is already large, and the held state has its own chip. It draws only where the pointer
/// is known and never over or into the streamed picture's pixels.
struct PointerAccentView: View {
    /// Phone user default; absent means off. `defaults write com.roshan.PocketDesk.Remote pointer.settleHalo -bool YES`
    /// brings the ring back.
    static let settleHaloKey = "pointer.settleHalo"
    static func settleHaloEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: settleHaloKey) }
    static let settleHalo = settleHaloEnabled()

    @ObservedObject var model: PointerOverlayModel
    let viewport: ViewportTransform
    let size: PointerSizePreference
    let acceptedClicks: UInt64
    var clickKind = ContactRipple.Kind.click
    @ObservedObject var pressHighlight: PressHighlight
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
                // Picture-container coordinates, like the pointer glyph, so accents stay on the pointer
                // while the camera eases; a pointer move never carries the camera's animation.
                let tip = PointerOverlayView.picturePoint(render.point, scale: viewport.scale)
                if Self.settleHalo && (haloVisible || holding || preview) {
                    SettleHalo(diameter: size.arrowHeight * 1.9, solid: holding)
                        .position(tip)
                        .transaction(value: render.point) { $0.disablesAnimations = true }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                }
                if let contact {
                    ContactRipple(serial: contact.serial, kind: contact.kind, frozen: preview)
                        .position(PointerOverlayView.picturePoint(contact.source, scale: viewport.scale))
                        .transaction(value: render.point) { $0.disablesAnimations = true }
                }
            }
            // Outside the pointer check: a direct touch's highlight sits under the finger even before the
            // drawn pointer arrives there.
            if let press = pressHighlight.press {
                // The outer id gives each press fresh animation state, so back-to-back presses each replay.
                ContactRipple(serial: press.serial, kind: .press)
                    .id(press.serial)
                    .position(PointerOverlayView.picturePoint(press.source, scale: viewport.scale))
                    .transaction(value: press.serial) { $0.disablesAnimations = true }
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
        guard Self.settleHalo else { return }
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
        static let restDelay: TimeInterval = 0.12
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

/// The phone's touch-down highlight (`PressHighlightSwitch`): a soft ember disc under the finger, or at the
/// drawn pointer in trackpad mode, the moment a press lands, while the Mac's picture of the click is still
/// 50–80 ms away. The click itself is untouched; the ripple still marks it once sent.
@MainActor
final class PressHighlight: ObservableObject {
    struct Press: Equatable {
        let source: CGPoint
        let serial: Int
    }

    let enabled: Bool
    @Published private(set) var press: Press?
    private var serial = 0

    init(enabled: Bool = PressHighlightSwitch.isOn) { self.enabled = enabled }

    func begin(at source: CGPoint?) {
        guard enabled, let source, source.x.isFinite, source.y.isFinite else { return }
        serial &+= 1
        let serial = serial
        press = Press(source: source, serial: serial)
        // The model outlives the session view: a faded press must not replay when the view is rebuilt.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ContactRipple.pressFade + 0.05))
            self?.clear(serial)
        }
    }

    /// The touch became a scroll, pinch, pointer travel or the loupe: drop the highlight, unanimated. A withdrawal
    /// can come from `updateUIView` (a reconfigure cancels the touch), so it publishes after the view update.
    func withdraw() {
        guard let serial = press?.serial else { return }
        Task { @MainActor [weak self] in self?.clear(serial) }
    }

    private func clear(_ serial: Int) {
        guard press?.serial == serial else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { press = nil }
    }
}

/// Phone flag for the press highlight (`defaults write <phone bundle id> PocketDeskPressHighlight -bool YES`, or
/// the launch argument `-PocketDeskPressHighlight YES`, then relaunch the app). Off by default until a device A/B.
enum PressHighlightSwitch {
    static let defaultsKey = "PocketDeskPressHighlight"
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
    static let isOn = enabled()
}

/// The ember contact at the pointer tip: a dot and an expanding ring for a click, two concentric
/// rings for a right-click, two quick rings for a double-click and one tight ring for a middle click.
/// `press` is the touch-down highlight: a 44 pt disc that fades over 180 ms.
struct ContactRipple: View {
    enum Kind {
        case click, secondary, double, middle, press

        init(action: String) {
            switch action {
            case "right": self = .secondary
            case "double": self = .double
            case "middle": self = .middle
            default: self = .click
            }
        }
    }

    let serial: Int
    var kind: Kind = .click
    /// Holds the first moment of the contact for previews and screenshots.
    var frozen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var first = false
    @State private var second = false

    static let pressDiameter: CGFloat = 44
    static let pressFade: TimeInterval = 0.18

    var body: some View {
        ZStack {
            if kind == .press {
                Circle()
                    .fill(Farside.Palette.ember.opacity(0.3))
                    .overlay(Circle().strokeBorder(Farside.Palette.ember.opacity(0.55), lineWidth: 1))
                    .frame(width: Self.pressDiameter, height: Self.pressDiameter)
                    .scaleEffect(first && !reduceMotion ? 1.12 : 1)
                    .opacity(first ? 0 : 1)
            } else {
                ring(expanded: first, size: kind == .middle ? 64 : 110)
                if kind == .secondary || kind == .double {
                    ring(expanded: second, size: kind == .secondary ? 70 : 110)
                }
                Circle()
                    .fill(Farside.Palette.ember)
                    .frame(width: 9, height: 9)
                    .shadow(color: Farside.Palette.ember, radius: 6)
                    .scaleEffect(first ? 1 : 1.5)
                    .opacity(first ? 0 : 1)
            }
        }
        .frame(width: 120, height: 120)
        .id(serial)
        .onAppear(perform: play)
        .accessibilityHidden(true)
    }

    private func ring(expanded: Bool, size: CGFloat) -> some View {
        Circle()
            .strokeBorder(Farside.Palette.ember, lineWidth: 2)
            .frame(width: expanded ? size : (frozen ? size * 0.42 : 12), height: expanded ? size : (frozen ? size * 0.42 : 12))
            .opacity(expanded ? 0 : 1)
    }

    private func play() {
        guard !frozen else { return }
        first = false
        second = false
        if kind == .press {
            // Ease-in holds the disc at full strength while the Mac's picture catches up, then lets it go.
            withAnimation(.easeIn(duration: Self.pressFade)) { first = true }
            return
        }
        let motion = reduceMotion ? Animation.easeOut(duration: 0.45) : Farside.Motion.easeOut(0.7)
        withAnimation(motion) { first = true }
        guard kind == .secondary || kind == .double else { return }
        withAnimation(motion.delay(kind == .secondary ? 0.07 : 0.16)) { second = true }
    }
}
