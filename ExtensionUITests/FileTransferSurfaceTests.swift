import XCTest
import SwiftUI
import UIKit
import CoreText

/// Render-only catalogue of production transfer/status and Connect prompt bodies plus inert actions/model shims.
@MainActor
final class FileTransferSurfaceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FARSIDE_EXTENSION_SHOTS_DIR"] != nil,
                          "Set FARSIDE_EXTENSION_SHOTS_DIR to opt into extension surface screenshots; images are xcresult attachments.")
        let names = ["files-progress-to-mac-waiting", "files-progress-from-mac-waiting",
                     "files-progress-to-mac-transferring", "files-progress-from-mac-transferring",
                     "files-progress-to-mac-verifying", "files-progress-from-mac-verifying",
                     "files-waiting-for-mac", "files-offer-recipient-bound-file",
                     "files-offer-recipient-bound-link", "files-offer-recipient-bound-text",
                     "files-offer-unbound-retarget", "files-offer-bound-to-other-recipient-retarget",
                     "files-offer-no-selected-destination", "files-notice-error", "files-notice-success",
                     "files-notice-hidden"]
        let plan = XCTAttachment(string: names.flatMap { name in
            [name + "-portrait-component", name + "-landscape-component"]
        }.joined(separator: "\n"))
        plan.name = "capture-plan"
        plan.lifetime = .keepAlways
        add(plan)
    }

    func testProgressDirectionsAndPhases() throws {
        let states: [(String, FileTransferSnapshot.Direction, FileTransferSnapshot.Phase, Int64, Int64)] = [
            ("to-mac-waiting", .outgoing, .waiting, 0, 8_000_000),
            ("from-mac-waiting", .incoming, .waiting, 0, 8_000_000),
            ("to-mac-transferring", .outgoing, .transferring, 3_400_000, 8_000_000),
            ("from-mac-transferring", .incoming, .transferring, 5_100_000, 8_000_000),
            ("to-mac-verifying", .outgoing, .verifying, 8_000_000, 8_000_000),
            ("from-mac-verifying", .incoming, .verifying, 8_000_000, 8_000_000)
        ]

        for (name, direction, phase, bytes, total) in states {
            let files = PhoneFileTransfer()
            files.snapshot = FileTransferSnapshot(transfer: "fixture-transfer", direction: direction,
                                                   name: "Quarterly report final.pdf", total: total,
                                                   bytes: bytes, phase: phase)
            try capture(FileTransferCapsule(files: files, inbox: SendToMacInbox(), hidesNotice: false),
                        name: "files-progress-\(name)")
        }
    }

    func testWaitingForMacAndShareOffers() throws {
        let waiting = PhoneFileTransfer()
        waiting.waitingForMac = true
        try capture(FileTransferCapsule(files: waiting, inbox: SendToMacInbox(), hidesNotice: false),
                    name: "files-waiting-for-mac")

        let bound = SendToMacInbox()
        bound.selectedDestination = "studio-id"
        bound.selectedName = "Studio Mac"
        bound.offer = FixtureSendToMacItem(kind: .file, name: "Quarterly report.pdf",
                                            destinationName: "Studio Mac", destinationID: "studio-id")
        try capture(FileTransferCapsule(files: PhoneFileTransfer(), inbox: bound, hidesNotice: false),
                    name: "files-offer-recipient-bound-file")

        let textOffers: [(String, FixtureSendToMacItem.Kind, String?)] = [("link", .link, nil), ("text", .text, nil)]
        for (name, kind, title) in textOffers {
            let inbox = SendToMacInbox()
            inbox.selectedDestination = "studio-id"
            inbox.selectedName = "Studio Mac"
            inbox.offer = FixtureSendToMacItem(kind: kind, name: title,
                                               destinationName: "Studio Mac", destinationID: "studio-id")
            try capture(FileTransferCapsule(files: PhoneFileTransfer(), inbox: inbox, hidesNotice: false),
                        name: "files-offer-recipient-bound-\(name)")
        }

        let unbound = SendToMacInbox()
        unbound.selectedDestination = "studio-id"
        unbound.selectedName = "Studio Mac"
        unbound.offer = FixtureSendToMacItem(kind: .file, name: "Shared presentation.key",
                                              destinationName: "Previous Mac", destinationID: nil)
        try capture(FileTransferCapsule(files: PhoneFileTransfer(), inbox: unbound, hidesNotice: false),
                    name: "files-offer-unbound-retarget")

        let otherRecipient = SendToMacInbox()
        otherRecipient.selectedDestination = "studio-id"
        otherRecipient.selectedName = "Studio Mac"
        otherRecipient.offer = FixtureSendToMacItem(kind: .file, name: "Notes.txt",
                                                     destinationName: "Office Mac", destinationID: "office-id")
        try capture(FileTransferCapsule(files: PhoneFileTransfer(), inbox: otherRecipient, hidesNotice: false),
                    name: "files-offer-bound-to-other-recipient-retarget")

        let noSelection = SendToMacInbox()
        noSelection.offer = FixtureSendToMacItem(kind: .link, name: nil,
                                                  destinationName: "Studio Mac", destinationID: nil)
        try capture(FileTransferCapsule(files: PhoneFileTransfer(), inbox: noSelection, hidesNotice: false),
                    name: "files-offer-no-selected-destination")
    }

    func testNoticeResults() throws {
        let notices: [(String, FixtureClipboardNotice.Tone, String)] = [
            ("error", .caution, "The Mac couldn’t receive that file. Check its connection, then try again."),
            ("success", .success, "Quarterly report.pdf arrived on your Mac.")
        ]
        for (name, tone, message) in notices {
            let files = PhoneFileTransfer()
            files.notice = FixtureClipboardNotice(id: 100, message: message, tone: tone)
            try capture(FileTransferCapsule(files: files, inbox: SendToMacInbox(), hidesNotice: false),
                        name: "files-notice-\(name)")
        }

        let hiddenNotice = PhoneFileTransfer()
        hiddenNotice.notice = FixtureClipboardNotice(id: 101, message: "Hidden by the dock.", tone: .caution)
        try capture(FileTransferCapsule(files: hiddenNotice, inbox: SendToMacInbox(), hidesNotice: true),
                    name: "files-notice-hidden")


    }

    func testBigTextPendingStatusComponents() throws {
        let names = [
            "big-text-making-portrait-component",
            "big-text-making-landscape-component",
            "big-text-restoring-portrait-component",
            "big-text-restoring-landscape-component"
        ]
        let plan = XCTAttachment(string: names.joined(separator: "\n"))
        plan.name = "capture-plan"
        plan.lifetime = .keepAlways
        add(plan)

        try capture(BigTextPendingStatusFixture(pendingTarget: 1280), name: "big-text-making")
        try capture(BigTextPendingStatusFixture(pendingTarget: 0), name: "big-text-restoring")
    }

    func testConnectPromptBodyAcrossDeviceOrientations() throws {
        let names = ["connect-prompt-body-portrait-component", "connect-prompt-body-landscape-component"]
        let plan = XCTAttachment(string: names.joined(separator: "\n"))
        plan.name = "capture-plan"
        plan.lifetime = .keepAlways
        add(plan)

        let bundle = Bundle(for: FileTransferSurfaceTests.self)
        let fonts = [("Doto-Variable", Farside.Typeface.dotMatrix),
                     ("InstrumentSerif-Italic", Farside.Typeface.serifItalic)]
        for (resource, face) in fonts {
            guard let url = bundle.url(forResource: resource, withExtension: "ttf")
                ?? bundle.url(forResource: resource, withExtension: "ttf", subdirectory: "Fonts") else {
                throw XCTSkip("Connect prompt component needs production font resource \(resource).ttf")
            }
            // CoreText can synthesize Doto's named variable instances during registration.
            // Verify the exact resolved face below instead of requiring descriptor enumeration.
            var registrationError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)
            let error = registrationError?.takeRetainedValue()
            let alreadyRegistered = error.map { CFErrorGetCode($0) == Int(CTFontManagerError.alreadyRegistered.rawValue) } ?? false
            guard registered || alreadyRegistered else {
                throw XCTSkip("Connect prompt production font \(resource).ttf could not be registered in this process")
            }
            guard let resolved = UIFont(name: face, size: 30), resolved.fontName == face else {
                throw XCTSkip("Connect prompt production font \(face) did not resolve exactly; refusing fallback typography")
            }
        }

        // Render the production question body, with inert actions. Native presentation and its
        // public-route failure remain separate evidence; no OS chrome or detents are simulated.
        try capture(ConnectPromptSheet(macName: "Studio Mac", connect: {}, close: {})
            .preferredColorScheme(.dark), name: "connect-prompt-body", topInset: 0)
    }

    private func capture<V: View>(_ content: V, name: String, topInset: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let screen = UIScreen.main.bounds
        for landscape in [false, true] {
        let bounds = CGRect(x: 0, y: 0, width: landscape ? max(screen.width, screen.height) : min(screen.width, screen.height),
                            height: landscape ? min(screen.width, screen.height) : max(screen.width, screen.height))
        let window = UIWindow(frame: bounds)
        let root = ZStack {
            Farside.Palette.void
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, topInset ?? max(80, bounds.height * 0.18))
        }
        .frame(width: bounds.width, height: bounds.height)
        .background(Farside.Palette.void)
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        var didDraw = false
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            didDraw = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw, "UIKit drawHierarchy failed for \(name)", file: file, line: line)

        let attachment = XCTAttachment(image: image)
        attachment.name = (didDraw ? "" : "failed-") + name + (landscape ? "-landscape" : "-portrait") + "-component"
        attachment.lifetime = .keepAlways
        add(attachment)
        }
    }
}
