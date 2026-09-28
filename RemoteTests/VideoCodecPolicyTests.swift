import XCTest
import CoreGraphics
import WebRTC

final class VideoCodecPolicyTests: XCTestCase {
    func testH264ProfilesAreAdvertisedAtLevel52WithoutChangingProfile() {
        let high = H264LevelPolicy.raisingLevel(["profile-level-id": "640c1f", "packetization-mode": "1",
                                                 "level-asymmetry-allowed": "1"])
        XCTAssertEqual(high["profile-level-id"], "640c34")
        XCTAssertEqual(high["packetization-mode"], "1")
        XCTAssertEqual(high["level-asymmetry-allowed"], "1")
        XCTAssertEqual(H264LevelPolicy.raisingLevel(["profile-level-id": "42e01f"])["profile-level-id"], "42e034")
        XCTAssertEqual(H264LevelPolicy.raisingLevel(["profile-level-id": "640C33"])["profile-level-id"], "640c34")
    }

    func testMalformedOrMissingProfileLevelIsLeftAlone() {
        XCTAssertEqual(H264LevelPolicy.raisingLevel(["profile-level-id": "zz"]), ["profile-level-id": "zz"])
        XCTAssertEqual(H264LevelPolicy.raisingLevel(["profile-level-id": "64zz1f"]), ["profile-level-id": "64zz1f"])
        XCTAssertEqual(H264LevelPolicy.raisingLevel([:]), [:])
    }

    func testLevel52FrameBudgetAt60FPS() {
        XCTAssertTrue(H264LevelPolicy.fitsAt60FPS(width: 2940, height: 1912))
        XCTAssertTrue(H264LevelPolicy.fitsAt60FPS(width: 3840, height: 2160))
        XCTAssertFalse(H264LevelPolicy.fitsAt60FPS(width: 3840, height: 2496))
    }

    func testEncoderFactoryPrefersH264AtLevel52AndKeepsSoftwareFallbacks() {
        let codecs = PocketDeskVideoEncoderFactory().supportedCodecs()
        XCTAssertEqual(codecs.first?.name, kRTCVideoCodecH264Name)
        let h264 = codecs.filter { $0.name == kRTCVideoCodecH264Name }
        XCTAssertFalse(h264.isEmpty)
        XCTAssertTrue(h264.allSatisfy { $0.parameters["profile-level-id"]?.hasSuffix("34") == true })
        XCTAssertTrue(codecs.contains { $0.name == kRTCVideoCodecVp8Name })
        let encoder = PocketDeskVideoEncoderFactory().createEncoder(h264[0])
        XCTAssertNotNil(encoder)
    }

    func testDecoderFactoryAdvertisesLevel52() {
        let codecs = PocketDeskVideoDecoderFactory().supportedCodecs()
        XCTAssertEqual(codecs.first?.name, kRTCVideoCodecH264Name)
        XCTAssertTrue(codecs.filter { $0.name == kRTCVideoCodecH264Name }
            .allSatisfy { $0.parameters["profile-level-id"]?.hasSuffix("34") == true })
        XCTAssertNotNil(PocketDeskVideoDecoderFactory().createDecoder(codecs[0]))
    }

    func testSharpCaptureStaysInsideTheH264Level52FrameBudget() throws {
        let dimensions = try XCTUnwrap(CapturePixelDimensions.fitted(
            contentSize: CGSize(width: 1920, height: 1248), pointPixelScale: 2, quality: .sharp))
        XCTAssertTrue(H264LevelPolicy.fitsAt60FPS(width: dimensions.width, height: dimensions.height))
        XCTAssertGreaterThan(dimensions.width, 3600)
        XCTAssertEqual(Double(dimensions.width) / Double(dimensions.height), 3840.0 / 2496.0, accuracy: 0.01)
        XCTAssertEqual(dimensions.width % 2, 0)
        XCTAssertEqual(dimensions.height % 2, 0)
    }
}
