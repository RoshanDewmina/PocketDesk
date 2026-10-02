import SwiftUI

struct FullColorSettingRows: View {
    @AppStorage(HEVC444Policy.preferenceKey) private var enabled = false
    var body: some View {
        Toggle("Full color detail (experimental)", isOn: $enabled)
            .frame(minHeight: 44)
            .accessibilityIdentifier("remote.experimentalFullColor")
        Text("Enable on both your Mac and \(DeviceWord.current), then quit and reopen both apps. Requires compatible hardware. Uses more bandwidth; picture quality and battery use are still being tested.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
