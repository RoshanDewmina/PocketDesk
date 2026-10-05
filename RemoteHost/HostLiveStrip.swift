import SwiftUI
import AppKit

// D39 · Mac popover "Live strip". Design: design/motion-lab-2026-09-30 (direction 1). The meters,
// sparkline and activity lights gave way to plain connection-quality bars in the popover (D63).
// Transform and opacity only; controls stay native buttons and toggles with their own accessibility.

// MARK: - Strip

/// The strip across the top of the popover. While a phone is connected each tap it sends ripples
/// out from the signal's peak; when sharing stops the strip powers down like an old monitor.
/// The caption sits on a solid plate, never on dots.
struct HostPopoverStrip: View {
    let presentation: HostPopoverPresentation
    var activity: HostActivityFeed?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var powerDowns = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            art
                .keyframeAnimator(initialValue: HostPowerDownFrame(), trigger: powerDowns) { content, frame in
                    content
                        .overlay(Farside.Palette.bone.opacity(frame.line))
                        .scaleEffect(x: frame.scaleX, y: frame.scaleY)
                        .opacity(frame.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scaleY) {
                        CubicKeyframe(0.03, duration: 0.18)
                        LinearKeyframe(0.03, duration: 0.26)
                        CubicKeyframe(1, duration: 0.01)
                    }
                    KeyframeTrack(\.scaleX) {
                        LinearKeyframe(1, duration: 0.18)
                        CubicKeyframe(0.02, duration: 0.14)
                        LinearKeyframe(0.02, duration: 0.12)
                        CubicKeyframe(1, duration: 0.01)
                    }
                    KeyframeTrack(\.line) {
                        CubicKeyframe(0.9, duration: 0.18)
                        LinearKeyframe(0.9, duration: 0.14)
                        CubicKeyframe(0, duration: 0.13)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 0.32)
                        CubicKeyframe(0, duration: 0.12)
                        LinearKeyframe(0, duration: 0.02)
                        CubicKeyframe(1, duration: 0.34)
                    }
                }
            HStack(spacing: 8) {
                if presentation.mood == .live { HostLiveDot() }
                Text(presentation.headline)
                    .hostCaption(11, color: Farside.Palette.bone)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Farside.Palette.void, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.leading, 8)
            .padding(.bottom, 10)
            .animation(Farside.Motion.easeOut(), value: presentation.headline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(Farside.Palette.void)
        .clipped()
        .onChange(of: presentation.mood) { old, new in
            guard old == .live, new != .live, !reduceMotion else { return }
            // The live picture is what powers down; the new mood's art fades in after it.
            lingerLive = true
            powerDowns += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { lingerLive = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.headline)
    }

    @State private var lingerLive = false

    @ViewBuilder private var art: some View {
        if let activity, presentation.mood == .live || lingerLive {
            HostLiveStripArt(activity: activity)
        } else {
            HostArt(.popoverStrip(presentation.mood))
        }
    }
}

struct HostPowerDownFrame {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var line: Double = 0
    var opacity: Double = 1
}

/// The live strip with one ripple per tap from the phone (the feed keeps the last six).
private struct HostLiveStripArt: View {
    @ObservedObject var activity: HostActivityFeed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let peak = HostArtScenes.peak(in: proxy.size)
            HostArt(.popoverStrip(.live), ripples: reduceMotion ? [] : activity.recentTaps.map {
                HalftoneRipple(center: peak, date: $0, strength: 1.1, speed: 220, width: 16, life: 0.9)
            })
        }
    }
}

extension HostArtScenes {
    /// Where the live signal peaks and the ember glow sits.
    static func peak(in size: CGSize) -> CGPoint {
        let x = size.width * 0.66
        return CGPoint(x: x, y: signalY(x, size: size, mood: .live, phase: 0))
    }
}

// MARK: - Stop Sharing confirmation

