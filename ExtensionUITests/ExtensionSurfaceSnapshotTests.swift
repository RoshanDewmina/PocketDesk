import ActivityKit
import XCTest
import SwiftUI
import UIKit

/// Isolated render-only coverage for the extension surfaces. Images are XCTAttachments so they
/// travel with the simulator result bundle; export them from xcresult after the run.
@MainActor
final class ExtensionSurfaceSnapshotTests: XCTestCase {
    private let canvas = Farside.Palette.void
    private let now = Date()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_EXTENSION_SHOTS_DIR"] != nil,
                          "Set FARSIDE_EXTENSION_SHOTS_DIR to opt into extension surface screenshots; images are xcresult attachments.")
    }

    func testConnectWidgetPresenceStates() throws {
        let dated = now.addingTimeInterval(-73)
        let cases: [(String, MacWidgetSnapshot?)] = [
            ("no-snapshot", nil),
            ("name-no-presence", MacWidgetSnapshot(macName: "Studio Mac"))
        ] + [MacWidgetSnapshot.Presence.awake, .asleep, .locked, .otherUser,
             .screenRecordingOff, .screenRecordingApproval, .notAnswering].map { presence in
            (presence.rawValue, MacWidgetSnapshot(macName: "Studio Mac", presence: presence,
                                                   presenceAt: dated, lastReached: dated.addingTimeInterval(-600)))
        }

        for (name, snapshot) in cases {
            try attach(ConnectWidgetView(snapshot: snapshot)
                .padding(16)
                .frame(width: 170, height: 170)
                .background(canvas), name: "widget-connect-\(name)-small", size: CGSize(width: 170, height: 170))
        }
    }

    func testEveryLiveActivityLookAcrossRenderedComponents() throws {
        let looks: [(String, FarsideSessionAttributes.ContentState, Bool)] = [
            ("live", .live(route: .direct), false),
            ("paused", .paused(graceEnds: now.addingTimeInterval(300), route: .local), false),
            ("paused-grace-elapsed", .paused(graceEnds: now.addingTimeInterval(-5), route: .local), false),
            ("reconnecting", .reconnecting(route: .relay), false),
            ("ended", .ended(.user), false),
            ("timed-out", .ended(.timeout), false),
            ("mac-stopped", .ended(.macStopped), false),
            ("problem", .ended(.error), false),
            ("stale", .live(route: .direct), true)
        ]

        for (name, state, stale) in looks {
            let content = activityContent(state: state, stale: stale)
            try attach(SessionLockScreenView(content: content)
                .frame(width: 393, height: 170, alignment: .topLeading)
                .background(canvas), name: "activity-\(name)-lock-screen-medium", size: CGSize(width: 393, height: 170))

            try attach(IslandCompactComponent(content: content)
                .frame(width: 145, height: 42)
                .background(canvas), name: "activity-\(name)-compact-component", size: CGSize(width: 145, height: 42))

            try attach(IslandMinimalComponent(content: content)
                .frame(width: 54, height: 42)
                .background(canvas), name: "activity-\(name)-minimal-component", size: CGSize(width: 54, height: 42))

            // Production uses the minimal glyph when iOS limits the compact region width.
            try attach(IslandMinimalComponent(content: content).frame(width: 46, height: 42).background(canvas),
                name: "activity-\(name)-landscape-limited-trailing-component", size: CGSize(width: 46, height: 42))
            try attach(IslandMinimalComponent(content: content).environment(\.isLuminanceReduced, true)
                .frame(width: 54, height: 42).background(canvas),
                name: "activity-\(name)-reduced-luminance-minimal-component", size: CGSize(width: 54, height: 42))

            try attach(IslandExpandedComponent(content: content)
                .frame(width: 360, height: 145)
                .background(canvas), name: "activity-\(name)-expanded-component", size: CGSize(width: 360, height: 145))

            let glance = SessionGlance.glance(attributes: content.attributes, state: state, isStale: stale, now: now)
            try attach(WatchGlanceView(glance: glance)
                .frame(width: 152, height: 69.5)
                .background(canvas), name: "activity-\(name)-watch-small", size: CGSize(width: 152, height: 69.5))
        }

        let sampleAttributes = FarsideSessionAttributes(macId: "fixture-mac-id", macLabel: "Your Mac",
            sessionId: "fixture-preview-id", startedAtUnix: Int(now.addingTimeInterval(-724).timeIntervalSince1970), preview: true)
        try attach(SessionLockScreenView(content: SessionActivityContent(attributes: sampleAttributes,
            state: .live(route: .direct), isStale: false)).frame(width: 393, height: 170).background(canvas),
            name: "activity-sample-preview-lock-screen-component", size: CGSize(width: 393, height: 170))

        // StandBy uses the production medium Lock Screen body, composed at a card-like ratio.
        let standby = activityContent(state: .live(route: .direct), stale: false)
        try attach(SessionLockScreenView(content: standby)
            .frame(width: 420, height: 190, alignment: .topLeading)
            .background(canvas, in: RoundedRectangle(cornerRadius: 28)),
            name: "activity-live-standby-medium-component", size: CGSize(width: 420, height: 190))
    }

    func testShareSheetStatesAcrossPhoneAndPadOrientations() throws {
        let states: [(String, ShareSendModel.Phase, String, String)] = [
            ("loading", .loading, "", "Studio Mac"),
            ("ready-file", .ready, "proposal.pdf · 2.4 MB", "Studio Mac"),
            ("ready-link", .ready, "docs.example.com", "Studio Mac"),
            ("ready-text", .ready, "Text for your Mac’s clipboard", "Studio Mac"),
            ("unavailable-no-pairing", .unavailable("Open Farside and pair using a fresh owner-approved QR code, then share again."), "", "your Mac"),
            ("unavailable-disconnected", .unavailable("Studio Mac isn’t connected. Open Farside and connect, then share again."), "", "Studio Mac"),
            ("unavailable-empty", .unavailable("There’s nothing here Farside can send."), "", "Studio Mac"),
            ("unavailable-unsupported", .unavailable("Only web links can be sent."), "", "Studio Mac"),
            ("unavailable-update-required", .unavailable("Files and links need the updated Farside on your Mac."), "", "Studio Mac"),
            ("unavailable-text-limit", .unavailable("That text is over 256 KB, the clipboard limit."), "", "Studio Mac"),
            ("unavailable-file-empty", .unavailable("That file is empty."), "", "Studio Mac"),
            ("unavailable-file-read", .unavailable("Farside couldn’t read that item. Folders can’t be sent; zip them first."), "", "Studio Mac"),
            ("unavailable-file-limit", .unavailable("That file is over 1 GB, the limit for now."), "", "Studio Mac"),
            ("sending", .sending(nil, "Handing it to Farside…"), "", "Studio Mac"),
            ("progress", .sending(0.42, "Sending to Downloads · 42%"), "", "Studio Mac"),
            ("handed-off", .handedOff("Open Farside to finish sending to Studio Mac. It asks before sending, and this expires in 10 minutes."), "", "Studio Mac"),
            ("success", .finished("Saved in Downloads › Farside."), "", "Studio Mac"),
            ("failed", .failed("Farside couldn’t hold that item. Try again."), "", "Studio Mac")
        ]
        let layouts: [(String, CGFloat, CGFloat)] = [
            ("phone-portrait", 390, 690),
            ("phone-landscape", 844, 330),
            ("pad-portrait", 768, 510),
            ("pad-landscape", 1024, 470)
        ]

        for (stateName, phase, summary, macName) in states {
            for (layoutName, width, height) in layouts {
                let model = ShareSendModel(finish: {}, cancel: {})
                model.phase = phase
                model.summary = summary
                model.macName = macName
                try attach(ShareSendView(model: model)
                    .frame(width: width, height: height)
                    .background(canvas), name: "share-\(stateName)-\(layoutName)-sheet", size: CGSize(width: width, height: height))
            }
        }
    }

    private func activityContent(state: FarsideSessionAttributes.ContentState, stale: Bool) -> SessionActivityContent {
        let attributes = FarsideSessionAttributes(macId: "fixture-mac-id", macLabel: "Studio Mac",
                                                   sessionId: "fixture-session-id",
                                                   startedAtUnix: Int(now.addingTimeInterval(-724).timeIntervalSince1970),
                                                   preview: false)
        return SessionActivityContent(attributes: attributes, state: state, isStale: stale)
    }

    private func attach<V: View>(_ view: V, name: String, size: CGSize,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        // UIKit's hierarchy renderer paints SwiftUI controls and CoreAnimation-backed components
        // (ProgressView/timers included) more faithfully than ImageRenderer's view-only pass.
        let hosting = UIHostingController(rootView: view.ignoresSafeArea())
        hosting.safeAreaRegions = []
        hosting.view.frame = CGRect(origin: .zero, size: size)
        hosting.view.bounds = CGRect(origin: .zero, size: size)
        hosting.view.backgroundColor = .clear
        hosting.loadViewIfNeeded()
        // This is the isolated UI-test runner on a simulator, never the product app or host.
        // Attach to a fixture window so native controls/timers have a real UIKit lifecycle.
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawn = hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            guard drawn else {
                XCTFail("UIKit could not draw the hosted view for \(name)", file: file, line: line)
                return
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = drawn ? name : "failed-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

/// Dynamic Island regions are SwiftUI components supplied to iOS. These wrappers add only the
/// black capsule/expanded island boundary; all content is the existing production widget view.
private struct IslandCompactComponent: View {
    let content: SessionActivityContent

    var body: some View {
        HStack(spacing: 8) {
            FarsideMarkGlyph(height: 16)
            SessionCompactTrailing(content: content)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, in: Capsule())
    }
}

private struct IslandMinimalComponent: View {
    let content: SessionActivityContent

    var body: some View {
        SessionMinimalGlyph(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black, in: Capsule())
    }
}

private struct IslandExpandedComponent: View {
    let content: SessionActivityContent

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SessionGlyphTile(look: content.look, size: 34)
                Spacer()
                if content.hasClock { SessionClock(content: content, size: 17) }
            }
            SessionExpandedBottom(content: content)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }
}
