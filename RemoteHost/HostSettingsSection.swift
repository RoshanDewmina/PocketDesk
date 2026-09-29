import SwiftUI

/// Grouped settings container that stands in for SwiftUI GroupBox and grouped Form, which
/// crash the current computer-use tree reader (Docs/CUA-GROUPBOX-BUG-REPORT.md).
struct HostSettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .hostCaption()
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(Farside.Palette.line)
                                .frame(height: 1)
                                .padding(.leading, 14)
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Farside.Palette.line, lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Farside.Palette.ash)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
