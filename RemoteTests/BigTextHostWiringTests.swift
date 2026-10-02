import CoreGraphics
import XCTest

final class VirtualDisplayCaptureWiringTests: XCTestCase {
    func testExactPixelsBypassPresetCapAt120ButKeepReceiverBudget() throws {
        let spec = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 402, height: 874, scale: 3, maximumFPS: 120)))
        XCTAssertEqual(RemoteCaptureConfiguration.virtualDisplayOutput(spec, budget: .level(52), fps: 120),
                       CapturePixelDimensions(width: 1206, height: 2622))
        XCTAssertNil(RemoteCaptureConfiguration.virtualDisplayOutput(spec, budget: .level(31), fps: 120))
        XCTAssertNil(RemoteCaptureConfiguration.virtualDisplayOutput(spec, budget: nil, fps: 120))
    }

    func testVirtualMetadataValidatesOnlyOnItsMessageAndLegacyBytesOmitIt() throws {
        let viewport = VirtualDisplayViewport(width: 402, height: 874, scale: 3, maximumFPS: 120)
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", virtualDisplayViewport: viewport).validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", virtualDisplayViewport: viewport).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", virtualDisplayActive: true).validate())
        XCTAssertNoThrow(try RemoteAction(action: "heartbeat", virtualDisplayViewportUnavailable: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", virtualDisplayViewportUnavailable: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", virtualDisplayViewport: viewport,
                                             virtualDisplayViewportUnavailable: true).validate())
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteAction(action: "heartbeat"))) as! [String: Any]
        XCTAssertNil(legacy["virtualDisplayViewport"])
        XCTAssertNil(legacy["virtualDisplayActive"])
        XCTAssertNil(legacy["virtualDisplayViewportUnavailable"])
    }

    func testVirtualFeatureIsOffByDefaultAndFits32OnlyOnModernPeers() {
        let base = SessionFeature.host + [SessionFeature.couch, SessionFeature.deliberateEnd, SessionFeature.lanWake, SessionFeature.away]
        let peer: Set<String> = [SessionFeature.extendedFeatureList, SessionFeature.causalInput, SessionFeature.ipadWorkspace]
        let legacy = HostFeatureList.features(base: base, allowBigText: true, accessibility: true, peerFeatures: peer)
        XCTAssertFalse(legacy.contains(SessionFeature.virtualDisplay))
        let enabled = HostFeatureList.features(base: base, allowBigText: true, accessibility: true, peerFeatures: peer, virtualDisplayEnabled: true)
        let phone = HostFeatureList.features(base: base, allowBigText: true, accessibility: true,
            peerFeatures: [SessionFeature.extendedFeatureList, SessionFeature.causalInput], virtualDisplayEnabled: true)
        XCTAssertFalse(phone.contains(SessionFeature.virtualDisplay))
        XCTAssertTrue(phone.contains(SessionFeature.displayScale))
        XCTAssertTrue(enabled.contains(SessionFeature.virtualDisplay))
        XCTAssertFalse(enabled.contains(SessionFeature.displayScale))
        XCTAssertLessThanOrEqual(enabled.count, 32)
        XCTAssertFalse(HostFeatureList.features(base: base, allowBigText: true, accessibility: true, peerFeatures: [], virtualDisplayEnabled: true).contains(SessionFeature.virtualDisplay))
    }
}

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

final class BigTextScreenSnapshotTests: XCTestCase {
    private let frames: [CGDirectDisplayID: CGRect] = [1: CGRect(x: 0, y: 0, width: 1280, height: 832),
                                                     2: CGRect(x: 1280, y: 0, width: 1920, height: 1080)]
    private let modes: [CGDirectDisplayID: Int32] = [1: 4, 2: 7]

    func testLateNotificationMatchesOnlyTheCompletedDisplayGeometryAndModes() {
        let snapshot = BigTextScreenSnapshot(frames: frames, modeIDs: modes)
        XCTAssertTrue(snapshot.matches(online: [1, 2], frames: frames, modeIDs: modes))
        var changed = modes; changed[1] = 5
        XCTAssertFalse(snapshot.matches(online: [1, 2], frames: frames, modeIDs: changed), "a person's choice is foreign")
        XCTAssertFalse(snapshot.matches(online: [1, 2, 3], frames: frames, modeIDs: modes), "a plugged-in monitor is foreign")
        var moved = frames; moved[2] = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(snapshot.matches(online: [1, 2], frames: moved, modeIDs: modes), "a changed origin is foreign")
        XCTAssertFalse(snapshot.matches(online: [1], frames: frames, modeIDs: modes), "an unplugged display is foreign")
    }
}
