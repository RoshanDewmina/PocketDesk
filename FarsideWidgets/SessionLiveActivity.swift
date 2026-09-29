import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The session Live Activity: Lock Screen, Dynamic Island (compact, minimal, expanded) and StandBy.
///
/// Reach rules: bone type on the void, ember only for contact (the live dot and End). Never screen
/// content, prompt text, file names or a latency figure: the state carries none. The Mac's name shows
/// only when the person turned that on; otherwise it says "Your Mac". Views take a plain value, so the
/// same drawing serves the widget, previews and tests.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FarsideSessionAttributes.self) { context in
            SessionLockScreenView(content: SessionActivityContent(context))
                .activityBackgroundTint(Farside.Palette.void)
                .activitySystemActionForegroundColor(Farside.Palette.bone)
                .widgetURL(SessionActivityLinks.session)
        } dynamicIsland: { context in
            let content = SessionActivityContent(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SessionGlyphTile(look: content.look, size: 34).padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionClock(content: content, size: 17).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionExpandedBottom(content: content)
                }
            } compactLeading: {
                FarsideMarkGlyph(height: 16)
            } compactTrailing: {
                if #available(iOS 27.0, *) {
                    LimitedWidthCompactTrailing(content: content)
                } else {
                    SessionCompactTrailing(content: content)
                }
            } minimal: {
                SessionMinimalGlyph(content: content)
            }
            .widgetURL(SessionActivityLinks.session)
            .keylineTint(content.keylineTint)
        }
    }
}

// MARK: - The plain value every view draws

struct SessionActivityContent {
    enum Look: Equatable {
        case live, paused, reconnecting, ended, problem, stale
    }

    let attributes: FarsideSessionAttributes
    let state: FarsideSessionAttributes.ContentState
    let isStale: Bool

    init(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState, isStale: Bool) {
        self.attributes = attributes
        self.state = state
        self.isStale = isStale
    }

    init(_ context: ActivityViewContext<FarsideSessionAttributes>) {
        self.init(attributes: context.attributes, state: context.state, isStale: context.isStale)
    }

    var look: Look {
        if isStale { return .stale }
        switch state.phase {
        case .live: return .live
        case .paused: return .paused
        case .reconnecting: return .reconnecting
        case .ended: return (state.endedReason ?? .user) == .user ? .ended : .problem
        }
    }

    var title: String { SessionActivityCopy.title(for: state, stale: isStale) }
    var line: String { SessionActivityCopy.line(for: state, macLabel: attributes.macLabel, stale: isStale) }
    var summary: String { SessionActivityCopy.accessibilitySummary(for: state, stale: isStale) }

    /// A stale activity keeps its End button: ending is always the safe direction.
    var canEnd: Bool { [.live, .paused, .reconnecting, .stale].contains(look) }
    var canReconnect: Bool { look == .problem && state.endedReason == .timeout }

    var keylineTint: Color? {
        switch look {
        case .live: Farside.Palette.ember
        case .paused, .reconnecting: Farside.Palette.bone.opacity(0.55)
        case .ended, .problem, .stale: nil
        }
    }
}

// MARK: - Lock Screen and StandBy

struct SessionLockScreenView: View {
    let content: SessionActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SessionGlyphTile(look: content.look, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.headline)
                    .foregroundStyle(Farside.Palette.bone)
                    .lineLimit(1)
                Text(content.line)
                    .font(.subheadline)
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(2)
                    .privacySensitive()
                if content.attributes.isPreview { SampleTag() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(content.summary)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 8) {
                SessionClock(content: content, size: 17)
                if content.canEnd {
                    EndSessionButton()
                } else if content.canReconnect {
                    ReconnectLink()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Dynamic Island

struct SessionExpandedBottom: View {
    let content: SessionActivityContent

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.headline)
                    .foregroundStyle(Farside.Palette.bone)
                    .lineLimit(1)
                Text(content.line)
                    .font(.subheadline)
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(2)
                    .privacySensitive()
                if content.attributes.isPreview { SampleTag() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(content.summary)
            Spacer(minLength: 4)
            if content.canEnd {
                EndSessionButton()
            } else if content.canReconnect {
                ReconnectLink()
            }
        }
    }
}

struct SessionCompactTrailing: View {
    let content: SessionActivityContent

    var body: some View {
        switch content.look {
        case .live, .paused:
            SessionClock(content: content, size: 13)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 46, alignment: .trailing)
        case .reconnecting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Farside.Palette.ash)
        case .ended:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Farside.Palette.bone)
        case .problem:
            Image(systemName: "exclamationmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Farside.Palette.bone)
        case .stale:
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Farside.Palette.ash)
        }
    }
}

/// iOS 27 shows the compact island in landscape too, where it cannot grow in width: the timer
/// becomes a ring or a dot. Earlier systems always use the narrow form.
@available(iOS 27.0, *)
struct LimitedWidthCompactTrailing: View {
    let content: SessionActivityContent
    @Environment(\.isDynamicIslandLimitedInWidth) private var limited

