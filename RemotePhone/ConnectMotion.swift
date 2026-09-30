import CoreHaptics
import SwiftUI
import UIKit

// D38 · Connect motion "Reach, restored". Design: design/motion-lab-2026-09-30 (direction A).
// Every beat here follows a real coordinator state; loops only ever mean "still trying".

// MARK: - Stage glyph

/// A 7×7 dot-matrix glyph per connect stage, in the Doto spirit: a chevron that sweeps while
/// reaching, a ring that blooms from the meeting dot once the Mac is found, and an aperture that
/// opens while the picture is on its way. No words, no numbers, nothing that reads as distance.
struct StageGlyph: View {
    let stage: ConnectStage
    /// Ember once finger and pointer are in contact (the Mac answered).
    var contact: Bool
    var pitch: CGFloat = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion)) { timeline in
            let frame = reduceMotion ? Self.stillFrame(stage) : Int(timeline.date.timeIntervalSinceReferenceDate * 12)
            Canvas { context, _ in
                let lit = Self.pattern(stage, frame: frame)
                let radius = pitch * 0.36
                for y in 0..<7 {
                    for x in 0..<7 {
                        let level = lit[y * 7 + x] ?? 0
                        let center = CGPoint(x: (CGFloat(x) + 0.5) * pitch, y: (CGFloat(y) + 0.5) * pitch)
                        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                        if level > 0 {
                            let color = contact ? Farside.Palette.ember : Farside.Palette.bone
                            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.35 + 0.65 * level)))
                        } else {
                            context.fill(Path(ellipseIn: rect), with: .color(Farside.Palette.dim.opacity(0.5)))
                        }
                    }
                }
            }
        }
        .frame(width: pitch * 7, height: pitch * 7)
        .accessibilityHidden(true)
    }

    static func stillFrame(_ stage: ConnectStage) -> Int {
        switch stage {
        case .idle, .reaching: 5
        case .found: 1
        case .opening: 3
        }
    }

    /// Lit cells, index y * 7 + x, with brightness 0…1.
    static func pattern(_ stage: ConnectStage, frame: Int) -> [Int: Double] {
        var lit: [Int: Double] = [:]
        func set(_ x: Int, _ y: Int, _ level: Double) {
            guard (0..<7).contains(x), (0..<7).contains(y) else { return }
            lit[y * 7 + x] = max(lit[y * 7 + x] ?? 0, level)
        }
        switch stage {
        case .idle, .reaching:
            let head = frame % 11 - 1
            set(head, 3, 1); set(head - 1, 2, 1); set(head - 1, 4, 1)
            set(head - 2, 3, 0.55); set(head - 3, 3, 0.25)
        case .found:
            set(3, 3, 1)
            let phase = frame % 12, radius = phase / 4 + 1, fade = 1 - Double(phase % 4) * 0.2
            for x in 0..<7 { for y in 0..<7 where abs(x - 3) + abs(y - 3) == radius { set(x, y, fade) } }
        case .opening:
            let size = frame % 4
            for x in 0..<7 {
                for y in 0..<7 {
                    let ring = max(abs(x - 3), abs(y - 3))
                    if ring == size { set(x, y, 1) } else if ring == size - 1 { set(x, y, 0.4) }
                }
            }
        }
        return lit
    }
}

/// The readout on Home's art while connecting: three stage pips and the stage glyph, on a solid plate.
struct StageReadout: View {
    let stage: ConnectStage
    let contact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                ForEach(1...3, id: \.self) { index in
                    Circle()
                        .fill(stage.rawValue >= index ? (contact ? Farside.Palette.ember : Farside.Palette.bone) : Farside.Palette.dim)
                        .frame(width: 5, height: 5)
                }
            }
            StageGlyph(stage: stage, contact: contact)
                .id(stage)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.7)))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Farside.Palette.void, in: .rect(cornerRadius: 6))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.easeOut(), value: stage)
        .accessibilityHidden(true)
    }
}

// MARK: - Haptics

/// Core Haptics for the connect beats (NOTES.md, direction A). Falls back to UIKit feedback when
/// the engine can't run. `.success` and `.warning` stay SwiftUI `sensoryFeedback` notifications.
@MainActor
final class ConnectHaptics {
    static let shared = ConnectHaptics()

