import SwiftUI

/// Open at login and keep-awake, each explained on its own and chosen explicitly. Prior choices
/// start filled in; nothing changes until Continue.
struct HostConsentView: View {
    let confirm: (_ openAtLogin: Bool, _ keepAwake: Bool) -> Void
    var cancel: (() -> Void)?
    @State private var openAtLogin: Bool
    @State private var keepAwake: Bool

    init(state: HostViewState, confirm: @escaping (_ openAtLogin: Bool, _ keepAwake: Bool) -> Void,
         cancel: (() -> Void)? = nil) {
        self.confirm = confirm
        self.cancel = cancel
        _openAtLogin = State(initialValue: state.openAtLogin)
        _keepAwake = State(initialValue: state.keepAwake)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeading(parts: [.display("Two choices"), .plain(". "), .accent("Both"), .display(" yours"), .plain(".")],
                        size: 28)
            paragraph(HostConsentCopy.intro, size: 14)
                .padding(.top, 8)
            VStack(spacing: 10) {
                choice(symbol: "power", title: HostConsentCopy.loginTitle, body: HostConsentCopy.loginBody,
                       isOn: $openAtLogin, identifier: "farside.consent.openAtLogin")
                choice(symbol: "moon.zzz", title: HostConsentCopy.keepAwakeTitle, body: HostConsentCopy.keepAwakeBody,
                       note: HostConsentCopy.alwaysTrue, isOn: $keepAwake, identifier: "farside.consent.keepAwake")
            }
            .padding(.top, 18)
            HStack(spacing: 10) {
                Spacer()
                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(HostButtonStyle(kind: .plate, height: 34))
                        .keyboardShortcut(.cancelAction)
                }
                Button(HostConsentCopy.confirm) { confirm(openAtLogin, keepAwake) }
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 34))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.consent.continue")
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 580)
        .background(HostTheme.windowBackground)
        .preferredColorScheme(.dark)
    }

    private func choice(symbol: String, title: String, body: String, note: String? = nil,
                        isOn: Binding<Bool>, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HostIconTile(systemImage: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Farside.Palette.bone)
                paragraph(body, size: 12.5)
                if let note {
                    paragraph(note, size: 12.5, color: Farside.Palette.bone)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            HostSwitch(label: title, isOn: isOn.wrappedValue, set: { isOn.wrappedValue = $0 })
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(HostPlate())
    }

    private func paragraph(_ text: String, size: CGFloat, color: Color = Farside.Palette.ash) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
