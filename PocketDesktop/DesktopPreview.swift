import SwiftUI

struct DesktopPreview: View {
    @Bindable var session: DemoSession

    var body: some View {
        GeometryReader { proxy in
            let factor = proxy.size.width / session.scale.width
            let canvas = CGSize(width: session.scale.width, height: proxy.size.height / factor)
            ZStack(alignment: .topLeading) {
                DesktopScene(session: session, canvas: canvas)
                    .frame(width: canvas.width, height: canvas.height)
                    .scaleEffect(factor, anchor: .topLeading)
                PointerShape().fill(.white)
                    .overlay(PointerShape().stroke(.black, lineWidth: 1))
                    .frame(width: 22, height: 30).shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: session.cursor.x * proxy.size.width + 11, y: session.cursor.y * proxy.size.height + 15)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Desktop pointer")
                if session.contextMenu {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Open Welcome") { session.activate("Welcome"); session.contextMenu = false }.desktopTarget("menu-welcome")
                        Button("Focus Window") { session.activate("focus"); session.contextMenu = false }.desktopTarget("menu-focus")
                        Button("Centre Pointer") { session.reset() }.desktopTarget("menu-centre")
                    }
                    .font(.system(size: 14)).padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(30)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .overlayPreferenceValue(HitTargets.self) { anchors in
                GeometryReader { geometry in
                    let frames = anchors.mapValues { geometry[$0] }
                    Color.clear
                        .onAppear { session.targets = frames }
                        .onChange(of: frames) { _, value in session.targets = value }
                }.allowsHitTesting(false)
            }
            .onAppear { session.viewport = proxy.size }
            .onChange(of: proxy.size) { _, size in session.viewport = size }
        }
        .accessibilityIdentifier("desktopPreview")
    }
}

private struct DesktopScene: View {
    @Bindable var session: DemoSession
    let canvas: CGSize
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.25, blue: 0.29), Color(red: 0.21, green: 0.47, blue: 0.45), Color(red: 0.61, green: 0.70, blue: 0.57)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(.white.opacity(0.08)).frame(width: canvas.width * 1.2, height: canvas.height * 0.8).rotationEffect(.degrees(-30)).offset(x: 220, y: 120).frame(width: 0, height: 0).allowsHitTesting(false)
            VStack(spacing: 0) {
                menuBar
                if !session.focusWindow { Spacer(minLength: 16) }
                workspace
                    .padding(.horizontal, session.focusWindow ? 8 : 34)
                    .padding(.vertical, 10)
                if !session.focusWindow { Spacer(minLength: 14); dock.padding(.bottom, 14) }
            }
        }
        .environment(\.colorScheme, .light)
    }
    private var menuBar: some View {
        HStack(spacing: 22) {
            Image(systemName: "desktopcomputer")
            Text("Pocket Desktop").bold()
            Text("File"); Text("Edit"); Text("View")
            Spacer()
            Text("DEMO").font(.system(size: 10, weight: .bold, design: .monospaced))
            Image(systemName: "wifi")
            Text("9:41")
        }
        .font(.system(size: 13)).padding(.horizontal, 18).frame(height: 28)
        .background(.white.opacity(0.45)).foregroundStyle(Color.black.opacity(0.8))
    }
    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in Circle().fill(color.opacity(0.85)).frame(width: 10, height: 10) }
                Spacer()
                Image(systemName: "doc.text"); Text(session.selected).fontWeight(.medium)
                Spacer()
                Button { session.activate("focus") } label: { Image(systemName: session.focusWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).desktopTarget("focus").accessibilityLabel("Focus demo window")
            }
            .font(.system(size: 13)).padding(14).background(Color(white: 0.93))
            HStack(spacing: 0) {
                sidebar
                VStack(alignment: .leading, spacing: 14) {
                    Text(session.selected == "Welcome" ? "Make yourself at home." : session.selected == "Ideas" ? "Built for the fold." : "This is an interaction demo.")
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                    Text("POCKET DESKTOP / PERSONAL WORKSPACE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
                    Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1)
                    DemoDocument(session: session, text: bodyText)
                    HStack {
                        Circle().fill(Color(red: 0.27, green: 0.52, blue: 0.43)).frame(width: 7, height: 7)
                        Text("Local demo · changes stay in this session").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            }
        }
        .foregroundStyle(Color(white: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .frame(maxHeight: .infinity)
    }
    private var bodyText: String {
        switch session.selected {
        case "Ideas": "01  A Mac that fits in your pocket\n\n02  A real trackpad below your work\n\n03  Bigger controls when you need them\n\n04  Unfold for a little more room\n\n05  Your own desktop, wherever you are"
        case "Read me": "This desktop is rendered locally.\nIt is not connected to your Mac.\n\nTry the trackpad, keyboard, scaling,\nand the unfolded layout.\n\nNext: pair with a Mac and replace\nthis canvas with its live video stream."
        default: session.document
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAVOURITES").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).padding(.vertical, 8)
            ForEach(["Welcome", "Ideas", "Read me"], id: \.self) { item in
                Button { session.activate(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item == "Ideas" ? "lightbulb" : "doc.text")
                        Text(item)
                        Spacer(minLength: 0)
                    }.padding(9).background(session.selected == item ? Color.black.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).font(.system(size: 13))
                .desktopTarget(item).accessibilityLabel("Open \(item)")
            }
            Spacer()
            Image(systemName: "externaldrive").foregroundStyle(.secondary)
            Text("Demo workspace").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).frame(width: 154).background(Color(white: 0.965))
    }
    private var dock: some View {
        HStack(spacing: 12) {
            ForEach(Array(["face.smiling", "safari", "note.text", "folder", "terminal"].enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background([Color.blue, .cyan, .orange, .blue, .black][index].gradient, in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(9).background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityHidden(true)
    }
}

private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        for point in [CGPoint(x: 0, y: 23), CGPoint(x: 6, y: 18), CGPoint(x: 12, y: 30), CGPoint(x: 17, y: 27), CGPoint(x: 11, y: 16), CGPoint(x: 22, y: 15)] { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

private struct DemoDocument: View {
    @Bindable var session: DemoSession
    let text: String
    @State private var position = ScrollPosition(edge: .top)
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 18)).lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(session.selectAll && session.selected == "Welcome" ? Color.blue.opacity(0.2) : .clear)
                .accessibilityIdentifier("demoDocument")
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, overflow in
            session.maxScroll = overflow
            session.scroll = max(-overflow, session.scroll)
        }
        .onChange(of: session.scroll) { _, offset in position.scrollTo(y: -offset) }
        .onChange(of: session.document) { _, _ in position.scrollTo(edge: .bottom) }
        .onChange(of: session.selected) { _, _ in position.scrollTo(edge: .top) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
