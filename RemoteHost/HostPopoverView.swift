import SwiftUI

/// The menu-bar popover: a halftone strip naming the state, who is steering, the two session
/// toggles, this state's actions, then Settings… · Pair a phone… · Quit.
struct HostPopoverView: View {
    let state: HostViewState
    let actions: HostActions
    /// Fixed time for review renders; the live popover uses the current time.
    var now: Date?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state, now: now ?? Date())
        VStack(alignment: .leading, spacing: 0) {
            HostPopoverStrip(presentation: presentation)
            VStack(alignment: .leading, spacing: 0) {
                who(presentation)
                if let message = presentation.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                if presentation.showsSessionToggles {
                    sessionToggles
                        .padding(.top, 12)
                }
                actionRow(presentation)
                    .padding(.top, presentation.showsSessionToggles ? 12 : 16)
                footer
                    .padding(.top, 14)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
        .frame(width: HostTheme.popoverWidth)
        .background(HostTheme.popoverBackground)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("farside.popover")
    }

    private func who(_ presentation: HostPopoverPresentation) -> some View {
        HStack(spacing: 12) {
            HostIconTile(systemImage: presentation.symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Farside.Palette.bone)
                if let caption = presentation.caption {
                    Text(caption)
                        .hostCaption(10.5)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([presentation.title, presentation.spokenCaption ?? presentation.caption]
            .compactMap { $0 }.joined(separator: ". "))
    }

    private var sessionToggles: some View {
        HostHairlineList {
            VStack(alignment: .leading, spacing: 6) {
                HostToggleRow(title: "Allow control",
                              subtitle: state.controlNeedsAccessibility ? "Needs Accessibility first" : "Off means view only",
                              isOn: state.allowControl, set: actions.setAllowControl)
                    .accessibilityIdentifier("farside.popover.allowControl")
                if state.controlNeedsAccessibility {
                    Button("Allow in System Settings…") {
                        dismiss()
                        actions.openSystemSettings(.accessibility)
                    }
                    .buttonStyle(HostButtonStyle(kind: .inline))
                    .accessibilityIdentifier("farside.popover.allowAccessibility")
                }
            }
            HostToggleRow(title: "Chime when a phone connects", subtitle: "So you always know",
                          isOn: state.chimeOnConnect, set: actions.setChimeOnConnect)
                .accessibilityIdentifier("farside.popover.chime")
        }
    }

    private func actionRow(_ presentation: HostPopoverPresentation) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { index, action in
                let button = Button(action.title) { perform(action) }
                    .buttonStyle(HostButtonStyle(kind: kind(presentation.emphasis(of: action)), fullWidth: true))
                    .accessibilityIdentifier("farside.popover.\(action.identifier)")
                    .hostDefaultAction(index == presentation.actions.count - 1
                                       && presentation.emphasis(of: action) == .primary)
                if presentation.actions.count > 1 && index == 0 {
                    button.frame(width: 146)
                } else {
                    button.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                dismiss()
                actions.openSettings()
            }
            .keyboardShortcut(",")
            .accessibilityIdentifier("farside.popover.settings")
            Spacer()
            Button("Pair a phone…") {
                dismiss()
                actions.pairNewPhone()
            }
            .accessibilityIdentifier("farside.popover.pairAPhone")
            Spacer()
            Button("Quit", action: actions.quit)
                .keyboardShortcut("q")
                .accessibilityLabel("Quit Farside")
                .accessibilityIdentifier("farside.popover.quit")
        }
        .buttonStyle(HostButtonStyle(kind: .link))
    }

    private func kind(_ emphasis: HostPopoverPresentation.Emphasis) -> HostButtonStyle.Kind {
        switch emphasis {
        case .plate: .plate
        case .primary: .primary
        case .ember: .ember
        }
    }

    private func perform(_ action: HostPopoverAction) {
        if action.leavesPopover { dismiss() }
        switch action {
        case .pause: actions.pauseSharing()
        case .stopSharing: actions.stopSharing()
        case .resumeNow, .resumeSharing, .tryAgain: actions.resumeSharing()
        case .allowPhone: actions.approvePhone()
        case .declinePhone: actions.declinePhone()
        case .finishSetup, .showCode: actions.openSetup()
        case .pairPhone: actions.pairNewPhone()
        }
    }
}

/// The strip across the top of the popover. The caption sits on a solid plate, never on dots.
struct HostPopoverStrip: View {
    let presentation: HostPopoverPresentation

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HostHalftoneArt(scene: .popoverStrip(mood))
            HStack(spacing: 8) {
                if presentation.mood == .live { HostLiveDot() }
                Text(presentation.headline)
                    .hostCaption(11, color: Farside.Palette.bone)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Farside.Palette.void, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.leading, 8)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(Farside.Palette.void)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.headline)
    }

    private var mood: HostHalftoneMood {
        switch presentation.mood {
        case .live: .live
        case .calm: .calm
        case .paused: .paused
        case .attention: .attention
        }
    }
}
