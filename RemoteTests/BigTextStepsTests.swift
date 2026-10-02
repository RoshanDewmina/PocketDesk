import XCTest

final class BigTextStepsTests: XCTestCase {
    func testAutomaticLevelUsesPhonePixelsAndOnlyOfferedHiDPIModes() {
        let cases: [(Int, Int, PixelSize, Double?)] = [
            (1470, 956, PixelSize(width: 1179, height: 2556), 1280),
            (1920, 1243, PixelSize(width: 1290, height: 2796), 1440),
            (2560, 1440, PixelSize(width: 1206, height: 2622), 1280),
            (1920, 1080, PixelSize(width: 750, height: 1334), 1280),
            (1280, 832, PixelSize(width: 1179, height: 2556), nil)
        ]
        for (width, height, phone, expected) in cases {
            let baseline = mode(width, height)
            let modes = [1440, 1280, 1024].map { w in
                mode(w, Int((Double(w) / baseline.aspect).rounded()))
            } + [mode(1360, Int((1360 / baseline.aspect).rounded()), px: (1360, Int((1360 / baseline.aspect).rounded())))]
            let steps = BigTextSteps.steps(baseline: baseline, modes: modes)
            let picked = BigTextAutoLevel.choose(phonePixels: phone, baselineWidth: Double(width), steps: steps.map(\.step))
            XCTAssertEqual(picked, expected, "baseline \(width), phone \(phone)")
            XCTAssertEqual(picked, BigTextAutoLevel.choose(phonePixels: PixelSize(width: phone.height, height: phone.width),
                                                         baselineWidth: Double(width), steps: steps.map(\.step)))
            if let picked { XCTAssertTrue(steps.contains { Double($0.width) == picked && $0.isHiDPI }) }
        }
    }

