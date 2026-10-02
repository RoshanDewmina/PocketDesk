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
