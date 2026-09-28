import SwiftUI

/// Keep section headings and controls accessible without the native GroupBox
/// title relationship that crashes the current computer-use tree reader.
struct HostSettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let palette = PocketDeskPalette.resolve(colorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
