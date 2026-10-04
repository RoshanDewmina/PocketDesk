import SwiftUI

/// Settings pages, in sidebar order. Overview answers "is it working?"; everything else is one click away.
enum HostSettingsPage: String, CaseIterable, Identifiable {
    case overview, devices, sharing, mac, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .devices: "Devices"
        case .sharing: "Sharing"
        case .mac: "This Mac"
        case .advanced: "Advanced"
        }
    }

    var summary: String? {
        switch self {
        case .overview: nil
        case .devices: "The devices that can connect to this Mac."
        case .sharing: "What a connected phone can see and do."
        case .mac: "Permissions, and keeping this Mac ready for your phone."
        case .advanced: "Troubleshooting and experiments. You shouldn’t need these."
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .devices: "ipad.and.iphone"
        case .sharing: "rectangle.on.rectangle"
        case .mac: "laptopcomputer"
        case .advanced: "slider.horizontal.3"
        }
    }

    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

struct HostSettingsView: View {
    let state: HostViewState
    let actions: HostActions
    @State private var page: HostSettingsPage
    @State private var confirmingRemoval = false
    @State private var deviceToRemove: HostPairedDeviceRow?
    @State private var confirmingServerRemoval = false
    @State private var showingNotices = false
    @State private var confirmingStop = false
    @State private var showingWakeRegistration = false
    @State private var confirmingAwayMode = false
    @State private var choosingBackground = false
    @State private var showingAvailability = false

