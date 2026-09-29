import ActivityKit
import SwiftUI
import UserNotifications

// MARK: - Alert sheet

/// What a tap on "needs you" opens. It tells you who asked and how long ago, then offers one way in.
/// Nothing connects until the person taps Open your Mac.
struct AgentAlertSheet: View {
    let item: AgentAlertPresentation
    @ObservedObject var center: AgentAlertCenter
    let sessionLive: Bool
    let openMac: () -> Void
    let close: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var payload: AgentAlertPayload { item.payload }
    private var name: String { center.preferences.showAgentName ? payload.kind.displayName : AgentKind.genericName }
    private var declined: Bool { center.wasDeclined(item.id) }
    private var old: Bool { item.freshness(at: center.now()) == .old }

    private var headline: String {
        if payload.isTest { return "Test alert received." }
        return "\(name) needs you."
    }

    private var accent: String? { payload.isTest ? "received" : "needs" }

    private var message: String {
        if payload.isTest { return "Notifications work. Nothing on your Mac is stuck." }
        if declined { return "You said not now to this one. It may still be waiting." }
        if payload.isReminder { return "Still waiting on you." }
        if old { return "This was asked a while ago. It may have ended, but you can still take a look." }
        return "Stuck on something only a human can click. Open your Mac to look."
    }

    private var meta: String {
        payload.isTest ? "TEST · NO AGENT INVOLVED" : "ASKED \(AgentAlertPresentation.ageText(center.now().timeIntervalSince(item.receivedAt)).uppercased())"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04),
                                scene: FarsideArt.reach(gap: payload.isTest ? 3 : 14, contact: payload.isTest ? 0.9 : 0.35))
                    .frame(height: verticalSizeClass == .compact ? 90 : 150)
                    .padding(.horizontal, -Farside.Space.l)
                FarsideHeading(headline, accent: accent, size: 32)
                    .padding(.top, Farside.Space.xs)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Farside.Space.s)
                Text(meta)
                    .farsideCaption()
                    .padding(.top, Farside.Space.s)
                if sessionLive && !payload.isTest {
                    FarsideNotice(message: "You’re already on your Mac.", tone: .info)
                        .padding(.top, Farside.Space.m)
                }
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.top, Farside.Space.m)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Farside.Space.xs) {
                Button(primaryTitle, action: primary)
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                    .accessibilityIdentifier("agent.alert.open")
                if !payload.isTest && !declined {
                    Button("Not now", action: notNow)
                        .buttonStyle(FarsideSecondaryButtonStyle())
                        .accessibilityIdentifier("agent.alert.notNow")
                }
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.bottom, Farside.Space.s)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(Farside.Palette.void2)
        }
        .background(FarsideBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.alert.sheet")
    }

    private var primaryTitle: String {
        if payload.isTest { return "Done" }
        return sessionLive ? "Back to your Mac" : "Open your Mac"
    }

    private func primary() {
        if payload.isTest || sessionLive { close() } else { openMac() }
    }

    private func notNow() {
        Task {
            await center.respond(.notNow, to: payload, deliveredAt: item.receivedAt, notificationIdentifier: nil)
            close()
        }
    }
}

// MARK: - In-session banner

/// Over a live session the picture already shows the Mac, so a "needs you" is one quiet line.
struct AgentAlertBanner: View {
    let item: AgentAlertPresentation
    let showName: Bool
    let dismiss: () -> Void

    private var name: String { showName ? item.payload.kind.displayName : AgentKind.genericName }

    var body: some View {
        HStack(spacing: 12) {
            LiveDot(state: .attention)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) needs you")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Farside.Palette.bone)
                Text("Stuck on something only a human can click.")
                    .font(.footnote)
                    .foregroundStyle(Farside.Palette.ash)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Farside.Palette.ash)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 8)
        .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        .padding(.horizontal, Farside.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.alert.banner")
    }
}

// MARK: - Settings

/// Agent alerts (beta). Asks iOS for permission only here, after saying what the alerts are.
struct AgentAlertsSettingsSheet: View {
    @ObservedObject var center: AgentAlertCenter
    @ObservedObject var registrar: PushRegistrar
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(AgentAlertPreferences.Key.alerts) private var alertsOn = false
    @AppStorage(AgentAlertPreferences.Key.breakThroughFocus) private var breakThroughFocus = false
    @AppStorage(AgentAlertPreferences.Key.showAgentName) private var showAgentName = true
    @AppStorage(AgentAlertPreferences.Key.sessionActivity) private var sessionActivity = true
    @AppStorage(AgentAlertPreferences.Key.showMacName) private var showMacName = false
    @State private var showPriming = false
    @State private var testStatus: String?
    @State private var previewStatus: String?

    private var alertsBinding: Binding<Bool> {
        Binding(get: { alertsOn }, set: { turnAlerts($0) })
    }

    /// iOS reports `.notSupported` for every per-setting value until the person answers the permission
    /// prompt, so it only means "this build has no Time Sensitive entitlement" once alerts are allowed.
    private var focusAvailable: Bool { !(center.access == .allowed && center.timeSensitive == .notSupported) }

