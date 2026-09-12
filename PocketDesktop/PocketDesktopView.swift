import SwiftUI

struct PocketDesktopView: View {
    @State private var session = DemoSession()
    @State private var showGuide = false
    @State private var remote = RemoteSession()
    @State private var showConnection = false
    @Environment(\.scenePhase) private var scenePhase
    private let mint = Color(red: 0.65, green: 0.87, blue: 0.75)

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(300, geometry.size.height - 150)
            let frameWidth = min(geometry.size.width - 32, availableHeight * 1878 / 2670)
            let controlsHeight = session.unfolded ? (session.keyboard ? min(360, availableHeight * 0.65) : availableHeight * 0.27) : frameWidth * 2670 / 1878 / 2
            VStack(spacing: 16) {
                header
                VStack(spacing: 0) {
                    Group {
                        if remote.connected { LiveVideoView(session: remote) }
                        else { DesktopPreview(session: session) }
                    }.frame(height: session.unfolded ? availableHeight - controlsHeight : controlsHeight)
                    if !session.unfolded {
                        HStack {
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                            Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 3)
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                        }.padding(.horizontal, 12).frame(height: 10).background(Color(white: 0.065))
                    }
                    Group {
                        if remote.connected { RemoteControls(remote: remote, keyboard: $session.keyboard) }
                        else { ControlDeck(session: session) }
                    }.frame(height: controlsHeight)
                }
                .frame(width: session.unfolded ? geometry.size.width - 32 : frameWidth)
                .background(Color(white: 0.095))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.10, blue: 0.105), Color(white: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .tint(mint)
        .sheet(isPresented: $showGuide) { guide }
        .sheet(isPresented: $showConnection) { ConnectionSheet(remote: remote) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { remote.disconnect() } }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pocket Desktop").font(.system(size: 25, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(remote.connected ? .green : .orange).frame(width: 5, height: 5)
                    Text(remote.connected ? remote.status : "Demo workspace · no Mac connected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                if remote.connected { remote.disconnect() } else { showConnection = true }
            } label: {
                Image(systemName: remote.connected ? "xmark.circle" : "desktopcomputer").frame(width: 44, height: 44)
            }.accessibilityLabel(remote.connected ? "Disconnect Mac" : "Connect to Mac").accessibilityIdentifier("connectionButton")
            Button { remote.release(); session.unfolded.toggle(); session.keyboard = false } label: {
                Label(session.unfolded ? "Laptop" : "Unfold", systemImage: session.unfolded ? "laptopcomputer" : "rectangle.expand.vertical")
                    .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 44)
                    .background(.white.opacity(0.07), in: Capsule())
            }.accessibilityIdentifier("layoutToggle")
            Button { showGuide = true } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 21)).frame(width: 44, height: 44)
            }.accessibilityLabel("How to use this demo")
        }.padding(.horizontal, 24).padding(.top, 10)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "ipad")
            Text("iPad mini reference · manual \(session.unfolded ? "unfolded" : "laptop") layout")
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 4)
    }
    private var guide: some View {
        NavigationStack {
            List {
                Section("Try it") {
                    Label("Move on the trackpad to move the desktop pointer.", systemImage: "cursorarrow.motionlines")
                    Label("Tap to open Welcome, Ideas or Read me.", systemImage: "hand.tap")
                    Label("Use two fingers to scroll; two-finger tap for a menu.", systemImage: "hand.draw")
                    Label("Keyboard writes into the Welcome document.", systemImage: "keyboard")
                    Label("Change interface size or focus the window.", systemImage: "textformat.size")
                }
                Section("What is working") {
                    Text("This is a native iOS app running a local demo desktop. Pointer movement, selection, scrolling, typing, focus and interface scaling are interactive.")
                }
                Section("What comes next") {
                    Text("Use Connect to Mac for the first live streaming prototype. Choose content and enable controls in Pocket Desktop Host. The fold layout remains a manual reference; physical device performance is not yet measured.")
                    Text("Desktop scaling here changes the demo canvas. It does not change your Mac's display settings.")
                }
            }
            .navigationTitle("Your pocket workspace")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGuide = false } } }
        }
    }
}

