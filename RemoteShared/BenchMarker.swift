import Foundation
import CoreGraphics

/// The bench window's machine-readable strip (Docs/perf/INSTRUMENTS-DESIGN.md §1).
///
/// Geometry is a fraction of the drawn surface, so the phone can read it from a decoded frame of
/// any size as long as the bench window covers the whole captured display: block size
/// `width / 72`, strip origin `(0, 0.05 × height)`, four rows of 18 square blocks with a top-left
/// origin. Row 0 is a sync row (white, black, white, ...) that also calibrates the reader's white
/// and black levels. Rows 1–3 are `[guard white][16 data blocks][guard black]`:
/// row A carries bits 0–15 of `timeMs`, row B bits 16–23 plus a CRC-8 of the three time bytes,
/// row C the 12-bit chart seed, the flash bit, the motion bit and two parity bits.
struct BenchMarker: Equatable {
    /// Mac display time of the frame in mach milliseconds, modulo 2^24 (about 4.7 hours).
    let timeMs: UInt32
    /// 12-bit chart seed; 0 means no chart is on screen (`LegibilityChart.noChartSeed`).
    let chartSeed: UInt16
    let flash: Bool
    let motion: Bool

    static let timeModulus: UInt32 = 1 << 24
    static let seedMask: UInt16 = 0x0fff
    static let blocksAcross = 72
    static let blocksPerRow = 18
    static let dataBlocks = 16
    static let rowCount = 4
    static let stripTopFraction = 0.05
    /// The sync row must differ from the data rows by at least this much luma to be trusted.
    static let minimumContrast = 40.0

    init(timeMs: UInt32, chartSeed: UInt16, flash: Bool, motion: Bool) {
        self.timeMs = timeMs % Self.timeModulus
        self.chartSeed = chartSeed & Self.seedMask
        self.flash = flash
        self.motion = motion
    }

    init(hostTimeMs: Double, chartSeed: UInt16, flash: Bool, motion: Bool) {
        let whole = Int64(hostTimeMs.rounded(.down)) % Int64(Self.timeModulus)
        self.init(timeMs: UInt32(max(0, whole)), chartSeed: chartSeed, flash: flash, motion: motion)
    }

    struct Layout: Equatable {
        let block: Double
        let originX: Double
        let originY: Double

        var width: Double { block * Double(BenchMarker.blocksPerRow) }
        var height: Double { block * Double(BenchMarker.rowCount) }
        var frame: CGRect { CGRect(x: originX, y: originY, width: width, height: height) }

        /// Top-left origin, `y` grows downwards.
        func rect(row: Int, block index: Int) -> CGRect {
            CGRect(x: originX + Double(index) * block, y: originY + Double(row) * block, width: block, height: block)
        }

        func center(row: Int, block index: Int) -> CGPoint {
            CGPoint(x: originX + (Double(index) + 0.5) * block, y: originY + (Double(row) + 0.5) * block)
        }
    }

    static func layout(width: Double, height: Double) -> Layout {
        Layout(block: width / Double(blocksAcross), originX: 0, originY: height * stripTopFraction)
    }

    /// Block values row by row, true meaning white.
    var rows: [[Bool]] {
        let time = timeMs
        let crc = Self.crc8(Self.timeBytes(time))
        let sync = (0..<Self.blocksPerRow).map { $0 % 2 == 0 }
        func data(_ bit: (Int) -> Bool) -> [Bool] { [true] + (0..<Self.dataBlocks).map(bit) + [false] }
        let rowA = data { (time >> UInt32($0)) & 1 == 1 }
        let rowB = data { $0 < 8 ? (time >> UInt32(16 + $0)) & 1 == 1 : (crc >> UInt8($0 - 8)) & 1 == 1 }
        let seedParity = Self.parity((0..<12).map { (chartSeed >> UInt16($0)) & 1 == 1 })
        let rowC = data { index in
            switch index {
            case 0..<12: return (chartSeed >> UInt16(index)) & 1 == 1
            case 12: return flash
            case 13: return motion
            case 14: return seedParity
            default: return Self.parity([seedParity, flash, motion])
            }
        }
        return [sync, rowA, rowB, rowC]
    }

