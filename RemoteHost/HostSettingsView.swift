import SwiftUI

struct HostSettingsView: View {
    let state: HostViewState
    let actions: HostActions
    @State private var confirmingRemoval = false

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state)
        VStack(alignment: .leading, spacing: 18) {
            header(presentation)
            statusPanel(presentation)

            HostSettingsSection("Phone") {
                phoneRow
            }

            HostSettingsSection("While your iPhone is connected", footer: sessionFooter) {
                HostSettingsRow("Allow control", subtitle: state.controlNeedsAccessibility
                                ? "Needs Accessibility first" : "Off means view only") {
                    HostSwitch(label: "Allow control", isOn: state.allowControl, set: actions.setAllowControl)
                        .accessibilityIdentifier("farside.settings.allowControl")
                }
                HostSettingsRow("Keep this Mac awake", subtitle: "While sharing is on, so your iPhone can reach it") {
                    HostSwitch(label: "Keep this Mac awake", isOn: state.keepAwake, set: actions.setKeepAwake)
                        .accessibilityIdentifier("farside.settings.keepAwake")
                }
                HostSettingsRow("Chime when a phone connects", subtitle: "So you always know") {
                    HostSwitch(label: "Chime when a phone connects", isOn: state.chimeOnConnect,
                               set: actions.setChimeOnConnect)
                        .accessibilityIdentifier("farside.settings.chime")
                }
                if state.displays.count > 1 {
                    HostSettingsRow("Shared display") {
                        Picker("Shared display",
                               selection: Binding(get: { state.selectedDisplayID }, set: actions.selectDisplay)) {
                            ForEach(state.displays) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            HostSettingsSection("Permissions") {
                permissionRow("Screen Recording", reason: "So your iPhone can see the screen",
                              status: state.screenRecording, pane: .screenRecording)
                permissionRow("Accessibility", reason: "So your iPhone can click and type",
                              status: state.accessibility, pane: .accessibility)
            }

            HostSettingsSection("General") {
                HostSettingsRow("Open at login", subtitle: "Recommended, so Farside is back after a restart") {
                    HostSwitch(label: "Open at login", isOn: state.openAtLogin, set: actions.setOpenAtLogin)
                        .accessibilityIdentifier("farside.settings.openAtLogin")
                }
            }
        }
        .padding(24)
        .frame(width: HostTheme.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(HostTheme.windowBackground)
        .preferredColorScheme(.dark)
        .confirmationDialog("Remove your paired phone?", isPresented: $confirmingRemoval) {
            Button("Remove Phone", role: .destructive, action: actions.removePhone)
        } message: {
            Text("It will no longer be able to connect to this Mac. You can pair again at any time.")
        }
    }

    private func header(_ presentation: HostPopoverPresentation) -> some View {
        HStack(spacing: 10) {
            HostMarkView(height: 18, tipLit: presentation.mood == .live)
            HostWordmark(height: 13)
            Spacer()
            HStack(spacing: 6) {
                if presentation.mood == .live { HostLiveDot(size: 6) }
                Text(pillText(presentation)).hostCaption(10.5, color: presentation.mood == .live
                                                         ? Farside.Palette.bone : Farside.Palette.ash)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Farside.Palette.line2, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    private func pillText(_ presentation: HostPopoverPresentation) -> String {
        switch state.status {
        case .viewing, .controlling: "Live"
        case .ready: "Ready"
        case .starting: "Starting"
        case .pairing: "Pairing"
        case .paused: state.pausedUntil == nil ? "Off" : "Paused"
        case .approvalRequested, .unavailable, .needsScreenRecording, .needsPhone: "Needs attention"
        }
    }

    private func statusPanel(_ presentation: HostPopoverPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HostIconTile(systemImage: presentation.symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                    if let caption = presentation.caption {
                        Text(caption)
                            .hostCaption(10.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let message = presentation.message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Pairing lives in the Phone section below; don't offer it twice.
            let actions = presentation.actions.filter { $0 != .pairPhone }
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action.title) { perform(action) }
                            .buttonStyle(HostButtonStyle(kind: kind(presentation.emphasis(of: action)), height: 34))
                            .fixedSize()
                            .accessibilityIdentifier("farside.settings.\(action.identifier)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Farside.Palette.line, lineWidth: 1))
    }

    @ViewBuilder
    private var phoneRow: some View {
        if state.hasPairedPhone {
            HostSettingsRow("Your iPhone", subtitle: state.status.isSessionLive ? "Paired · connected now" : "Paired") {
                HStack(spacing: 8) {
                    Button("Pair New Phone…", action: actions.pairNewPhone)
                        .accessibilityIdentifier("farside.settings.pairNewPhone")
                    Button("Remove…") { confirmingRemoval = true }
                        .accessibilityIdentifier("farside.settings.removePhone")
                }
                .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
            }
        } else {
            HostSettingsRow("No phone paired", subtitle: "Pairing takes about a minute") {
                Button("Pair a Phone…", action: actions.pairNewPhone)
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 30))
                    .accessibilityIdentifier("farside.settings.pairNewPhone")
            }
        }
    }

    private var sessionFooter: String {
        state.controlNeedsAccessibility
            ? "Control also needs Accessibility for Farside."
            : "Closing the lid, restarting or logging out still stops sharing."
    }

    private func permissionRow(_ title: String, reason: String, status: HostPermissionStatus,
                               pane: HostSystemSettingsPane) -> some View {
        HostSettingsRow(title, subtitle: reason) {
            if status.isGranted {
                HostGrantedBadge()
            } else {
                Button("Open Settings") { actions.openSystemSettings(pane) }
                    .buttonStyle(HostArrowButtonStyle())
                    .accessibilityLabel("Open System Settings for \(title)")
            }
        }
    }

    private func kind(_ emphasis: HostPopoverPresentation.Emphasis) -> HostButtonStyle.Kind {
        switch emphasis {
        case .plate: .plate
        case .primary: .primary
        case .ember: .ember
        }
    }

    private func perform(_ action: HostPopoverAction) {
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
