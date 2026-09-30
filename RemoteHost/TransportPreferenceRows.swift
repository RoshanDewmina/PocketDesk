import SwiftUI

struct TransportPreferenceRows: View {
    @AppStorage("farsideRelayPacketRepair") private var repair = false
    var body: some View {
        HostSettingsSection("Packet loss testing") {
            Toggle("Relay packet repair after restarting Farside", isOn: $repair)
                .accessibilityIdentifier("farside.settings.relayPacketRepair")
            Text("Experimental. Quit and reopen the Mac app after changing this setting. Video quality under packet loss is still being tested.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
