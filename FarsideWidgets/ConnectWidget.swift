import SwiftUI
import WidgetKit

/// Home Screen shortcut to the Connect prompt. It shows no Mac state and starts nothing: a tap opens
/// Farside, which asks "Connect to …?" before anything reaches the Mac. The extension cannot read the
/// pairing, so it names no Mac and never claims one is awake.
struct ConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ConnectWidgetLink.kind, provider: ConnectWidgetProvider()) { _ in
            ConnectWidgetView()
                .containerBackground(Farside.Palette.void, for: .widget)
                .widgetURL(ConnectWidgetLink.url)
        }
        .configurationDisplayName("Connect to Mac")
        .description("Opens Farside ready to connect. Nothing connects until you tap Connect.")
        .supportedFamilies([.systemSmall])
    }
}

struct ConnectWidgetEntry: TimelineEntry {
    let date: Date
}

struct ConnectWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConnectWidgetEntry { ConnectWidgetEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ConnectWidgetEntry) -> Void) {
        completion(ConnectWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConnectWidgetEntry>) -> Void) {
        completion(Timeline(entries: [ConnectWidgetEntry(date: .now)], policy: .never))
    }
}

/// The Connect pill in miniature: the mark, the word, and the ember arrow that closes the gap.
struct ConnectWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FarsideMarkGlyph(height: 24)
            Spacer(minLength: 8)
            Text("Connect")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
            Text("Your Mac")
                .font(Farside.Typeface.caption())
                .foregroundStyle(Farside.Palette.ash)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.right")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Farside.Palette.ember)
                .frame(width: 40, height: 40)
                .background(Farside.Palette.panel2, in: .circle)
                .overlay(Circle().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connect to your Mac")
        .accessibilityHint("Opens Farside. Nothing connects until you tap Connect.")
    }
}