    enum Beat {
        case press, contact, click, meet, slack, back, softEnd
        /// Stage clicks are decoration; Reduce Motion drops them, the rest are information.
        var decorative: Bool { self == .click }
    }

    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func play(_ beat: Beat) {
        if beat.decorative && UIAccessibility.isReduceMotionEnabled { return }
        guard supported else { return }
        do {
            let player = try readyEngine().makePlayer(with: try Self.pattern(beat))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: beat == .meet ? .heavy : .medium).impactOccurred(intensity: Self.fallbackIntensity(beat))
        }
    }

    private func readyEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak engine] in try? engine?.start() }
        try engine.start()
        self.engine = engine
        return engine
    }

    private static func fallbackIntensity(_ beat: Beat) -> CGFloat {
        switch beat {
        case .meet: 1
        case .contact, .back: 0.7
        case .press, .softEnd: 0.5
        case .click, .slack: 0.4
        }
    }

    static func pattern(_ beat: Beat) throws -> CHHapticPattern {
        func tap(_ intensity: Float, _ sharpness: Float, at time: TimeInterval = 0) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ], relativeTime: time)
        }
        func hum(_ intensity: Float, _ sharpness: Float, _ duration: TimeInterval) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ], relativeTime: 0, duration: duration)
        }
        func decay(_ duration: TimeInterval) -> CHHapticParameterCurve {
            CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1),
                CHHapticParameterCurve.ControlPoint(relativeTime: duration, value: 0)
            ], relativeTime: 0)
        }
        switch beat {
        case .press: return try CHHapticPattern(events: [tap(0.5, 0.7)], parameters: [])
        case .contact: return try CHHapticPattern(events: [tap(0.7, 0.35), hum(0.3, 0.1, 0.18)], parameterCurves: [decay(0.18)])
        case .click: return try CHHapticPattern(events: [tap(0.4, 0.8)], parameters: [])
        case .meet: return try CHHapticPattern(events: [tap(1, 0.55), hum(0.6, 0.2, 0.24)], parameterCurves: [decay(0.24)])
        case .slack: return try CHHapticPattern(events: [tap(0.35, 0.15)], parameters: [])
        case .back: return try CHHapticPattern(events: [tap(0.55, 0.5)], parameters: [])
        case .softEnd: return try CHHapticPattern(events: [tap(0.5, 0.3)], parameters: [])
        }
    }
}

// MARK: - Session transitions

/// The session opens as an iris out of the ember dot where finger met pointer, with a fading
/// ember rim. Transform and opacity only: a scaled circle mask over the live picture.
struct IrisReveal: ViewModifier {
    var progress: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    let diameter = Self.diameter(proxy.size)
                    Circle()
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(max(progress, 0.001))
                        .position(x: anchor.x * proxy.size.width, y: anchor.y * proxy.size.height)
                }
                .ignoresSafeArea()
            }
            .overlay {
                GeometryReader { proxy in
                    let diameter = Self.diameter(proxy.size)
                    Circle()
                        .strokeBorder(Farside.Palette.ember, lineWidth: min(90, 4 / max(progress, 0.05)))
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(max(progress, 0.001))
                        .position(x: anchor.x * proxy.size.width, y: anchor.y * proxy.size.height)
                        .opacity(Double(1 - progress) * 0.9)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
    }

    /// Wide enough to cover the screen from any anchor.
    static func diameter(_ size: CGSize) -> CGFloat { 2 * (size.width * size.width + size.height * size.height).squareRoot() + 2 }
}

/// Ending powers the picture down like an old monitor: it collapses to a bright line, then to a dot.
struct PowerDown: ViewModifier, Animatable {
    /// 1 on screen, 0 gone.
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let off = 1 - min(max(progress, 0), 1)
        let squash = min(1, off / 0.55)
        let pinch = max(0, (off - 0.55) / 0.45)
        let scaleY = off < 0.55 ? 1 - (1 - 0.006) * squash * squash * squash : 0.006
        let scaleX = off < 0.55 ? 1 : 1 - (1 - 0.012) * (1 - pow(1 - pinch, 3))
        content
            .overlay(Farside.Palette.bone.opacity(0.9 * squash).allowsHitTesting(false))
            .scaleEffect(x: scaleX, y: scaleY)
            .opacity(off > 0.97 ? 0 : 1)
    }
}

extension AnyTransition {
    /// The session's arrival and departure (D38). Reduce Motion cross-fades.
    static func farsideSession(anchor: UnitPoint, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .modifier(active: IrisReveal(progress: 0, anchor: anchor),
                                                identity: IrisReveal(progress: 1, anchor: anchor)),
                           removal: .modifier(active: PowerDown(progress: 0), identity: PowerDown(progress: 1)))
    }
}

extension Animation {
    static func farsideSession(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : Farside.Motion.easeOut(0.46)
    }
}

/// Where finger meets pointer on Home, in global coordinates, so the iris opens from there.
struct ReachMeetingPointKey: PreferenceKey {
    static let defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) { value = nextValue() ?? value }
}

