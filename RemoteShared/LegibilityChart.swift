import Foundation
import CoreGraphics

/// The size chart the bench window draws and the phone scores (Docs/perf/INSTRUMENTS-DESIGN.md §2).
///
/// Eight rows, size-major (9, 11, 13, 15 pt) then face (SF Pro, SF Mono), four columns of
/// colourways. Every cell holds an 8-character token derived from the 12-bit seed the marker
/// carries, so both sides know the ground truth without a message. Layout is in display points
/// with a top-left origin; the phone converts to pixels with the frame width ÷ display point width.
enum LegibilityChart {
    static let pointSizes: [Double] = [9, 11, 13, 15]
    /// Seed 0 in the marker means no chart is on screen; real charts use 1…4095.
    static let noChartSeed: UInt16 = 0
    static let seedRange: ClosedRange<UInt16> = 1...BenchMarker.seedMask

    static func randomSeed() -> UInt16 { UInt16.random(in: seedRange) }

    enum Face: String, CaseIterable, Codable {
        case system, mono
    }

    enum Colourway: String, CaseIterable, Codable {
        case blackOnWhite, whiteOnDark, blueOnWhite, redOnWhite

        var isColoured: Bool { self == .blueOnWhite || self == .redOnWhite }
    }

    struct Cell: Equatable, Hashable {
        let row: Int
        let column: Int
        let pointSize: Double
        let face: Face
        let colourway: Colourway
        let text: String

        var id: String { "\(Int(pointSize))\(face == .mono ? "m" : "s")\(column)" }
    }

    static let rowCount = pointSizes.count * Face.allCases.count
    static let columnCount = Colourway.allCases.count
    static let tokenLength = 8
    /// Glyphs that commonly confuse readers and OCR, and glyphs that anchor a token.
    static let confusable = Array("Il1O0rnmS5Z2B8")
    static let distinct = Array("ACEFHKMNRTUWXY347")

    static var rowSpecs: [(pointSize: Double, face: Face)] {
        pointSizes.flatMap { size in Face.allCases.map { (pointSize: size, face: $0) } }
    }

    static func cells(seed: UInt16) -> [Cell] {
        var cells: [Cell] = []
        for (row, spec) in rowSpecs.enumerated() {
            for (column, colourway) in Colourway.allCases.enumerated() {
                cells.append(Cell(row: row, column: column, pointSize: spec.pointSize, face: spec.face,
                                  colourway: colourway, text: token(seed: seed, row: row, column: column)))
            }
        }
        return cells
    }

    /// Deterministic 8-character token: anchor glyphs on even positions, confusables on odd ones.
    static func token(seed: UInt16, row: Int, column: Int) -> String {
        var state = (UInt32(seed & BenchMarker.seedMask) &* 2_654_435_761) ^ (UInt32(row * 97 + column * 31 + 1) &* 0x9E37_79B9)
        if state == 0 { state = 0x1234_5678 }
        func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }
        return String((0..<tokenLength).map { index in
            let set = index % 2 == 0 ? distinct : confusable
            return set[Int(next() % UInt32(set.count))]
        })
    }

    struct Layout: Equatable {
        let frame: CGRect
        /// Index `row * columnCount + column`, top-left origin, display points.
        let cellRects: [CGRect]
        let rowHeight: CGFloat

        func rect(for cell: Cell) -> CGRect { cellRects[cell.row * LegibilityChart.columnCount + cell.column] }
    }

    static let rowHeightPt: CGFloat = 30
    static let originFraction = CGPoint(x: 0.03, y: 0.14)
    static let widthFraction: CGFloat = 0.62
    static let textInsetPt: CGFloat = 8
    /// Space between the marker strip and the chart when the strip reaches below 14 % of the height
    /// (displays wider than about 1.62:1).
    static let stripMarginPt: CGFloat = 8

    static func layout(displayPointSize size: CGSize) -> Layout {
        let width = size.width * widthFraction
        let stripBottom = BenchMarker.layout(width: Double(size.width), height: Double(size.height)).frame.maxY
        let origin = CGPoint(x: size.width * originFraction.x,
                             y: max(size.height * originFraction.y, stripBottom + stripMarginPt))
        let columnWidth = width / CGFloat(columnCount)
        var rects: [CGRect] = []
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                rects.append(CGRect(x: origin.x + CGFloat(column) * columnWidth, y: origin.y + CGFloat(row) * rowHeightPt,
                                    width: columnWidth, height: rowHeightPt))
            }
        }
        return Layout(frame: CGRect(x: origin.x, y: origin.y, width: width, height: rowHeightPt * CGFloat(rowCount)),
                      cellRects: rects, rowHeight: rowHeightPt)
    }
}

/// One legibility measurement, as carried in the phone's per-second statistics.
struct LegibilitySummary: Codable, Equatable {
    var seed: Int
    /// Time since the chart seed changed, when the scored frame was taken.
    var ageMs: Double
    /// "displayed" (resampled to the on-screen pixel size), "decoded" (native stream pixels) or "screenshot".
    var surface: String
    var zoom: Double?
    /// Character error rate in percent per size ("9pt", "11pt", "13pt", "15pt") and "coloured11pt".
    var cer: [String: Double]
}