    init(state: HostViewState, actions: HostActions, page: HostSettingsPage = .overview) {
        self.state = state
        self.actions = actions
        _page = State(initialValue: page)
    }

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state)
        HStack(spacing: 0) {
            sidebar(presentation)
            Rectangle().fill(Farside.Palette.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeader
                    pageContent(presentation)
                }
                .frame(maxWidth: 640, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .id(page)
        }
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
            Text("It will no longer be able to connect. This removes local pairing, not server records. Use Server Data in Advanced for server removal. It doesn’t cancel an Apple subscription.")
        }
    }

    // MARK: Sidebar

    private func sidebar(_ presentation: HostPopoverPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                HostMarkView(height: 18, tipLit: presentation.mood == .live)
                HostWordmark(height: 13)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .accessibilityHidden(true)

            ForEach(HostSettingsPage.allCases) { item in
                sidebarItem(item)
            }

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if presentation.mood == .live { HostLiveDot(size: 6) }
                    Text(pillText).hostCaption(10.5, color: presentation.mood == .live
                                               ? Farside.Palette.bone : Farside.Palette.ash)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Farside.Palette.line2, lineWidth: 1))
                Text(state.macName)
                    .font(.system(size: 12))
                    .foregroundStyle(Farside.Palette.ash)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
        .frame(width: 216, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(HostTheme.railBackground)
    }

    private func sidebarItem(_ item: HostSettingsPage) -> some View {
        let selected = page == item
        return Button {
            page = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Farside.Palette.bone : Farside.Palette.ash)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Farside.Palette.bone : Farside.Palette.bone.opacity(0.78))
                Spacer(minLength: 4)
                sidebarBadge(item)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Farside.Palette.panel2)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Farside.Palette.line, lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(item.shortcut, modifiers: .command)
        .accessibilityLabel(item.title)
        .accessibilityValue(sidebarBadgeDescription(item) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("farside.settings.page.\(item.rawValue)")
    }

    @ViewBuilder
    private func sidebarBadge(_ item: HostSettingsPage) -> some View {
        switch item {
        case .overview where state.lockWarning != nil, .mac where macNeedsAttention:
            Circle().fill(Farside.Palette.ember).frame(width: 7, height: 7)
        case .devices where !state.pairedDevices.isEmpty:
            Text("\(state.pairedDevices.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Farside.Palette.ash)
        default:
            EmptyView()
        }
    }

    private func sidebarBadgeDescription(_ item: HostSettingsPage) -> String? {
        switch item {
        case .overview where state.lockWarning != nil, .mac where macNeedsAttention: "Needs attention"
        case .devices where !state.pairedDevices.isEmpty: "\(state.pairedDevices.count) paired"
        default: nil
        }
    }

    private var macNeedsAttention: Bool {
        !state.screenRecording.isGranted || state.controlNeedsAccessibility
            || state.loginItem == .needsApproval || state.automaticRecovery == .needsApproval
            || !state.permissionsTurnedOffByUpdate.isEmpty
    }

    private var pillText: String {
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

    // MARK: Pages

    @ViewBuilder
    private var pageHeader: some View {
        if page != .overview {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                        .accessibilityAddTraits(.isHeader)
                    if let summary = page.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(Farside.Palette.ash)
                    }
                }
                Spacer(minLength: 16)
                if page == .devices && !state.pairedDevices.isEmpty {
                    Button("Pair Another Device…", action: actions.pairNewPhone)
                        .buttonStyle(HostButtonStyle(kind: .plate, height: 32))
                        .fixedSize()
                        .accessibilityIdentifier("farside.settings.pairNewPhone")
                }
            }
        }
    }

    @ViewBuilder
    private func pageContent(_ presentation: HostPopoverPresentation) -> some View {
        switch page {
        case .overview:
            statusHero(presentation)
            if let warning = state.lockWarning { lockBanner(warning) }
            readyChecklist
        case .devices:
            devicesSection
            connectionSection
            if state.guestViewingAvailable || !state.guestRows.isEmpty {
                HostGuestSettingsView(state: state, actions: actions)
            }
        case .sharing:
            captureScopeSection
            controlSection
            privacySection
        case .mac:
            permissionsSection
            reachableSection
            menuBarSection
            availabilityDisclosure
        case .advanced:
            agentAlertsSection
            troubleshootingSection
            TransportPreferenceRows()
            serverDataSection
            aboutSection
        }
    }

    // MARK: Overview

    private func statusHero(_ presentation: HostPopoverPresentation) -> some View {
        let live = presentation.mood == .live
        let heroActions = presentation.actions.filter { $0 != .pairPhone || state.pairedDevices.isEmpty }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                HostIconTile(systemImage: presentation.symbol, size: 56)
                    .overlay {
                        if live {
                            RoundedRectangle(cornerRadius: 56 * 0.3, style: .continuous)
                                .strokeBorder(Farside.Palette.ember.opacity(0.7), lineWidth: 1)
                        }
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    statusLine(presentation)
                }
                Spacer(minLength: 0)
            }
            if let message = presentation.message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !heroActions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(heroActions.enumerated()), id: \.offset) { _, action in
                        Button(title(of: action)) { perform(action) }
                            .buttonStyle(HostButtonStyle(kind: kind(presentation.emphasis(of: action)), height: 36))
                            .fixedSize()
                            .accessibilityIdentifier("farside.settings.\(action.identifier)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(live ? Farside.Palette.ember.opacity(0.35) : Farside.Palette.line, lineWidth: 1))
    }

    @ViewBuilder
    private func statusLine(_ presentation: HostPopoverPresentation) -> some View {
        if presentation.mood == .live, let quality = state.session.flatMap(HostConnectionQuality.init) {
            HStack(spacing: 8) {
                HostSignalBars(bars: quality.bars)
                Text(quality.label)
                if let started = state.sessionStartedAt {
                    Text("·").foregroundStyle(Farside.Palette.dim)
                    Image(systemName: "timer").font(.system(size: 11))
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Farside.Palette.ash)
            .help(presentation.caption ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.spokenCaption.map { "\(quality.label). \($0)" } ?? quality.label)
        } else if let caption = presentation.caption {
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lockBanner(_ warning: HostLockWarning) -> some View {
        let screenSaver: Bool = if case .screenSaverLocked = warning { true } else { false }
        let offerAway = !screenSaver && state.away.available && !state.awayMode
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(Farside.Palette.ember)
                .frame(width: 32, height: 32)
                .background(Farside.Palette.ember.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(HostAwayCopy.lockWarningText(warning, awayAvailable: state.away.available))
                    .font(.system(size: 13))
                    .foregroundStyle(Farside.Palette.bone)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("farside.settings.lockWarning")
                if screenSaver || offerAway {
                    HStack(spacing: 8) {
                        if screenSaver {
                            Button(HostAwayCopy.lockScreenSettingsTitle, action: actions.openLockScreenSettings)
                                .accessibilityIdentifier("farside.settings.lockScreenSettings")
                        }
                        if offerAway {
                            Button("Turn On Away Mode…") { setAwayMode(true) }
                                .accessibilityIdentifier("farside.settings.lockWarningAway")
                        }
                    }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                }
            }
            Spacer(minLength: 8)
            Button(action: actions.dismissLockWarning) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(HostAwayCopy.dismissTitle)
            .accessibilityLabel(HostAwayCopy.dismissTitle)
            .accessibilityIdentifier("farside.settings.dismissLockWarning")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Farside.Palette.ember.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var readyChecklist: some View {
        let tiles = checklistTiles
        let allGood = !tiles.contains { $0.ok == false }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Ready to connect").hostCaption()
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                ForEach(tiles) { tile in
                    HostStatusTile(tile: tile)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(allGood ? "Everything your phone needs is set up."
                         : "Fix the highlighted items so your phone can connect.")
                .font(.system(size: 12))
                .foregroundStyle(Farside.Palette.ash)
                .padding(.horizontal, 4)
        }
    }

    private var checklistTiles: [HostStatusTile.Model] {
        let screen = state.screenRecording.isGranted
        let control = state.accessibility.isGranted
        let devices = state.pairedDevices.count
        return [
            .init(id: "screen", title: "See the screen", value: screen ? "Allowed" : "Allow…", ok: screen,
                  action: screen ? { page = .mac } : { actions.openSystemSettings(.screenRecording) }),
            .init(id: "control", title: "Click and type",
                  value: !state.allowControl ? "View only" : (control ? "Allowed" : "Allow…"),
                  ok: !state.allowControl ? nil : control,
                  action: state.controlNeedsAccessibility ? { actions.openSystemSettings(.accessibility) } : { page = .sharing }),
            .init(id: "devices", title: "Devices",
                  value: devices == 0 ? (state.hasPairedPhone ? "Paired" : "Pair…") : "\(devices) paired",
                  ok: devices > 0 || state.hasPairedPhone,
                  action: devices == 0 && !state.hasPairedPhone ? actions.pairNewPhone : { page = .devices }),
            .init(id: "login", title: "Opens at login",
                  value: state.loginItem == .needsApproval ? "Approve…" : (state.openAtLogin ? "On" : "Off"),
                  ok: state.loginItem == .needsApproval ? false : (state.openAtLogin ? true : nil),
                  action: state.loginItem == .needsApproval ? actions.openLoginItems : { page = .mac })
        ]
    }

    // MARK: Devices

    private var devicesSection: some View {
        HostSettingsSection(footer: state.localPairRemovalMessage ?? (state.pairedDevices.isEmpty ? nil
            : "Up to five devices. Disconnect one before connecting another.")) {
            if state.pairedDevices.isEmpty {
                HostSettingsRow("No device paired", subtitle: "Pairing takes about a minute", systemImage: "iphone.gen3") {
                    Button("Pair a Device…", action: actions.pairNewPhone)
                        .buttonStyle(HostButtonStyle(kind: .primary, height: 30))
                        .accessibilityIdentifier("farside.settings.pairNewPhone")
                }
            } else {
                ForEach(state.pairedDevices) { device in
                    HostSettingsRow(device.name, subtitle: deviceSubtitle(device), systemImage: deviceSymbol(device)) {
                        HStack(spacing: 12) {
                            if device.connected { HostLiveDot(size: 6) }
                            Button("Remove…") { deviceToRemove = device; confirmingRemoval = true }
                                .accessibilityLabel("Remove \(device.name)")
                                .accessibilityIdentifier("farside.settings.removeDevice.\(device.id)")
                                .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                        }
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        HostSettingsSection("Connection") {
            HostSettingsRow("Local network only",
                            subtitle: "Connect without the internet. Turn this on for both devices. Changing it ends the current connection; sharing stays on.") {
                HostSwitch(label: "Local network only", isOn: state.localOnly, set: actions.setLocalOnly)
                    .accessibilityIdentifier("farside.settings.localOnly")
            }
        }
    }

    private func deviceSubtitle(_ device: HostPairedDeviceRow) -> String {
        if device.connected { return "Connected now" }
        guard let date = device.lastUsed else { return "Paired" }
        return "Last used " + date.formatted(date: .abbreviated, time: .shortened)
    }

    private func deviceSymbol(_ device: HostPairedDeviceRow) -> String {
        device.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone.gen3"
    }

    // MARK: Sharing

    private var captureScopeSection: some View {
        HostSettingsSection("What to share", footer: state.captureScopeNeedsSelection
            ? "Choose live content before sharing. A closed target never switches to your whole display."
            : "Changing this disconnects your phone; share again when ready. A single app or window is view only: audio, control, clipboard, files, screen hiding and Big Text are off.") {
            HostSettingsRow("Content") {
                HStack(spacing: 8) {
                    Picker("Shared content", selection: Binding(get: { state.selectedCaptureScopeID }, set: actions.selectCaptureScope)) {
                        if state.captureScopeNeedsSelection { Text("Choose content…").tag("unavailable") }
                        ForEach(state.captureScopes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("farside.settings.captureScope")
                    Button(action: actions.refreshCaptureScopes) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 28))
                    .help("Refresh apps and windows")
                    .accessibilityLabel("Refresh apps and windows")
                    .accessibilityIdentifier("farside.settings.refreshCaptureScopes")
                }
            }
            if state.displays.count > 1 && !state.captureScopeViewOnly {
                HostSettingsRow("Display") {
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

    private var controlSection: some View {
        HostSettingsSection("What your phone can do", footer: sessionFooter) {
            HostSettingsRow("Allow control", subtitle: state.controlNeedsAccessibility
                            ? "Needs Accessibility first" : "Off means view only") {
                HostSwitch(label: "Allow control", isOn: state.allowControl, set: actions.setAllowControl)
                    .accessibilityIdentifier("farside.settings.allowControl")
                    .disabled(state.captureScopeViewOnly)
            }
            HostSettingsRow("Allow phone to listen", subtitle: "Listen on your phone plays sound from all Mac apps") {
                HostSwitch(label: "Allow phone to listen", isOn: state.allowSystemAudio, set: actions.setAllowSystemAudio)
                    .accessibilityIdentifier("farside.settings.systemAudio")
                    .disabled(state.captureScopeViewOnly)
            }
            HostSettingsRow("Allow Big Text",
                            subtitle: state.bigTextStatus ?? "Your phone can make text larger on this Mac. It goes back when the phone disconnects; windows on other Spaces may stay smaller.") {
                HostSwitch(label: "Allow a connected phone to change text size", isOn: state.allowBigText,
                           set: actions.setAllowBigText)
                    .accessibilityIdentifier("farside.settings.allowBigText")
                    .disabled(state.captureScopeViewOnly)
            }
        }
    }

    private var privacySection: some View {
        HostSettingsSection("Privacy") {
            HostSettingsRow("Hide this Mac’s screen", subtitle: HostCurtainCopy.subtitle(for: state)) {
                HostSwitch(label: "Hide this Mac’s screen", isOn: state.privacyCurtain,
                           set: actions.setPrivacyCurtain)
                    .accessibilityIdentifier("farside.settings.privacyCurtain")
                    .disabled(state.captureScopeViewOnly)
            }
            HostSettingsRow("Chime when a phone connects", subtitle: "So you always know") {
                HostSwitch(label: "Chime when a phone connects", isOn: state.chimeOnConnect,
                           set: actions.setChimeOnConnect)
                    .accessibilityIdentifier("farside.settings.chime")
            }
            if state.away.available {
                awayModeRow
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

    private var sessionFooter: String {
        state.controlNeedsAccessibility
            ? "Control also needs Accessibility for Farside."
            : "Closing the lid, restarting or logging out still stops sharing."
    }

    // MARK: This Mac

    private var permissionsSection: some View {
        HostSettingsSection("Permissions") {
            permissionRow("Screen Recording", reason: "So your phone can see the screen",
                          status: state.screenRecording, pane: .screenRecording)
            permissionRow("Accessibility", reason: "So your phone can click and type",
                          status: state.accessibility, pane: .accessibility)
        }
    }

    private var reachableSection: some View {
        HostSettingsSection("Stay ready", footer: generalFooter) {
            HostSettingsRow("Keep this Mac awake",
                            subtitle: HostKeepAwakeCopy.subtitle(pausedOnBattery: state.keepAwakePausedOnBattery)) {
                HostSwitch(label: "Keep this Mac awake", isOn: state.keepAwake, set: actions.setKeepAwake)
                    .accessibilityIdentifier("farside.settings.keepAwake")
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
        }
    }

    private var menuBarSection: some View {
        HostSettingsSection("Menu bar") {
            HostSettingsRow("Show in menu bar", subtitle: HostMenuBarIconCopy.subtitle(shown: state.menuBarIconShown)) {
                HostSwitch(label: "Show in menu bar", isOn: state.menuBarIconShown, set: actions.setMenuBarIconShown)
                    .accessibilityIdentifier("farside.settings.showInMenuBar")
            }
        }
    }

    /// What each Mac state means for a phone, folded away because it is reference, not a choice.
    @ViewBuilder private var availabilityDisclosure: some View {
        disclosureButton("When can my phone reach this Mac?", expanded: showingAvailability,
                         identifier: "farside.settings.availability") {
            showingAvailability.toggle()
        }
        if showingAvailability {
            HostSettingsSection(footer: "Start at login and recovery apply after you log in. Farside never stores your Mac password or unlocks FileVault.") {
                HostSettingsRow("Awake and unlocked", subtitle: "A current authenticated connection and fresh content are required.") { EmptyView() }
                HostSettingsRow("Display asleep", subtitle: "Farside can request display wake while this user’s Mac is awake.") { EmptyView() }
                HostSettingsRow("System sleep or closed lid", subtitle: "Needs supported network wake and another powered LAN peer. Packet sent does not mean awake.") { EmptyView() }
                HostSettingsRow("Locked or switched user", subtitle: "Sharing stops. Unlock or return to this user at the Mac.") { EmptyView() }
                HostSettingsRow("Logout, restart or FileVault", subtitle: "Unavailable until this user logs in and normal permissions allow sharing.") { EmptyView() }
                if let hostID = state.wakeHelperHostID, state.wakeOwnerPairID != nil {
                    HostSettingsRow("This Mac’s durable host ID", subtitle: "Copy locally to an owner-configured powered helper. This ID is not permission to connect.") {
                        Text(hostID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Register another Mac for LAN wake") { showingWakeRegistration = true }
                        .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .accessibilityIdentifier("farside.settings.wakeRegistration")
                }
            }
        }
    }

    private var generalFooter: String? {
        state.crashLoopStopped ? "Farside stopped after repeated crashes. Try Again in Overview resumes sharing." : nil
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

    // MARK: Advanced

    private var agentAlertsSection: some View {
        HostSettingsSection("Agent alerts (beta)") {
            HostSettingsRow("Agent alerts",
                            subtitle: state.agentAlertsStatus ?? "Tell your phone when a coding agent on this Mac needs you") {
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
        }
    }

    private var troubleshootingSection: some View {
        HostSettingsSection("Troubleshooting", footer: "Local reports expire after 7 days, up to 10 reports. Nothing is uploaded automatically.") {
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
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityIdentifier("farside.settings.localReport")
            }
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

    private var serverDataSection: some View {
        HostSettingsSection("Server data", footer: "Room removal does not cancel an Apple subscription. Purchase history remains for up to 90 days after access ends; security blocks and pending relay revocations may be retained.") {
            HostSettingsRow("This Mac’s server room", subtitle: state.serverRemovalMessage) {
                Button(state.serverRemovalBusy ? "Removing…" : (state.serverRemovalPending ? "Retry Removal…" : "Remove…"), role: .destructive) {
                    confirmingServerRemoval = true
                }
                .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                .disabled(state.serverRemovalBusy || (!state.hasPairedPhone && !state.serverRemovalPending))
                .accessibilityLabel(state.serverRemovalPending ? "Retry Server Room Removal" : "Remove This Mac’s Server Room")
                .accessibilityIdentifier("farside.settings.removeServerRoom")
            }
        }
    }

    private var aboutSection: some View {
        HostSettingsSection("About") {
            HostSettingsRow("Legal", subtitle: "Open-source software and fonts") {
                Button("View Notices…") { showingNotices = true }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
            }
        }
    }

    // MARK: Shared pieces

    private func disclosureButton(_ title: String, expanded: Bool, identifier: String,
                                  toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Farside.Motion.easeOut()) { toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Farside.Palette.bone)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Farside.Palette.ash)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer()
            }
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(identifier)
    }

    private func title(of action: HostPopoverAction) -> String {
        action == .pairPhone ? "Pair a Device…" : action.title
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

/// One readiness check on Overview: a word on its state and a click that goes where it is fixed.
struct HostStatusTile: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let value: String
        /// nil is neutral: a choice, not a problem.
        let ok: Bool?
        let action: () -> Void
    }

    let tile: Model
    @State private var hovering = false

    var body: some View {
        Button(action: tile.action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(tile.ok == false ? Farside.Palette.ember : Farside.Palette.bone)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Farside.Palette.ash)
                        .opacity(hovering ? 1 : 0.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Farside.Palette.ash)
                        .lineLimit(1)
                    Text(tile.value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(hovering ? Farside.Palette.panel2 : Farside.Palette.panel,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tile.ok == false ? Farside.Palette.ember.opacity(0.55) : Farside.Palette.line, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(tile.title): \(tile.value)")
        .accessibilityIdentifier("farside.settings.ready.\(tile.id)")
    }

    private var symbol: String {
        switch tile.ok {
        case true: "checkmark.circle.fill"
        case false: "exclamationmark.circle.fill"
        case nil: "circle.dashed"
        }
    }
}

/// Four rising bars, lit up to the connection quality.
struct HostSignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index <= bars ? Farside.Palette.bone : Farside.Palette.dim)
                    .frame(width: 3, height: CGFloat(3 + index * 2))
            }
        }
        .accessibilityHidden(true)
    }
}
