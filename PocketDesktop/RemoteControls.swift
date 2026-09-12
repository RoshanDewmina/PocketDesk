import SwiftUI

struct ConnectionSheet: View {
    @Bindable var remote: RemoteSession
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Your Mac") {
                    Text("Open Pocket Desktop Host on your Mac, choose a window or display, and copy its connection code.")
                    TextField("Paste connection code", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("pairingCode")
                    PasteButton(payloadType: String.self) { strings in code = strings.first ?? "" }
                    Button(remote.connecting ? "Connecting…" : "Connect") { remote.connect(code: code) }
                        .disabled(remote.connecting || code.isEmpty).accessibilityIdentifier("connectMac")
                    Text(remote.status).foregroundStyle(.secondary)
                }
                Section("This first version") {
                    Text("A Mac-selected window or display, encrypted video, and optional remote controls. Keep the Mac awake and unlocked. Simulator uses this Mac's local connection.")
                    Text("Choose Fit for the complete picture, or Fill for a closer view. This changes the video view, not your Mac's display scaling.")
                }
            }
            .navigationTitle("Connect to Mac")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: remote.connected) { _, connected in if connected { code = ""; dismiss() } }
        }
    }
}

struct RemoteControls: View {
    @Bindable var remote: RemoteSession
    @Binding var keyboard: Bool
    @State private var draft = ""
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                HStack {
                    Picker("Controls", selection: $keyboard) {
                        Text("Trackpad").tag(false); Text("Keyboard").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 250)
                    Spacer(minLength: 0)
                    Button(remote.zoom ? "Fit" : "Fill") { remote.zoom.toggle() }.frame(minWidth: 44, minHeight: 44)
                }
                if !remote.usable {
                    Text("Viewing only · enable control on your Mac").font(.caption).foregroundStyle(.orange)
                }
                if keyboard {
                    VStack(spacing: 8) {
                        HStack {
                            TextField("Write on your Mac", text: $draft, axis: .vertical).lineLimit(1...3)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("remoteText")
                            Button("Send") { remote.text(draft); draft = "" }.disabled(draft.isEmpty || !remote.usable)
                        }
                        HStack {
                            modifier("⌘", active: $remote.command); modifier("⇧", active: $remote.shift)
                            modifier("⌥", active: $remote.option); modifier("⌃", active: $remote.control)
                            ForEach(["a", "c", "v", "z"], id: \.self) { key in
                                Button(key.uppercased()) { remote.key(key) }.frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        HStack {
                            key("Esc", "escape"); key("Tab", "tab"); key("⌫", "delete"); key("↵", "return")
                        }
                        HStack { key("←", "left"); key("↓", "down"); key("↑", "up"); key("→", "right") }
                        Text("Compose with the native keyboard, then Send. Modifiers apply once to a shortcut.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.055))
                        VStack(spacing: 8) {
                            Image(systemName: remote.dragging ? "hand.draw.fill" : "cursorarrow.motionlines").font(.largeTitle)
                            Text(remote.dragging ? "Dragging · tap Release to finish" : "Tap to click · two fingers to scroll").font(.caption)
                        }.foregroundStyle(.secondary).allowsHitTesting(false)
                        TrackpadSurface(onMove: { remote.move($0, viewport: geometry.size) }, onScroll: remote.scroll,
                            onClick: { remote.click() }, onRightClick: { remote.click("right") })
                            .accessibilityIdentifier("remoteTrackpad")
                    }
                    HStack {
                        Button("Click") { remote.click() }
                        Spacer()
                        Button("Double") { remote.click("double") }
                        Spacer()
                        Button(remote.dragging ? "Release" : "Drag") { remote.toggleDrag() }.tint(remote.dragging ? .orange : .accentColor)
                        Spacer()
                        Button("Right click") { remote.click("right") }
                    }.font(.caption).frame(minHeight: 44)
                }
                HStack {
                    Text("\(remote.fps) fps · encode \(remote.encodeMS, specifier: "%.1f") ms").accessibilityIdentifier("streamStats")
                    Spacer(minLength: 0)
                    Text(remote.event)
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(14)
            .onChange(of: keyboard) { _, _ in remote.release() }
            .onDisappear { remote.release() }
        }
    }
    private func modifier(_ name: String, active: Binding<Bool>) -> some View {
        Button(name) { active.wrappedValue.toggle() }.frame(maxWidth: .infinity, minHeight: 44)
            .background(active.wrappedValue ? .white.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private func key(_ label: String, _ code: String) -> some View {
        Button(label) { remote.key(code) }.frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
