import SwiftUI
import AppKit
import ScreenCaptureKit

struct BrowserHostSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var browser: BrowserMediaSession
    @ObservedObject var controller: BrowserPeerController
    let selected: SCDisplay?
    let nativeActive: Bool

    private var palette: PocketDeskPalette { PocketDeskPalette.resolve(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.ink)
                Spacer()
                if controller.running {
                    Label("On", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(palette.sage)
                }
            }
            Text(browser.notice)
                .font(.caption)
                .foregroundStyle(palette.muted)
            TextField("Private browser service URL", text: $browser.endpoint)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.running)
            Toggle("Allow this browser to control the mouse and keyboard",
                   isOn: Binding(get: { browser.allowControl }, set: browser.changeControl))
            Text("Viewing and control have separate permission. Native phone pairing is preserved. Only one access mode can be enabled at a time.")
                .font(.caption)
                .foregroundStyle(palette.muted)
            HStack {
                Button("Enable browser access") {
                    if let selected { browser.start(display: selected) }
                }
                .disabled(selected == nil || nativeActive || controller.running)
                Button("Stop browser", action: browser.stop)
                    .disabled(!controller.running)
            }
            Button("Create browser enrollment code", action: controller.makeEnrollment)
                .disabled(!controller.running || controller.connected)
            if !controller.enrollmentCode.isEmpty {
                Text("Paste this private code into the viewer within two minutes; then approve the browser here.")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                Button("Copy browser enrollment code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.enrollmentCode, forType: .string)
                }
            }
            if controller.pendingApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A browser is requesting access. Approve only the browser you are enrolling.")
                        .font(.callout)
                        .foregroundStyle(palette.ink)
                    HStack {
                        Button("Approve browser", action: controller.approveEnrollment)
                            .buttonStyle(.borderedProminent)
                        Button("Decline", action: controller.rejectEnrollment)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.warning.opacity(0.65), lineWidth: 1))
            }
            Button("Revoke browser trust", role: .destructive, action: browser.revoke)
                .controlSize(.small)
            Text("Public hosting and cellular access are not configured. Physical phone testing is still pending.")
                .font(.caption)
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
