import SwiftUI

/// The window, not the device or its orientation, decides whether the picture needs a pad.
enum SessionWindowLayout {
    static func stacked(regular: Bool, window: CGSize, source: CGSize, wasStacked: Bool) -> Bool {
        guard regular, valid(window), valid(source) else { return false }
        let coverage = (window.width * source.height / source.width) / window.height
        return wasStacked ? coverage <= 0.66 : coverage < 0.60
    }

    static func pictureSize(window: CGSize, source: CGSize, stacked: Bool) -> CGSize {
        guard stacked, valid(window), valid(source) else { return window }
        return CGSize(width: window.width, height: min(window.height, window.width * source.height / source.width))
    }

    static func zoomAnchor(_ point: CGPoint, picture: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), picture.width), y: min(max(0, point.y), picture.height))
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

#if DEBUG
/// Screenshot fixtures constrain SwiftUI's window and explicitly supply its width class.
/// These exercise layout bands; they do not emulate system multitasking or scene focus.
struct SimulatedSessionWindow: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if let width = LaunchOptions.value("--ui-window-width=").flatMap(Double.init), width.isFinite, width > 0 {
            GeometryReader { proxy in
                let height = LaunchOptions.value("--ui-window-height=").flatMap(Double.init)
                ZStack { content }
                    .frame(width: min(CGFloat(width), proxy.size.width),
                           height: height.map { $0.isFinite && $0 > 0 ? min(CGFloat($0), proxy.size.height) : proxy.size.height }
                            ?? proxy.size.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ui.simulated.window")
                    .environment(\.horizontalSizeClass, LaunchOptions.value("--ui-width-class=") == "compact" ? .compact : .regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Farside.Palette.void)
        } else {
            content
        }
    }
}
#endif

extension Farside.Motion {
    static let windowLayout = Animation.easeInOut(duration: 0.32)
    /// Sheets and the dock: a quick spring that settles without wobble.
    static let sheetSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

/// The fingertip reaching for the pointer, with `gap`, `contact` and the pointer's pose animating smoothly.
struct ReachArt: View, Animatable {
    var gap: CGFloat
    var contact: CGFloat
    var cell: CGFloat = 5
    var active = true
    var ripples: [HalftoneRipple] = []
    /// The connect stage's dot glyph while connecting (D38): a pattern per stage, never a number.
    var readoutStage: ConnectStage?
    /// 0…1: the pointer lies down asleep (the Mac is napping).
    var sink: CGFloat = 0
    /// 0…1: the pointer dissolves (the Mac can't be reached).
    var fade: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(gap, contact), AnimatablePair(sink, fade)) }
        set { gap = newValue.first.first; contact = newValue.first.second; sink = newValue.second.first; fade = newValue.second.second }
    }

    var body: some View {
        FarsideHalftone(style: HalftoneStyle(cell: cell, dust: 0.05), active: active, ripples: ripples,
                        scene: FarsideArt.reach(gap: gap, contact: contact, sink: sink, fade: fade))
            .overlay(alignment: .bottomTrailing) {
                if let readoutStage, readoutStage != .idle {
                    StageReadout(stage: readoutStage, contact: contact > 0.5)
                        .padding(.trailing, 24)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
            }
    }

    /// Where the fingertip meets the pointer, in the art's own coordinates.
    static func meetingPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.52, y: size.height * 0.42)
    }

    /// Where the fingertip is for a given gap, in the art's own coordinates (see `FarsideArt.reach`).
    static func fingertip(in size: CGSize, gap: CGFloat) -> CGPoint {
        let unit = min(size.width, size.height * 1.95) / 390, meet = meetingPoint(in: size), angle: CGFloat = -0.12
        return CGPoint(x: meet.x - gap * unit * cos(angle), y: meet.y - gap * unit * sin(angle))
    }

    /// Bone rings leaving the fingertip while a stage waits (D38); none before 0.4 s.
    static func searchRings(from start: Date?, in size: CGSize, gap: CGFloat) -> [HalftoneRipple] {
        guard let start, size != .zero else { return [] }
        let tip = fingertip(in: size, gap: gap)
        return SearchRings.dates(from: start).map {
            HalftoneRipple(center: tip, date: $0, strength: 0.7, speed: 150, width: 20, life: 1.3, ember: 0, push: 1.5)
        }
    }
}

