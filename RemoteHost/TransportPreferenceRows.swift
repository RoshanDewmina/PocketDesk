import SwiftUI

struct TransportPreferenceRows: View {
    @AppStorage(HEVC444Policy.preferenceKey) private var fullColor = false
    @AppStorage("farsideRelayPacketRepair") private var repair = false
    var body: some View {
        HostSettingsSection("Experimental full color") {
            Toggle("Full color detail after restarting Farside", isOn: $fullColor)
                .accessibilityIdentifier("farside.settings.experimentalFullColor")
            Text("Enable on both your Mac and iPhone, then quit and reopen both apps. Requires compatible hardware. Uses more bandwidth; picture quality and battery use are still being tested.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        HostSettingsSection("Packet loss testing") {
            Toggle("Relay packet repair after restarting Farside", isOn: $repair)
                .accessibilityIdentifier("farside.settings.relayPacketRepair")
            Text("Experimental. Quit and reopen the Mac app after changing this setting. Video quality under packet loss is still being tested.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
