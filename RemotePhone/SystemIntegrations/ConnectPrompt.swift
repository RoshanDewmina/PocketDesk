import SwiftUI

/// Where the Home Screen Connect widget and `farside://open` links land: a question, never a
/// connection. Nothing reaches the Mac until the person taps Connect here.
struct ConnectPromptSheet: View {
    let macName: String
    var connect: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            FarsideHeading("Connect to \(macName)?", size: 30)
            Text("Opens your Mac’s screen on this iPhone. Nothing reaches your Mac until you tap Connect.")
                .font(.body)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: Farside.Space.xs) {
                Button("Connect", action: connect)
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                    .accessibilityHint("Opens your Mac’s screen on this iPhone")
                    .accessibilityIdentifier("connectPrompt.connect")
                Button("Not now", action: close)
                    .buttonStyle(FarsideLinkButtonStyle())
                    .accessibilityIdentifier("connectPrompt.close")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Farside.Space.l)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(FarsideBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectPrompt")
    }

    /// Only a paired, idle phone is asked. A live or starting session is already where the link points.
    static func macName(paired name: String?, connected: Bool, running: Bool) -> String? {
        guard !connected, !running else { return nil }
        return name
    }
}
