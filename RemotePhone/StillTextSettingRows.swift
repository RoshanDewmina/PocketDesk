import SwiftUI

struct StillTextSettingRows: View {
    @AppStorage(StillTextPreferences.sharpenKey) private var sharpen = false
    @AppStorage(StillTextPreferences.textClarityKey) private var clarity = false
    @AppStorage(HEVC444Policy.preferenceKey) private var fullColor = false
    var body: some View {
        Toggle("Sharpen still text", isOn: $sharpen)
            .frame(minHeight: 44)
            .disabled(fullColor)
            .accessibilityIdentifier("remote.sharpenStillText")
        Text(fullColor
             ? "Off while Full color detail is on. Full color already keeps text edges sharp."
             : "When the picture holds still, the middle of your Mac's screen is sent as an exact image so small text reads cleanly. Uses more bandwidth. Stays off while Full color detail is on, on this iPhone or your Mac. Applies from your next connection.")
            .font(.footnote).foregroundStyle(.secondary)
        Toggle("Text clarity", isOn: $clarity)
            .frame(minHeight: 44)
            .accessibilityIdentifier("remote.textClarity")
        Text("When the picture holds still, your Mac spends more of the connection on text detail. A busy connection still comes first. Works with either option above. Applies from your next connection.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
