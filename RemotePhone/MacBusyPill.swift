import SwiftUI

/// "Your Mac is busy · 30 fps at 1440 px": a quiet capsule for the top of the session while the
/// Mac's ladder holds the stream below its best (`BusyState`). It never takes touches, and it
/// fades rather than pulses, so it informs without pulling the eye off the Mac.
struct MacBusyPill: View {
    let state: BusyState
    var isVisible: Bool
    var device: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: BusyState, isVisible: Bool? = nil, device: String = "iPhone") {
        self.state = state
        self.isVisible = isVisible ?? state.isVisible
        self.device = device
    }

    private var presentation: BusyPresentation? {
        isVisible ? BusyPresentation(state, device: device) : nil
    }

    var body: some View {
        let presentation = self.presentation
        ZStack {
            if let presentation {
                capsule(presentation)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.reveal(0.6), value: presentation)
        .onChange(of: presentation != nil) { _, shown in
            guard shown, let presentation else { return }
            AccessibilityNotification.Announcement(presentation.accessibilityLabel).post()
        }
    }

    private func capsule(_ presentation: BusyPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                symbol(presentation)
                title(presentation)
                if let detail = presentation.detail { self.detail(detail) }
            }
            HStack(spacing: 10) {
                symbol(presentation)
                VStack(alignment: .leading, spacing: 2) {
                    title(presentation)
                    if let detail = presentation.detail { self.detail(detail) }
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .farsidePlate(Farside.Radius.pill, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("remote.macBusy")
    }

    private func symbol(_ presentation: BusyPresentation) -> some View {
        Image(systemName: presentation.symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Farside.Palette.ash)
    }

    private func title(_ presentation: BusyPresentation) -> some View {
        Text(presentation.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Farside.Palette.bone)
            .contentTransition(.opacity)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(Farside.Typeface.caption(.footnote))
            .monospacedDigit()
            .foregroundStyle(Farside.Palette.ash)
            .contentTransition(.opacity)
    }
}

private struct MacBusyPillPreview: View {
    let state: BusyState

    var body: some View {
        ZStack(alignment: .top) {
            Farside.Palette.void.ignoresSafeArea()
            MacBusyPill(state: state).padding(.top, 8)
        }
    }
}

#Preview("Busy") {
    MacBusyPillPreview(state: BusyState(level: .busy, fps: 30, longEdge: 1440, reason: "encoding"))
}

#Preview("Strained") {
    MacBusyPillPreview(state: BusyState(level: .strained, fps: 60, longEdge: 1920, reason: "network"))
}

#Preview("OK (hidden)") {
    MacBusyPillPreview(state: .ok)
}