private struct ReturningFromSessionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Home was just uncovered by a session ending: the hand eases back from the pointer once.
    var farsideReturningFromSession: Bool {
        get { self[ReturningFromSessionKey.self] }
        set { self[ReturningFromSessionKey.self] = newValue }
    }
}

// MARK: - Arrival

/// Once the first frame is on screen: a small route toast that says "Measuring…" until the stream
/// has measured the route, then shows it, then folds away. Informational only; it never blocks input.
struct SessionRouteToast: View {
    let macName: String
    let diagnostics: String
    let pictureReady: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var played = false

    private var caption: String? { SessionRouteCaption.parse(diagnostics).text }

    var body: some View {
        ZStack {
            if shown {
                HStack(spacing: 9) {
                    LiveDot(state: .live, size: 7)
                    Text(verbatim: "\(macName) · \(caption ?? "Measuring…")")
                        .font(Farside.Typeface.caption(.footnote))
                        .foregroundStyle(Farside.Palette.bone)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("session.arrival")
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Farside.Motion.easeOut(), value: shown)
        .animation(Farside.Motion.easeOut(Farside.Motion.micro), value: caption)
        .allowsHitTesting(false)
        .task(id: pictureReady) {
            guard pictureReady, !played else { return }
            played = true
            try? await Task.sleep(for: .milliseconds(120))
            shown = true
            // Waiting for a measurement is not progress: the toast only reports what exists.
            for _ in 0..<16 where caption == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(2))
            shown = false
        }
    }
}

// MARK: - Reconnecting

/// Watches a live session's connection: a drop gets a slack tap; the same session coming back
/// gets a "back" tap and shows `back` for a moment. The first connect is neither.
struct ReconnectWatcher: View {
    let connected: Bool
    @Binding var back: Bool
    @State private var dropped = false

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: connected) { was, now in
                if was && !now {
                    dropped = true
                    back = false
                    ConnectHaptics.shared.play(.slack)
                } else if !was && now && dropped {
                    dropped = false
                    ConnectHaptics.shared.play(.back)
                    back = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        back = false
                    }
                }
            }
    }
}

/// "Back · Direct · 16 ms": the measured route if there is one, otherwise the Mac's name.
struct ReconnectBackPill: View {
    let macName: String
    let diagnostics: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            LiveDot(state: .live)
            Text(verbatim: "Back · \(SessionRouteCaption.parse(diagnostics).text ?? macName)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote.back")
    }
}

/// While a live session is away, its frozen picture dims through a dot screen that washes down
/// from the top; when it returns, the dim opens as a circle from the middle. Transform-only masks.
struct ReconnectVeil: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active {
                FarsideDotScreen(wash: 0.35...0.8)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(active: VeilWipe(progress: 0), identity: VeilWipe(progress: 1)),
                        removal: .modifier(active: VeilOpening(progress: 1), identity: VeilOpening(progress: 0))))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Farside.Motion.easeOut(0.44), value: active)
    }
}

private struct VeilWipe: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            Rectangle().scaleEffect(x: 1, y: max(progress, 0.001), anchor: .top)
        }
    }
}

private struct VeilOpening: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let diameter = IrisReveal.diameter(proxy.size)
                Rectangle()
                    .overlay {
                        Circle()
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(max(progress, 0.001))
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        }
    }
}

// MARK: - Pairing

