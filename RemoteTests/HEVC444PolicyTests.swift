import XCTest

final class HEVC444PolicyTests: XCTestCase {
    private let sps = Data([0x42,0x01,0x01,0x04,0x08,0x00,0x00,0x03,0x00,0xbe,0x08,0x00,0x00,0x03,0x00,0x00,0x1e,0x90,0x02,0x84,0x08,0x38,0x18,0x7c,0x40,0xaf,0x72,0x2c,0xa8,0x80])
    func testActualSynthetic64SPSIsMain444EightBitSingleLayer() throws {
        let parsed = try XCTUnwrap(HEVC444SPS.parse(sps))
        XCTAssertEqual(parsed.width, 160); XCTAssertEqual(parsed.height, 64)
        XCTAssertEqual(parsed.displayWidth, 64); XCTAssertEqual(parsed.displayHeight, 64)
        XCTAssertEqual(parsed.level, 30); XCTAssertEqual(parsed.tier, 0)
        for count in 0..<22 { XCTAssertNil(HEVC444SPS.parse(Data(sps.prefix(count)))) }
    }
    func testHostileProfileLayerConstraintAndEmulationEscapeReject() {
        for (offset, value) in [(0,UInt8(0xc2)),(1,2),(2,3),(3,1),(9,0xba),(10,0),(16,156)] {
            var changed = sps; changed[offset] = value; XCTAssertNil(HEVC444SPS.parse(changed))
        }
        var badEscape = sps; badEscape[8] = 4
        XCTAssertNil(HEVC444SPS.parse(badEscape))
        XCTAssertNil(HEVC444SPS.parse(Data(repeating: 0, count: 65537)))
    }
    func testRejectsOtherRExtChromaBitDepthSeparatePlanesAndOverlappingConformanceCrop() {
        for fields in [(UInt64(2), UInt64(0), UInt64(0), UInt64(0)), (3, 1, 0, 0), (3, 0, 2, 2), (3, 0, 0, 2)] {
            XCTAssertNil(HEVC444SPS.parse(prefix(chroma: fields.0, separate: fields.1, lumaDepth: fields.2, chromaDepth: fields.3)))
        }
        XCTAssertNil(HEVC444SPS.parse(prefix(rightCrop: 64)))
        XCTAssertNil(HEVC444SPS.parse(prefix(width: 4097)))
        let config = OwnedHEVCConfiguration(parameters: OwnedHEVCConfiguration.fullColorCodecInfo.parameters)!
        var lower = OwnedHEVCConfiguration.fullColorCodecInfo.parameters; lower["level-id"] = "120"; lower["tier-flag"] = "0"
        XCTAssertFalse(OwnedHEVCConfiguration(parameters: lower)!.acceptsSPS(prefix(tier: 1, level: 153)))
        XCTAssertFalse(config.acceptsSPS(prefix(chroma: 1)))
    }
    private func prefix(chroma: UInt64 = 3, separate: UInt64 = 0, lumaDepth: UInt64 = 0, chromaDepth: UInt64 = 0,
                        rightCrop: UInt64 = 0, width: UInt64 = 64, tier: UInt64 = 0, level: UInt64 = 30) -> Data {
        func fixed(_ value: UInt64, _ count: Int) -> String { String((0..<count).reversed().map { (value >> $0) & 1 == 1 ? Character("1") : Character("0") }) }
        func ue(_ value: UInt64) -> String { let bits = String(value + 1, radix: 2); return String(repeating: "0", count: bits.count - 1) + bits }
        var bits = "00000001" + fixed(tier, 3) + fixed(4, 5) + fixed(0x08000000, 32) + fixed(0xbe0800000000, 48) + fixed(level, 8)
        bits += ue(0) + ue(chroma)
        if chroma == 3 { bits += fixed(separate, 1) }
        bits += ue(width) + ue(64) + "1" + ue(0) + ue(rightCrop) + ue(0) + ue(0) + ue(lumaDepth) + ue(chromaDepth)
        bits += "1" + String(repeating: "0", count: (8 - (bits.count + 1) % 8) % 8)
        let characters = Array(bits); var output = Data([0x42, 1]), zeros = 0
        for i in stride(from: 0, to: characters.count, by: 8) {
            var byte: UInt8 = 0
            for character in characters[i..<(i + 8)] { byte = (byte << 1) | (character == "1" ? 1 : 0) }
            if zeros >= 2 && byte <= 3 { output.append(3); zeros = 0 }
            output.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }
    func testDisabledDefaultAndExactRoleCatalogCacheIdentity() {
        XCTAssertNil(HEVC444Policy.catalogProfile(["HEVC_Main_AutoLevel", "HEVC_Main10_AutoLevel"]))
        XCTAssertEqual(HEVC444Policy.catalogProfile(["HEVC_Main444_AutoLevel"]), "HEVC_Main444_AutoLevel")
        XCTAssertFalse(HEVC444Policy.permits(preference: false, simulator: false, disabled: false, decoder: true, encoder: true, isHost: true))
        XCTAssertFalse(HEVC444Policy.permits(preference: true, simulator: true, disabled: false, decoder: true, encoder: true, isHost: false))
        XCTAssertFalse(HEVC444Policy.permits(preference: true, simulator: false, disabled: true, decoder: true, encoder: true, isHost: false))
        XCTAssertFalse(HEVC444Policy.permits(preference: true, simulator: false, disabled: false, decoder: true, encoder: false, isHost: true))
        XCTAssertTrue(HEVC444Policy.permits(preference: true, simulator: false, disabled: false, decoder: true, encoder: false, isHost: false))
        XCTAssertNil(HEVC444Policy.cacheKey(role: "unknown", systemAndModel: "26.0.Mac16,13"))
        XCTAssertNil(HEVC444Policy.cacheKey(role: "decode", systemAndModel: "26.0.unknown"))
        XCTAssertNotEqual(HEVC444Policy.cacheKey(role: "encode", systemAndModel: "26.0.Mac16,13"), HEVC444Policy.cacheKey(role: "decode", systemAndModel: "26.0.Mac16,13"))
    }

    func testFullColorWinsOverStillTextRefinementOnBothSides() {
        XCTAssertTrue(HEVC444Policy.permitsRefinement(requested: true, fullColor: false))
        XCTAssertFalse(HEVC444Policy.permitsRefinement(requested: true, fullColor: true))
        XCTAssertFalse(HEVC444Policy.permitsRefinement(requested: false, fullColor: false))
        XCTAssertEqual(StillTextPreferences.requestedFeatures(sharpen: true, textClarity: false, fullColor: true), [],
                       "A phone with full color on never asks for refinement")
        XCTAssertEqual(StillTextPreferences.requestedFeatures(sharpen: true, textClarity: true, fullColor: true), [SessionFeature.textClarity],
                       "Text clarity is independent of full color")
        let fullColorHost = PeerMedia(isHost: true, servers: [], hevc: true, hevc444: true)
        let plainHost = PeerMedia(isHost: true, servers: [], hevc: true, hevc444: false)
        defer { fullColorHost.close(); plainHost.close() }
        XCTAssertTrue(fullColorHost.fullColorCaptureEnabled)
        fullColorHost.requestRefinementCapture(true); plainHost.requestRefinementCapture(true)
        XCTAssertFalse(fullColorHost.refinementCaptureEnabled, "An earlier phone's refinement request yields to this Mac's full color")
        XCTAssertTrue(plainHost.refinementCaptureEnabled)
    }
}
