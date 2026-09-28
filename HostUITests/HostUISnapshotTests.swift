import XCTest
import SwiftUI
import AppKit

/// Renders the host's menu, setup and Settings views offscreen in light and dark appearance.
/// Set POCKETDESK_SNAPSHOT_DIR to write PNGs for design review.
@MainActor
final class HostUISnapshotTests: XCTestCase {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["POCKETDESK_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static let expires = Date().addingTimeInterval(104)
    private static let code = "pocketdesk:" + String(repeating: "c29tZS1wcml2YXRlLXBhaXJpbmctY29kZQ", count: 8)

    private func ready(_ status: HostStatus, change: (inout HostViewState) -> Void = { _ in }) -> HostViewState {
        var state = HostViewState()
        state.macName = "Roshan’s MacBook Air"
        state.screenRecording = .granted
        state.accessibility = .granted
        state.hasPairedPhone = true
        state.setupStep = .done
        state.status = status
        change(&state)
        return state
    }

    func testMenuStates() throws {
        let states: [(String, HostViewState)] = [
            ("menu-ready", ready(.ready)),
            ("menu-controlling", ready(.controlling)),
            ("menu-viewing", ready(.viewing) { $0.accessibility = .denied }),
            ("menu-approval", ready(.approvalRequested) { $0.hasPairedPhone = false }),
            ("menu-paused", ready(.paused)),
            ("menu-unavailable", ready(.unavailable) { $0.detail = "Connection service: unreachable." }),
            ("menu-needs-attention", ready(.needsScreenRecording) { $0.screenRecording = .denied })
        ]
        for (name, state) in states {
            let items = HostMenuModel.items(for: state)
            XCTAssertFalse(items.isEmpty)
            for item in items {
                switch item {
                case .status(let title, _), .note(let title):
                    XCTAssertLessThanOrEqual(title.count, 30, "Menu text should stay scannable in \(name)")
                case .action(let action):
                    XCTAssertLessThanOrEqual(action.title.count, 30)
                case .separator: break
                }
            }
            try render(name, HostMenuPreview(state: state), menuChrome: true)
        }
    }

    func testSetupSteps() throws {
        var screen = HostViewState()
        screen.screenRecording = .denied
        screen.setupStep = .screenRecording
        try render("setup-1-screen-recording", HostSetupView(state: screen, actions: .preview))

        screen.screenRecordingSettingsOpened = true
        try render("setup-1b-screen-recording-waiting", HostSetupView(state: screen, actions: .preview))

        var control = screen
        control.screenRecording = .granted
        control.accessibility = .denied
        control.setupStep = .accessibility
        try render("setup-2-accessibility", HostSetupView(state: control, actions: .preview))

        var pair = control
        pair.accessibility = .granted
        pair.setupStep = .pairPhone
        pair.pairing = .showingCode(Self.code, expires: Self.expires)
        try render("setup-3-pair-code", HostSetupView(state: pair, actions: .preview))

        pair.pairing = .awaitingApproval
        try render("setup-3b-pair-approve", HostSetupView(state: pair, actions: .preview))

        pair.pairing = .expired
        try render("setup-3c-pair-expired", HostSetupView(state: pair, actions: .preview))

        var done = pair
        done.hasPairedPhone = true
        done.setupStep = .done
        try render("setup-4-ready", HostSetupView(state: done, actions: .preview))
    }

    func testSettings() throws {
        try render("settings-ready", HostSettingsView(state: ready(.ready), actions: .preview))
        try render("settings-controlling-two-displays", HostSettingsView(state: ready(.controlling) {
            $0.displays = [HostDisplayOption(id: 1, name: "Built-in Retina Display"),
                           HostDisplayOption(id: 2, name: "Studio Display")]
            $0.selectedDisplayID = 1
        }, actions: .preview))
        try render("settings-needs-attention", HostSettingsView(state: ready(.needsPhone) {
            $0.hasPairedPhone = false
            $0.accessibility = .denied
        }, actions: .preview))
    }

    private func render<V: View>(_ name: String, _ view: V, menuChrome: Bool = false) throws {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let content = AnyView(
                view
                    .background(menuChrome
                                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                                : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
                    .clipShape(RoundedRectangle(cornerRadius: menuChrome ? 10 : 0, style: .continuous))
                    .environment(\.colorScheme, appearanceName == .darkAqua ? .dark : .light)
            )
            let host = NSHostingView(rootView: content)
            host.appearance = appearance
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))

            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("No bitmap for \(name)")
                return
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 100, name)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 60, name)
            if let outputDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            }
            window.contentView = nil
        }
    }
}
