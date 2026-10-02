// Offscreen snapshot fixture: exact production View body and copy enum, no HUD controller.
// Source: RemoteHost/CouchHUD.swift SHA-256 c2a80646e7845770ee986bca7b4d896066f0cde0a3fe3eda29b42263acf7e2fe
// Source: RemoteShared/CouchProtocol.swift SHA-256 d4105751b09bf321c1fdd7559f9f94dd942058a53625014178a13c314db5a682
import SwiftUI

enum SessionModeRefusal: String, Equatable, CaseIterable {
    case notLocal, controlOff, screenRecording, displayUnavailable
}

enum CouchCopy {
    static let entryTitle = "Couch mode"
    static let entryCaption = "Trackpad and keys. No picture."
    static let checking = "Checking you’re on the same network…"
    static let notLocal = "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac’s network and try again."
    static let controlOff = "Control is off on your Mac. Turn on Allow control in Farside’s menu."
    static let updateMac = "Update Farside on your Mac to use Couch mode. Showing the picture instead."
    static let notAnswering = "Your Mac isn’t answering. Input paused."
    static let needsScreenRecording = "Your Mac needs Screen Recording to show the picture."
    static let displayUnavailable = "Couldn’t load your Mac’s display. Still in Couch mode. Try showing the picture again."
    static let showingPicture = "Showing your Mac’s screen…"
    static let restHeadline = "Look at your Mac. This is its trackpad."
    static let restDeadpan = "The picture is the one on your wall."
    static let hud = "iPhone is steering this Mac · Couch mode, no picture shared"
    static let connectWithPicture = "Connect with picture"
    /// Coordinator status when the phone itself stops a Couch attempt that did not get a local route.
    static let phoneRefusedStatus = "Couch mode needs the same network as your Mac."

    static func refusal(_ reason: SessionModeRefusal) -> String {
        switch reason {
        case .notLocal: notLocal
        case .controlOff: controlOff
        case .screenRecording: needsScreenRecording
        case .displayUnavailable: displayUnavailable
        }
    }
}

struct CouchHUDView: View {
    var body: some View {
        HStack(spacing: Farside.Space.s) {
            HostLiveDot(size: 8)
            Text(CouchCopy.hud)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Farside.Palette.bone)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Farside.Space.l)
        .padding(.vertical, Farside.Space.m)
        .background(HostTheme.popoverBackground,
                    in: RoundedRectangle(cornerRadius: Farside.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Farside.Radius.card, style: .continuous)
            .strokeBorder(Farside.Palette.line2, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// Offscreen snapshot fixture: exact production styles and View body, no curtain controller.
// Source: RemoteHost/PrivacyCurtain.swift SHA-256 79ee9b39f80a9b912576c5c7f7c9ca64c8236478fc7e418e256d6a250b0bcbc6
enum PrivacyCurtainStyle: Equatable {
    case sharing, away, awayLockFailed
}

struct PrivacyCurtainView: View {
    var style: PrivacyCurtainStyle = .sharing

    private var title: LocalizedStringKey {
        switch style {
        case .sharing: "This Mac is being used remotely"
        case .away, .awayLockFailed: "Away mode is on"
        }
    }

    private var line: LocalizedStringKey {
        switch style {
        case .sharing: "Press Esc three times to lift"
        case .away: "Touching the keyboard, mouse or trackpad locks this Mac"
        case .awayLockFailed: "This Mac stays covered. Unlock it at the Mac to continue"
        }
    }

    var body: some View {
        ZStack {
            Farside.Palette.void.ignoresSafeArea()
            VStack(spacing: Farside.Space.s) {
                HStack(spacing: Farside.Space.s) {
                    Circle()
                        .fill(Farside.Palette.ember)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Farside.Palette.bone)
                }
                Text(line)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Farside.Palette.ash)
            }
            .multilineTextAlignment(.center)
            .padding(Farside.Space.xl)
        }
    }
}

// Offscreen snapshot fixture: exact production View body; private visibility relaxed for test access.
// Open and Dismiss callbacks are no-ops in the snapshot. No link or clipboard effect.
// Source: RemoteHost/HostFileTransfer.swift SHA-256 cc19b6e8eb8f5066cb8d08008bc1be5fdfd1bfda12a8847e3f8a8f2bf23ccccd
struct HostLinkOfferView: View {
    let url: URL
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(url.host() ?? url.absoluteString)
                .font(.headline)
                .lineLimit(1)
            Text("Also copied to the clipboard. Farside doesn’t open links by itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss", action: dismiss)
                    .accessibilityIdentifier("farside.link.dismiss")
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("farside.link.open")
            }
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
    }
}

// Offscreen component fixture: exact production permission-recovery popover content.
// The system popover container/arrow is deliberately not presented.
// Source: RemoteHost/HostSetupView.swift SHA-256 5f8b78bcf8bb91da12ca41e50245e97c6304bedfcff3e3d8bf6dc59fafd22b01
struct HostPermissionRecoverySnapshotBody: View {
    let recovery: String

    var body: some View {
        Text(recovery)
        .font(.system(size: 13))
        .foregroundStyle(Farside.Palette.bone)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280)
        .padding(16)
        .preferredColorScheme(.dark)
    }
}
