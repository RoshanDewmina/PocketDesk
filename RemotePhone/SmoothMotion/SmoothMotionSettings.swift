import SwiftUI

/// Settings → Picture → Smooth motion.
struct SmoothMotionPictureRows: View {
    @Binding var mode: SmoothMotionMode

    var body: some View {
        FarsideSegmented(label: "Smooth motion",
                         options: SmoothMotionMode.allCases.map { (value: $0, title: $0.title) },
                         selection: $mode)
            .accessibilityIdentifier("remote.smoothMotion")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        Text(mode.footnote)
            .font(.footnote).foregroundStyle(Farside.Palette.ash)
            .listRowBackground(Farside.Palette.panel)
    }
}

/// Settings → Diagnostics: this session's smooth-motion evidence, refreshed once a second.
struct SmoothMotionDiagnosticsRows: View {
    @Binding var upscale: Bool
    let showsTestingControls: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                Text("Smooth motion").foregroundStyle(Farside.Palette.bone)
                Text(InterpolationAvailability.summary)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
            }
            .font(.footnote)
            .foregroundStyle(Farside.Palette.ash)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote.smoothMotionDiagnostics")
        }
        .listRowBackground(Farside.Palette.panel)
        if showsTestingControls {
            Toggle("Smooth motion 2× upscale", isOn: $upscale)
                .toggleStyle(FarsideSwitchStyle())
                .listRowBackground(Farside.Palette.panel)
            Text("For legibility A/B tests. Interpolates at half size and lets VideoToolbox scale it back up (iOS 27). Off keeps full-size interpolation.")
                .font(.footnote).foregroundStyle(Farside.Palette.ash)
                .listRowBackground(Farside.Palette.panel)
        }
    }

    private var lines: [String] {
        SmoothMotionController.active?.diagnostics.snapshot().settingsLines ?? ["No stream on screen."]
    }
}

extension SmoothMotionController {
    static let upscaleKey = "smoothMotion.upscale2x"

    /// The stream statistics overlay line, nil without a stream on screen.
    static var overlayLine: String? {
        active?.diagnostics.snapshot().overlayLine
    }
}