/// Before the first frame of a session: a placeholder that locks from noise to coarse to fine as
/// real events arrive, then fades as the real picture arrives. It never draws on the live picture;
/// once frames flow it is gone.
struct ResolutionLockView: View {
    let connected: Bool
    /// The remote video track is attached (`connection.remoteVideo != nil`).
    var videoTrack = false
    let pictureReady: Bool
    var fixedStage: Int?
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0
    @State private var connectedAt: Date?
    @State private var finishing = false
    @State private var slow = false

    var body: some View {
        GeometryReader { proxy in
            let shown = fixedStage ?? stage
            FarsideHalftone(style: style(for: shown), animated: shown < 3,
                            ripples: connectedAt.map { [HalftoneRipple(center: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2),
                                                                        date: $0, strength: 1.4, speed: 900, width: 60, life: 1.4)] } ?? [],
                            scene: scene(for: shown))
                .opacity(shown >= 3 ? 0 : (connected ? 1 : 0.55))
        }
        .overlay {
            if slow && connected && stage < 3 {
                Label("Waiting for your Mac’s screen…", systemImage: "hourglass")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
                    .transition(.opacity)
            }
        }
        .background(Farside.Palette.void)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // The connected beat is ConnectHaptics.meet (PhoneRemoteView); the lock only confirms the picture.
        .sensoryFeedback(trigger: stage) { old, new in new >= 3 && old < 3 ? .success : nil }
        .task(id: connected) { await run() }
        .onChange(of: videoTrack) { _, _ in advance() }
        .onChange(of: pictureReady) { _, ready in if ready { finish() } }
    }

    private func style(for stage: Int) -> HalftoneStyle {
        switch stage {
        case 0: HalftoneStyle(cell: 9, dotScale: 0.9, dust: 0.28)
        case 1: HalftoneStyle(cell: 22, dotScale: 1.05, dust: 0.02)
        default: HalftoneStyle(cell: 7, dotScale: 1.05, dust: 0.02)
        }
    }

    private func scene(for stage: Int) -> FarsideArt.Scene {
        if stage == 0 {
            return { layers, _ in
                let s = layers.size
                layers.glow(at: CGPoint(x: s.width / 2, y: s.height / 2), radius: min(s.width, s.height) * 0.12, intensity: 0.5)
            }
        }
        return FarsideArt.macThumbnail
    }

    /// Steps follow real events only (D38): connected → coarse, video track → finer, first frame → crisp.
    /// The two-second hint is a message about waiting, not a step.
    private func run() async {
        guard connected, fixedStage == nil else { return }
        if pictureReady { finish(); return }
        if !reduceMotion { connectedAt = Date() }
        advance()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard !finishing else { return }
        withAnimation(.easeOut(duration: 0.3)) { slow = true }
    }

    private func advance() {
        guard fixedStage == nil, !finishing else { return }
        let next = min(2, ResolutionLockStage(connected: connected, videoTrack: videoTrack, pictureReady: false).rawValue)
        guard next > stage else { return }
        if reduceMotion { stage = next } else { withAnimation(.easeOut(duration: 0.18)) { stage = next } }
    }

    /// Steps follow the connection, so the lock never adds a wait: the first frame goes straight to crisp.
    private func finish() {
        guard fixedStage == nil, !finishing else { return }
        finishing = true
        Task { @MainActor in
            withAnimation(.easeOut(duration: reduceMotion ? 0.25 : 0.3)) { stage = 3 }
            try? await Task.sleep(for: .milliseconds(330))
            onFinished()
        }
    }
}

/// Shown while an interrupted session reconnects on its own; the view, zoom and pan stay put.
struct ReconnectPill: View {
    let macName: String
    let end: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LiveDot(state: .busy)
            Text("Reconnecting to \(macName)…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button("End", action: end)
                .buttonStyle(FarsideEndButtonStyle(height: 32))
                .fixedSize()
                .accessibilityLabel("End session")
        }
        .padding(.leading, 16).padding(.trailing, 5).padding(.vertical, 5)
        .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.reconnecting")
    }
}

