import SwiftUI

/// The menu-bar popover: a halftone strip naming the state, who is steering, the two session
/// toggles, this state's actions, then Settings… · Pair a phone… · Quit.
struct HostPopoverView: View {
    let state: HostViewState
    let actions: HostActions
    /// Fixed time for review renders; the live popover uses the current time.
    var now: Date?
    /// The live session's taps, keys, scrolls and round trips (D39); nil in review renders.
    var activity: HostActivityFeed?
    /// Stop Sharing was pressed while a phone is connected; review renders can start here.
    @State var confirmingStop = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state, now: now ?? Date())
        VStack(alignment: .leading, spacing: 0) {
            HostPopoverStrip(presentation: presentation, activity: activity)
            VStack(alignment: .leading, spacing: 0) {
                who(presentation)
                if state.status.isSessionLive {
                    HostLiveReadout(session: state.session, allowControl: state.status == .controlling,
                                    activity: activity ?? HostActivityFeed())
                        .padding(.top, 12)
                }
                if state.status == .pairing {
                    HostPopoverPairingCode(pairing: state.pairing, copy: actions.copyPairingCode, newCode: actions.beginPairing)
                        .padding(.top, 14)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.05).combined(with: .opacity))
                }
                if let message = presentation.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                if let warning = state.lockWarning {
                    HostLockWarningBlock(warning: warning, awayAvailable: state.away.available,
                                         identifierPrefix: "farside.popover",
                                         openLockScreenSettings: {
                                             dismiss()
                                             actions.openLockScreenSettings()
                                         },
                                         dismiss: actions.dismissLockWarning)
                        .padding(.top, 12)
                }
                if state.away.available && state.awayMode {
                    awayStatus
                        .padding(.top, 12)
                }
                if presentation.showsSessionToggles {
                    sessionToggles
                        .padding(.top, 12)
                } else if let status = state.bigTextStatus {
                    // A restore can be pending while locked or asleep, when the session toggles are hidden.
                    HostHairlineList { bigTextRow(status) }
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
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.easeOut(), value: state.status)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.easeOut(), value: confirmingStop)
        .onChange(of: state.status.isSessionLive) { _, live in if !live { confirmingStop = false } }
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
            if state.status.isSessionLive, let started = state.sessionStartedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Farside.Palette.bone)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([presentation.title, presentation.spokenCaption ?? presentation.caption]
            .compactMap { $0 }.joined(separator: ". "))
    }

    private var awayStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let line = HostAwayCopy.statusLine(state.away, now: now ?? context.date) {
                    Text(line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Farside.Palette.bone)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("farside.popover.awayStatus")
                }
            }
            HStack(spacing: 8) {
                if state.away.phase == .armed {
                    Button(HostAwayCopy.coverNowTitle, action: actions.coverNow)
                        .accessibilityIdentifier("farside.popover.awayCoverNow")
                    Button(HostAwayCopy.turnOffTitle) { actions.setAwayMode(false) }
                        .accessibilityIdentifier("farside.popover.awayTurnOff")
                }
            }
            .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let warning = HostAwayCopy.warningLine(state.away, now: now ?? context.date) {
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("farside.popover.awayWarning")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
            HostToggleRow(title: "Hide this Mac’s screen", subtitle: HostCurtainCopy.subtitle(for: state),
                          isOn: state.privacyCurtain, set: actions.setPrivacyCurtain)
                .accessibilityIdentifier("farside.popover.privacyCurtain")
            if let status = state.bigTextStatus {
                bigTextRow(status)
            }
            VStack(alignment: .leading, spacing: 6) {
                HostToggleRow(title: "Open at login", subtitle: HostBackgroundItemCopy.loginSubtitle(state.loginItem),
                              isOn: state.openAtLogin, set: actions.setOpenAtLogin)
                    .accessibilityIdentifier("farside.popover.openAtLogin")
                if state.loginItem == .needsApproval {
                    Button("Allow in Login Items…") {
                        dismiss()
                        actions.openLoginItems()
                    }
                    .buttonStyle(HostButtonStyle(kind: .inline))
                    .accessibilityIdentifier("farside.popover.allowLoginItem")
                }
            }
        }
    }

    private func bigTextRow(_ status: String) -> some View {
        HStack(spacing: 12) {
            Text(status)
                .font(.system(size: 14))
                .foregroundStyle(Farside.Palette.bone)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("farside.popover.bigTextStatus")
            Spacer(minLength: 12)
            if !status.hasPrefix("Restoring") {
                Button("Restore normal size", action: actions.restoreNormalSize)
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                    .fixedSize()
                    .accessibilityIdentifier("farside.popover.restoreNormalSize")
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ presentation: HostPopoverPresentation) -> some View {
        if confirmingStop && state.status.isSessionLive {
            HostStopConfirm(phoneName: state.phoneName, keep: { confirmingStop = false }, stop: {
                confirmingStop = false
                actions.stopSharing()
            })
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
        } else {
            HStack(spacing: 8) {
                ForEach(Array(presentation.actions.enumerated()), id: \.offset) { index, action in
                    let button = Button(action.title) { perform(action) }
                        .buttonStyle(HostButtonStyle(kind: kind(presentation.emphasis(of: action)), fullWidth: true))
                        .accessibilityIdentifier("farside.popover.\(action.identifier)")
                        .hostDefaultAction(action == presentation.defaultAction)
                    if presentation.actions.count > 1 && index == 0 {
                        button.frame(width: 146)
                    } else {
                        button.frame(maxWidth: .infinity)
                    }
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
        // Disconnecting a phone that is steering right now asks first (D39).
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

// HostPopoverStrip (the live strip, D39) lives in HostLiveStrip.swift.
/// Tells the person the Mac locked while sharing, in Settings and the popover, whether or not
/// Away mode is available.
struct HostLockWarningBlock: View {
    let warning: HostLockWarning
    let awayAvailable: Bool
    let identifierPrefix: String
    let openLockScreenSettings: () -> Void
    let dismiss: () -> Void

    private var isScreenSaver: Bool {
        if case .screenSaverLocked = warning { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Farside.Palette.ash)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(HostAwayCopy.lockWarningText(warning, awayAvailable: awayAvailable))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Farside.Palette.bone)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifierPrefix).lockWarning")
            }
            HStack(spacing: 8) {
                if isScreenSaver {
                    Button(HostAwayCopy.lockScreenSettingsTitle, action: openLockScreenSettings)
                        .accessibilityIdentifier("\(identifierPrefix).lockScreenSettings")
                }
                Button(HostAwayCopy.dismissTitle, action: dismiss)
                    .accessibilityIdentifier("\(identifierPrefix).dismissLockWarning")
            }
            .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Farside.Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Farside.Palette.line2, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
