import XCTest
import SwiftUI
import AppKit

/// Renders the Farside host's popover, menu-bar mark, setup window and Settings offscreen in the
/// app's dark appearance. Set POCKETDESK_SNAPSHOT_DIR to write farside-mac-<view>.png files.
@MainActor
final class HostUISnapshotTests: XCTestCase {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["POCKETDESK_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let expires = Date().addingTimeInterval(104)
    private static let code = "pocketdesk:" + String(repeating: "c29tZS1wcml2YXRlLXBhaXJpbmctY29kZQ", count: 8)
    private static let measured = HostSessionReadout(route: .direct, roundTripMs: 14, framesPerSecond: 60)

    private func ready(_ status: HostStatus, change: (inout HostViewState) -> Void = { _ in }) -> HostViewState {
        var state = HostViewState()
        state.macName = "Roshan’s MacBook Air"
        state.appListName = "PocketDesk Host"
        state.screenRecording = .granted
        state.accessibility = .granted
        state.hasPairedPhone = true
        state.setupStep = .done
        state.status = status
        state.openAtLogin = true
        state.displays = [HostDisplayOption(id: 1, name: "Built-in Retina Display")]
        state.selectedDisplayID = 1
        change(&state)
        return state
    }

    func testMenuStates() throws {
        let now = Date()
        let states: [(String, HostViewState)] = [
            ("popover-live", ready(.controlling) { $0.session = Self.measured }),
            ("popover-view-only", ready(.viewing) {
                $0.accessibility = .denied
                $0.session = HostSessionReadout(route: .relayed, roundTripMs: 48, framesPerSecond: 30)
            }),
            ("popover-ready", ready(.ready)),
            ("popover-approval", ready(.approvalRequested) { $0.hasPairedPhone = false }),
            ("popover-paused", ready(.paused) { $0.pausedUntil = now.addingTimeInterval(540) }),
            ("popover-off", ready(.paused)),
            ("popover-locked", ready(.unavailable) { $0.availability = .locked }),
            ("popover-unavailable", ready(.unavailable) {
                $0.detail = "Couldn’t reach the connection. Check this Mac’s internet, then try again."
            }),
            ("popover-needs-setup", ready(.needsScreenRecording) { $0.screenRecording = .denied })
        ]
        for (name, state) in states {
            let presentation = HostPopoverPresentation.make(for: state, now: now)
            XCTAssertLessThanOrEqual(presentation.headline.count, 34, name)
            XCTAssertEqual(presentation.mood == .live, state.status.isSessionLive, name)
            try render(name, HostPopoverReviewScene(state: state, now: now))
        }
    }

    func testMenuBarMark() throws {
        for state in HostMarkState.allCases {
            let image = HostMenuBarIcon.image(for: state, accessibilityDescription: "Farside, \(state)")
            XCTAssertEqual(image.isTemplate, state != .live, "Only the live mark carries its own colors")
            XCTAssertEqual(image.accessibilityDescription, "Farside, \(state)")
            XCTAssertLessThanOrEqual(image.size.height, 22, "Fits the menu bar")
        }

        let strip = HostMenuBarReviewStrip()
        let bitmap = try render("menubar", strip, fixedSize: strip.size)
        let scale = CGFloat(bitmap.pixelsWide) / strip.size.width
        for (row, dark) in [(0, false), (1, true)] {
            for (index, state) in HostMarkState.allCases.enumerated() {
                let frame = strip.imageFrame(row: row, column: index)
                let ember = count(in: bitmap, frame: frame, scale: scale) { isEmber($0) }
                XCTAssertEqual(ember > 0, state == .live, "Ember tip only while live (\(state), dark: \(dark))")
                if state == .live {
                    let body = luminance(bitmap, point: CGPoint(x: frame.minX + 2, y: frame.minY + 6), scale: scale)
                    if dark {
                        XCTAssertGreaterThan(body, 0.6, "Live mark body follows a dark menu bar")
                    } else {
                        XCTAssertLessThan(body, 0.4, "Live mark body follows a light menu bar")
                    }
                }
            }
        }
    }

    func testHalftoneArtKeepsTextPlatesClearAndEmberForContact() {
        let strip = CGSize(width: 360, height: 96)
        for mood in [HostHalftoneMood.live, .calm, .paused, .attention] {
            let field = HostHalftoneField(scene: .popoverStrip(mood), size: strip, cell: 2)
            var ember = 0, bone = 0, underCaption = 0
            for row in 0..<field.rows {
                for column in 0..<field.columns {
                    let ink = field.ink(column: column, row: row)
                    if ink == .ember { ember += 1 }
                    if ink == .bone { bone += 1 }
                    let center = CGPoint(x: (CGFloat(column) + 0.5) * 2, y: (CGFloat(row) + 0.5) * 2)
                    if ink != .none, center.x < strip.width * 0.72, center.y > strip.height * 0.62 { underCaption += 1 }
                }
            }
            XCTAssertEqual(ember > 0, mood == .live, "Ember only while live: \(mood)")
            XCTAssertGreaterThan(bone, 50, "The strip has art: \(mood)")
            XCTAssertEqual(underCaption, 0, "No dots under the caption plate: \(mood)")
        }

        for (reach, contact) in [(0, false), (3, false), (3, true)] {
            let field = HostHalftoneField(scene: .setupRail(reach: reach, contact: contact),
                                          size: CGSize(width: 280, height: 520), cell: 2)
            var ember = 0
            for row in 0..<field.rows {
                for column in 0..<field.columns where field.ink(column: column, row: row) == .ember { ember += 1 }
            }
            XCTAssertEqual(ember > 0, contact, "Rail ember only at contact (reach \(reach))")
        }

        let image = HostHalftoneRenderer.image(scene: .popoverStrip(.calm), size: strip, cell: 2, scale: 2)
        XCTAssertEqual(image?.width, 720)
        XCTAssertEqual(image?.height, 192)
        XCTAssertTrue(image === HostHalftoneRenderer.image(scene: .popoverStrip(.calm), size: strip, cell: 2, scale: 2),
                      "Still art is drawn once and cached")
    }

    func testSetupSteps() throws {
        var fresh = HostViewState()
        fresh.appListName = "PocketDesk Host"
        fresh.screenRecording = .denied
        fresh.accessibility = .denied
        fresh.setupStep = .screenRecording
        XCTAssertEqual(HostSetupFlow.initialPage(for: fresh), .hello)
        try render("setup-1-hello", HostSetupView(state: fresh, actions: .preview))
        try render("setup-2-permissions", HostSetupView(state: fresh, actions: .preview, page: .permissions))

        var waiting = fresh
        waiting.screenRecording = .granted
        waiting.setupStep = .accessibility
        waiting.accessibilitySettingsOpened = true
        try render("setup-2b-permissions-waiting", HostSetupView(state: waiting, actions: .preview, page: .permissions))

        var granted = waiting
        granted.accessibility = .granted
        granted.setupStep = .pairPhone
        try render("setup-2c-permissions-granted", HostSetupView(state: granted, actions: .preview, page: .permissions))

        var pair = granted
        pair.pairing = .showingCode(Self.code, expires: Self.expires)
        XCTAssertEqual(HostSetupFlow.initialPage(for: pair), .pair)
        try render("setup-3-pair", HostSetupView(state: pair, actions: .preview))
        pair.pairing = .awaitingApproval
        try render("setup-3b-approve", HostSetupView(state: pair, actions: .preview))
        pair.pairing = .expired
        try render("setup-3c-expired", HostSetupView(state: pair, actions: .preview))
        let replace = ready(.ready) {
            $0.pairingRequested = true
            $0.setupStep = .pairPhone
            $0.pairing = .confirmReplace
        }
        try render("setup-3d-replace", HostSetupView(state: replace, actions: .preview))

        try render("setup-4-ready-check", HostSetupView(state: ready(.ready) { $0.openAtLogin = false }, actions: .preview))
        try render("setup-4b-ready-live", HostSetupView(state: ready(.controlling) { $0.session = Self.measured },
                                                         actions: .preview))
        try render("setup-4c-ready-issues", HostSetupView(state: ready(.unavailable) {
            $0.detail = "Couldn’t reach the connection."
            $0.accessibility = .denied
        }, actions: .preview))
    }

    func testSettings() throws {
        try render("settings", HostSettingsView(state: ready(.ready), actions: .preview))
        try render("settings-live-two-displays", HostSettingsView(state: ready(.controlling) {
            $0.displays = [HostDisplayOption(id: 1, name: "Built-in Retina Display"),
                           HostDisplayOption(id: 2, name: "Studio Display")]
            $0.session = Self.measured
        }, actions: .preview))
        try render("settings-needs-attention", HostSettingsView(state: ready(.needsPhone) {
            $0.hasPairedPhone = false
            $0.accessibility = .denied
            $0.openAtLogin = false
        }, actions: .preview))
    }

    // MARK: Rendering

    @discardableResult
    private func render<V: View>(_ name: String, _ view: V, fixedSize: CGSize? = nil) throws -> NSBitmapImageRep {
        guard let appearance = NSAppearance(named: .darkAqua) else { throw XCTSkip("No dark appearance") }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = appearance
        let size = fixedSize ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "No bitmap for \(name)")
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 100, name)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 40, name)
        if let outputDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try png.write(to: outputDirectory.appendingPathComponent("farside-mac-\(name).png"))
        }
        window.contentView = nil
        return bitmap
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat) -> NSColor? {
        let x = Int((point.x * scale).rounded(.down)), y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func count(in bitmap: NSBitmapImageRep, frame: CGRect, scale: CGFloat, where test: (NSColor) -> Bool) -> Int {
        var total = 0
        var y = frame.minY
        while y < frame.maxY {
            var x = frame.minX
            while x < frame.maxX {
                if let color = pixel(bitmap, CGPoint(x: x, y: y), scale: scale), test(color) { total += 1 }
                x += 0.5
            }
            y += 0.5
        }
        return total
    }

    private func isEmber(_ color: NSColor) -> Bool {
        color.redComponent > 0.85 && color.greenComponent > 0.2 && color.greenComponent < 0.5 && color.blueComponent < 0.3
    }

    private func luminance(_ bitmap: NSBitmapImageRep, point: CGPoint, scale: CGFloat) -> CGFloat {
        guard let color = pixel(bitmap, point, scale: scale) else { return -1 }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

/// The popover under a stand-in menu bar, for design review. The live app shows the same view in
/// a MenuBarExtra window.
private struct HostPopoverReviewScene: View {
    let state: HostViewState
    let now: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 16) {
                Spacer()
                Image(nsImage: HostMenuBarIcon.image(for: HostMarkState(status: state.status),
                                                     accessibilityDescription: "Farside"))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(verbatim: "Wi-Fi")
                Text(verbatim: "Tue 9:41")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            HostPopoverView(state: state, actions: .preview, now: now)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Farside.Palette.line2, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 14)
        }
        .padding(24)
        .frame(width: 432)
        .background(Color(red: 0.035, green: 0.035, blue: 0.035))
    }
}