/// Stopping while a phone is connected asks first. Keep Sharing is the default (Return) and Esc
/// cancels; Stop Sharing is the destructive button. The strip then powers down.
struct HostStopConfirm: View {
    let phoneName: String
    let keep: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stop sharing with \(PhoneDisplayName.inSentence(phoneName))?")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Farside.Palette.bone)
                .fixedSize(horizontal: false, vertical: true)
            Text("It disconnects right away. You can share again from here.")
                .font(.system(size: 12))
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep Sharing", action: keep)
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30, fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.popover.keepSharing")
                Button("Stop Sharing", role: .destructive, action: stop)
                    .buttonStyle(HostButtonStyle(kind: .ember, height: 30, fullWidth: true))
                    .accessibilityIdentifier("farside.popover.confirmStop")
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Farside.Palette.line2, lineWidth: 1))
        .onExitCommand(perform: keep)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("farside.popover.stopConfirm")
    }
}

// MARK: - Pairing code

/// The pairing code right in the popover: it resolves through an ordered dither, a row of twelve
/// dots drains as the two-minute code ages, and a scan hands over to "Is this your phone?".
struct HostPopoverPairingCode: View {
    let pairing: HostPairingState
    let copy: () -> Void
    let newCode: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0

    static let lifetime: TimeInterval = 120

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Farside.Palette.bone)
                switch pairing {
                case .showingCode(let value, _):
                    if let image = HostQRCode.image(for: value) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .padding(12)
                            .mask(HostDitherReveal(reveal: reveal))
                            .accessibilityLabel("Private pairing code")
                    }
                case .expired:
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 20))
                        Text("Code expired").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(HostTheme.ink.opacity(0.7))
                default:
                    ProgressView().controlSize(.small).environment(\.colorScheme, .light)
                }
            }
            .frame(width: 156, height: 156)
            switch pairing {
            case .showingCode(_, let expires):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, expires.timeIntervalSince(context.date))
                    VStack(spacing: 6) {
                        HostDrainDots(remaining: remaining, lifetime: Self.lifetime)
                        Text(verbatim: "Expires in \(Int(remaining) / 60):\(String(format: "%02d", Int(remaining) % 60)) · keep it private")
                            .hostCaption(10)
                    }
                }
                Button("Copy code instead", action: copy)
                    .buttonStyle(HostButtonStyle(kind: .inline))
                    .accessibilityIdentifier("farside.popover.copyCode")
            case .expired:
                Button("New Code", action: newCode)
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 30))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.popover.newCode")
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if reduceMotion { reveal = 1 } else { withAnimation(.easeOut(duration: 0.42)) { reveal = 1 } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("farside.popover.pairingCode")
    }
}

/// Twelve dots, one per ten seconds of the code's life, going out as it ages.
private struct HostDrainDots: View {
    let remaining: TimeInterval
    let lifetime: TimeInterval

    var body: some View {
        let lit = Int((remaining / lifetime * 12).rounded(.up))
        HStack(spacing: 5) {
            ForEach(0..<12, id: \.self) { index in
                Circle()
                    .fill(index < lit ? Farside.Palette.bone : Farside.Palette.dim)
                    .frame(width: 5, height: 5)
            }
        }
        .animation(Farside.Motion.easeOut(), value: lit)
        .accessibilityHidden(true)
    }
}

/// An 8×8 ordered-dither mask: cells switch on in Bayer order as `reveal` goes 0 → 1.
private struct HostDitherReveal: View, Animatable {
    var reveal: CGFloat
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    private static let bayer: [Int] = [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
                                       12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
                                       3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
                                       15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21]

    var body: some View {
        Canvas { context, size in
            guard reveal < 1 else {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                return
            }
            let cell: CGFloat = 6
            let columns = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
            var path = Path()
            for y in 0..<rows {
                for x in 0..<columns where (CGFloat(Self.bayer[(y % 8) * 8 + x % 8]) + 0.5) / 64 <= reveal {
                    path.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(.black))
        }
    }
}
