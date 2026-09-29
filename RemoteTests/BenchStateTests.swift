import XCTest
import CoreGraphics

final class BenchStateTests: XCTestCase {
    func testFirstFrameDrawsThenAStaticBenchHoldsItsMarker() {
        var state = BenchState(seed: 0x123)
        XCTAssertTrue(state.wantsFrames)
        XCTAssertEqual(state.markerTime(now: 1_000.4), 1_000.4)
        let held = BenchMarker(hostTimeMs: 1_000.4, chartSeed: 0x123, flash: false, motion: false)
        XCTAssertEqual(state.shownMarker, held)
        XCTAssertFalse(state.wantsFrames)
        for frame in 1...120 {
            XCTAssertNil(state.markerTime(now: 1_000.4 + Double(frame) * 16.7))
        }
        XCTAssertEqual(state.shownMarker, held)
        XCTAssertEqual(state.shownTimeMs, 1_000.4)
    }

    func testMotionTicksEveryFrameAndOneFinalFrameClearsTheMotionBit() {
        var state = BenchState(seed: 1)
        _ = state.markerTime(now: 0)
        XCTAssertTrue(state.setMotion(true))
        XCTAssertFalse(state.setMotion(true), "switching to the current value is not an event")
        var times: [Double] = []
        for frame in 1...60 {
            if let time = state.markerTime(now: 1_000 + Double(frame) * 16) { times.append(time) }
        }
        XCTAssertEqual(times.count, 60)
        XCTAssertEqual(Set(times).count, 60)
        XCTAssertEqual(state.shownMarker?.motion, true)
        XCTAssertEqual(state.motionSeconds, 59 * 0.016, accuracy: 1e-9, "the first tick after switching on does not advance")
        XCTAssertEqual(state.scrollOffset, 0)

        XCTAssertTrue(state.setMotion(false))
        XCTAssertEqual(state.markerTime(now: 2_000), 2_000)
        XCTAssertEqual(state.shownMarker?.motion, false)
        XCTAssertNil(state.markerTime(now: 2_016))
        XCTAssertEqual(state.shownTimeMs, 2_000)

        let seconds = state.motionSeconds
        state.setMotion(true)
        _ = state.markerTime(now: 60_000)
        XCTAssertEqual(state.motionSeconds, seconds, "resuming does not jump by the time spent static")
    }

    func testScrollAloneSetsTheMotionBitAndAdvancesAtOneThousandPointsPerSecond() {
        var state = BenchState(seed: 7)
        _ = state.markerTime(now: 0)
        state.setScroll(true)
        for frame in 0...10 { XCTAssertNotNil(state.markerTime(now: 500 + Double(frame) * 10)) }
        XCTAssertEqual(state.scrollOffset, 100, accuracy: 1e-9)
        XCTAssertEqual(state.motionSeconds, 0)
        XCTAssertEqual(state.shownMarker?.motion, true)
        XCTAssertTrue(state.wantsFrames)
    }

    func testEventsRedrawOnceWhileStatic() {
        var state = BenchState(seed: 5)
        _ = state.markerTime(now: 10)

        XCTAssertFalse(state.setChart(seed: 5), "the same chart is not an event")
        XCTAssertNil(state.markerTime(now: 20))
        XCTAssertFalse(state.setChart(seed: 0), "seed 0 means no chart")
        XCTAssertFalse(state.setChart(seed: 0x1abc), "real charts are 1…4095")
        XCTAssertNil(state.markerTime(now: 25))
        XCTAssertTrue(state.setChart(seed: 0xabc))
        XCTAssertEqual(state.seed, 0xabc)
        XCTAssertEqual(state.markerTime(now: 30), 30)
        XCTAssertEqual(state.shownMarker?.chartSeed, 0xabc)
        XCTAssertNil(state.markerTime(now: 40))

        state.toggleFlash()
        XCTAssertEqual(state.markerTime(now: 50), 50)
        XCTAssertEqual(state.shownMarker?.flash, true)
        XCTAssertNil(state.markerTime(now: 60))
        state.toggleFlash()
        XCTAssertEqual(state.markerTime(now: 70), 70)
        XCTAssertEqual(state.shownMarker?.flash, false)

        state.jump(by: 640)
        XCTAssertEqual(state.markerTime(now: 80), 80)
        XCTAssertEqual(state.scrollOffset, 640)
        XCTAssertEqual(state.shownMarker?.motion, false)
        XCTAssertNil(state.markerTime(now: 90))

        state.setScroll(true)
        state.setScroll(false)
        XCTAssertEqual(state.markerTime(now: 100), 100, "a switch that ends where it began still redraws once")
        XCTAssertNil(state.markerTime(now: 110))
    }