/// The four mark states on a light and a dark menu bar, drawn by AppKit image views the way a
/// status item draws them.
private struct HostMenuBarReviewStrip: NSViewRepresentable {
    let cellWidth: CGFloat = 64
    let rowHeight: CGFloat = 30
    var size: CGSize { CGSize(width: cellWidth * CGFloat(HostMarkState.allCases.count), height: rowHeight * 2) }

    func imageFrame(row: Int, column: Int) -> CGRect {
        let image = HostMenuBarIcon.size
        return CGRect(x: CGFloat(column) * cellWidth + (cellWidth - image.width) / 2,
                      y: CGFloat(row) * rowHeight + (rowHeight - image.height) / 2,
                      width: image.width, height: image.height)
    }

    func makeNSView(context: Context) -> NSView {
        let container = FlippedView(frame: NSRect(origin: .zero, size: size))
        for (row, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let bar = FlippedView(frame: NSRect(x: 0, y: CGFloat(row) * rowHeight, width: size.width, height: rowHeight))
            bar.appearance = NSAppearance(named: appearanceName)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (row == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).cgColor
            container.addSubview(bar)
            for (column, state) in HostMarkState.allCases.enumerated() {
                let frame = imageFrame(row: 0, column: column)
                let view = NSImageView(frame: frame)
                view.image = HostMenuBarIcon.image(for: state, accessibilityDescription: "Farside")
                view.imageScaling = .scaleNone
                bar.addSubview(view)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
