import SwiftUI

struct HostSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    let state: HostViewState
    let actions: HostActions
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusHeader

            HostSettingsSection("Phone") {
                phoneRow
            }

            HostSettingsSection("While your phone is connected", footer: controlFooter) {
                HostSettingsRow("Allow mouse and keyboard control", systemImage: "cursorarrow.rays") {
                    Toggle("Allow mouse and keyboard control",
                           isOn: Binding(get: { state.allowControl }, set: actions.setAllowControl))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                HostSettingsRow("Keep this Mac awake while sharing", systemImage: "cup.and.saucer") {
                    Toggle("Keep this Mac awake while sharing",
                           isOn: Binding(get: { state.keepAwake }, set: actions.setKeepAwake))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if state.displays.count > 1 {
                    HostSettingsRow("Shared display", systemImage: "display") {
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
                permissionRow("Screen Recording", systemImage: "rectangle.dashed.badge.record",
                              status: state.screenRecording, pane: .screenRecording)
                permissionRow("Accessibility", systemImage: "hand.point.up.left",
                              status: state.accessibility, pane: .accessibility)
            }

            HostSettingsSection {
                HostSettingsRow("Open at login", systemImage: "power") {
                    Toggle("Open at login",
                           isOn: Binding(get: { state.openAtLogin }, set: actions.setOpenAtLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove your paired phone?", isPresented: $confirmingRemoval) {
            Button("Remove Phone", role: .destructive, action: actions.removePhone)
        } message: {
            Text("It will no longer be able to connect to this Mac. You can pair again at any time.")
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            HostIconTile(systemImage: headerSymbol, tone: headerTone, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.status.title)
                    .font(.headline)
                Text(headerDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            headerAction
        }
    }

    @ViewBuilder
    private var headerAction: some View {
        switch state.status {
        case .viewing, .controlling, .ready, .starting, .pairing:
            Button("Stop Sharing", action: actions.stopSharing)
        case .paused:
            Button("Resume Sharing", action: actions.resumeSharing)
        case .unavailable:
            Button("Try Again", action: actions.resumeSharing)
        case .needsScreenRecording, .needsPhone:
            Button("Finish Setup…", action: actions.openSetup)
        case .approvalRequested:
            Button("Review…", action: actions.openSetup)
        }
    }

    private var headerSymbol: String {
        state.status.needsAttention ? "exclamationmark.triangle" : state.status.menuBarSymbol
    }

    private var headerTone: HostTone {
        switch state.status {
        case .viewing, .controlling, .ready: .sage
        case .needsScreenRecording, .needsPhone, .unavailable, .approvalRequested: .clay
        default: .sand
        }
    }

    private var headerDetail: String {
        switch state.status {
        case .ready: "Your phone can connect to \(state.macName)."
        case .viewing: state.controlNeedsAccessibility ? "View only until Accessibility is allowed." : "View only."
        case .controlling: "Your phone can use this Mac’s mouse and keyboard."
        case .paused: "Your phone can’t connect until you resume."
        case .unavailable: state.detail ?? "Check your internet connection, then try again."
        case .needsScreenRecording: "PocketDesk needs Screen Recording to share this Mac."
        case .needsPhone: "Pair your phone to start."
        case .pairing: "Scan the code in the setup window."
        case .approvalRequested: "Allow or decline the phone that scanned your code."
        case .starting: "Connecting to the PocketDesk service."
        }
    }

    @ViewBuilder
    private var phoneRow: some View {
        if state.hasPairedPhone {
            HostSettingsRow("Your iPhone", subtitle: state.status.isSessionLive ? "Paired · Connected now" : "Paired",
                            systemImage: "iphone.gen3") {
                HStack(spacing: 8) {
                    Button("Pair New Phone…", action: actions.pairNewPhone)
                    Button("Remove…") { confirmingRemoval = true }
                }
                .controlSize(.small)
            }
        } else {
            HostSettingsRow("No phone paired", systemImage: "iphone.gen3") {
                Button("Pair a Phone…", action: actions.pairNewPhone)
                    .controlSize(.small)
            }
        }
    }

    private var controlFooter: String? {
        if state.controlNeedsAccessibility {
            return "Control also needs Accessibility permission for PocketDesk Host."
        }
        return nil
    }

    private func permissionRow(_ title: String, systemImage: String, status: HostPermissionStatus,
                               pane: HostSystemSettingsPane) -> some View {
        HostSettingsRow(title, systemImage: systemImage) {
            HStack(spacing: 8) {
                HostPermissionBadge(status: status)
                if !status.isGranted {
                    Button("Open…") { actions.openSystemSettings(pane) }
                        .controlSize(.small)
                }
            }
        }
    }
}
