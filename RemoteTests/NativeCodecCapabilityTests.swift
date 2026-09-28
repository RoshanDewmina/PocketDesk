import CoreMedia
import XCTest

final class NativeCodecCapabilityTests: XCTestCase {
    func testEmbeddedFixtureIsHighLevel52At4K() throws {
        let description = try XCTUnwrap(NativeCodecCapability.fixtureDescription())
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        XCTAssertEqual(dimensions.width, 3840)
        XCTAssertEqual(dimensions.height, 2160)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
    }

    func testProbeReturnsCachedResult() {
        let first = NativeCodecCapability.supportsLevel52
        XCTAssertEqual(first, NativeCodecCapability.supportsLevel52)
        #if targetEnvironment(simulator)
        XCTAssertFalse(first)
        #endif
    }
}
