import XCTest
import CoreGraphics

final class LegibilityChartTests: XCTestCase {
    func testCellsAreDeterministicAndDistinctPerSeed() {
        let a = LegibilityChart.cells(seed: 0x123)
        let b = LegibilityChart.cells(seed: 0x123)
        let c = LegibilityChart.cells(seed: 0x124)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.map(\.text), c.map(\.text))
        XCTAssertEqual(a.count, LegibilityChart.rowCount * LegibilityChart.columnCount)
        XCTAssertEqual(Set(a.map(\.text)).count, a.count, "tokens are unique within a chart")
        XCTAssertTrue(a.allSatisfy { $0.text.count == LegibilityChart.tokenLength })
        XCTAssertEqual(a.map(\.pointSize).prefix(8), [9, 9, 11, 11, 13, 13, 15, 15].flatMap { [$0, $0, $0, $0] }.prefix(8))
        XCTAssertEqual(a[0].face, .system)
        XCTAssertEqual(a[4].face, .mono)
        XCTAssertEqual(LegibilityChart.cells(seed: 0x1123).map(\.text), a.map(\.text), "only 12 seed bits count")
    }

    func testTokensAlternateAnchorAndConfusableGlyphs() {
        for cell in LegibilityChart.cells(seed: 99) {
            for (index, character) in cell.text.enumerated() {
                let set = index % 2 == 0 ? LegibilityChart.distinct : LegibilityChart.confusable
                XCTAssertTrue(set.contains(character), "\(cell.text) position \(index)")
            }
        }
    }

    func testLayoutIsInDisplayPointsWithATopLeftOrigin() {
        let layout = LegibilityChart.layout(displayPointSize: CGSize(width: 1440, height: 932))
        XCTAssertEqual(layout.cellRects.count, 32)
        XCTAssertEqual(layout.frame.minX, 1440 * 0.03, accuracy: 0.001)
        let expectedMinimumY: CGFloat = max(932.0 * 0.14, 932.0 * 0.05 + 4.0 * 1440.0 / 72.0 + 8.0)
        XCTAssertEqual(layout.frame.minY, expectedMinimumY, accuracy: 0.001)
        XCTAssertEqual(layout.frame.width, 1440 * 0.62, accuracy: 0.001)
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440), CGSize(width: 1440, height: 900),
                     CGSize(width: 1728, height: 1117), CGSize(width: 1024, height: 768)] {
            let chart = LegibilityChart.layout(displayPointSize: size)
            let strip = BenchMarker.layout(width: Double(size.width), height: Double(size.height))
            XCTAssertGreaterThanOrEqual(chart.frame.minY, strip.frame.maxY + LegibilityChart.stripMarginPt, "\(size)")
            XCTAssertLessThanOrEqual(chart.frame.maxY, size.height * 0.62, "\(size): the chart stays in the upper part")
        }
        XCTAssertEqual(layout.frame.height, LegibilityChart.rowHeightPt * 8)
        let cell = LegibilityChart.cells(seed: 1)[5]
        XCTAssertEqual(layout.rect(for: cell), layout.cellRects[5])
        XCTAssertEqual(layout.cellRects[5].minY, layout.cellRects[4].minY)
        XCTAssertEqual(layout.cellRects[4].minY, layout.cellRects[0].minY + LegibilityChart.rowHeightPt)
        let marker = BenchMarker.layout(width: 1440, height: 932)
        XCTAssertLessThanOrEqual(marker.frame.maxY, layout.frame.minY, "the marker strip sits above the chart")
    }

    func testLevenshteinAndAssignment() {
        XCTAssertEqual(LegibilityScore.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(LegibilityScore.levenshtein("", "abc"), 3)
        XCTAssertEqual(LegibilityScore.levenshtein("same", "same"), 0)
        let cells = LegibilityChart.cells(seed: 5)
        let words = [cells[0].text, String(cells[1].text.dropLast()) + "?", "unrelatedword"]
        let scores = LegibilityScore.assign(words: words, to: Array(cells.prefix(3)))
        XCTAssertEqual(scores[0].cer, 0)
        XCTAssertEqual(scores[0].recognized, cells[0].text)
        XCTAssertEqual(scores[1].cer, 1.0 / 8, accuracy: 0.0001)
        XCTAssertEqual(scores[2].cer, 1, "no word within the threshold counts as unread")
        XCTAssertNil(scores[2].recognized)
        XCTAssertEqual(LegibilityScore.normalize("CØХ2Un4ø"), "C0X2Un40")
        XCTAssertEqual(LegibilityScore.normalize("plain"), "plain")
        let halfWrong = String(cells[0].text.prefix(4)) + "????"
        XCTAssertEqual(LegibilityScore.assign(words: [halfWrong], to: [cells[0]])[0].cer, 0.5, "half read is the limit")
        let mostlyWrong = String(cells[0].text.prefix(3)) + "?????"
        XCTAssertNil(LegibilityScore.assign(words: [mostlyWrong], to: [cells[0]])[0].recognized, "beyond it counts as unread")
        let result = LegibilityResult(seed: 5, cells: scores)
        XCTAssertEqual(result.cerBySize["9pt"] ?? -1, 37.5, accuracy: 0.001)
    }

    func testVisionReadsTheRenderedChartAtTwoTimesScale() throws {
        let seed: UInt16 = 0x3a7
        let cells = LegibilityChart.cells(seed: seed)
        let points = CGSize(width: 1440, height: 932)
        let layout = LegibilityChart.layout(displayPointSize: points)
        let scale: CGFloat = 2
        let crop = layout.frame.insetBy(dx: -8, dy: -8)
        let width = Int(crop.width * scale), height = Int(crop.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw XCTSkip("no RGB context") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        LegibilityChartRenderer.draw(cells: cells, layout: layout, in: context)
        let image = try XCTUnwrap(context.makeImage())
        let result = try LegibilityScore.score(image: image, seed: seed)
        let cer = result.cerBySize
        print("LEGIBILITY CEILING at 2x:", cer)
        XCTAssertEqual(result.cells.count, cells.count)
        XCTAssertLessThan(cer["15pt"] ?? 100, 25, "Vision reads most 15 pt tokens on a pristine render: \(cer)")
        XCTAssertLessThan(cer["13pt"] ?? 100, 35, "and most 13 pt tokens: \(cer)")
        XCTAssertGreaterThan(result.cells.filter { $0.cer == 0 }.count, cells.count / 3, "at least a third of the cells are read exactly")
    }
}
