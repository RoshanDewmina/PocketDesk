import SwiftUI

/// Settings from Home's ⋯ menu: the selected Mac's options, alerts, the optional owner check before
/// Connect and Forget This Mac, the gesture lessons, and privacy and data removal.
struct SecuritySettingsSheet: View {
    var owner: DeviceOwnerGate?
    @ObservedObject var model: PhoneRemoteModel
    @ObservedObject var connection: RemoteCoordinator
    /// A Mac is selected, or saved Macs wait to be chosen.
    var showsMacOptions: Bool
    var pairAnotherMac: () -> Void
    var howToSteer: () -> Void
    @State private var required = PhoneSecurityPreferences().requireOwnerToConnect
    @State private var changing = false
    @State private var note: String?
    @State private var showAlerts = false
    @State private var showServerData = false
    @State private var showLegal = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var gate: DeviceOwnerGate { owner ?? .live }

    var body: some View {
        let name = gate.authenticator.biometryName
        NavigationStack {
            Form {
                if showsMacOptions {
                    Section {
                        Toggle("Local network only", isOn: Binding(get: { connection.localOnly }, set: { model.setLocalOnly($0) }))
                            .toggleStyle(FarsideSwitchStyle())
                            .disabled(!connection.localOnly && connection.invitation?.hasOwnerLocalIdentity != true)
                            .listRowBackground(Farside.Palette.panel)
                            .accessibilityIdentifier("home.localOnly")
                        row("Pair another Mac", systemImage: "plus", action: pairAnotherMac)
                            .accessibilityIdentifier("settings.pairAnother")
                    } header: {
                        Text("Your Mac").farsideCaption()
                    } footer: {
                        Text(macFooter).foregroundStyle(Farside.Palette.ash)
                    }
                    Section {
                        row("Alerts & Lock Screen", systemImage: "bell") { showAlerts = true }
                            .accessibilityLabel("Alerts and Lock Screen")
                            .accessibilityIdentifier("home.agentAlerts")
                    }
                }
                Section {
                    Toggle("Require \(name) to connect", isOn: Binding(get: { required }, set: change))
                        .toggleStyle(FarsideSwitchStyle())
                        .disabled(changing)
                        .listRowBackground(Farside.Palette.panel)
                        .accessibilityIdentifier("settings.security.requireOwner")
                } header: {
                    Text("Security").farsideCaption()
                } footer: {
                    Text(note ?? "Asks before Connect, including from the widget, Siri and links, and before Forget This Mac. Your passcode works too. It never interrupts a session that is already open.")
                        .foregroundStyle(Farside.Palette.ash)
                }
                Section {
                    row("How to steer · 40 sec", systemImage: "hand.draw", action: howToSteer)
                        .accessibilityLabel("How to steer, 40 seconds")
                        .accessibilityIdentifier("settings.howToSteer")
                }
                Section {
                    row("Privacy Policy", systemImage: "hand.raised") { openURL(AnywherePlan.privacyURL) }
                        .accessibilityIdentifier("settings.privacy")
                    row("Server Data", systemImage: "externaldrive") { showServerData = true }
                        .accessibilityIdentifier("settings.serverData")
                    row("Third-Party Notices", systemImage: "doc.text") { showLegal = true }
                        .accessibilityIdentifier("settings.legal")
                } header: {
                    Text("Privacy").farsideCaption()
                } footer: {
                    Text("Server Data removes this \(DeviceWord.current)’s Farside Anywhere link from our server.")
                        .foregroundStyle(Farside.Palette.ash)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Farside.Palette.void2)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Farside.Palette.bone)
        .farsideCompactDetents([.medium, .large])
        .farsideSheet()
        .sheet(isPresented: $showAlerts) { AgentAlertsSettingsSheet(center: .shared, registrar: .shared) }
        .sheet(isPresented: $showServerData) {
            ServerDataRemovalView(connection: connection, access: AnywhereAccess.shared).farsideSheet()
        }
        .sheet(isPresented: $showLegal) { LegalNoticesView().farsideRegularSheet() }
    }

    private var macFooter: String {
        guard let invitation = connection.invitation else {
            return "Choose a saved Mac first. Then turn on Local network only here and in Farside on your Mac."
        }
        var text = invitation.hasOwnerLocalIdentity
            ? "Connects only when your \(DeviceWord.current) and Mac are on the same network, never over the internet. Turn it on in Farside on your Mac too."
            : "To use Local network only, pair again with a new code from Farside on your Mac. Connect works as usual until then."
        if invitation.ownerPairID == nil {
            text += "\n\nSend to My Mac needs a new pairing: scan a new code from Farside on your Mac. Check the new pairing works before you forget the old one."
        }
        return text
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Farside.Palette.bone)
                Spacer()
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.ash)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .frame(minHeight: 44)
        .listRowBackground(Farside.Palette.panel)
    }

    private func change(_ on: Bool) {
        guard !changing else { return }
        changing = true
        Task { @MainActor in
            let changed = await gate.setRequired(on)
            required = gate.preferences.requireOwnerToConnect
            note = changed ? nil : (on ? "This \(DeviceWord.current) needs a passcode first, or the check didn’t pass." : "The check didn’t pass, so it stays on.")
            changing = false
        }
    }
}
