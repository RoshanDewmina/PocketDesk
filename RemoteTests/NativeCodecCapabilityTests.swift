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
        XCTAssertEqual(NativeCodecCapability.outcome, .simulator)
        #else
        XCTAssertNotNil(NativeCodecCapability.outcome, "the probe records how it decided")
        XCTAssertNotEqual(NativeCodecCapability.outcome, .simulator)
        #endif
        XCTAssertFalse(NativeCodecCapability.outcomeDescription.isEmpty)
    }

    func testOnlyPositiveResultsAreCachedPerSystemAndModel() throws {
        let suite = "NativeCodecCapabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = NativeCodecCapability.cacheDefaultsKey
        XCTAssertTrue(key.hasPrefix("PocketDeskLevel52Probe."))
        XCTAssertTrue(key.contains(NativeCodecCapability.systemAndModel))
        XCTAssertFalse(NativeCodecCapability.systemAndModel.contains(" "))
        XCTAssertNil(NativeCodecCapability.cachedResult(defaults: defaults, key: key))
        NativeCodecCapability.storeResult(false, defaults: defaults, key: key)
        XCTAssertNil(NativeCodecCapability.cachedResult(defaults: defaults, key: key), "a failed probe is retried next launch")
        NativeCodecCapability.storeResult(true, defaults: defaults, key: key)
        XCTAssertEqual(NativeCodecCapability.cachedResult(defaults: defaults, key: key), true)
        XCTAssertNil(NativeCodecCapability.cachedResult(defaults: defaults, key: key + ".other-os"), "an OS or model change re-probes")
    }
}
