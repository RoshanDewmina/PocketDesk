import SwiftUI
import UIKit
import XCTest
@testable import PocketDeskRemote

@MainActor
final class WatchGlanceLayoutTests: XCTestCase {
    private typealias M = WatchGlanceMetrics

    private enum Line {
        case title, detail, clock, note

        var font: UIFont {
            switch self {
            case .title: UIFont.systemFont(ofSize: M.titleSize, weight: .semibold)
            case .detail: UIFont.systemFont(ofSize: M.detailSize, weight: .medium)
            case .clock: UIFont.monospacedDigitSystemFont(ofSize: M.detailSize, weight: .medium)
            case .note: UIFont.systemFont(ofSize: M.noteSize, weight: .medium)
            }
        }
    }

    private var smallestWatch: CGSize { M.watchSurfaces[0].size }

    private func width(_ string: String, as line: Line) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: line.font]).width)
    }

    private func available(for line: Line, in size: CGSize) -> CGFloat {
        line == .title ? M.titleWidth(in: size) : M.lineWidth(in: size)
    }

    private func fits(_ string: String, as line: Line, in size: CGSize, scale: CGFloat) -> Bool {
        let measured = width(string, as: line)
        let room = available(for: line, in: size)
        print("watch-glance fit: \"\(string)\" \(line) \(measured) pt × \(scale) = \(measured * scale) of \(room) pt")
        return measured * scale <= room
    }

    // MARK: Surfaces

    func testSurfacesMatchTheHIG() {
        XCTAssertEqual(M.watchSurfaces.count, 5)
        XCTAssertEqual(M.carPlaySurfaces.count, 3)
        XCTAssertEqual(M.watchSurfaces.map(\.name), ["watch-40mm", "watch-41mm", "watch-44mm", "watch-45mm", "watch-49mm"])
        XCTAssertEqual(M.watchSurfaces.map(\.size), [CGSize(width: 152, height: 69.5), CGSize(width: 165, height: 72.5),
                                                     CGSize(width: 173, height: 76.5), CGSize(width: 184, height: 80.5),
                                                     CGSize(width: 191, height: 81.5)])
        XCTAssertEqual(M.carPlaySurfaces.map(\.name), ["carplay-170x78", "carplay-240x78", "carplay-240x100"])
        XCTAssertEqual(M.carPlaySurfaces.map(\.size), [CGSize(width: 170, height: 78), CGSize(width: 240, height: 78),
                                                       CGSize(width: 240, height: 100)])
        XCTAssertEqual(M.allSurfaces, M.watchSurfaces + M.carPlaySurfaces)
        XCTAssertEqual(M.lineWidth(in: smallestWatch), 152 - 2 * M.horizontalPadding)
        XCTAssertEqual(M.titleWidth(in: smallestWatch),
                       M.lineWidth(in: smallestWatch) - (M.glyphHeight + 6) - M.glyphSpacing)
    }

    // MARK: Fit at 40 mm

    func testEverySessionLineFitsTheSmallestWatch() {
        let titles = ["Live · Your Mac", "Paused", "Reconnecting", "Session ended", "Farside let go", "Sharing stopped",
                      "Session ended?"]
        for title in titles {
            XCTAssertTrue(fits(title, as: .title, in: smallestWatch, scale: M.titleMinimumScale), title)
            XCTAssertTrue(fits(title, as: .title, in: smallestWatch, scale: 0.9), "\(title) should need little shrinking")
        }
        for clock in ["Lets go in 88:88", "88:88", "888:88"] {
            XCTAssertTrue(fits(clock, as: .clock, in: smallestWatch, scale: M.lineMinimumScale), clock)
        }
        let details = ["Lets go soon.", "Hold on.", "Mac handed back.", "You were away.", "Stopped at the Mac.",
                       "Nothing left open.", "Check your iPhone."]
        for detail in details {
            XCTAssertTrue(fits(detail, as: .detail, in: smallestWatch, scale: M.lineMinimumScale), detail)
        }
        for note in ["End it on your iPhone.", "Sample · preview"] {
            XCTAssertTrue(fits(note, as: .note, in: smallestWatch, scale: M.lineMinimumScale), note)
        }
    }

    func testTheMacLineFitsTheSmallestWatch() {
        for line in ["Mac · seen 88:88 · 100%", "Not seen since 88:88", "Mac · asleep since 88:88", "Mac not seen lately"] {
            XCTAssertTrue(fits(line, as: .note, in: smallestWatch, scale: M.lineMinimumScale), line)
        }
    }

    func testLA2CopyFindingsStayRecorded() {
        XCTAssertTrue(fits("An agent needs you", as: .title, in: smallestWatch, scale: M.titleMinimumScale))
        XCTAssertFalse(fits("Claude Code needs you", as: .title, in: smallestWatch, scale: M.titleMinimumScale),
                       "Amendment 6 says this title does not fit 40 mm; update the spec if fonts changed")
        XCTAssertFalse(fits("12 min · nothing needs you", as: .detail, in: smallestWatch, scale: M.lineMinimumScale),
                       "Amendment 6 says this line does not fit 40 mm; update the spec if fonts changed")
        XCTAssertFalse(fits("Nothing was sent to your Mac.", as: .detail, in: smallestWatch, scale: M.lineMinimumScale),
                       "Amendment 6 says this line does not fit 40 mm; update the spec if fonts changed")
    }

    func testThreeLinesFitTheShortestSurface() {
        let shortest = M.allSurfaces.map(\.size.height).min() ?? 0
        let firstRow = max(Line.title.font.lineHeight, M.glyphHeight + 6)
        let total = firstRow + Line.clock.font.lineHeight + Line.note.font.lineHeight
            + 2 * M.lineSpacing + 2 * M.verticalPadding
        print("watch-glance fit: three lines need \(total) pt of \(shortest) pt")
        XCTAssertEqual(shortest, 69.5)
        XCTAssertLessThanOrEqual(total, shortest)
    }

    // MARK: Render

    private static let fixtures: [(name: String, glance: WatchGlance)] = {
        let now = Date.now
        return [
            ("live", WatchGlance(mark: .plain, title: "Live · Your Mac",
                                 detail: .clock(prefix: nil, interval: now.addingTimeInterval(-724)...now.addingTimeInterval(8 * 3600),
                                                countsDown: false),
                                 note: "End it on your iPhone.", accessibilityLabel: "Live on Your Mac")),
            ("paused", WatchGlance(mark: .plain, title: "Paused",
                                   detail: .clock(prefix: "Lets go in", interval: now...now.addingTimeInterval(42), countsDown: true),
                                   note: nil, accessibilityLabel: "Paused")),
            ("needs-you", WatchGlance(mark: .needsYou, title: "An agent needs you",
                                      detail: .clock(prefix: "Waiting", interval: now.addingTimeInterval(-134)...now.addingTimeInterval(3600),
                                                     countsDown: false),
                                      note: "Mac · seen 11:41 · 64%", accessibilityLabel: "An agent needs you")),
            ("stale", WatchGlance(mark: .plain, title: "Session ended?", detail: .text("Check your iPhone."), note: nil,
                                  accessibilityLabel: "Session ended?")),
        ]
    }()

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            bytes = buffer
        }

        var distinctColours: Int {
            var seen = Set<UInt32>()
            for index in stride(from: 0, to: bytes.count, by: 4) {
                seen.insert(UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]))
            }
            return seen.count
        }

        var brightPixels: Int {
            stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 180 && bytes[$0 + 1] > 180 }.count
        }

        /// Ember is #FF5B1F: red far above green. Bone and ash stay near-neutral even when antialiased.
        var emberPixels: Int {
            stride(from: 0, to: bytes.count, by: 4).filter { Int(bytes[$0]) - Int(bytes[$0 + 1]) > 60 }.count
        }
    }

    func testTheViewRendersAtEverySurface() throws {
        let directory = ProcessInfo.processInfo.environment["FARSIDE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for surface in M.allSurfaces {
            for fixture in Self.fixtures {
                let name = "watch-glance-\(fixture.name)-\(surface.name)"
                let renderer = ImageRenderer(content: WatchGlanceView(glance: fixture.glance)
                    .frame(width: surface.size.width, height: surface.size.height)
                    .background(Farside.Palette.void))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage, name)
                let cgImage = try XCTUnwrap(image.cgImage, name)
                XCTAssertEqual(cgImage.width, Int(surface.size.width * 2), name)
                XCTAssertEqual(cgImage.height, Int(surface.size.height * 2), name)
                let pixels = try XCTUnwrap(Pixels(cgImage), name)
                XCTAssertGreaterThan(pixels.distinctColours, 1, "\(name) is a flat colour")
                XCTAssertGreaterThan(pixels.brightPixels, 0, "\(name) drew no bone text")
                XCTAssertEqual(pixels.emberPixels, 0, "\(name) uses ember")
                if let directory, let png = image.pngData() {
                    try png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
        }
    }
}