    func testAStalledTickAdvancesByAtMostTheMaximumStep() {
        var state = BenchState(seed: 2)
        state.setMotion(true)
        state.setScroll(true)
        _ = state.markerTime(now: 1_000)
        _ = state.markerTime(now: 3_000)
        XCTAssertEqual(state.motionSeconds, BenchState.maximumStepMs / 1000, accuracy: 1e-9)
        XCTAssertEqual(state.scrollOffset, BenchState.maximumStepMs, accuracy: 1e-9)
        _ = state.markerTime(now: 2_000)
        XCTAssertEqual(state.motionSeconds, BenchState.maximumStepMs / 1000, accuracy: 1e-9, "time never runs backwards")
    }

    func testBoxBouncesOneTraversalEveryTwoSeconds() {
        let expected: [(Double, Double)] = [(0, 0), (1, 0.5), (2, 1), (3, 0.5), (4, 0), (5, 0.5), (6.5, 0.75)]
        for (seconds, fraction) in expected {
            XCTAssertEqual(BenchState.boxFraction(motionSeconds: seconds), fraction, accuracy: 1e-9, "\(seconds) s")
        }
        var state = BenchState(seed: 3)
        state.setMotion(true)
        for frame in 0...5 { _ = state.markerTime(now: Double(frame) * 200) }
        XCTAssertEqual(state.boxFraction, 0.5, accuracy: 1e-9)
    }

    func testRequestedSeedsAndRandomSeedsAreRealCharts() {
        XCTAssertNil(BenchState.chartSeed(requested: -1, current: 9))
        XCTAssertNil(BenchState.chartSeed(requested: 4096, current: 9))
        XCTAssertEqual(BenchState.chartSeed(requested: 1, current: 9), 1)
        XCTAssertEqual(BenchState.chartSeed(requested: 4095, current: 9), 4095)
        for _ in 0..<200 {
            let picked = BenchState.chartSeed(requested: 0, current: 9)
            XCTAssertNotNil(picked, "0 asks for a random chart")
            XCTAssertNotEqual(picked, 9)
            XCTAssertTrue(picked.map { LegibilityChart.seedRange.contains($0) } ?? false)
        }
        for excluded in [UInt16(1), 1_234, 4_095] {
            for _ in 0..<500 {
                let seed = BenchState.randomSeed(excluding: excluded)
                XCTAssertNotEqual(seed, excluded)
                XCTAssertTrue(LegibilityChart.seedRange.contains(seed))
                XCTAssertNotEqual(seed, LegibilityChart.noChartSeed)
            }
        }
    }

    func testPartsNeverCoverTheMarkerStripOrTheChart() {
        let sizes = [CGSize(width: 1470, height: 956), CGSize(width: 1710, height: 1112), CGSize(width: 1512, height: 982),
                     CGSize(width: 1728, height: 1117), CGSize(width: 1440, height: 900), CGSize(width: 1280, height: 800),
                     CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440), CGSize(width: 1080, height: 1920)]
        for size in sizes {
            for safeTop in [CGFloat(0), 38] {
                let layout = BenchPadLayout(size: size, safeTop: safeTop)
                let bounds = CGRect(origin: .zero, size: size)
                XCTAssertEqual(layout.marker, BenchMarker.layout(width: Double(size.width), height: Double(size.height)).frame)
                XCTAssertEqual(layout.chart, LegibilityChart.layout(displayPointSize: size).frame)
                let parts = layout.parts
                for (name, rect) in parts {
                    let label = "\(name) at \(size)"
                    XCTAssertGreaterThan(rect.width, 0, label)
                    XCTAssertGreaterThan(rect.height, 0, label)
                    XCTAssertTrue(bounds.contains(rect), label)
                    XCTAssertFalse(rect.intersects(layout.marker), label)
                    XCTAssertFalse(rect.intersects(layout.chart), label)
                    XCTAssertGreaterThanOrEqual(rect.minY, safeTop, label)
                    for (other, otherRect) in parts where other < name {
                        XCTAssertFalse(rect.intersects(otherRect), "\(label) overlaps \(other)")
                    }
                }
                XCTAssertEqual(layout.flash.size, CGSize(width: 220, height: 220))
                XCTAssertGreaterThanOrEqual(layout.lane.height, BenchPadLayout.boxSide)
                XCTAssertGreaterThan(layout.flash.midX, size.width / 2)
                XCTAssertGreaterThan(layout.flash.midY, size.height / 2)
            }
        }
    }
}