    var body: some View {
        if limited {
            SessionMinimalGlyph(content: content)
        } else {
            SessionCompactTrailing(content: content)
        }
    }
}

/// Never a bare logo: the minimal island always conveys the state.
struct SessionMinimalGlyph: View {
    let content: SessionActivityContent
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        switch content.look {
        case .live:
            Circle()
                .fill(reduced ? Farside.Palette.bone.opacity(0.85) : Farside.Palette.ember)
                .frame(width: 11, height: 11)
        case .paused:
            if let end = content.state.graceEndsAt, end > .now {
                ProgressView(timerInterval: Date.now...end, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: "pause.fill").font(.system(size: 8, weight: .semibold))
                }
                .progressViewStyle(.circular)
                .tint(Farside.Palette.bone)
            } else {
                Image(systemName: "pause.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Farside.Palette.bone)
            }
        case .reconnecting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Farside.Palette.ash)
        case .ended:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Farside.Palette.bone)
        case .problem:
            Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Farside.Palette.bone)
        case .stale:
            Image(systemName: "questionmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Farside.Palette.ash)
        }
    }
}

// MARK: - Pieces

/// Elapsed time while live, and the time left before Farside lets go while paused. Both are computed
/// by the system from dates, so the phone can be off the network the whole time.
struct SessionClock: View {
    let content: SessionActivityContent
    var size: CGFloat = 13

    var body: some View {
        clock
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .foregroundStyle(Farside.Palette.bone)
            .multilineTextAlignment(.trailing)
    }

    @ViewBuilder private var clock: some View {
        switch content.look {
        case .live:
            let started = content.attributes.startedAt
            Text(timerInterval: started...started.addingTimeInterval(8 * 3600), pauseTime: nil,
                 countsDown: false, showsHours: false)
        case .paused:
            if let end = content.state.graceEndsAt, end > .now {
                Text(timerInterval: Date.now...end, pauseTime: nil, countsDown: true, showsHours: false)
            }
        default:
            EmptyView()
        }
    }
}

/// A rounded tile with the state's glyph. Ember only for the live dot.
struct SessionGlyphTile: View {
    let look: SessionActivityContent.Look
    var size: CGFloat = 46
    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Farside.Palette.panel)
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Farside.Palette.line2, lineWidth: 1))
            .overlay { glyph }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch look {
        case .live:
            Circle()
                .fill(reduced ? Farside.Palette.bone.opacity(0.85) : Farside.Palette.ember)
                .frame(width: size * 0.3, height: size * 0.3)
                .shadow(color: Farside.Palette.ember.opacity(reduced ? 0 : 0.8), radius: size * 0.2)
        case .paused:
            symbol("pause.fill", Farside.Palette.bone)
        case .reconnecting:
            symbol("arrow.triangle.2.circlepath", Farside.Palette.ash)
        case .ended:
            symbol("checkmark", Farside.Palette.bone)
        case .problem:
            symbol("exclamationmark", Farside.Palette.bone)
        case .stale:
            symbol("questionmark", Farside.Palette.ash)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(color)
    }
}

/// The Farside pointer with its ember tip: the mark, small enough for the compact island.
struct FarsideMarkGlyph: View {
    var height: CGFloat = 16

    private struct Pointer: Shape {
        func path(in rect: CGRect) -> Path {
            let points: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 250), .init(x: 60, y: 196), .init(x: 98, y: 284),
                                     .init(x: 134, y: 268), .init(x: 96, y: 180), .init(x: 176, y: 180)]
            var path = Path()
            let scale = rect.height / 284
            path.addLines(points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
            path.closeSubpath()
            return path
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Pointer().fill(Farside.Palette.bone)
            Circle()
                .fill(Farside.Palette.ember)
                .frame(width: height * 0.3, height: height * 0.3)
                .offset(x: -height * 0.02, y: -height * 0.02)
        }
        .frame(width: height * 0.62, height: height)
        .accessibilityHidden(true)
    }
}

/// The only interactive element: it runs `EndSessionIntent` in the app process, so it works from a
/// locked phone. Ember, because ending is one of the two things ember is for.
struct EndSessionButton: View {
    var body: some View {
        Button(intent: EndSessionIntent()) {
            Text("End session")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Farside.Palette.void)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Farside.Palette.ember, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// After a timeout, a tap on the activity opens the app, which reconnects by itself. This says so.
struct ReconnectLink: View {
    var body: some View {
        Link(destination: SessionActivityLinks.session) {
            Text("Reconnect")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(Farside.Palette.line2, lineWidth: 1))
        }
    }
}

/// Sample content is labelled, as App Review asks.
struct SampleTag: View {
    var body: some View {
        Text("SAMPLE · PREVIEW")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(Farside.Palette.ash)
    }
}