/// A successful scan dissolves the code into the mark before the sheet closes.
struct PairingBurstView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var flight: CGFloat = 0

    var body: some View {
        VStack(spacing: Farside.Space.l) {
            ZStack {
                if reduceMotion {
                    FarsideHalftone(style: HalftoneStyle(cell: 6, dust: 0), animated: false, scene: FarsideArt.pairingCode)
                        .frame(width: 220, height: 220)
                        .opacity(settled ? 0 : 1)
                    FarsideMark(height: 72).opacity(settled ? 1 : 0)
                } else {
                    // The code's own modules fly into the mark; the tip lights ember as they land (D38).
                    CodeToMarkBurst(progress: flight)
                        .shadow(color: Farside.Palette.ember.opacity(flight > 0.92 ? 0.5 : 0), radius: 24)
                }
            }
            .frame(width: 240, height: 240)
            VStack(spacing: Farside.Space.xs) {
                Text("Paired").farsideCaption(Farside.Palette.bone)
                Text("Now choose Allow on your Mac.")
                    .font(.body)
                    .foregroundStyle(Farside.Palette.ash)
                AwaitingAllowMark().padding(.top, Farside.Space.s)
            }
            .opacity(settled ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Farside.Palette.void2.ignoresSafeArea())
        .onAppear {
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.3)) { settled = true }
            } else {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.7)) { flight = 1 }
                withAnimation(Farside.Motion.easeOut().delay(0.45)) { settled = true }
            }
        }
        .sensoryFeedback(.success, trigger: settled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Paired. Now choose Allow on your Mac.")
        .accessibilityIdentifier("pairing.success")
    }
}

extension FarsideArt {
    /// A QR-like block pattern for the pairing burst.
    static let pairingCode: Scene = { layers, _ in
        let size = layers.size
        let cells = 11
        let cell = min(size.width, size.height) / CGFloat(cells + 2)
        let origin = CGPoint(x: (size.width - cell * CGFloat(cells)) / 2, y: (size.height - cell * CGFloat(cells)) / 2)
        layers.bone.setFillColor(gray: 0.9, alpha: 1)
        for y in 0..<cells {
            for x in 0..<cells {
                let finder = (x < 3 && y < 3) || (x > 7 && y < 3) || (x < 3 && y > 7)
                if finder || ((x * 7 + y * 13 + x * y) % 5) < 2 {
                    layers.bone.fill(CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell,
                                            width: cell - 1, height: cell - 1))
                }
            }
        }
    }
}


/// Pure decisions shared by the session chrome and regular-width sheet presentations.
/// Callers supply the effective width/rollback state; no device idiom or UIKit state is read here.
enum SessionChromePolicy {
    static let idleInterval: TimeInterval = 2

    static func form(regular: Bool, enabled: Bool) -> Bool { regular && enabled }

    static func cameraMaxHeight(regular: Bool, enabled: Bool) -> CGFloat? {
        form(regular: regular, enabled: enabled) ? nil : 340
    }

    /// Whether the special-key row appears; the text field remains in both cases.
    static func keyboardBar(regular: Bool, hardware: Bool) -> Bool { !(regular && hardware) }

    static func keyboardBottom(regular: Bool, stacked: Bool, couch: Bool, keyboardOpen: Bool,
                               barFrame: CGRect, canvas: CGRect) -> CGFloat {
        guard regular, !stacked, !couch, keyboardOpen, barFrame.height > 0 else { return 0 }
        return max(0, canvas.maxY - barFrame.minY)
    }

    static func persistent(reconnecting: Bool, reconnectBack: Bool, busy: Bool, bigText: Bool,
                           notice: Bool, pan: Bool, viewOnly: Bool, connected: Bool, covered: Bool) -> Bool {
        reconnecting || reconnectBack || busy || bigText || notice || pan || viewOnly || (connected && covered)
    }

    /// The idle task restarts on activity; state and open controls never enter its delay.
    static func mayCollapse(regular: Bool, controlsCollapsed: Bool, showControls: Bool,
                            keyboardOpen: Bool, persistent: Bool) -> Bool {
        regular && controlsCollapsed && !showControls && !keyboardOpen && !persistent
    }
}

/// High-rate input renews a monotonic deadline without publishing a view-state change
/// or spawning a task for each motion sample. Only showing/hiding the pill changes state.
@MainActor
final class SessionPillActivityClock {
    private var lastActivity = ProcessInfo.processInfo.systemUptime

    func note(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastActivity = now }
    func remaining(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, lastActivity + SessionChromePolicy.idleInterval - now)
    }
}
