import SwiftUI

/// Open at login and keep-awake, each explained on its own and chosen explicitly. Current choices
/// start filled in; nothing changes until Continue or Keep current settings.
struct HostConsentView: View {
    let confirm: (HostConsentChoices) -> Void
    var cancel: (() -> Void)?
    private let current: HostConsentChoices
    @State private var draft: HostConsentChoices

    init(state: HostViewState, confirm: @escaping (HostConsentChoices) -> Void, cancel: (() -> Void)? = nil) {
        self.confirm = confirm
        self.cancel = cancel
        current = HostConsentChoices(state)
        _draft = State(initialValue: HostConsentChoices(state))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Two choices"), .plain(". "), .accent("Both"), .display(" yours"), .plain(".")],
                        size: 26)
            paragraph(HostConsentCopy.intro, size: 13.5)
                .padding(.top, 6)
            VStack(spacing: 10) {
                choice(symbol: "power", title: HostConsentCopy.loginTitle, body: HostConsentCopy.loginBody,
                       isOn: $draft.openAtLogin, identifier: "farside.consent.openAtLogin")
                choice(symbol: "moon.zzz", title: HostConsentCopy.keepAwakeTitle, body: HostConsentCopy.keepAwakeBody,
                       note: HostConsentCopy.alwaysTrue, isOn: $draft.keepAwake, identifier: "farside.consent.keepAwake")
            }
            .padding(.top, 16)
            HStack(spacing: 10) {
                Spacer()
                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(HostButtonStyle(kind: .plate, height: 34))
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(HostConsentCopy.keepCurrent) { confirm(current) }
                        .buttonStyle(HostButtonStyle(kind: .plate, height: 34))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("farside.consent.keepCurrent")
                }
                Button(HostConsentCopy.confirm) { confirm(draft) }
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 34))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.consent.continue")
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 640)
        .background(HostTheme.windowBackground)
        .preferredColorScheme(.dark)
    }

    private func choice(symbol: String, title: String, body: String, note: String? = nil,
                        isOn: Binding<Bool>, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HostIconTile(systemImage: symbol, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Farside.Palette.bone)
                paragraph(body, size: 12.5)
                if let note {
                    paragraph(note, size: 12.5, color: Farside.Palette.bone)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            HostSwitch(label: title, isOn: isOn.wrappedValue, set: { isOn.wrappedValue = $0 })
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(HostPlate())
    }

    private func paragraph(_ text: String, size: CGFloat, color: Color = Farside.Palette.ash) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(color)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}
