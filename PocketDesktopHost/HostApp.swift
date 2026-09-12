import SwiftUI
import ScreenCaptureKit
import AppKit
import Network

@main
struct PocketDesktopHostApp: App {
    @StateObject private var host = HostModel()
    var body: some Scene {
        WindowGroup("Pocket Desktop Host", id: "host") { HostView(host: host) }.defaultSize(width: 520, height: 510)
        Window("Pocket Desktop Practice", id: "practice") { PracticeView() }.defaultSize(width: 1000, height: 680)
        MenuBarExtra("Pocket Desktop", systemImage: "desktopcomputer") {
            Text(host.status)
            Button("Stop sharing") { host.stop() }
            Button("Quit") { host.stop(); NSApplication.shared.terminate(nil) }
        }
    }
}

final class HostModel: NSObject, ObservableObject, SCContentSharingPickerObserver {
    @Published var status = "Choose what to share"
    @Published var metrics = "H.264 · up to 1920 pixels wide · 60 fps target"
    @Published var pairingCode = ""
    @Published var allowControl = false
    @Published var lan = false
    @Published var address = ""
    @Published var inputStatus = "Viewing only"
    @Published var sharing = false
    let stream = HostStream()
    let driver = HostInput()
    override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
        stream.report = { [weak self] value in DispatchQueue.main.async { self?.status = value } }
        stream.metrics = { [weak self] value in DispatchQueue.main.async { self?.metrics = value } }
        stream.pairing = { [weak self] value in DispatchQueue.main.async { self?.pairingCode = value; self?.sharing = !value.isEmpty } }
        stream.input = { [weak self] value in DispatchQueue.main.async { self?.driver.handle(value) } }
        stream.disconnected = { [weak self] in DispatchQueue.main.async { self?.driver.release() } }
        driver.report = { [weak self] value in self?.inputStatus = value }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }
    func choose() {
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lan || IPv4Address(address) != nil || IPv6Address(address) != nil else { status = "Enter this Mac's local IP address first"; return }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        SCContentSharingPicker.shared.defaultConfiguration = configuration
        SCContentSharingPicker.shared.isActive = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let practice = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "practice" }) { practice.makeKeyAndOrderFront(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { SCContentSharingPicker.shared.present() }
    }
    func stop() {
        driver.enabled = false; driver.release(); allowControl = false
        stream.stop(); SCContentSharingPicker.shared.isActive = false
    }
    func updateControl(_ value: Bool) {
        if value && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            allowControl = false
            status = "Allow PocketDesktopHost in System Settings → Accessibility, then enable control again."
        } else { allowControl = value }
        driver.enabled = allowControl
        if !allowControl { driver.release() }
        stream.setControl(allowControl)
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async {
            self.allowControl = false; self.driver.enabled = false; self.driver.configure(filter)
            self.stream.start(filter: filter, lan: self.lan, address: self.address)
        }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { self.status = error.localizedDescription }
    }
}

struct HostView: View {
    @ObservedObject var host: HostModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Your Mac, in your pocket", systemImage: "laptopcomputer").font(.title2.weight(.semibold))
            Text(host.status).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Open practice document") { openWindow(id: "practice") }
                Button(host.sharing ? "Change shared content" : "Choose window or display", action: host.choose).buttonStyle(.borderedProminent)
            }
            Toggle("Connect a device on the same Wi-Fi", isOn: $host.lan).disabled(host.sharing)
            if host.lan { TextField("This Mac's local IP address", text: $host.address).textFieldStyle(.roundedBorder).disabled(host.sharing) }
            if host.sharing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pair your device").font(.headline)
                    Text("Copy the connection code, then paste it into Connect to Mac in Pocket Desktop. A fresh code is created each time sharing starts.").font(.callout).foregroundStyle(.secondary)
                    Button("Copy connection code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host.pairingCode, forType: .string)
                    }.accessibilityIdentifier("copyPairing")
                    Toggle("Allow mouse and keyboard control", isOn: Binding(get: { host.allowControl }, set: host.updateControl))
                    Text(host.inputStatus).font(.caption).foregroundStyle(.secondary)
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Button("Stop sharing", role: .destructive, action: host.stop)
            } else {
                Text("Start with the practice document. Simulator connects on this Mac; enable Wi-Fi only when pairing a physical device.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(host.metrics).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(24).frame(minWidth: 480, minHeight: 440)
    }
}

struct PracticeView: View {
    @State private var text = "POCKET DESKTOP — LIVE MAC DOCUMENT\n\nThis is a real, editable Mac window.\n\nTry selecting a line, typing a correction, using the arrow keys, and scrolling.\n\nThe clock below proves the picture is live.\n\nSmall type: abcdefghijklmnopqrstuvwxyz 0123456789\n\n" + String(repeating: "A little Mac. A useful task.\n", count: 35)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Pocket Desktop Practice").font(.title.bold())
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(context.date.formatted(.dateTime.hour().minute().second()) + String(format: ".%01d", Int(context.date.timeIntervalSince1970 * 10) % 10))
                        .font(.title2.monospacedDigit()).foregroundStyle(.green)
                }
            }
            Text("LIVE MAC WINDOW · safe place to test remote controls").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 21, design: .monospaced)).accessibilityIdentifier("practiceDocument")
                .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
        }.padding(24).frame(minWidth: 720, minHeight: 500)
    }
}