private struct ControlDeck: View {
    @Bindable var session: DemoSession
    var body: some View {
        VStack(spacing: 10) {
            toolbar
            if session.keyboard {
                KeyboardDeck(session: session)
            } else {
                pad
            }
            HStack(spacing: 10) {
                if !session.unfolded || session.keyboard {
                    Text(session.keyboard ? "Typing into Welcome" : "Tap to click · two fingers to scroll")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(session.event).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).accessibilityIdentifier("inputStatus")
            }
        }.padding(16)
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                modeButton("Trackpad", symbol: "rectangle.and.hand.point.up.left", keyboard: false)
                modeButton("Keyboard", symbol: "keyboard", keyboard: true)
            }.padding(3).background(.white.opacity(0.055), in: Capsule())
            Spacer(minLength: 0)
            Menu {
                Picker("Interface size", selection: $session.scale) {
                    ForEach(DesktopScale.allCases) { scale in Text(scale.rawValue).tag(scale) }
                }
            } label: {
                Image(systemName: "textformat.size").frame(width: 44, height: 44)
            }.accessibilityLabel("Interface size").accessibilityValue(session.scale.rawValue)
            Button { session.focusWindow.toggle() } label: {
                Image(systemName: session.focusWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 44, height: 44)
            }.accessibilityLabel(session.focusWindow ? "Show desktop" : "Focus window")
        }.foregroundStyle(Color(white: 0.8))
    }
    private func modeButton(_ title: String, symbol: String, keyboard: Bool) -> some View {
        Button {
            session.keyboard = keyboard
            if keyboard { session.selected = "Welcome"; session.scroll = 0 }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).frame(height: 38)
                .background(session.keyboard == keyboard ? .white.opacity(0.12) : .clear, in: Capsule())
        }.accessibilityIdentifier(keyboard ? "keyboardMode" : "trackpadMode")
    }
    private var pad: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.105)], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: session.unfolded ? 22 : 30, weight: .ultraLight))
                    if !session.unfolded { Text("Your whole surface is a trackpad").font(.system(size: 12)) }
                }.foregroundStyle(.white.opacity(0.26)).allowsHitTesting(false)
                TrackpadSurface(onMove: session.move, onScroll: { delta in
                    session.scroll = min(0, max(-session.maxScroll, session.scroll + delta.height))
                    session.event = "Scroll \(Int(session.scroll))"
                }, onClick: session.click, onRightClick: {
                    session.contextMenu = true; session.event = "Context menu"
                }).accessibilityIdentifier("trackpadSurface")
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.06), lineWidth: 1))
            HStack(spacing: 1) {
                Button { session.click() } label: { Text("Click").frame(maxWidth: .infinity).frame(height: 44) }
                    .accessibilityIdentifier("leftClick")
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 15)
                Button { session.reset() } label: { Image(systemName: "scope").frame(width: 54, height: 44) }.accessibilityLabel("Centre pointer")
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 15)
                Button { session.contextMenu = true; session.event = "Context menu" } label: { Text("Right click").frame(maxWidth: .infinity).frame(height: 44) }
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct KeyboardDeck: View {
    @Bindable var session: DemoSession
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { session.command.toggle() } label: { Text("⌘").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .background(session.command ? .white.opacity(0.3) : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Command modifier")
                ForEach(["⇥", ",", "!"], id: \.self) { key in
                    Button { session.insert(key == "⇥" ? "    " : key) } label: { Text(key).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                Button { session.document = ""; session.event = "Document cleared" } label: { Text("Clear").font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("clearDocument")
            }
            ForEach(["qwertyuiop", "asdfghjkl", "zxcvbnm"], id: \.self) { row in
                HStack(spacing: 5) {
                    if row == "zxcvbnm" {
                        Button { session.shift.toggle() } label: { Image(systemName: "shift").frame(maxWidth: .infinity, maxHeight: .infinity) }
                            .accessibilityLabel("Shift").background(session.shift ? .white.opacity(0.3) : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(Array(row), id: \.self) { char in
                        Button { session.insert(String(char)) } label: {
                            Text(session.shift ? String(char).uppercased() : String(char)).font(.system(size: 20))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if row == "zxcvbnm" {
                        Button { session.delete() } label: { Image(systemName: "delete.left").frame(maxWidth: .infinity, maxHeight: .infinity) }
                            .accessibilityLabel("Delete").background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.horizontal, row == "asdfghjkl" ? 16 : 0)
            }
            HStack(spacing: 6) {
                Button { session.insert(".") } label: { Text(".").frame(width: 50, height: 44) }.background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Button { session.insert(" ") } label: { Text("space").font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Space")
                Button { session.insert("\n") } label: { Image(systemName: "return").frame(width: 64, height: 44) }
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Return")
            }
        }.foregroundStyle(.white.opacity(0.85)).buttonStyle(.plain)
    }
}
