import SwiftUI
import AppKit
import ScreenCaptureKit

struct BrowserHostSettingsView: View {
    @ObservedObject var browser: BrowserMediaSession
    @ObservedObject var controller: BrowserPeerController
    let selected: SCDisplay?
    let nativeActive: Bool
    var body: some View {
        HostSettingsSection("Browser access · private preview") {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.status).font(.headline)
                Text(browser.notice).font(.caption).foregroundStyle(.secondary)
                TextField("Private browser service URL", text: $browser.endpoint).textFieldStyle(.roundedBorder).disabled(controller.running)
                Toggle("Allow this browser to control the mouse and keyboard", isOn: Binding(get: { browser.allowControl }, set: browser.changeControl))
                Text("Viewing and control have separate permission. Your native phone pairing is preserved. Only one access mode can be enabled at a time.").font(.caption)
                HStack {
                    Button("Enable browser access") { if let selected { browser.start(display: selected) } }.disabled(selected == nil || nativeActive || controller.running)
                    Button("Stop browser", action: browser.stop).disabled(!controller.running)
                }
                Button("Create browser enrollment code", action: controller.makeEnrollment).disabled(!controller.running || controller.connected)
                if !controller.enrollmentCode.isEmpty {
                    Text("Paste this private code into the viewer within two minutes; then approve the browser here.").font(.caption)
                    Button("Copy browser enrollment code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.enrollmentCode, forType:.string) }
                }
                if controller.pendingApproval {
                    Text("A browser is requesting access. Approve only the browser you are enrolling.")
                    HStack { Button("Approve browser", action: controller.approveEnrollment).buttonStyle(.borderedProminent); Button("Decline", action: controller.rejectEnrollment) }
                }
                Button("Revoke browser trust", role:.destructive, action:browser.revoke)
                Text("Public hosting and cellular access are not configured. Physical phone testing is still pending.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