    private var focusDetail: String {
        guard center.access == .allowed else { return "Time Sensitive. iOS lets you switch it off for Farside." }
        switch center.timeSensitive {
        case .notSupported: return "Not available in this build."
        case .disabled: return "Off for Farside in iOS Settings."
        default: return "Time Sensitive. iOS lets you switch it off for Farside."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Farside.Space.l) {
                    VStack(alignment: .leading, spacing: Farside.Space.s) {
                        Text("AGENT ALERTS · BETA").farsideCaption()
                        FarsideHeading("Know when it needs you.", accent: "needs", size: 30)
                        Text("When a coding agent on your Mac gets stuck on something only a human can click, Farside can tap your shoulder.")
                            .font(.body)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if center.access == .denied {
                        VStack(alignment: .leading, spacing: Farside.Space.s) {
                            FarsideNotice(message: "Notifications are off for Farside in iOS Settings.", tone: .caution)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .buttonStyle(FarsideLinkButtonStyle())
                        }
                    }

                    VStack(spacing: 0) {
                        row(divider: true) {
                            Toggle(isOn: alertsBinding) {
                                label("Agent alerts", "Notifications from agents on your Mac.")
                            }
                            .toggleStyle(FarsideSwitchStyle())
                            .accessibilityIdentifier("agent.settings.alerts")
                        }
                        row(divider: true) {
                            Toggle(isOn: $breakThroughFocus) {
                                label("Break through Focus", focusDetail)
                            }
                            .toggleStyle(FarsideSwitchStyle())
                            .disabled(!alertsOn || !focusAvailable)
                            .accessibilityIdentifier("agent.settings.focus")
                        }
                        row(divider: true) {
                            Toggle(isOn: $showAgentName) {
                                label("Show agent name", "Off says “An agent”. Only Claude Code, Codex or Cursor are ever named.")
                            }
                            .toggleStyle(FarsideSwitchStyle())
                            .accessibilityIdentifier("agent.settings.name")
                        }
                        row(divider: false) {
                            Button(action: sendTest) {
                                HStack {
                                    label("Send test alert", testStatus ?? "A real notification, with no agent involved.")
                                    Spacer(minLength: 8)
                                    Image(systemName: "bell.badge")
                                        .foregroundStyle(Farside.Palette.ash)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(!alertsOn)
                            .opacity(alertsOn ? 1 : 0.4)
                            .accessibilityIdentifier("agent.settings.test")
                        }
                    }
                    .farsidePlate()

                    Text("Alerts reach you while a session is open. To reach a locked phone, Farside needs its push service, which is not switched on yet. Alerts never contain what is on your screen.")
                        .farsideCaption()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agent.settings.beta")

                    VStack(alignment: .leading, spacing: Farside.Space.s) {
                        Text("LOCK SCREEN").farsideCaption().padding(.top, Farside.Space.s)
                        Text("While a session is open and Farside is in the background, it can show on the Lock Screen and in the Dynamic Island, with an End button.")
                            .font(.body)
                            .foregroundStyle(Farside.Palette.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 0) {
                        row(divider: true) {
                            Toggle(isOn: $sessionActivity) {
                                label("Session on the Lock Screen", "Time on the line, and an End button that works while locked.")
                            }
                            .toggleStyle(FarsideSwitchStyle())
                            .accessibilityIdentifier("agent.settings.activity")
                        }
                        row(divider: true) {
                            Toggle(isOn: $showMacName) {
                                label("Show Mac name", "Off says “Your Mac”. Lock screens are visible to other people.")
                            }
                            .toggleStyle(FarsideSwitchStyle())
                            .disabled(!sessionActivity)
                            .accessibilityIdentifier("agent.settings.macname")
                        }
                        row(divider: false) {
                            Button(action: previewActivity) {
                                HStack {
                                    label("Preview Live Activity", previewStatus ?? "A labelled sample. It connects to nothing.")
                                    Spacer(minLength: 8)
                                    Image(systemName: "rectangle.topthird.inset.filled")
                                        .foregroundStyle(Farside.Palette.ash)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("agent.settings.preview")
                        }
                    }
                    .farsidePlate()

                    Text("Never shows your screen, prompts, file names or how fast the connection is.")
                        .farsideCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Farside.Space.l)
                .padding(.vertical, Farside.Space.m)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Farside.Palette.void2)
            .navigationTitle("Alerts & Lock Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Farside.Palette.bone)
        .presentationDetents([.large])
        .farsideSheet()
        .task { await center.refreshAccess() }
        .fullScreenCover(isPresented: $showPriming) {
            PermissionPrimingView(kind: .notifications) {
                showPriming = false
                Task { _ = await center.requestAndEnable() }
            }
        }
        .accessibilityIdentifier("agent.settings")
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body).foregroundStyle(Farside.Palette.bone)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Content: View>(divider: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if divider { Rectangle().fill(Farside.Palette.line).frame(height: 1).padding(.leading, 18) }
            }
    }

    private func turnAlerts(_ on: Bool) {
        Task {
            switch await center.setAlertsEnabled(on) {
            case .enabled: break
            case .needsPriming:
                if PermissionPrimer.needsPriming(.notifications) { showPriming = true }
                else { _ = await center.requestAndEnable() }
            case .deniedInSettings: break
            }
        }
    }

    private func sendTest() {
        testStatus = "Sending…"
        Task {
            let sent = await center.sendTestAlert()
            testStatus = sent ? "Sent. It arrives in a moment." : "Turn on agent alerts first."
        }
    }

    private func previewActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            previewStatus = "Live Activities are off for Farside in iOS Settings."
            return
        }
        FarsideSystemIntegrations.shared.activity.startPreview()
        previewStatus = "Leave Farside to see it. It ends by itself."
    }
}
