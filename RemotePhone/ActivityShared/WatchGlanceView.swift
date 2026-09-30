import SwiftUI

/// The `.small` Live Activity family (Watch Smart Stack and CarPlay). It never acts: no controls, and
/// no ember or motion, because a Watch face may tint it and it must read the same on Always-On.
struct WatchGlanceView: View {
    let glance: WatchGlance

    private typealias M = WatchGlanceMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: M.lineSpacing) {
            HStack(spacing: M.glyphSpacing) {
                mark
                HStack(spacing: 0) {
                    Text(glance.title)
                        .layoutPriority(1)
                    if let suffix = glance.sensitiveTitleSuffix {
                        Text(verbatim: " · " + suffix)
                            .privacySensitive()
                    }
                }
                .font(.system(size: M.titleSize, weight: .semibold))
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(1)
                .minimumScaleFactor(M.titleMinimumScale)
            }
            detail
                .foregroundStyle(Farside.Palette.ash)
                .lineLimit(1)
                .minimumScaleFactor(M.lineMinimumScale)
                .privacySensitive()
            if let note = glance.note {
                Text(note)
                    .font(.system(size: M.noteSize, weight: .medium))
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(M.lineMinimumScale)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, M.horizontalPadding)
        .padding(.vertical, M.verticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glance.accessibilityLabel)
    }

    private var mark: some View {
        ZStack {
            if glance.mark == .needsYou {
                Circle().strokeBorder(Farside.Palette.bone, lineWidth: 1.5)
            }
            FarsideMarkGlyph(height: M.glyphHeight, tip: Farside.Palette.bone)
        }
        .frame(width: M.ringDiameter, height: M.ringDiameter)
    }

    @ViewBuilder private var detail: some View {
        switch glance.detail {
        case .text(let text):
            Text(text)
                .font(.system(size: M.detailSize, weight: .medium))
        case .clock(let prefix, let interval, let countsDown):
            let timer = Text(timerInterval: interval, pauseTime: nil, countsDown: countsDown, showsHours: false)
            Group {
                if let prefix {
                    Text("\(prefix) \(timer)")
                } else {
                    timer
                }
            }
            .font(.system(size: M.detailSize, weight: .medium).monospacedDigit())
        }
    }
}

private enum WatchGlancePreview {
    static func framed(_ glance: WatchGlance) -> some View {
        WatchGlanceView(glance: glance)
            .frame(width: 152, height: 69.5)
            .background(Farside.Palette.void)
    }
}

#Preview("Live session") {
    let now = Date.now
    WatchGlancePreview.framed(WatchGlance(
        mark: .plain, title: "Live",
        detail: .clock(prefix: nil, interval: now.addingTimeInterval(-724)...now.addingTimeInterval(8 * 3600), countsDown: false),
        note: "End it on your iPhone.", accessibilityLabel: "Live on Your Mac",
        sensitiveTitleSuffix: "Your Mac"))
}

#Preview("Paused") {
    let now = Date.now
    WatchGlancePreview.framed(WatchGlance(
        mark: .plain, title: "Paused",
        detail: .clock(prefix: "Lets go in", interval: now...now.addingTimeInterval(42), countsDown: true),
        note: nil, accessibilityLabel: "Paused"))
}

#Preview("Needs you, with a Mac line") {
    let now = Date.now
    WatchGlancePreview.framed(WatchGlance(
        mark: .needsYou, title: "An agent needs you",
        detail: .clock(prefix: "Waiting", interval: now.addingTimeInterval(-134)...now.addingTimeInterval(3600), countsDown: false),
        note: "Mac · seen 11:41 · 64%", accessibilityLabel: "An agent needs you"))
}
