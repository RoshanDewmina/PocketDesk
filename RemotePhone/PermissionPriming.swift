import SwiftUI
import AVFoundation
import Speech

/// Remembers which permissions were explained before iOS asks. The system prompt still decides.
enum PermissionPrimer {
    private static func key(_ kind: PermissionKind) -> String { "primed.\(kind.rawValue)" }

    static func wasPrimed(_ kind: PermissionKind, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(kind))
    }

    static func markPrimed(_ kind: PermissionKind, in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(kind))
    }

    /// Microphone priming is explained once, before either iOS prompt. Local Network has no status API.
    static func needsPriming(_ kind: PermissionKind, in defaults: UserDefaults = .standard,
                             microphoneNeedsAuthorization: () -> Bool = {
                                 AVAudioApplication.shared.recordPermission == .undetermined
                                     || SFSpeechRecognizer.authorizationStatus() == .notDetermined
                             }) -> Bool {
        guard !LaunchOptions.suppressesOnboarding else { return false }
        switch kind {
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        case .localNetwork:
            return !wasPrimed(.localNetwork, in: defaults)
        case .microphone:
            // Continue marks this before re-entering voice input; iOS has not asked yet.
            return !wasPrimed(.microphone, in: defaults) && microphoneNeedsAuthorization()
        case .notifications:
            return !wasPrimed(.notifications, in: defaults)
        }
    }

    static var cameraDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }
}

/// A pre-alert screen: what iOS is about to ask, why, and one Continue button (per the HIG,
/// no cancel and no picture of the system alert).
struct PermissionPrimingView: View {
    let kind: PermissionKind
    let onContinue: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FarsideHalftone(style: HalftoneStyle(cell: 5, dust: 0.04), scene: FarsideArt.priming(kind))
                    .frame(height: verticalSizeClass == .compact ? 130 : 230)
                    .padding(.horizontal, -Farside.Space.l)
                FarsideHeading(copy.heading, accent: copy.accent, size: 32)
                    .padding(.top, Farside.Space.xs)
                Text(copy.body)
                    .font(.body)
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Farside.Space.s)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(copy.points.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .firstTextBaseline, spacing: Farside.Space.s) {
                            Image(systemName: point.symbol)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Farside.Palette.bone)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(point.text)
                                .font(.subheadline)
                                .foregroundStyle(Farside.Palette.bone)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Farside.Space.m)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            if index < copy.points.count - 1 {
                                Rectangle().fill(Farside.Palette.line).frame(height: 1).padding(.leading, 52)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .farsidePlate()
                .padding(.top, Farside.Space.l)
            }
            .padding(.horizontal, Farside.Space.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Farside.Space.s) {
                Button("Continue") {
                    PermissionPrimer.markPrimed(kind)
                    onContinue()
                }
                .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                .accessibilityIdentifier("priming.continue")
                Text(copy.footnote).farsideCaption().multilineTextAlignment(.center)
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.bottom, Farside.Space.s)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(Farside.Palette.void)
        }
        .background(FarsideBackground())
        .accessibilityIdentifier("priming.\(kind.rawValue)")
    }

    private struct Copy {
        var heading: String
        var accent: String?
        var body: String
        var points: [(symbol: String, text: String)]
        var footnote: String
    }

    private var copy: Copy {
        switch kind {
        case .camera:
            Copy(heading: "Point, then pair.", accent: "then",
                 body: "Farside uses the camera only to read the pairing code on your Mac.",
                 points: [("qrcode.viewfinder", "Aim at the code in the Farside window on your Mac."),
                          ("eye.slash", "Nothing is recorded or saved."),
                          ("hand.tap", "iOS asks next. Choose Allow.")],
                 footnote: "No camera? You can paste the code instead")
        case .localNetwork:
            Copy(heading: "Connect faster at home.", accent: "faster",
                 body: "When your iPhone and Mac share Wi-Fi, Farside connects to it directly.",
                 points: [("wifi", "iOS will ask to find devices on your local network."),
                          ("hand.tap", "Choose Allow so Farside can reach your Mac at home."),
                          ("lock", "Only your paired Mac is contacted. Nothing is scanned or shared.")],
                 footnote: "You can change this later in Settings")
        case .microphone:
            Copy(heading: "Two quick permissions.", accent: "quick",
                 body: "Speak and Farside types it on your Mac.",
                 points: [("mic", "The microphone hears you only while the Mic key is lit."),
                          ("text.bubble", "Speech is turned into text on this iPhone. Audio never leaves it."),
                          ("hand.tap", "iOS asks twice: microphone, then speech recognition.")],
                 footnote: "Typing always works without these")
        case .notifications:
            Copy(heading: "Know when it needs you.", accent: "needs",
                 body: "Farside can tap your shoulder when a coding agent on your Mac is stuck on something only a human can click.",
                 points: [("bell.badge", "iOS asks next. Choose Allow."),
                          ("eye.slash", "Alerts say who needs you. Never what is on your screen."),
                          ("moon", "Breaking through Focus is a separate switch, and iOS lets you turn it off.")],
                 footnote: "Farside works fine without notifications")
        }
    }
}