    func testAutomaticLevelEmptyInvalidAndTieCases() {
        let phone = PixelSize(width: 1206, height: 2622)
        XCTAssertNil(BigTextAutoLevel.choose(phonePixels: phone, baselineWidth: 1920, steps: []))
        XCTAssertNil(BigTextAutoLevel.choose(phonePixels: PixelSize(width: 0, height: 2622), baselineWidth: 1920,
                                            steps: [ScaleStep(width: 1280, height: 832)]))
        let tied = [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1440, height: 936)]
        XCTAssertEqual(BigTextAutoLevel.choose(phonePixels: PixelSize(width: 1200, height: 2720),
                                              baselineWidth: 1920, steps: tied), 1440)
        XCTAssertNil(BigTextAutoLevel.choose(phonePixels: phone, baselineWidth: 1920,
                                            steps: [ScaleStep(width: 2048, height: 1330)]))
    }
    private func mode(_ w: Int, _ h: Int, px: (Int, Int)? = nil, hz: Double = 60, gui: Bool = true, id: Int32? = nil) -> DisplayModeInfo {
        let pixels = px ?? (w * 2, h * 2)
        return DisplayModeInfo(ioModeID: id ?? Int32(w * 10_000 + h), width: w, height: h, pixelWidth: pixels.0,
                               pixelHeight: pixels.1, refreshRate: hz, usableForDesktopGUI: gui)
    }

    private var airBaseline: DisplayModeInfo { mode(1470, 956) }
    private var airModes: [DisplayModeInfo] {
        [mode(1710, 1112), mode(1470, 956), mode(1280, 832), mode(1024, 665),
         mode(1280, 832, px: (1280, 832)), mode(1280, 832, id: 99), mode(800, 520, gui: false),
         mode(1440, 900), mode(1280, 832, hz: 120)]
    }

    func testOnlyBiggerTextHiDPIStepsOfTheSameShapeAndRate() {
        let steps = BigTextSteps.steps(baseline: airBaseline, modes: airModes)
        XCTAssertEqual(steps.map(\.width), [1280, 1024], "no More Space, no 1x, no other aspect, rate or non-GUI mode")
    }

    func testDuplicatesCollapseAndLongListsSpreadToFour() {
        let many = (0..<9).map { mode(1400 - $0 * 100, Int((Double(1400 - $0 * 100) / airBaseline.aspect).rounded())) }
        let steps = BigTextSteps.steps(baseline: airBaseline, modes: many + many)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.first?.width, 1400, "the step closest to the Mac's size stays")
        XCTAssertEqual(steps.last?.width, 600, "the largest text stays")
    }

    func testSpreadKeepsEndsAndOrder() {
        XCTAssertEqual(BigTextSteps.spread([1, 2, 3, 4, 5, 6, 7], count: 4), [1, 3, 5, 7])
        XCTAssertEqual(BigTextSteps.spread([1, 2], count: 4), [1, 2])
    }

    func testNearestWithinTenPercentElseNil() {
        let steps = BigTextSteps.steps(baseline: airBaseline, modes: airModes)
        XCTAssertEqual(BigTextSteps.nearest(to: 1300, in: steps)?.width, 1280)
        XCTAssertEqual(BigTextSteps.nearest(to: 1000, in: steps)?.width, 1024)
        XCTAssertNil(BigTextSteps.nearest(to: 700, in: steps), "a saved size from another display is refused, not guessed")
        XCTAssertNil(BigTextSteps.nearest(to: 0, in: steps))
    }

    func testAlreadyAtTheLargestOffersNothing() {
        XCTAssertEqual(BigTextSteps.steps(baseline: mode(1024, 665), modes: airModes), [])
    }

    func testPanelsReportingZeroHertzStillMatch() {
        let steps = BigTextSteps.steps(baseline: mode(1470, 956, hz: 0), modes: [mode(1280, 832, hz: 0)])
        XCTAssertEqual(steps.map(\.width), [1280])
    }

    func testCapturedAirList() {
        // CGDisplayCopyAllDisplayModes on the dev Mac's main display, 2026-09-30, with duplicate low-resolution modes shown.
        let capturedBaseline = mode(1920, 1243, px: (3840, 2486), hz: 60.0, gui: true, id: 11)
        let capturedAirModes: [DisplayModeInfo] = [
            mode(960, 600, px: (1920, 1200), hz: 60.0, gui: true, id: 0),
            mode(1024, 640, px: (2048, 1280), hz: 60.0, gui: true, id: 1),
            mode(1024, 663, px: (2048, 1326), hz: 60.0, gui: true, id: 2),
            mode(1280, 800, px: (2560, 1600), hz: 60.0, gui: true, id: 3),
            mode(1280, 828, px: (2560, 1656), hz: 60.0, gui: true, id: 4),
            mode(1440, 900, px: (2880, 1800), hz: 60.0, gui: true, id: 5),
            mode(1440, 932, px: (2880, 1864), hz: 60.0, gui: true, id: 6),
            mode(1710, 1068, px: (3420, 2136), hz: 60.0, gui: true, id: 7),
            mode(1710, 1107, px: (3420, 2214), hz: 60.0, gui: true, id: 8),
            mode(1920, 1200, px: (1920, 1200), hz: 60.0, gui: true, id: 9),
            mode(1920, 1200, px: (3840, 2400), hz: 60.0, gui: true, id: 10),
            mode(1920, 1243, px: (3840, 2486), hz: 60.0, gui: true, id: 11),
            mode(2048, 1280, px: (2048, 1280), hz: 60.0, gui: true, id: 12),
            mode(2048, 1326, px: (2048, 1326), hz: 60.0, gui: true, id: 13),
            mode(2560, 1600, px: (2560, 1600), hz: 60.0, gui: true, id: 14),
            mode(2560, 1656, px: (2560, 1656), hz: 60.0, gui: true, id: 15),
            mode(2880, 1800, px: (2880, 1800), hz: 60.0, gui: true, id: 16),
            mode(2880, 1864, px: (2880, 1864), hz: 60.0, gui: true, id: 17),
        ]
        let steps = BigTextSteps.steps(baseline: capturedBaseline, modes: capturedAirModes)
        XCTAssertFalse(steps.isEmpty, "the built-in display offers larger text")
        XCTAssertLessThanOrEqual(steps.count, 4)
        XCTAssertTrue(steps.allSatisfy { $0.isHiDPI && $0.width < capturedBaseline.width })
        XCTAssertEqual(steps.map(\.width), steps.map(\.width).sorted(by: >))
    }
}
