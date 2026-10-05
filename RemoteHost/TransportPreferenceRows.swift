import SwiftUI

struct TransportPreferenceRows: View {
    @AppStorage(HEVC444Policy.preferenceKey) private var fullColor = false
    #if DEBUG
    @AppStorage("farsideRelayPacketRepair") private var repair = false
    #endif
    var body: some View {
        HostSettingsSection("Experiments") {
            HostSettingsRow("Full color detail",
                            subtitle: "Turn on for both your Mac and iPhone, then quit and reopen both apps. Needs compatible hardware and uses more bandwidth; picture quality and battery use are still being tested.") {
                HostSwitch(label: "Full color detail after restarting Farside", isOn: fullColor) { fullColor = $0 }
                    .accessibilityIdentifier("farside.settings.experimentalFullColor")
            }
            #if DEBUG
            HostSettingsRow("Relay packet repair",
                            subtitle: "Packet loss testing. Quit and reopen the Mac app after changing this. Video quality under packet loss is still being tested.") {
                HostSwitch(label: "Relay packet repair after restarting Farside", isOn: repair) { repair = $0 }
                    .accessibilityIdentifier("farside.settings.relayPacketRepair")
            }
            #endif
        }
    }
}
