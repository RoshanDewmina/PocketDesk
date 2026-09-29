import XCTest
import MetalKit
import WebRTC
@testable import PocketDeskRemote

@MainActor
final class VideoPresentationProbeTests: XCTestCase {
    func testTrackerMatchesTheCompletedStampAndLeavesLaterFramesPending() throws {
        let tracker = PresentationTracker()
        XCTAssertNil(tracker.drew(stampNs: 10, atMs: 1_000), "no registered frame, nothing presented")
        XCTAssertFalse(tracker.hasPending)
        tracker.frameWillForward(stampNs: 10, atMs: 1_000)
        tracker.frameWillForward(stampNs: 11, atMs: 1_004)
        tracker.frameWillForward(stampNs: 12, atMs: 1_010)
        XCTAssertTrue(tracker.hasPending)
        let presented = try XCTUnwrap(tracker.drew(stampNs: 11, atMs: 1_015))
        XCTAssertEqual(presented.latencyMs, 11, accuracy: 0.001)
        XCTAssertEqual(presented.superseded, 1)
        XCTAssertTrue(tracker.hasPending, "a frame forwarded during the draw remains pending")
        let later = try XCTUnwrap(tracker.drew(stampNs: 12, atMs: 1_020))
        XCTAssertEqual(later.latencyMs, 10, accuracy: 0.001)
        XCTAssertEqual(later.superseded, 0)
        XCTAssertFalse(tracker.hasPending)
        XCTAssertNil(tracker.drew(stampNs: 12, atMs: 1_021), "the same frame is not counted twice")
    }

    func testTrackerTreatsAnUnknownCompletedStampAsUnavailable() throws {
        let tracker = PresentationTracker()
        tracker.frameWillForward(stampNs: 20, atMs: 2_000)
        XCTAssertNil(tracker.drew(stampNs: 19, atMs: 2_005))
        XCTAssertTrue(tracker.hasPending, "an unknown stamp must not consume a genuine pending frame")
        XCTAssertNotNil(tracker.drew(stampNs: 20, atMs: 2_006))
    }

    func testProbePublishesOnlyAnExactCompletedStamp() {
        let probe = VideoPresentationProbe()
        let counters = StreamCounters()
        let metal = MTKView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        probe.counters = counters
        probe.tracker.frameWillForward(stampNs: 30, atMs: MachClock.nowMs())

        probe.drawnStampReader = { nil }
        probe.draw(in: metal)
        var snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.presentedFrames, 0,
                       "a missing compatibility stamp makes the metric unavailable")
        snapshot.interval = 1
        var report = StreamStatsReport(role: "phone", previous: nil,
                                       current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertNil(report.presentedFPS)
        XCTAssertNil(report.supersededFrames)
        XCTAssertNil(PhoneLoadFeedback(report: report).presentedFPS)
        XCTAssertNil(PhoneLoadFeedback(report: report).supersededPerSecond)

        probe.drawnStampReader = { 29 }
        probe.draw(in: metal)
        snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.presentedFrames, 0,
                       "an unknown stamp is not reported as a good draw")
        snapshot.interval = 1
        report = StreamStatsReport(role: "phone", previous: nil,
                                   current: StreamStatsSample(entries: []), counters: snapshot)
        XCTAssertNil(report.presentedFPS)
        XCTAssertNil(report.supersededFrames)

        probe.drawnStampReader = { 30 }
        probe.draw(in: metal)
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil).presentedFrames, 1)
        probe.draw(in: metal)
        XCTAssertEqual(counters.drain(inputBufferedBytes: nil).presentedFrames, 0,
                       "the completed stamp is counted once")
    }

    func testPresentedMarkerWaitsForExactStampResolution() {
        let frame = PresentedFrameMarker()
        var callbacks = 0
        var received: BenchMarker?
        frame.whenResolved { marker in callbacks += 1; received = marker }
        XCTAssertEqual(callbacks, 0, "a drawable callback alone is not proof of a matched frame")
        let marker = BenchMarker(timeMs: 123, chartSeed: 1, flash: false, motion: true)
        frame.resolve(marker: marker)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(received, marker)
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
        probe.tracker.frameWillForward(stampNs: 40)
        probe.drawnStampReader = { 40 }
        probe.draw(in: metal)
        let snapshot = counters.drain(inputBufferedBytes: nil)
        XCTAssertEqual(snapshot.presentedFrames, 1)
        XCTAssertEqual(fetches, 0, "without Stream statistics the probe never asks for a drawable")
        probe.markerForStamp = { _ in nil }
        probe.draw(in: metal)
        XCTAssertEqual(fetches, 0, "nothing pending, no drawable")
        probe.tracker.frameWillForward(stampNs: 41)
        probe.drawnStampReader = { 41 }
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
