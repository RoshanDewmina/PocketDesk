import SwiftUI
import WidgetKit

/// The same one-tap action in Control Center, Lock Screen and the Action button.
struct ConnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: FarsideControlConnect.kind, provider: ConnectControlProvider()) { title in
            ControlWidgetButton(action: ControlConnectIntent()) {
                Label(title, systemImage: "desktopcomputer")
            }
        }
        .displayName("Connect to Mac")
        .description("Opens Farside to connect to your paired Mac.")
    }
}

struct ConnectControlProvider: ControlValueProvider {
    var previewValue: String { FarsideControlConnect.title(snapshot: nil) }
    func currentValue() async throws -> String {
        FarsideControlConnect.title(snapshot: MacWidgetSnapshot.load())
    }
}

/// Home Screen shortcut to the Connect prompt. It starts nothing: a tap opens Farside, which asks
/// "Connect to …?" before anything reaches the Mac. It shows the Mac's name and the last presence the
/// app observed, with its age, from the App Group snapshot; with no snapshot it says "Your Mac".
struct ConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ConnectWidgetLink.kind, provider: ConnectWidgetProvider()) { entry in
            ConnectWidgetView(snapshot: entry.snapshot)
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
    var snapshot: MacWidgetSnapshot?
}

/// The app reloads this timeline whenever it stores a new snapshot, so it never polls.
struct ConnectWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConnectWidgetEntry { ConnectWidgetEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ConnectWidgetEntry) -> Void) {
        completion(ConnectWidgetEntry(date: .now, snapshot: context.isPreview ? nil : MacWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConnectWidgetEntry>) -> Void) {
        completion(Timeline(entries: [ConnectWidgetEntry(date: .now, snapshot: MacWidgetSnapshot.load())], policy: .never))
    }
}

/// The Connect pill in miniature: the mark, the word, and the ember arrow that closes the gap.
struct ConnectWidgetView: View {
    var snapshot: MacWidgetSnapshot?

    private var macName: String { snapshot?.macName ?? "Your Mac" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FarsideMarkGlyph(height: 24)
            Spacer(minLength: 8)
            Text("Connect")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
            Text(macName)
                .font(Farside.Typeface.caption())
                .foregroundStyle(Farside.Palette.ash)
                .lineLimit(1)
                .padding(.top, 2)
            if let presence = snapshot?.presence, let at = snapshot?.presenceAt {
                Text("\(presence.label) · \(Text(at, style: .relative))")
                    .font(Farside.Typeface.caption(.caption2))
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.trailing, 44)
            }
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens Farside. Nothing connects until you tap Connect.")
    }

    private var accessibilityLabel: String {
        guard let presence = snapshot?.presence, let at = snapshot?.presenceAt else { return "Connect to " + macName }
        let age = at.formatted(.relative(presentation: .named))
        return "Connect to " + macName + ". Last seen " + presence.label.lowercased() + ", " + age
    }
}
