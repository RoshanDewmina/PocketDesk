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
        if NativeCodecCapability.supportsLevel52 { XCTAssertTrue(h264.allSatisfy { $0.parameters["profile-level-id"]?.hasSuffix("34") == true }) }
        XCTAssertTrue(codecs.contains { $0.name == "VP8" })
        let encoder = PocketDeskVideoEncoderFactory().createEncoder(h264[0])
        XCTAssertNotNil(encoder)
    }

    func testDecoderFactoryAdvertisesLevel52() {
        let codecs = PocketDeskVideoDecoderFactory().supportedCodecs()
        XCTAssertEqual(codecs.first?.name, kRTCVideoCodecH264Name)
        if NativeCodecCapability.supportsLevel52 {
            XCTAssertTrue(codecs.filter { $0.name == kRTCVideoCodecH264Name }
                .allSatisfy { $0.parameters["profile-level-id"]?.hasSuffix("34") == true })
        }
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
    func testAnswerLevelCapsPixelsBeforeEncodingForOldPeer() {
        let answer = "m=video 9 UDP/TLS/RTP/SAVPF 96 98\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 profile-level-id=42e01f;packetization-mode=1\r\na=rtpmap:98 H264/90000\r\na=fmtp:98 profile-level-id=640c34\r\n"
        let budget = H264FrameBudget.receivingLimit(sdp: answer)!
        XCTAssertEqual(budget, .level(31))
        let fitted = budget.fitted(width: 2940, height: 1912)
        XCTAssertLessThanOrEqual(((fitted.width + 15) / 16) * ((fitted.height + 15) / 16) * 60, 108000)
        XCTAssertEqual(Double(fitted.width) / Double(fitted.height), 2940.0 / 1912, accuracy: 0.02)
        XCTAssertNil(H264FrameBudget.receivingLimit(sdp: "m=video 9 UDP/TLS/RTP/SAVPF 100\r\na=rtpmap:100 VP8/90000"))
    }

    func testLevel52Allows4K60AndLimitsTallDesktop() {
        let budget = H264FrameBudget.level(52)
        let full = budget.fitted(width: 3840, height: 2160)
        XCTAssertEqual(full.width, 3840)
        XCTAssertEqual(full.height, 2160)
        let tall = budget.fitted(width: 3840, height: 2496)
        XCTAssertTrue(H264LevelPolicy.fitsAt60FPS(width: tall.width, height: tall.height))
        XCTAssertEqual(H264FrameBudget.level(255), .level(31))
    }
}
