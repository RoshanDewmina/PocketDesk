import CoreGraphics
import XCTest

final class BigTextHostWiringTests: XCTestCase {
    func testFeatureIsAdvertisedOnlyWhenAllowedAndAccessible() {
        let base = ["curtain.1"]
        XCTAssertEqual(HostFeatureList.features(base: base, allowBigText: true, accessibility: true), base + [SessionFeature.displayScale])
        XCTAssertEqual(HostFeatureList.features(base: base, allowBigText: false, accessibility: true), base)
        XCTAssertEqual(HostFeatureList.features(base: base, allowBigText: true, accessibility: false), base)
    }

    func testPreferenceDefaultsOn() {
        let suite = "BigTextHostWiringTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HostPreferences(defaults: defaults)
        XCTAssertTrue(preferences.allowBigText)
        preferences.allowBigText = false
        XCTAssertFalse(HostPreferences(defaults: defaults).allowBigText)
    }

    func testViewStateDefaultsShowNothingForBigText() {
        let state = HostViewState()
        XCTAssertTrue(state.allowBigText)
        XCTAssertNil(state.bigTextStatus)
    }
}

final class BigTextRefreshTests: XCTestCase {
    func testAcceptsTheRefreshedFrame() {
        XCTAssertTrue(BigTextRefresh.matches(frame: CGRect(x: 0, y: 0, width: 1280, height: 832),
                                            coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1280, height: 832)))
    }

    func testRejectsAFrameThatDisagreesWithCoreGraphics() {
        XCTAssertFalse(BigTextRefresh.matches(frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                             coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1280, height: 832)),
                       "a stale SCDisplay would map clicks to the old size")
    }

    func testRejectsAStaleOriginOnASecondDisplay() {
        XCTAssertFalse(BigTextRefresh.matches(frame: CGRect(x: 1470, y: 0, width: 1920, height: 1080),
                                             coreGraphicsBounds: CGRect(x: 1280, y: 0, width: 1920, height: 1080)),
                       "a display beside the changed one moves; clicks there would land offset")
    }

    func testToleratesSubPointRounding() {
        XCTAssertTrue(BigTextRefresh.matches(frame: CGRect(x: 0, y: 0, width: 1280.4, height: 831.6),
                                            coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1280, height: 832)))
    }
}
