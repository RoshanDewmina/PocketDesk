import SwiftUI

/// What the quality banner says, if anything: one observed condition and one fix, only while the
/// picture is losing frames or stalling about once a second, and never for a condition the person
/// already dismissed this session.
struct QualityBannerContent: Equatable {
    enum Key: Hashable {
        case poor(ConnectionQualityCause)
        case stall
    }

    var key: Key
    var symbol: String
    var title: String
    var fix: String

    static func make(connected: Bool, verdict: ConnectionQualityVerdict?, stall: WiFiStallTip?,
                     dismissed: Set<Key>, device: String) -> QualityBannerContent? {
        guard connected else { return nil }
        if let verdict, !dismissed.contains(.poor(verdict.cause)) {
            return QualityBannerContent(key: .poor(verdict.cause),
                                        symbol: verdict.cause == .relay ? "arrow.triangle.branch"
                                            : verdict.cause == .unknown ? "exclamationmark.triangle" : "wifi.exclamationmark",
                                        title: verdict.title(device: device), fix: verdict.fix)
        }
        if verdict == nil, let stall, !dismissed.contains(.stall) {
            return QualityBannerContent(key: .stall, symbol: "wifi.exclamationmark", title: stall.title, fix: stall.fix(device: device))
        }
        return nil
    }
}

/// GeForce NOW-style "appears only on trouble" banner. Tapping it hides that condition for the
/// rest of the session; the dock line and Diagnostics keep reporting it.
struct ConnectionQualityBanner: View {
    let content: QualityBannerContent?
    var dismiss: (QualityBannerContent.Key) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let content {
                plate(content)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.reveal(0.6), value: content)
        .onChange(of: content?.key) { _, key in
            guard key != nil, let content else { return }
            AccessibilityNotification.Announcement("\(content.title). \(content.fix)").post()
        }
    }

    private func plate(_ content: QualityBannerContent) -> some View {
        Button { dismiss(content.key) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: content.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.ash)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Farside.Palette.bone)
                    Text(content.fix)
                        .font(Farside.Typeface.caption(.footnote))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.96), stroke: Farside.Palette.line2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(content.title). \(content.fix)")
        .accessibilityHint("Hides this for the rest of the session.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("remote.qualityBanner")
    }
}
