import SwiftUI

/// Settings → Security: the optional owner check before Connect and Forget this Mac.
struct SecuritySettingsSheet: View {
    var owner: DeviceOwnerGate?
    @State private var required = PhoneSecurityPreferences().requireOwnerToConnect
    @State private var changing = false
    @State private var note: String?
    @Environment(\.dismiss) private var dismiss

    private var gate: DeviceOwnerGate { owner ?? .live }

    var body: some View {
        let name = gate.authenticator.biometryName
        NavigationStack {
            Form {
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
