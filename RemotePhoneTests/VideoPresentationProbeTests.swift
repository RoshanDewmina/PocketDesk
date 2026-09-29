import XCTest
import MetalKit
import WebRTC
@testable import PocketDeskRemote

@MainActor
final class VideoPresentationProbeTests: XCTestCase {
    func testTrackerReportsNewestFrameLatencyAndReplacedFrames() throws {
        let tracker = PresentationTracker()
        XCTAssertNil(tracker.drew(at: 1), "no new frame, nothing presented")
        XCTAssertFalse(tracker.hasPending)
        tracker.frameArrived(at: 1.000)
        tracker.frameArrived(at: 1.004)
        tracker.frameArrived(at: 1.010)
        XCTAssertTrue(tracker.hasPending)
        let presented = try XCTUnwrap(tracker.drew(at: 1.015))
        XCTAssertEqual(presented.latencyMs, 5, accuracy: 0.001)
        XCTAssertEqual(presented.superseded, 2)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertNil(tracker.drew(at: 1.020), "the same frame is not counted twice")
    }

    func testProbeWrapsWebRTCMetalViewAndRestoresItsDelegate() throws {
        let view = RTCMTLVideoView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let metal = try XCTUnwrap(VideoPresentationProbe.findMetalView(in: view), "RTCMTLVideoView hosts an MTKView")
        let original = try XCTUnwrap(metal.delegate)
        let probe = try XCTUnwrap(VideoPresentationProbe.install(on: view))
        XCTAssertTrue(metal.delegate === probe)
        if StreamTuning.current.presentAtDisplayMaximum {
            XCTAssertEqual(metal.preferredFramesPerSecond, VideoPresentationProbe.preferredFramesPerSecond)
        }
        let counters = StreamCounters()
        probe.counters = counters
        var fetches = 0
        probe.drawableProvider = { _ in fetches += 1; return nil }
        probe.tracker.frameArrived()
        probe.draw(in: metal)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.presentedFrames, 1)
        XCTAssertEqual(fetches, 0, "without Stream statistics the probe never asks for a drawable")
        probe.markerForStamp = { _ in nil }
        probe.draw(in: metal)
        XCTAssertEqual(fetches, 0, "nothing pending, no drawable")
        probe.tracker.frameArrived()
        probe.draw(in: metal)
        XCTAssertEqual(fetches, 1, "a pending frame gets one drawable")
        probe.uninstall()
        XCTAssertTrue(metal.delegate === original)
    }

    func testProbeDeclinesViewsWithoutAMetalRenderer() {
        XCTAssertNil(VideoPresentationProbe.install(on: UIView()))
    }

    func testAppRequestsProMotionRates() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool, true)
    }
}
