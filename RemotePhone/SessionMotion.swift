import SwiftUI

extension Farside.Motion {
    /// Sheets and the dock: a quick spring that settles without wobble.
    static let sheetSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

/// The fingertip reaching for the pointer, with `gap` and `contact` animating smoothly.
struct ReachArt: View, Animatable {
    var gap: CGFloat
    var contact: CGFloat
    var cell: CGFloat = 5
    var active = true
    var ripples: [HalftoneRipple] = []
    /// Shows the gap as a dot-matrix count-down while connecting.
    var readout = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(gap, contact) }
        set { gap = newValue.first; contact = newValue.second }
    }

    var body: some View {
        FarsideHalftone(style: HalftoneStyle(cell: cell, dust: 0.05), active: active, ripples: ripples,
                        scene: FarsideArt.reach(gap: gap, contact: contact))
            .overlay(alignment: .bottomTrailing) {
                if readout {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("Gap").farsideCaption()
                        Text("\(Int(gap.rounded()))")
                            .font(.custom(Farside.Typeface.dotMatrix, fixedSize: 30))
                            .foregroundStyle(contact > 0.5 ? Farside.Palette.ember : Farside.Palette.bone)
                            .monospacedDigit()
                        Text("cm").farsideCaption()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Farside.Palette.void)
                    .padding(.trailing, 24)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
    }

    /// Where the fingertip meets the pointer, in the art's own coordinates.
    static func meetingPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.52, y: size.height * 0.42)
    }
}

/// Before the first frame of a session: a placeholder that locks from noise to coarse to fine,
/// one light tick per step, then fades as the real picture arrives. It never draws on the live
/// picture; once frames flow it is gone.
struct ResolutionLockView: View {
    let connected: Bool
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
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: stage,
                         condition: { old, new in new > old && !reduceMotion })
        .task(id: connected) { await run() }
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

    private func run() async {
        guard connected, fixedStage == nil else { return }
        if reduceMotion {
            if pictureReady { finish() }
            return
        }
        connectedAt = Date()
        for next in 1...2 {
            do { try await Task.sleep(for: .milliseconds(pictureReady ? 90 : 300)) } catch { return }
            withAnimation(.easeOut(duration: 0.18)) { stage = max(stage, next) }
        }
        if pictureReady { finish(); return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        withAnimation(.easeOut(duration: 0.3)) { slow = true }
    }

    private func finish() {
        guard fixedStage == nil, !finishing else { return }
        finishing = true
        Task { @MainActor in
            if !reduceMotion {
                while stage < 2 {
                    withAnimation(.easeOut(duration: 0.1)) { stage += 1 }
                    try? await Task.sleep(for: .milliseconds(90))
                }
            }
            withAnimation(.easeOut(duration: reduceMotion ? 0.25 : 0.35)) { stage = 3 }
            try? await Task.sleep(for: .milliseconds(380))
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

    var body: some View {
        VStack(spacing: Farside.Space.l) {
            ZStack {
                FarsideHalftone(style: HalftoneStyle(cell: 6, dust: 0), animated: false, scene: FarsideArt.pairingCode)
                    .frame(width: 220, height: 220)
                    .scaleEffect(settled ? 0.35 : 1)
                    .opacity(settled ? 0 : 1)
                    .blur(radius: settled && !reduceMotion ? 6 : 0)
                FarsideMark(height: 72)
                    .scaleEffect(settled ? 1 : (reduceMotion ? 1 : 0.4))
                    .opacity(settled ? 1 : 0)
                    .shadow(color: Farside.Palette.ember.opacity(settled ? 0.5 : 0), radius: 24)
            }
            .frame(width: 240, height: 240)
            VStack(spacing: Farside.Space.xs) {
                Text("Paired").farsideCaption(Farside.Palette.bone)
                Text("Now choose Allow on your Mac.")
                    .font(.body)
                    .foregroundStyle(Farside.Palette.ash)
            }
            .opacity(settled ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Farside.Palette.void2.ignoresSafeArea())
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.72)) {
                settled = true
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
