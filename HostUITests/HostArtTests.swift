import XCTest
import SwiftUI
import AppKit

/// The host's halftone art: what its scenes draw, and how the shared renderer is kept quiet
/// (at most 30 frames a second, none while the window is hidden, one still frame at time 0).
@MainActor
final class HostArtTests: XCTestCase {
    // MARK: Scenes

    private struct Painted {
        let columns: Int
        let rows: Int
        let cell: CGFloat
        let bone: [UInt8]
        let ember: [UInt8]

        func cells(in layer: [UInt8], atLeast level: UInt8, where region: (CGPoint) -> Bool = { _ in true }) -> Int {
            var total = 0
            for row in 0..<rows {
                for column in 0..<columns where layer[row * columns + column] >= level
                    && region(CGPoint(x: (CGFloat(column) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)) {
                    total += 1
                }
            }
            return total
        }
    }

    /// Runs a scene into the same kind of luminance layers the renderer gives it.
    private func paint(_ scene: HostArtScene, size: CGSize, time: TimeInterval = 0) -> Painted {
        let cell = scene.style.cell
        let columns = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
        func layer() -> CGContext {
            let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: columns, height: rows))
            context.translateBy(x: 0, y: CGFloat(rows))
            context.scaleBy(x: CGFloat(columns) / size.width, y: -CGFloat(rows) / size.height)
            return context
        }
        func bytes(_ context: CGContext) -> [UInt8] {
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<rows).flatMap { row in (0..<columns).map { data[row * context.bytesPerRow + $0] } }
        }
        let bone = layer(), ember = layer()
        scene.draw(HalftoneLayers(bone: bone, ember: ember, size: size), time)
        return Painted(columns: columns, rows: rows, cell: cell, bone: bytes(bone), ember: bytes(ember))
    }

    /// A luminance byte the renderer turns into a dot: its radius must reach 0.38 pt at a 2 pt pitch.
    private let drawn: UInt8 = 31
    /// Glow strong enough to be drawn in solid ember rather than a softer tint.
    private let emberDot: UInt8 = 128

    func testStripKeepsTheCaptionCornerFreeAndEmberForContact() {
        let size = CGSize(width: 360, height: 96)
        let plate = HostArtScenes.captionPlate(in: size)
        for mood in [HostPopoverPresentation.Mood.live, .calm, .paused, .attention] {
            for time in [0.0, 1.7, 9.3] {
                let art = paint(.popoverStrip(mood), size: size, time: time)
                XCTAssertEqual(art.cells(in: art.ember, atLeast: emberDot) > 0, mood == .live,
                               "Ember only while live: \(mood) at \(time)")
                XCTAssertGreaterThan(art.cells(in: art.bone, atLeast: drawn), 200, "The strip has art: \(mood)")
                XCTAssertEqual(art.cells(in: art.bone, atLeast: 1, where: plate.contains), 0,
                               "No dots where the caption plate sits: \(mood) at \(time)")
            }
        }
    }

    func testASceneAnimatesExactlyWhenItsDrawingMoves() {
        let strip = CGSize(width: 360, height: 96)
        for mood in [HostPopoverPresentation.Mood.live, .calm, .paused, .attention] {
            let scene = HostArtScene.popoverStrip(mood)
            let still = paint(scene, size: strip, time: 0)
            let later = paint(scene, size: strip, time: 1.7)
            let moves = still.bone != later.bone || still.ember != later.ember
            XCTAssertEqual(moves, mood == .live || mood == .calm, "\(mood)")
            XCTAssertEqual(scene.animated, moves, "Redrawing a strip that never changes would only burn frames: \(mood)")
        }

        let rail = CGSize(width: 280, height: 520)
        for (reach, contact) in [(0, false), (3, false), (3, true)] {
            let scene = HostArtScene.setupRail(reach: reach, contact: contact)
            let still = paint(scene, size: rail, time: 0), later = paint(scene, size: rail, time: 1.7)
            XCTAssertTrue(still.bone == later.bone && still.ember == later.ember, "The rail is a still frame")
            XCTAssertFalse(scene.animated)
        }
    }

    func testRailClosesTheGapStepByStepAndShowsEmberOnlyAtContact() {
        let size = CGSize(width: 280, height: 520)
        func gap(_ reach: Int, contact: Bool) -> CGFloat {
            let geometry = HostArtScenes.railGeometry(size: size, reach: reach, contact: contact)
            return hypot(geometry.cursorTip.x - geometry.fingertip.x, geometry.cursorTip.y - geometry.fingertip.y)
        }
        XCTAssertGreaterThan(gap(0, contact: false), gap(1, contact: false))
        XCTAssertGreaterThan(gap(1, contact: false), gap(2, contact: false))
        XCTAssertGreaterThan(gap(2, contact: false), gap(3, contact: false))
        XCTAssertGreaterThan(gap(3, contact: false), gap(3, contact: true))

        for (reach, contact) in [(0, false), (3, false), (3, true)] {
            let art = paint(.setupRail(reach: reach, contact: contact), size: size)
            XCTAssertEqual(art.cells(in: art.ember, atLeast: emberDot) > 0, contact,
                           "Rail ember only at contact (reach \(reach))")
        }
    }

    func testRailGlowThinsOutInsteadOfEndingInAnEdge() {
        let size = CGSize(width: 280, height: 520)
        let art = paint(.setupRail(reach: 3, contact: true), size: size)
        let lit = art.cells(in: art.bone, atLeast: drawn)
        XCTAssertGreaterThan(lit, 1500, "The hand, the pointer and the glow are drawn")
        XCTAssertLessThan(Double(lit) / Double(art.columns * art.rows), 0.3, "The glow thins out instead of filling the rail")

        // Density falls off steadily with distance from the centre and reaches the outer rows as scattered dots,
        // rather than stopping at an edge.
        func density(in rect: CGRect) -> Double {
            Double(art.cells(in: art.bone, atLeast: drawn, where: rect.contains))
                / Double(max(1, Int(rect.width * rect.height / (art.cell * art.cell))))
        }
        let inner = density(in: CGRect(x: 60, y: 300, width: 160, height: 40))
        let outer = density(in: CGRect(x: 60, y: 420, width: 160, height: 40))
        let far = density(in: CGRect(x: 60, y: 480, width: 160, height: 40))
        XCTAssertGreaterThan(inner, outer)
        XCTAssertGreaterThan(outer, far)
        XCTAssertGreaterThan(outer, 0, "The fade reaches the outer rows as scattered dots")
    }

    // MARK: A real window

    private func pump(_ seconds: TimeInterval) {
        _ = pump(seconds, until: { false })
    }

    /// Runs the AppKit event loop until `condition` holds or `seconds` pass, so a busy machine only slows
    /// these tests down instead of failing them. Window-server updates arrive through this loop.
    @discardableResult
    private func pump(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    /// A tiny, all but transparent window: it is really on screen when ordered front, and nobody sees it.
    /// The scene phase is set because a hosting view outside an app scene reports `.background`.
    private func makeWindow<V: View>(_ view: V) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view.frame(width: 60, height: 40).environment(\.scenePhase, .active))
        host.frame = NSRect(x: 0, y: 0, width: 60, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = host
        return window
    }

    func testAnimatesAtMostThirtyFramesPerSecondOnlyWhileTheWindowIsVisible() throws {
        var times: [TimeInterval] = []
        let window = makeWindow(HostArt(style: HalftoneStyle(cell: 6, dust: 0)) { _, time in times.append(time) })
        defer { window.close() }

        pump(0.5)
        XCTAssertLessThanOrEqual(times.count, 2, "A window that is not on screen only gets the still frame")
        XCTAssertTrue(times.allSatisfy { $0 == 0 }, "The still frame is drawn at time 0")

        window.orderFrontRegardless()
        try XCTSkipUnless(pump(3, until: { HostWindowVisibility.isVisible(window) }),
                          "No on-screen window here (the display is asleep or there is no login session)")
        XCTAssertTrue(pump(3, until: { times.count > 3 }), "The art animates while it can be seen")
        times.removeAll()
        pump(1.0)
        XCTAssertLessThanOrEqual(times.count, 34, "It never draws faster than 30 frames a second")
        XCTAssertGreaterThan(times.last ?? 0, 0, "Animation time moves past the still frame")

        window.orderOut(nil)
        XCTAssertTrue(pump(3, until: { !HostWindowVisibility.isVisible(window) }), "The window reports hidden")
        pump(0.5)
        times.removeAll()
        pump(1.0)
        XCTAssertLessThanOrEqual(times.count, 1, "It stops drawing when the window is hidden")
    }

    func testVisibilityWatcherFollowsShowHideAndClose() throws {
        struct Probe: View {
            @State private var visible = false
            let record: (Bool) -> Void

            var body: some View {
                Color.clear
                    .background(HostWindowVisibility(isVisible: $visible))
                    .onChange(of: visible, initial: true) { _, new in record(new) }
            }
        }

        var seen: [Bool] = []
        let window = makeWindow(Probe { seen.append($0) })
        defer { window.close() }

        pump(0.4)
        XCTAssertEqual(seen, [false], "A window that was never shown is not visible")
        window.orderFrontRegardless()
        try XCTSkipUnless(pump(3, until: { HostWindowVisibility.isVisible(window) }),
                          "No on-screen window here (the display is asleep or there is no login session)")
        XCTAssertTrue(pump(3, until: { seen.last == true }), "Showing the window reports visible: \(seen)")
        window.orderOut(nil)
        XCTAssertTrue(pump(3, until: { seen.last == false }), "Ordering it out, as a closed popover does, reports hidden: \(seen)")
        window.orderFrontRegardless()
        XCTAssertTrue(pump(3, until: { seen.last == true }), "Showing it again reports visible: \(seen)")
        window.close()
        XCTAssertTrue(pump(3, until: { seen.last == false }), "Closing it reports hidden: \(seen)")
    }
}
