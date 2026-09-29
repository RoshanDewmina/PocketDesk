import XCTest
import CoreGraphics

final class BenchMarkerTests: XCTestCase {
    func testRowsRoundTripThroughDecode() {
        for (time, seed, flash, motion) in [(UInt32(0), UInt16(0), false, false),
                                            (UInt32(0xabcdef), UInt16(0xfff), true, true),
                                            (UInt32(123_456), UInt16(2_047), true, false),
                                            (UInt32(1 << 24) + 5, UInt16(0x1234), false, true)] {
            let marker = BenchMarker(timeMs: time, chartSeed: seed, flash: flash, motion: motion)
            XCTAssertEqual(marker.timeMs, time % BenchMarker.timeModulus)
            XCTAssertEqual(marker.chartSeed, seed & BenchMarker.seedMask)
            let rows = marker.rows
            XCTAssertEqual(rows.count, BenchMarker.rowCount)
            XCTAssertTrue(rows.allSatisfy { $0.count == BenchMarker.blocksPerRow })
            XCTAssertEqual(BenchMarker.decode(rows: rows), marker)
        }
    }

    func testCorruptedRowsAreRejected() {
        let marker = BenchMarker(timeMs: 0x5a5a5a, chartSeed: 0x2c3, flash: true, motion: false)
        var rows = marker.rows
        rows[1][5].toggle()
        XCTAssertNil(BenchMarker.decode(rows: rows), "a flipped time bit fails the CRC")
        rows = marker.rows
        rows[3][3].toggle()
        XCTAssertNil(BenchMarker.decode(rows: rows), "a flipped seed bit fails parity")
        rows = marker.rows
        rows[2][0] = false
        XCTAssertNil(BenchMarker.decode(rows: rows), "a wrong guard fails")
        rows = marker.rows
        for index in 0..<4 { rows[0][index].toggle() }
        XCTAssertNil(BenchMarker.decode(rows: rows), "three or more sync mismatches fail")
        rows = marker.rows
        rows[0][7].toggle()
        XCTAssertEqual(BenchMarker.decode(rows: rows), marker, "one sync block may be damaged")
    }

    func testCRC8KnownValue() {
        // CRC-8 poly 0x07 of "123456789" is 0xF4.
        XCTAssertEqual(BenchMarker.crc8(Array("123456789".utf8)), 0xf4)
    }

    func testReadsTheStripFromARenderedLumaPlane() throws {
        let width = 1280, height = 828
        let marker = BenchMarker(hostTimeMs: 1_234_567.9, chartSeed: 0x0abc, flash: false, motion: true)
        let luma = try Self.renderedLuma(marker, width: width, height: height, white: 235, black: 16, background: 120)
        let read = luma.withUnsafeBufferPointer {
            BenchMarker.read(luma: $0.baseAddress!, width: width, height: height, bytesPerRow: width)
        }
        XCTAssertEqual(read, marker)
        XCTAssertEqual(read?.timeMs, 1_234_567 % BenchMarker.timeModulus)
    }

    func testReadIsTolerantOfLevelsAndRejectsNoContrast() throws {
        let width = 832, height = 538
        let marker = BenchMarker(timeMs: 42, chartSeed: 7, flash: true, motion: false)
        let fullRange = try Self.renderedLuma(marker, width: width, height: height, white: 255, black: 0, background: 40)
        XCTAssertEqual(fullRange.withUnsafeBufferPointer {
            BenchMarker.read(luma: $0.baseAddress!, width: width, height: height, bytesPerRow: width)
        }, marker)
        let flat = [UInt8](repeating: 128, count: width * height)
        XCTAssertNil(flat.withUnsafeBufferPointer {
            BenchMarker.read(luma: $0.baseAddress!, width: width, height: height, bytesPerRow: width)
        })
    }

    func testUnwrapsNearTheReference() {
        let modulus = Double(BenchMarker.timeModulus)
        let marker = BenchMarker(timeMs: 10, chartSeed: 0, flash: false, motion: false)
        XCTAssertEqual(marker.unwrappedTimeMs(near: 3 * modulus + 20), 3 * modulus + 10)
        XCTAssertEqual(marker.unwrappedTimeMs(near: 4 * modulus - 5), 4 * modulus + 10, "just before a wrap, the next period is nearer")
        XCTAssertEqual(marker.unwrappedTimeMs(near: 12), 10)
    }

    func testLayoutScalesWithTheFrame() {
        let full = BenchMarker.layout(width: 2880, height: 1864)
        let stream = BenchMarker.layout(width: 2560, height: 1656)
        XCTAssertEqual(full.block, 40, accuracy: 0.001)
        XCTAssertEqual(stream.block, 2560.0 / 72, accuracy: 0.001)
        XCTAssertEqual(full.center(row: 1, block: 3).x / 2880, stream.center(row: 1, block: 3).x / 2560, accuracy: 0.0001)
        XCTAssertEqual(full.center(row: 1, block: 3).y / 1864, stream.center(row: 1, block: 3).y / 1656, accuracy: 0.0001)
    }

    /// A luma plane with the marker drawn through the shared renderer, then written at the given levels.
    static func renderedLuma(_ marker: BenchMarker, width: Int, height: Int, white: UInt8, black: UInt8, background: UInt8) throws -> [UInt8] {
        var pixels = [UInt8](repeating: background, count: width * height)
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw XCTSkip("no gray context") }
            // The renderer expects a flipped (top-left) context.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            BenchMarkerRenderer.draw(marker, layout: BenchMarker.layout(width: Double(width), height: Double(height)), in: context)
        }
        return pixels.map { $0 == 255 ? white : $0 == 0 ? black : $0 }
    }
}
