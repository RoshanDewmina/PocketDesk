import SwiftUI

struct HostSettingsView: View {
    let state: HostViewState
    let actions: HostActions
    @State private var confirmingRemoval = false
    @State private var confirmingServerRemoval = false
    @State private var showingNotices = false
    @State private var confirmingStop = false

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state)
        VStack(alignment: .leading, spacing: 18) {
            header(presentation)
            statusPanel(presentation)

            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        phoneSection
                        sharingSection
                        serverDataSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 18) {
                        permissionsSection
                        generalSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.bottom, 2)
            }
        }
        .padding(24)
        .frame(width: HostTheme.settingsWidth, height: HostTheme.settingsHeight)
        .background(HostTheme.windowBackground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingNotices) { LegalNoticesView() }
        .confirmationDialog("Remove this Mac’s server room?", isPresented: $confirmingServerRemoval) {
            Button("Remove Server Room", role: .destructive, action: actions.removeServerRoom)
        } message: {
            Text("Sharing stops now. Saved pairing is removed only after server confirmation. If the request fails, keep it and retry.")
        }
        .confirmationDialog("Stop sharing with \(PhoneDisplayName.inSentence(state.phoneName))?", isPresented: $confirmingStop) {
            Button("Stop Sharing", role: .destructive, action: actions.stopSharing)
            Button("Keep Sharing", role: .cancel) {}
        } message: {
            Text("It disconnects right away. You can share again from the menu bar.")
        }
        .confirmationDialog("Remove your paired phone locally?", isPresented: $confirmingRemoval) {
            Button("Remove Phone", role: .destructive, action: actions.removePhone)
        } message: {
            Text("It will no longer be able to connect. This removes local pairing, not server records. Use Server Data for server removal. It doesn’t cancel an Apple subscription.")
        }
    }

    private var phoneSection: some View {
        HostSettingsSection("Phone", footer: state.localPairRemovalMessage) {
            phoneRow
        }
    }

    private var sharingSection: some View {
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
            HostSettingsRow("Allow file transfer", subtitle: "Files from your iPhone go to Downloads › Farside") {
                HostSwitch(label: "Allow file transfer", isOn: state.allowFileTransfer, set: actions.setAllowFileTransfer)
                    .accessibilityIdentifier("farside.settings.allowFileTransfer")
            }
            HostSettingsRow("Hide this Mac’s screen", subtitle: HostCurtainCopy.subtitle(for: state)) {
                HostSwitch(label: "Hide this Mac’s screen", isOn: state.privacyCurtain,
                           set: actions.setPrivacyCurtain)
                    .accessibilityIdentifier("farside.settings.privacyCurtain")
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
    }

    private var serverDataSection: some View {
        HostSettingsSection("Server Data", footer: "Room removal does not cancel an Apple subscription. Purchase history remains for up to 90 days after access ends; security blocks and pending relay revocations may be retained.") {
            Button(state.serverRemovalBusy ? "Removing…" : (state.serverRemovalPending ? "Retry Server Room Removal…" : "Remove This Mac’s Server Room…"), role: .destructive) {
                confirmingServerRemoval = true
            }
            .disabled(state.serverRemovalBusy || (!state.hasPairedPhone && !state.serverRemovalPending))
            .accessibilityIdentifier("farside.settings.removeServerRoom")
            if let message = state.serverRemovalMessage { Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var permissionsSection: some View {
        HostSettingsSection("Permissions") {
            permissionRow("Screen Recording", reason: "So your iPhone can see the screen",
                          status: state.screenRecording, pane: .screenRecording)
            permissionRow("Accessibility", reason: "So your iPhone can click and type",
                          status: state.accessibility, pane: .accessibility)
        }
    }

    private var generalSection: some View {
        HostSettingsSection("General", footer: generalFooter) {
            HostSettingsRow("Show in menu bar", subtitle: HostMenuBarIconCopy.subtitle(shown: state.menuBarIconShown)) {
                HostSwitch(label: "Show in menu bar", isOn: state.menuBarIconShown, set: actions.setMenuBarIconShown)
                    .accessibilityIdentifier("farside.settings.showInMenuBar")
            }
            HostSettingsRow("Open at login", subtitle: HostBackgroundItemCopy.loginSubtitle(state.loginItem)) {
                backgroundItemAccessory(state.loginItem) {
                    HostSwitch(label: "Open at login", isOn: state.openAtLogin, set: actions.setOpenAtLogin)
                        .accessibilityIdentifier("farside.settings.openAtLogin")
                }
            }
            HostSettingsRow("Restart Farside if it quits",
                            subtitle: HostBackgroundItemCopy.recoverySubtitle(state.automaticRecovery)) {
                backgroundItemAccessory(state.automaticRecovery) {
                    HostSwitch(label: "Restart Farside if it quits", isOn: state.automaticRecovery.isRegistered,
                               set: actions.setAutomaticRecovery)
                        .accessibilityIdentifier("farside.settings.automaticRecovery")
                }
            }
            HostSettingsRow("Agent alerts (beta)",
                            subtitle: state.agentAlertsStatus ?? "Tell your iPhone when an agent needs you") {
                HostSwitch(label: "Agent alerts", isOn: state.agentAlerts, set: actions.setAgentAlerts)
                    .accessibilityIdentifier("farside.settings.agentAlerts")
            }
            if state.agentAlerts {
                HostSettingsRow("Agent hooks", subtitle: "Sends a kind and a hash, never an agent’s words") {
                    HStack(spacing: 8) {
                        Button("Copy Setup", action: actions.copyAgentHookSetup)
                            .accessibilityIdentifier("farside.settings.copyAgentHookSetup")
                        Button("Reset", action: actions.resetAgentAlertLink)
                            .accessibilityLabel("Reset the agent link")
                            .accessibilityIdentifier("farside.settings.resetAgentAlertLink")
                    }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                }
            }
            HostSettingsRow("Legal", subtitle: "Open-source software and fonts") {
                Button("View Notices…") { showingNotices = true }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
            }
            HostSettingsRow("Diagnostics", subtitle: "No screen content, typed text, clipboard, tokens or IP addresses") {
                Button("Copy Diagnostics", action: actions.copyDiagnostics)
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                    .accessibilityIdentifier("farside.settings.copyDiagnostics")
            }
            HostSettingsRow("Newest frame wins", subtitle: "Skip a frame the encoder can’t take yet instead of queueing it. Lower lag on a busy Mac") {
                HostSwitch(label: "Newest frame wins", isOn: state.newestFrameWins, set: actions.setNewestFrameWins)
                    .accessibilityIdentifier("farside.settings.newestFrameWins")
            }
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
        case .reconnecting: "Reconnecting"
        case .pairing: "Pairing"
        case .paused: state.pausedUntil == nil ? "Off" : "Paused"
        case .approvalRequested, .unavailable, .needsScreenRecording, .captureNeedsApproval, .needsPhone: "Needs attention"
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
                Spacer(minLength: 16)
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
            if let message = presentation.message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var generalFooter: String? {
        state.crashLoopStopped ? "Farside stopped after repeated crashes. Try Again above resumes sharing." : nil
    }

    @ViewBuilder
    private func backgroundItemAccessory<Switch: View>(_ item: HostBackgroundItemState,
                                                       @ViewBuilder toggle: () -> Switch) -> some View {
        HStack(spacing: 8) {
            if item == .needsApproval {
                Button("Allow…", action: actions.openLoginItems)
                    .buttonStyle(HostArrowButtonStyle())
                    .accessibilityLabel("Open Login Items in System Settings")
            }
            toggle()
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
        case .stopSharing where state.status.isSessionLive: confirmingStop = true
        case .stopSharing: actions.stopSharing()
        case .resumeNow, .resumeSharing, .tryAgain: actions.resumeSharing()
        case .allowPhone: actions.approvePhone()
        case .declinePhone: actions.declinePhone()
        case .finishSetup, .showCode: actions.openSetup()
        case .pairPhone: actions.pairNewPhone()
        case .openScreenRecording: actions.openSystemSettings(.screenRecording)
        }
    }
}