    static func decode(rows: [[Bool]]) -> BenchMarker? {
        guard rows.count == rowCount, rows.allSatisfy({ $0.count == blocksPerRow }) else { return nil }
        let expectedSync = (0..<blocksPerRow).map { $0 % 2 == 0 }
        let syncMatches = zip(rows[0], expectedSync).filter { $0 == $1 }.count
        guard syncMatches >= blocksPerRow - 2 else { return nil }
        for row in rows[1...] where row[0] != true || row[blocksPerRow - 1] != false { return nil }
        func bits(_ row: [Bool]) -> [Bool] { Array(row[1..<(1 + dataBlocks)]) }
        let a = bits(rows[1]), b = bits(rows[2]), c = bits(rows[3])
        var time: UInt32 = 0
        for index in 0..<16 where a[index] { time |= 1 << UInt32(index) }
        for index in 0..<8 where b[index] { time |= 1 << UInt32(16 + index) }
        var crc: UInt8 = 0
        for index in 0..<8 where b[8 + index] { crc |= 1 << UInt8(index) }
        guard crc == crc8(timeBytes(time)) else { return nil }
        var seed: UInt16 = 0
        for index in 0..<12 where c[index] { seed |= 1 << UInt16(index) }
        let flash = c[12], motion = c[13]
        let seedParity = parity(Array(c[0..<12]))
        guard c[14] == seedParity, c[15] == parity([seedParity, flash, motion]) else { return nil }
        return BenchMarker(timeMs: time, chartSeed: seed, flash: flash, motion: motion)
    }

    /// Reads the strip from an 8-bit luma plane with a top-left origin, sampling a 3×3 patch at
    /// each block centre and thresholding at the midpoint of the sync row's white and black means.
    /// Returns nil when the strip is too small, has no contrast, or fails sync, guard, CRC or parity.
    static func read(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> BenchMarker? {
        guard width >= blocksAcross * 3, height > 0, bytesPerRow >= width else { return nil }
        let layout = layout(width: Double(width), height: Double(height))
        guard layout.block >= 3, layout.originY + layout.height <= Double(height) else { return nil }
        func sample(_ row: Int, _ block: Int) -> Int {
            let center = layout.center(row: row, block: block)
            let cx = Int(center.x), cy = Int(center.y)
            var sum = 0
            for dy in -1...1 {
                let y = min(max(cy + dy, 0), height - 1)
                for dx in -1...1 {
                    let x = min(max(cx + dx, 0), width - 1)
                    sum += Int(luma[y * bytesPerRow + x])
                }
            }
            return sum / 9
        }
        let sync = (0..<blocksPerRow).map { sample(0, $0) }
        let whites = stride(from: 0, to: blocksPerRow, by: 2).map { Double(sync[$0]) }
        let blacks = stride(from: 1, to: blocksPerRow, by: 2).map { Double(sync[$0]) }
        let white = whites.reduce(0, +) / Double(whites.count)
        let black = blacks.reduce(0, +) / Double(blacks.count)
        guard white - black >= minimumContrast else { return nil }
        let threshold = Int(((white + black) / 2).rounded())
        let rows = (0..<rowCount).map { row in (0..<blocksPerRow).map { sample(row, $0) > threshold } }
        return decode(rows: rows)
    }

    /// The full host time nearest `reference` (host mach ms) that this 24-bit value can stand for.
    func unwrappedTimeMs(near reference: Double) -> Double {
        let modulus = Double(Self.timeModulus)
        let base = (reference / modulus).rounded(.down) * modulus
        let candidates = [base - modulus, base, base + modulus].map { $0 + Double(timeMs) }
        return candidates.min { abs($0 - reference) < abs($1 - reference) } ?? Double(timeMs)
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    private static func timeBytes(_ time: UInt32) -> [UInt8] {
        [UInt8(time & 0xff), UInt8((time >> 8) & 0xff), UInt8((time >> 16) & 0xff)]
    }

    private static func parity(_ bits: [Bool]) -> Bool {
        bits.reduce(false) { $0 != $1 }
    }
}
