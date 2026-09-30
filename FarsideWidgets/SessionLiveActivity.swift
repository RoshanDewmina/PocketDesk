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
    var islandLine: String { SessionActivityCopy.islandLine(for: state, macLabel: attributes.macLabel, stale: isStale) }
    var summary: String { SessionActivityCopy.accessibilitySummary(for: state, stale: isStale) }

    /// Live shows the time held, paused the time left before Farside lets go. Nothing else shows a clock.
    var hasClock: Bool {
        switch look {
        case .live: true
        case .paused: (state.graceEndsAt ?? .distantPast) > .now
        case .reconnecting, .ended, .problem, .stale: false
        }
    }

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

/// The words that name the state: a title and one plain line. They get the full width of their row, so
/// a title is never cut short by a button beside it.
struct SessionTextColumn: View {
    let content: SessionActivityContent
    /// The island has less height than the Lock Screen: two lines, and a shorter paused line.
    var forIsland = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.title)
                .font(.headline)
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(forIsland ? content.islandLine : content.line)
                .font(.subheadline)
                .foregroundStyle(Farside.Palette.ash)
                .lineLimit(forIsland ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.summary)
    }
}

/// The one button a state offers, if any: End while a session is open, Reconnect after a timeout.
struct SessionActionButton: View {
    let content: SessionActivityContent

    var body: some View {
        if content.canEnd {
            EndSessionButton()
        } else if content.canReconnect {
            ReconnectLink()
        }
    }
}

struct SessionLockScreenView: View {
    let content: SessionActivityContent

    private var hasSecondRow: Bool {
        content.canEnd || content.canReconnect || content.attributes.isPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SessionGlyphTile(look: content.look, size: 42)
                SessionTextColumn(content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if content.hasClock {
                    SessionClock(content: content, size: 19)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            if hasSecondRow {
                HStack(spacing: 10) {
                    if content.attributes.isPreview { SampleTag() }
                    Spacer(minLength: 6)
                    SessionActionButton(content: content)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Dynamic Island

/// The island's bottom region runs to the rounded corners, so it takes its own inset: text near a
/// corner would otherwise lose its first letters.
struct SessionExpandedBottom: View {
    let content: SessionActivityContent

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                SessionTextColumn(content: content, forIsland: true)
                if content.attributes.isPreview { SampleTag() }
            }
            Spacer(minLength: 4)
            SessionActionButton(content: content)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.bottom, 10)
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
