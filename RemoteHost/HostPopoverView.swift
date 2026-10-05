import SwiftUI
import AppKit

/// The menu-bar popover: a halftone strip naming the state, who is steering and how good the
/// connection is, the two session toggles, this state's actions, then Settings… · Quit.
struct HostPopoverView: View {
    let state: HostViewState
    let actions: HostActions
    /// Fixed time for review renders; the live popover uses the current time.
    var now: Date?
    /// The live session's taps, which ripple across the strip (D39); nil in review renders.
    var activity: HostActivityFeed?
    /// Stop Sharing was pressed while a phone is connected; review renders can start here.
    @State var confirmingStop = false
    @State private var confirmingGuest: HostGuestRow?
    @State private var visibleHeight = Double(NSScreen.main?.visibleFrame.height ?? 700)
    @State private var measuredHeights: [String: Double] = [:]
    /// Review harness can exercise both launch-switch states and small screens without changing defaults.
    var boundedOverride: Bool?
    var visibleHeightOverride: Double?

    private var bounded: Bool { boundedOverride ?? HostPopoverPolicy.bounded }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = HostPopoverPresentation.make(for: state, now: now ?? Date())
        let maximum = HostPopoverPolicy.maximumHeight(visibleHeight: visibleHeightOverride ?? visibleHeight)
        // Reserve confirmation space in the same pass that Stop opens, before preferences arrive.
        // Once normal actions are measured, return their unused reserve to scrolling details.
        let actionsHeight = max(measuredHeights["actions"] ?? 240, confirmingStop ? 240 : 0)
        let headerHeight = HostPopoverPolicy.headerHeight(
            content: measuredHeights["naturalWho"] ?? 100, actions: actionsHeight, maximum: maximum)
        VStack(alignment: .leading, spacing: 0) {
            HostPopoverStrip(presentation: presentation, activity: activity)
            if bounded {
                who(presentation)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .measurePopoverHeight("naturalWho")
                    .frame(height: headerHeight, alignment: .top)
                    .clipped()
                ScrollView {
                    details(presentation)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                        .measurePopoverHeight("details")
                }
                .frame(height: HostPopoverPolicy.detailHeight(
                    content: measuredHeights["details"] ?? 400,
                    pinned: 96 + headerHeight + actionsHeight,
                    maximum: maximum))
                .accessibilityIdentifier("farside.popover.details")
                // Session exits and their confirmation remain outside the scrolling details.
                VStack(alignment: .leading, spacing: 14) {
                    actionRow(presentation)
                    footer
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
                .measurePopoverHeight("actions")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    who(presentation)
                    details(presentation)
                    actionRow(presentation)
                        .padding(.top, presentation.showsSessionToggles ? 12 : 16)
                    footer.padding(.top, 14)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
            }
        }
        .frame(width: HostTheme.popoverWidth)
        .background(HostTheme.popoverBackground)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.easeOut(), value: state.status)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Farside.Motion.easeOut(), value: confirmingStop)
        .onChange(of: state.status.isSessionLive) { _, live in if !live { confirmingStop = false } }
        .onPreferenceChange(HostPopoverHeightKey.self) { measuredHeights = $0 }
        .background(HostPopoverScreenReader { visibleHeight = $0 })
        .alert("Approve this recipient for video viewing?", isPresented: Binding(
            get: { confirmingGuest != nil }, set: { if !$0 { confirmingGuest = nil } })) {
            Button("Approve viewing") {
                if let row = confirmingGuest, state.guestRows.contains(where: {
                    $0.id == row.id && $0.pending && $0.fingerprint == row.fingerprint
                }) { actions.approveGuest(row.id) }
                confirmingGuest = nil
            }
            Button("Cancel", role: .cancel) { confirmingGuest = nil }
        } message: {
            Text("Verify this full key fingerprint with the recipient through a channel you trust:\n\(confirmingGuest?.fingerprint ?? "")\n\nViewing ends after ten minutes or when the current session or shared content changes. Audio and control are unavailable.")
        }
        .accessibilityIdentifier("farside.popover")
    }

    private func details(_ presentation: HostPopoverPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
            if HostPopoverPolicy.audience(state.guestRows) != nil {
                guestAudience.padding(.top, 12)
            }
        }
    }

    private var guestAudience: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.guestRows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(HostPopoverPolicy.guestStatus(row)).font(.system(size: 12)).foregroundStyle(Farside.Palette.ash)
                    HStack(spacing: 8) {
                        if row.pending && HostGuestPolicy.enabled {
                            Button("Review") { confirmingGuest = row }
                                .accessibilityLabel("Review guest approval")
                                .accessibilityIdentifier("farside.popover.reviewGuest.\(row.id)")
                        }
                        Button(row.pending ? "Decline" : "End guest") { actions.revokeGuest(row.id) }
                            .accessibilityIdentifier("farside.popover.endGuest.\(row.id)")
                    }
                    .buttonStyle(HostButtonStyle(kind: .plate, height: 30))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func who(_ presentation: HostPopoverPresentation) -> some View {
        HStack(spacing: 12) {
            HostIconTile(systemImage: presentation.symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .lineLimit(bounded ? 2 : nil)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Farside.Palette.bone)
                if state.status.isSessionLive {
                    connectionLine(presentation)
                } else if let caption = presentation.caption {
                    Text(caption)
                        .hostCaption(10.5)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if HostPopoverPolicy.scopedControls, let caption = HostPopoverPolicy.scopeCaption(state) {
                    Text(caption).font(.system(size: 13)).foregroundStyle(Farside.Palette.ash)
                        .lineLimit(bounded ? 2 : nil)
                        .help(caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("farside.popover.captureScope")
                }
                if let audience = HostPopoverPolicy.audience(state.guestRows) {
                    Text(audience).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("farside.popover.guestAudience")
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
        .accessibilityLabel([presentation.title, connectionQuality?.label,
            presentation.spokenCaption ?? presentation.caption,
            HostPopoverPolicy.scopedControls ? HostPopoverPolicy.scopeCaption(state) : nil,
            HostPopoverPolicy.audience(state.guestRows)]
            .compactMap { $0 }.joined(separator: ". "))
    }

    private var connectionQuality: HostConnectionQuality? {
        state.status.isSessionLive ? state.session.flatMap(HostConnectionQuality.init) : nil
    }

    /// Plain words and signal bars while live; the measured numbers stay in the tooltip.
    private func connectionLine(_ presentation: HostPopoverPresentation) -> some View {
        HStack(spacing: 7) {
            if let quality = connectionQuality {
                HostSignalBars(bars: quality.bars)
                Text(quality.label)
            } else {
                Text("Measuring the connection")
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Farside.Palette.ash)
        .lineLimit(1)
        .help(presentation.caption ?? "")
        .accessibilityIdentifier("farside.popover.connectionQuality")
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
                    .disabled(HostPopoverPolicy.controlsDisabled(scoped: state.captureScopeViewOnly))
                if state.controlNeedsAccessibility && (!HostPopoverPolicy.scopedControls || !state.captureScopeViewOnly) {
                    Button("Allow in System Settings…") {
                        dismiss()
                        actions.openSystemSettings(.accessibility)
                    }
                    .buttonStyle(HostButtonStyle(kind: .inline))
                    .accessibilityIdentifier("farside.popover.allowAccessibility")
                }
            }
            HostToggleRow(title: "Hide this Mac’s screen", subtitle: HostCurtainCopy.subtitle(for: state),
                          isOn: state.privacyCurtain, set: actions.setPrivacyCurtain)
                .accessibilityIdentifier("farside.popover.privacyCurtain")
                .disabled(HostPopoverPolicy.controlsDisabled(scoped: state.captureScopeViewOnly))
            if let status = state.bigTextStatus {
                bigTextRow(status)
            }
            // Only when there is a nudge to show; an empty row would draw a blank hairline gap.
            if !bounded && ((state.consentPending && state.setupStep == .done) || state.loginItem == .needsApproval) {
                VStack(alignment: .leading, spacing: 6) {
                    if state.consentPending && state.setupStep == .done {
                        Button("Review open at login and keep awake…") {
                            dismiss()
                            actions.openSetup()
                        }
                        .buttonStyle(HostButtonStyle(kind: .inline))
                        .accessibilityIdentifier("farside.popover.reviewBackgroundChoices")
                    }
                    if state.loginItem == .needsApproval {
                        Button("Allow in System Settings…") {
                            dismiss()
                            actions.openLoginItems()
                        }
                        .buttonStyle(HostButtonStyle(kind: .inline))
                        .accessibilityIdentifier("farside.popover.allowLoginItem")
                    }
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

// Measure only the pinned areas and the detail content; warning growth cannot push exits offscreen.
private struct HostPopoverHeightKey: PreferenceKey {
    static let defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func measurePopoverHeight(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: HostPopoverHeightKey.self, value: [name: Double(geometry.size.height)])
        })
    }
}

/// Use the actual popover's screen, and refresh when screen geometry or the Dock changes.
private struct HostPopoverScreenReader: NSViewRepresentable {
    let changed: (Double) -> Void
    func makeNSView(context: Context) -> ScreenView { ScreenView(changed: changed) }
    func updateNSView(_ view: ScreenView, context: Context) { view.changed = changed; view.refresh() }

    final class ScreenView: NSView {
        var changed: (Double) -> Void
        private var lastHeight: Double?
        init(changed: @escaping (Double) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                name: NSWindow.didChangeScreenNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
        @objc func refresh() {
            guard let screen = window?.screen ?? NSScreen.main else { return }
            let height = Double(screen.visibleFrame.height)
            guard height != lastHeight else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.changed(height) }
        }
    }
}
