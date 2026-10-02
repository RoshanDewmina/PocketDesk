import SwiftUI

struct HostSettingsView: View {
    let state: HostViewState
    let actions: HostActions
    @State private var confirmingRemoval = false
    @State private var deviceToRemove: HostPairedDeviceRow?
    @State private var confirmingServerRemoval = false
    @State private var showingNotices = false
    @State private var confirmingStop = false
    @State private var showingWakeRegistration = false
    @State private var confirmingAwayMode = false
    @State private var choosingBackground = false

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state)
        VStack(alignment: .leading, spacing: 18) {
            header(presentation)
            statusPanel(presentation)
            if let warning = state.lockWarning {
                HostLockWarningBlock(warning: warning, awayAvailable: state.away.available,
                                     identifierPrefix: "farside.settings",
                                     openLockScreenSettings: actions.openLockScreenSettings,
                                     dismiss: actions.dismissLockWarning)
            }

            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        phoneSection
                        captureScopeSection
                        sharingSection
                        HostGuestSettingsView(state: state, actions: actions)
                        serverDataSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 18) {
                        permissionsSection
                        generalSection
                        availabilitySection
                        TransportPreferenceRows()
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
        .onAppear(perform: actions.refreshCaptureScopes)
        .sheet(isPresented: $showingNotices) { LegalNoticesView() }
        .sheet(isPresented: $choosingBackground) {
            HostConsentView(state: state) { choices in
                actions.confirmBackgroundChoices(choices.openAtLogin, choices.keepAwake)
                choosingBackground = false
            }
            .interactiveDismissDisabled()
        }
        .onChange(of: state.consentPending, initial: true) { _, pending in
            if pending && state.setupStep == .done { choosingBackground = true }
        }
        .sheet(isPresented: $showingWakeRegistration) {
            if let helper = state.wakeHelperHostID, let grant = state.wakeOwnerPairID {
                WakeTargetRegistrationView(helperHostID: helper, ownerPairID: grant, store: HostWakeTargetStore())
            }
        }
        .confirmationDialog(HostAwayCopy.introTitle, isPresented: $confirmingAwayMode) {
            Button(HostAwayCopy.introConfirm) { actions.setAwayMode(true) }
                .accessibilityIdentifier("farside.settings.awayModeConfirm")
            Button(HostAwayCopy.introCancel, role: .cancel) {}
        } message: {
            Text(HostAwayCopy.introBody.joined(separator: "\n\n"))
        }
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
        .confirmationDialog("Remove this paired device locally?", isPresented: $confirmingRemoval) {
            Button("Remove Device", role: .destructive) {
                if let deviceToRemove { actions.removePairedDevice(deviceToRemove.id) }
                else { actions.removePhone() }
                deviceToRemove = nil
            }
        } message: {
            Text("It will no longer be able to connect. This removes local pairing, not server records. Use Server Data for server removal. It doesn’t cancel an Apple subscription.")
        }
    }

    private var phoneSection: some View {
        HostSettingsSection("Devices", footer: state.localPairRemovalMessage) {
            phoneRow
            HostSettingsRow("Local network only", subtitle: "Enable on both devices to connect without internet. Changing it ends the current connection; sharing stays on.") {
                HostSwitch(label: "Local network only", isOn: state.localOnly, set: actions.setLocalOnly)
                    .accessibilityIdentifier("farside.settings.localOnly")
            }
        }
    }

    private var captureScopeSection: some View {
        HostSettingsSection("Shared content", footer: state.captureScopeNeedsSelection
            ? "Choose live content before sharing. A closed target never switches to your whole display."
            : "Changing content disconnects. Share again when ready. Apps and windows are view only; audio, control, clipboard, files, screen hiding and Big Text are off.") {
            HostSettingsRow("Content") {
                Picker("Shared content", selection: Binding(get: { state.selectedCaptureScopeID }, set: actions.selectCaptureScope)) {
                    if state.captureScopeNeedsSelection { Text("Choose content…").tag("unavailable") }
                    ForEach(state.captureScopes) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .accessibilityIdentifier("farside.settings.captureScope")
            }
            Button("Refresh apps and windows", action: actions.refreshCaptureScopes)
                .accessibilityIdentifier("farside.settings.refreshCaptureScopes")
        }
    }

    private var sharingSection: some View {
        HostSettingsSection("While your phone is connected", footer: sessionFooter) {
            HostSettingsRow("Allow control", subtitle: state.controlNeedsAccessibility
                            ? "Needs Accessibility first" : "Off means view only") {
                HostSwitch(label: "Allow control", isOn: state.allowControl, set: actions.setAllowControl)
                    .accessibilityIdentifier("farside.settings.allowControl")
                    .disabled(state.captureScopeViewOnly)
            }
            if state.away.available {
                awayModeRow
            }
            HostSettingsRow("Chime when a phone connects", subtitle: "So you always know") {
                HostSwitch(label: "Chime when a phone connects", isOn: state.chimeOnConnect,
                           set: actions.setChimeOnConnect)
                    .accessibilityIdentifier("farside.settings.chime")
            }
            HostSettingsRow("Allow phone to listen", subtitle: "Listen on your phone starts sound from all Mac apps. Turn this off to block it.") {
                HostSwitch(label: "Allow phone to listen", isOn: state.allowSystemAudio, set: actions.setAllowSystemAudio)
                    .accessibilityIdentifier("farside.settings.systemAudio")
                    .disabled(state.captureScopeViewOnly)
            }
            HostSettingsRow("Hide this Mac’s screen", subtitle: HostCurtainCopy.subtitle(for: state)) {
                HostSwitch(label: "Hide this Mac’s screen", isOn: state.privacyCurtain,
                           set: actions.setPrivacyCurtain)
                    .accessibilityIdentifier("farside.settings.privacyCurtain")
                    .disabled(state.captureScopeViewOnly)
            }
            HostSettingsRow("Allow a connected phone to change text size",
                            subtitle: "Big Text. Your Mac’s size comes back when the phone disconnects. Windows on other Spaces may stay smaller.") {
                HostSwitch(label: "Allow a connected phone to change text size", isOn: state.allowBigText,
                           set: actions.setAllowBigText)
                    .accessibilityIdentifier("farside.settings.allowBigText")
                    .disabled(state.captureScopeViewOnly)
            }
            if state.displays.count > 1 && !state.captureScopeViewOnly {
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

    private var awayModeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostSettingsRow(HostAwayCopy.settingTitle, subtitle: HostAwayCopy.settingSubtitle) {
                HostSwitch(label: HostAwayCopy.settingTitle, isOn: state.awayMode, set: setAwayMode)
                    .accessibilityIdentifier("farside.settings.awayMode")
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let warning = HostAwayCopy.warningLine(state.away, now: context.date) {
                    HStack(spacing: 12) {
                        Text(warning)
                            .font(.system(size: 12))
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("farside.settings.awayWarning")
                        Spacer(minLength: 12)
                        if state.away.unavailable == .needsAccessibility {
                            Button("Open Settings") { actions.openSystemSettings(.accessibility) }
                                .buttonStyle(HostArrowButtonStyle())
                                .accessibilityLabel("Open System Settings for Accessibility")
                                .accessibilityIdentifier("farside.settings.awayAccessibility")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
                }
            }
        }
    }

    private func setAwayMode(_ isOn: Bool) {
        if isOn && !state.awayIntroShown {
            confirmingAwayMode = true
        } else {
            actions.setAwayMode(isOn)
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

    private var availabilitySection: some View {
        HostSettingsSection("Availability", footer: "Start at login and recovery apply after you log in. Farside never stores your Mac password or unlocks FileVault. Virtual workspace is unavailable in this build.") {
            HostSettingsRow("Keep this Mac awake",
                            subtitle: HostKeepAwakeCopy.subtitle(pausedOnBattery: state.keepAwakePausedOnBattery)) {
                HostSwitch(label: "Keep this Mac awake", isOn: state.keepAwake, set: actions.setKeepAwake)
                    .accessibilityIdentifier("farside.settings.keepAwake")
            }
            if let hostID = state.wakeHelperHostID, state.wakeOwnerPairID != nil {
                HostSettingsRow("This Mac’s durable host ID", subtitle: "Copy locally to an owner-configured powered helper. This ID is not permission to connect.") {
                    Text(hostID).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Register another Mac for LAN wake") { showingWakeRegistration = true }
                    .accessibilityIdentifier("farside.settings.wakeRegistration")
            }
            HostSettingsRow("Awake and unlocked", subtitle: "A current authenticated connection and fresh content are required.") { EmptyView() }
            HostSettingsRow("Display asleep", subtitle: "Farside can request display wake while this user’s Mac is awake.") { EmptyView() }
            HostSettingsRow("System sleep or closed lid", subtitle: "Needs supported network wake and another powered LAN peer. Packet sent does not mean awake.") { EmptyView() }
            HostSettingsRow("Locked or switched user", subtitle: "Sharing stops. Unlock or return to this user at the Mac.") { EmptyView() }
            HostSettingsRow("Logout, restart or FileVault", subtitle: "Unavailable until this user logs in and normal permissions allow sharing.") { EmptyView() }
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
            HostSettingsRow("Open at login",
                            subtitle: HostBackgroundItemCopy.loginSubtitle(wanted: state.openAtLogin, state: state.loginItem)) {
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
            ForEach(state.diagnosticReports) { report in
                DisclosureGroup("Local report · \(report.outcome.rawValue)") {
                    Text(report.preview).font(.footnote).textSelection(.enabled)
                    ShareLink(item: report.preview) { Label("Export this preview", systemImage: "square.and.arrow.up") }
                    Button("Delete report", role: .destructive) { actions.deleteDiagnosticReport(report.id) }
                }.accessibilityIdentifier("farside.settings.localReport")
            }
            Text("Local reports expire after 7 days, up to 10 reports. Nothing is uploaded automatically.").font(.footnote)
            HostSettingsRow("Compatibility video encoder", subtitle: "Use the previous encoder if the new picture has trouble. Applies to your next connection") {
                HostSwitch(label: "Compatibility video encoder", isOn: state.compatibilityVideoEncoder, set: actions.setCompatibilityVideoEncoder)
                    .accessibilityIdentifier("farside.settings.compatibilityVideoEncoder")
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
        if !state.pairedDevices.isEmpty {
            ForEach(state.pairedDevices) { device in
                HostSettingsRow(device.name, subtitle: deviceSubtitle(device)) {
                    Button("Remove…") { deviceToRemove = device; confirmingRemoval = true }
                        .accessibilityLabel("Remove \(device.name)")
                        .accessibilityIdentifier("farside.settings.removeDevice.\(device.id)")
                        .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                }
            }
            Button("Pair Another Device…", action: actions.pairNewPhone)
                .accessibilityIdentifier("farside.settings.pairNewPhone")
                .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
            Text("Up to five devices. Disconnect one before connecting another.")
                .font(.system(size: 12)).foregroundStyle(Farside.Palette.ash)
        } else {
            HostSettingsRow("No device paired", subtitle: "Pairing takes about a minute") {
                Button("Pair a Device…", action: actions.pairNewPhone)
                    .buttonStyle(HostButtonStyle(kind: .primary, height: 30))
                    .accessibilityIdentifier("farside.settings.pairNewPhone")
            }
        }
    }

    private func deviceSubtitle(_ device: HostPairedDeviceRow) -> String {
        if device.connected { return "Paired · connected now" }
        guard let date = device.lastUsed else { return "Paired" }
        return "Last used " + date.formatted(date: .abbreviated, time: .shortened)
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