/// A successful scan: the code's modules fly into the Farside mark, the tip lights ember last.
struct CodeToMarkBurst: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let codeCells = 11
    private static let markRows = ["#", "##", "###", "####", "#####", "######", "#######", "########",
                                   "#########", "##########", "######", "##.##", "#...##", "....##",
                                   ".....##", ".....##"]
    private static let modules: [CGPoint] = {
        var result: [CGPoint] = []
        for y in 0..<codeCells {
            for x in 0..<codeCells {
                let finder = (x < 3 && y < 3) || (x > 7 && y < 3) || (x < 3 && y > 7)
                if finder || ((x * 7 + y * 13 + x * y) % 5) < 2 { result.append(CGPoint(x: x, y: y)) }
            }
        }
        return result
    }()
    private static let markDots: [(point: CGPoint, tip: Bool)] = markRows.enumerated().flatMap { y, row in
        row.enumerated().compactMap { x, cell in cell == "#" ? (CGPoint(x: x, y: y), x == 0 && y == 0) : nil }
    }
    /// Module i flies to mark dot `targets[i]`; the rest fade and scatter.
    private static let targets: [Int?] = {
        var result = [Int?](repeating: nil, count: modules.count)
        var used = Set<Int>()
        for (markIndex, dot) in markDots.enumerated() {
            let goal = CGPoint(x: dot.point.x / 10 * 10, y: dot.point.y / 16 * 10)
            var best: Int?, bestDistance = CGFloat.infinity
            for (index, module) in modules.enumerated() where !used.contains(index) {
                let distance = hypot(module.x - goal.x, module.y - goal.y)
                if distance < bestDistance { bestDistance = distance; best = index }
            }
            if let best { used.insert(best); result[best] = markIndex }
        }
        return result
    }()

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let cell = side / CGFloat(Self.codeCells + 2)
            let codeOrigin = CGPoint(x: (size.width - cell * CGFloat(Self.codeCells)) / 2,
                                     y: (size.height - cell * CGFloat(Self.codeCells)) / 2)
            let pitch = side * 0.52 / 16
            let markOrigin = CGPoint(x: size.width / 2 - pitch * 5, y: size.height / 2 - pitch * 8)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for (index, module) in Self.modules.enumerated() {
                let start = CGPoint(x: codeOrigin.x + (module.x + 0.5) * cell, y: codeOrigin.y + (module.y + 0.5) * cell)
                let lag = min(0.3, hypot(start.x - center.x, start.y - center.y) / side * 0.5)
                let local = min(1, max(0, (progress - lag) / (1 - lag)))
                let eased = 1 - pow(1 - local, 3)
                if let target = Self.targets[index] {
                    let dot = Self.markDots[target]
                    let end = CGPoint(x: markOrigin.x + (dot.point.x + 0.5) * pitch, y: markOrigin.y + (dot.point.y + 0.5) * pitch)
                    let point = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
                    let radius = cell * 0.5 + (pitch * (dot.tip ? 0.5 : 0.42) - cell * 0.5) * eased
                    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    let shape = eased < 0.3 ? Path(rect.insetBy(dx: 0.5, dy: 0.5)) : Path(ellipseIn: rect)
                    let color = dot.tip && progress > 0.92 ? Farside.Palette.ember : Farside.Palette.bone
                    context.fill(shape, with: .color(color))
                } else if eased < 1 {
                    let angle = atan2(start.y - center.y, start.x - center.x)
                    let point = CGPoint(x: start.x + cos(angle) * 40 * eased, y: start.y + sin(angle) * 40 * eased)
                    let radius = cell * 0.5 * (1 - eased) + 0.5
                    context.opacity = Double(1 - eased)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                                 with: .color(Farside.Palette.bone))
                    context.opacity = 1
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Waiting for Allow on the Mac: the mark with its attention ring, pulsing until the Mac answers.
struct AwaitingAllowMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            FarsideMark(height: 20)
            Circle()
                .strokeBorder(Farside.Palette.ember, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .offset(x: -3, y: -3)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { ring, opacity in
                    ring.opacity(opacity)
                } animation: { _ in .easeInOut(duration: 0.7) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Anywhere

/// Anywhere just unlocked: the dotted home Wi‑Fi edge scatters and the hand stretches to the far
/// pointer. Illustration only; it implies no distance and shows no numbers.
struct AnywhereUnlockArt: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04), scene: Self.scene(progress))
            .overlay(alignment: .bottom) {
                Text(verbatim: "anywhere")
                    .font(Farside.Typeface.display(30))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Farside.Palette.void)
                    .opacity(Double(max(0, (progress - 0.55) / 0.45)))
                    .padding(.bottom, 6)
            }
            .accessibilityHidden(true)
    }

    static func scene(_ progress: CGFloat) -> FarsideArt.Scene {
        let reach = FarsideArt.reach(gap: 96 - 90 * progress, contact: max(0, (progress - 0.75) * 4))
        return { layers, time in
            reach(layers, time)
            let size = layers.size
            let unit = min(size.width, size.height * 1.95) / 390
            let meet = CGPoint(x: size.width * 0.52, y: size.height * 0.42)
            let edgeCenter = CGPoint(x: meet.x - 116 * unit, y: meet.y + 12 * unit)
            let scatter = min(1, progress * 1.6)
            guard scatter < 1 else { return }
            layers.bone.setFillColor(gray: 0.75 * (1 - scatter), alpha: 1)
            for index in 0..<36 {
                let angle = CGFloat(index) / 36 * .pi * 2
                let radius = (62 + 60 * scatter) * unit
                let point = CGPoint(x: edgeCenter.x + cos(angle) * radius, y: edgeCenter.y + sin(angle) * radius)
                layers.bone.fillEllipse(in: CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8))
            }
        }
    }
}
