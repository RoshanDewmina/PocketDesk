import XCTest
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class ViewportCaptureTests: XCTestCase {
    private typealias Policy = ViewportCapturePolicy

    /// Roshan's ASUS VG32VQ1B at 1x, and the M4 Air 13" panel at its default 1470x956 pt @2x.
    private let asus = DisplayGeometry(size: CGSize(width: 2560, height: 1440), pointPixelScale: 1)
    private let air = DisplayGeometry(size: CGSize(width: 1470, height: 956), pointPixelScale: 2)

    private func output(_ display: DisplayGeometry, fps: Int, quality: StreamQuality = .sharp,
                        clientLongEdge: Int? = 2622) throws -> CapturePixelDimensions {
        try XCTUnwrap(RemoteCaptureConfiguration.outputSize(
            contentSize: display.size, pointPixelScale: display.pointPixelScale, quality: quality, budget: nil,
            fps: fps, clientLongEdge: clientLongEdge, tuning: .tuned))
    }

    /// An iPhone 17 in landscape (2622x1206 px) showing the display's centre at `zoom` px per point.
    private func centered(zoom: Double, on display: DisplayGeometry, epoch: UInt64 = 1) -> ViewportRegion {
        let width = 2622 / zoom
        let height = 1206 / zoom
        return ViewportRegion(epoch: epoch, x: (Double(display.size.width) - width) / 2,
                              y: (Double(display.size.height) - height) / 2, width: width, height: height,
                              pixelWidth: 2622, pixelHeight: 1206, zoom: zoom)
    }

    private func region(_ viewport: ViewportRegion?, on display: DisplayGeometry? = nil,
                        output: CapturePixelDimensions, tuning: StreamTuning = .tuned,
                        previous: CaptureRegion? = nil) -> CaptureRegion {
        Policy.region(for: viewport, display: display ?? asus, output: output, tuning: tuning, previous: previous)
    }

    private func size(_ width: Int, _ height: Int) -> CapturePixelDimensions {
        CapturePixelDimensions(width: width, height: height)
    }

    // MARK: Whole display

    func testNoViewportSwitchOffOrZoomAtMostOneIsTheWholeDisplay() throws {
        let whole = try output(asus, fps: 120)
        XCTAssertEqual(whole, size(2048, 1152), "Sharper at 120 fps: 2048 long edge, under the phone's 2622")
        let expected = CaptureRegion(epoch: 0, x: 0, y: 0, width: 2560, height: 1440,
                                     outputWidth: 2048, outputHeight: 1152)
        XCTAssertTrue(expected.isWholeDisplay)
        XCTAssertNoThrow(try expected.validate())

        XCTAssertEqual(region(nil, output: whole), expected)
        var off = StreamTuning.tuned
        off.viewportCapture = false
        XCTAssertEqual(region(centered(zoom: 2, on: asus), output: whole, tuning: off), expected)
        XCTAssertEqual(region(centered(zoom: 1, on: asus), output: whole), expected)
        XCTAssertEqual(region(centered(zoom: 0.84, on: asus), output: whole), expected)
    }

    func testDegenerateViewportsFallBackToTheWholeDisplayWithoutCrashing() throws {
        let whole = try output(asus, fps: 120)
        let expected = Policy.wholeDisplay(asus, output: whole)
        let base = centered(zoom: 2, on: asus)
        let changes: [(inout ViewportRegion) -> Void] = [
            { $0.width = 0 }, { $0.width = -1311 }, { $0.height = 0 }, { $0.height = -603 },
            { $0.x = .nan }, { $0.y = .infinity }, { $0.width = .infinity }, { $0.zoom = .nan },
            { $0.zoom = 25 }, { $0.pixelWidth = 0 }, { $0.epoch = 0 },
            { $0.x = 3000 }, { $0.y = -2000 }, { $0.x = -1311 }
        ]
        for change in changes {
            var viewport = base
            change(&viewport)
            XCTAssertEqual(region(viewport, output: whole), expected, "\(viewport)")
        }
        let empty = DisplayGeometry(size: .zero, pointPixelScale: 2)
        XCTAssertTrue(region(base, on: empty, output: whole).isWholeDisplay)
        XCTAssertTrue(region(base, output: size(0, 0)).isWholeDisplay)
    }

    func testCropThatWouldCoverNearlyTheWholeDisplayIsTheWholeDisplay() throws {
        let whole = try output(asus, fps: 120)
        XCTAssertTrue(region(centered(zoom: 1.1, on: asus), output: whole).isWholeDisplay, "wider than the display")
        // 70 % of the display, but 2512x1424 (97 %) once the margin and the output's aspect are added.
        let wide = ViewportRegion(epoch: 1, x: 200, y: 120, width: 2160, height: 1200,
                                  pixelWidth: 2622, pixelHeight: 1456, zoom: 1.2)
        XCTAssertTrue(region(wide, output: whole).isWholeDisplay)
        let nearlyAll = ViewportRegion(epoch: 1, x: 24, y: 14, width: 2512, height: 1412,
                                       pixelWidth: 2622, pixelHeight: 1474, zoom: 1.04)
        XCTAssertTrue(region(nearlyAll, output: whole).isWholeDisplay)
    }

    // MARK: Crop geometry

    func testReadingZoomOnTheASUSCropsOneToOneOnMacroblocksAndEchoesTheEpoch() throws {
        let whole = try output(asus, fps: 120)
        // 1311x603 pt visible, +8 % a side is 1521x700, widened to 16:9 is 1521x856, aligned 1536x864.
        let crop = region(centered(zoom: 2, on: asus, epoch: 7), output: whole)
        XCTAssertEqual(crop, CaptureRegion(epoch: 7, x: 512, y: 288, width: 1536, height: 864,
                                           outputWidth: 1536, outputHeight: 864))
        XCTAssertNoThrow(try crop.validate())
    }

    func testLightZoomKeepsTheWholeDisplayOutputSize() throws {
        let whole = try output(asus, fps: 120)
        let crop = region(centered(zoom: 1.25, on: asus), output: whole)
        XCTAssertEqual(crop, CaptureRegion(epoch: 1, x: 56, y: 32, width: 2448, height: 1376,
                                           outputWidth: 2048, outputHeight: 1152),
                       "the crop has more pixels than the output, so the encoder's frame size is unchanged")
    }

    func testRetinaCropAlignsDisplayPixelsNotPoints() throws {
        let at120 = try output(air, fps: 120)
        // 2940 x (2048 / 2940) evaluates to 2047.99..., which CapturePixelDimensions rounds down to 2046.
        XCTAssertEqual(at120, size(2046, 1330))
        XCTAssertTrue(region(centered(zoom: 2, on: air), on: air, output: at120).isWholeDisplay,
                      "1311 pt of a 1470 pt display is a 3041 px crop, wider than the panel")
        XCTAssertEqual(region(centered(zoom: 2.5, on: air), on: air, output: at120),
                       CaptureRegion(epoch: 1, x: 123, y: 82, width: 1224, height: 792,
                                     outputWidth: 2046, outputHeight: 1330))
        XCTAssertEqual(region(centered(zoom: 3, on: air), on: air, output: at120),
                       CaptureRegion(epoch: 1, x: 227, y: 146, width: 1016, height: 664,
                                     outputWidth: 2032, outputHeight: 1328))

        let at60 = try output(air, fps: 60)
        XCTAssertEqual(at60, size(2560, 1664))
        XCTAssertEqual(region(centered(zoom: 2.5, on: air), on: air, output: at60),
                       CaptureRegion(epoch: 1, x: 123, y: 82, width: 1224, height: 792,
                                     outputWidth: 2448, outputHeight: 1584))
    }

    func testPanInsideTheMarginKeepsTheCropAndEchoesTheNewEpoch() throws {
        let whole = try output(asus, fps: 120)
        let first = region(centered(zoom: 2, on: asus, epoch: 1), output: whole)
        var panned = centered(zoom: 2, on: asus, epoch: 2)
        panned.x += 50
        let second = region(panned, output: whole, previous: first)
        XCTAssertEqual(second, CaptureRegion(epoch: 2, x: 512, y: 288, width: 1536, height: 864,
                                             outputWidth: 1536, outputHeight: 864))
        XCTAssertFalse(Policy.needsReconfiguration(from: first, to: second))
    }

    func testPanPastTheMarginReCropsAtTheSameOutputSize() throws {
        let whole = try output(asus, fps: 120)
        let first = region(centered(zoom: 2, on: asus, epoch: 1), output: whole)
        var panned = centered(zoom: 2, on: asus, epoch: 2)
        panned.x += 200
        let second = region(panned, output: whole, previous: first)
        XCTAssertEqual(second, CaptureRegion(epoch: 2, x: 712, y: 288, width: 1536, height: 864,
                                             outputWidth: 1536, outputHeight: 864))
        XCTAssertTrue(Policy.needsReconfiguration(from: first, to: second))
    }

    func testViewportPartlyOutsideTheDisplayIsClampedIntoIt() throws {
        let whole = try output(asus, fps: 120)
        var right = centered(zoom: 2, on: asus)
        right.x = 2000
        XCTAssertEqual(region(right, output: whole),
                       CaptureRegion(epoch: 1, x: 1312, y: 368, width: 1248, height: 704,
                                     outputWidth: 1248, outputHeight: 704))
        var left = centered(zoom: 2, on: asus)
        left.x = -300
        XCTAssertEqual(region(left, output: whole),
                       CaptureRegion(epoch: 1, x: 0, y: 368, width: 1248, height: 704,
                                     outputWidth: 1248, outputHeight: 704))
    }

    func testCropIsNeverSmallerThanAQuarterOfTheDisplayLongEdge() throws {
        let whole = try output(asus, fps: 120)
        XCTAssertEqual(region(centered(zoom: 10, on: asus), output: whole),
                       CaptureRegion(epoch: 1, x: 960, y: 536, width: 640, height: 368,
                                     outputWidth: 640, outputHeight: 368))
    }

    func testEveryCropIsAlignedInsideTheDisplayAndCoversTheViewport() throws {
        var crops = 0
        for (display, fps) in [(asus, 120), (asus, 60), (air, 120), (air, 60)] {
            let whole = try output(display, fps: fps)
            let aspect = Double(whole.width) / Double(whole.height)
            let scale = display.pointPixelScale
            for zoom in [1.2, 1.5, 2, 2.5, 3, 4, 6, 10, 20] {
                for fractionX in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    for fractionY in [0.0, 0.5, 1.0] {
                        var viewport = centered(zoom: zoom, on: display)
                        viewport.x = (Double(display.size.width) - viewport.width) * fractionX
                        viewport.y = (Double(display.size.height) - viewport.height) * fractionY
                        let crop = region(viewport, on: display, output: whole)
                        let label = "\(display.size)@\(scale) \(fps) fps zoom \(zoom) at \(fractionX),\(fractionY)"
                        XCTAssertNoThrow(try crop.validate(), label)
                        guard !crop.isWholeDisplay else { continue }
                        crops += 1
                        let x = crop.x * scale, y = crop.y * scale
                        let width = crop.width * scale, height = crop.height * scale
                        XCTAssertEqual(crop.epoch, 1, label)
                        XCTAssertEqual(x, x.rounded(), label)
                        XCTAssertEqual(y, y.rounded(), label)
                        XCTAssertEqual(Int(x) % 2, 0, label)
                        XCTAssertEqual(Int(y) % 2, 0, label)
                        XCTAssertEqual(Int(width) % 16, 0, label)
                        XCTAssertEqual(Int(height) % 16, 0, label)
                        XCTAssertTrue(display.bounds.contains(crop.rect), label)
                        XCTAssertTrue(crop.rect.contains(viewport.rect.intersection(display.bounds)), label)
                        let longEdge = max(display.pixelWidth, display.pixelHeight)
                        XCTAssertGreaterThanOrEqual(max(width, height), 0.25 * longEdge, label)
                        XCTAssertLessThan(abs(width / height - aspect) / aspect, 0.05, label)
                        let expected = Int(width) >= whole.width && Int(height) >= whole.height ? whole
                            : size(min(Int(width), whole.width / 16 * 16), min(Int(height), whole.height / 16 * 16))
                        XCTAssertEqual(size(crop.outputWidth, crop.outputHeight), expected, label)
                    }
                }
            }
        }
        XCTAssertGreaterThan(crops, 200)
    }

    // MARK: Output size

    /// The rule: the whole-display output unless the crop has fewer pixels; then the crop's pixels,
    /// held until the crop falls below 90 % of the held size or reaches 110 % of it.
    func testOutputShrinksToTheCropHoldsWithinTheBandAndGrowsBack() {
        let whole = size(2048, 1152)
        XCTAssertEqual(Policy.outputSize(source: size(2448, 1376), whole: whole, held: nil), whole)
        XCTAssertEqual(Policy.outputSize(source: size(2048, 1152), whole: whole, held: nil), whole)
        XCTAssertEqual(Policy.outputSize(source: size(1536, 864), whole: whole, held: nil), size(1536, 864))
        XCTAssertEqual(Policy.outputSize(source: size(2064, 1136), whole: whole, held: nil), size(2048, 1136))
        XCTAssertEqual(Policy.outputSize(source: size(2032, 1152), whole: whole, held: whole), size(2032, 1152),
                       "the whole-display size is never held above the crop's pixels")

        let held = size(1536, 864)
        XCTAssertEqual(Policy.outputSize(source: size(1456, 816), whole: whole, held: held), held)
        XCTAssertEqual(Policy.outputSize(source: size(1680, 944), whole: whole, held: held), held)
        XCTAssertEqual(Policy.outputSize(source: size(1376, 768), whole: whole, held: held), size(1376, 768))
        XCTAssertEqual(Policy.outputSize(source: size(1696, 960), whole: whole, held: held), size(1696, 960))
        XCTAssertEqual(Policy.outputSize(source: size(2448, 1376), whole: whole, held: held), whole)

        let edge = size(1600, 800)
        XCTAssertEqual(Policy.outputSize(source: size(1440, 720), whole: whole, held: edge), edge, "exactly 90 % holds")
        XCTAssertEqual(Policy.outputSize(source: size(1424, 720), whole: whole, held: edge), size(1424, 720))
        XCTAssertEqual(Policy.outputSize(source: size(1760, 880), whole: whole, held: edge), size(1760, 880),
                       "exactly 110 % grows")
        XCTAssertEqual(Policy.outputSize(source: size(1744, 880), whole: whole, held: edge), edge)

        XCTAssertEqual(Policy.outputSize(source: size(2448, 1376), whole: whole, held: size(2560, 1440)), whole,
                       "a held size above a smaller whole-display output is dropped")
        XCTAssertEqual(Policy.outputSize(source: size(1536, 864), whole: whole, held: size(2560, 1440)),
                       size(1536, 864))
    }

    func testZoomSequenceChangesTheFrameSizeOnlyWhenTheBandIsLeft() throws {
        let whole = try output(asus, fps: 120)
        var previous: CaptureRegion?
        var epoch: UInt64 = 0
        var sizes: [CapturePixelDimensions] = []
        for zoom: Double? in [2, 2.1, 2, 2.5, 2.1, 1.25, nil] {
            epoch += 1
            let viewport = zoom.map { centered(zoom: $0, on: asus, epoch: epoch) }
            let next = region(viewport, output: whole, previous: previous)
            sizes.append(size(next.outputWidth, next.outputHeight))
            previous = next
        }
        XCTAssertEqual(sizes, [size(1536, 864), size(1536, 864), size(1536, 864), size(1232, 688),
                               size(1456, 816), whole, whole])
        XCTAssertEqual(previous?.isWholeDisplay, true)
        XCTAssertEqual(region(centered(zoom: 2.1, on: asus), output: whole, previous: nil).outputWidth, 1456,
                       "without a previous region (quality change, restart) nothing is held")
    }

    // MARK: Restart, reconfiguration, coalescing

    func testRestartKeepsOnlyAViewportThatLiesOnTheNewDisplay() {
        let viewport = centered(zoom: 2, on: asus)
        XCTAssertTrue(Policy.isValid(viewport, for: asus))
        XCTAssertFalse(Policy.isValid(viewport, for: air), "reaches x = 1935.5 on a 1470 pt display")
        var edge = viewport
        edge.x = 2560 - 1311
        XCTAssertTrue(Policy.isValid(edge, for: asus))
        var outside = viewport
        outside.x = 2000
        XCTAssertFalse(Policy.isValid(outside, for: asus))
        var empty = viewport
        empty.width = 0
        XCTAssertFalse(Policy.isValid(empty, for: asus))
        XCTAssertFalse(Policy.isValid(viewport, for: DisplayGeometry(size: CGSize(width: 2560, height: 1440),
                                                                      pointPixelScale: 0)))
    }

    func testOnlyARegularHeartbeatStatesTheViewport() {
        let viewport = centered(zoom: 3, on: asus)
        XCTAssertTrue(Policy.describesViewport(RemoteAction(action: "heartbeat", epoch: 4, viewport: viewport)))
        XCTAssertTrue(Policy.describesViewport(RemoteAction(action: "heartbeat", epoch: 4)),
                      "a regular heartbeat without one returns to the whole display")
        let ack = VideoFeedback(operation: .ltrAck, generation: "g", nonce: "n", token: 7, scopeEpoch: 1)
        XCTAssertFalse(Policy.describesViewport(RemoteAction(action: "heartbeat", epoch: 4, videoFeedback: ack)),
                       "an LTR acknowledgement must not drop the crop")
        XCTAssertFalse(Policy.describesViewport(RemoteAction(action: "heartbeat", epoch: 4, pointerProbe: "probe-1")))
    }

    func testOnlyGeometryChangesReconfigureTheStream() {
        let crop = CaptureRegion(epoch: 3, x: 512, y: 288, width: 1536, height: 864,
                                 outputWidth: 1536, outputHeight: 864)
        var epoch = crop
        epoch.epoch = 4
        XCTAssertFalse(Policy.needsReconfiguration(from: crop, to: epoch))
        var moved = crop
        moved.x = 514
        XCTAssertTrue(Policy.needsReconfiguration(from: crop, to: moved))
        var resized = crop
        resized.outputWidth = 1520
        XCTAssertTrue(Policy.needsReconfiguration(from: crop, to: resized))
        var whole = crop
        whole.epoch = 0
        XCTAssertTrue(Policy.needsReconfiguration(from: crop, to: whole))
    }

    func testUpdateGateAppliesTheLatestViewportOnATrailingEdge() {
        let interval = ConfigurationUpdateGate.minimumInterval
        var gate = ConfigurationUpdateGate()
        XCTAssertEqual(gate.request(at: 0, immediate: false), .start, "leading edge: no wait when idle")
        XCTAssertEqual(gate.request(at: 0.01, immediate: false), .none, "one call in flight")
        XCTAssertEqual(gate.request(at: 0.02, immediate: false), .none)
        XCTAssertTrue(gate.pending)
        XCTAssertEqual(gate.finished(at: 0.03, immediate: false), .wait(until: interval),
                       "both requests collapse into one update, 50 ms after the previous start")
        XCTAssertEqual(gate.deadlineReached(at: interval - 0.001, immediate: false), .wait(until: interval))
        XCTAssertEqual(gate.deadlineReached(at: interval, immediate: false), .start)
        XCTAssertFalse(gate.pending)
        XCTAssertEqual(gate.finished(at: 0.06, immediate: false), .none, "nothing left to apply")
        XCTAssertFalse(gate.inFlight)
        XCTAssertEqual(gate.request(at: 0.2, immediate: false), .start)
    }

    func testUpdateGateLetsQualityChangesSkipTheInterval() {
        var gate = ConfigurationUpdateGate()
        XCTAssertEqual(gate.request(at: 1, immediate: false), .start)
        XCTAssertEqual(gate.finished(at: 1.005, immediate: false), .none)
        XCTAssertEqual(gate.request(at: 1.01, immediate: true), .start)
        XCTAssertEqual(gate.request(at: 1.02, immediate: true), .none, "still one call at a time")
        XCTAssertEqual(gate.finished(at: 1.03, immediate: true), .start)
        XCTAssertEqual(gate.finished(at: 1.04, immediate: false), .none)
    }

    // MARK: Stream configuration

    /// RemoteCaptureSession's builder as of 0c2325b, before the region was threaded through.
    private func previousConfiguration(contentSize: CGSize, pointPixelScale: Double, quality: StreamQuality,
                                       showsCursor: Bool, budget: H264FrameBudget?, fps: Int, displayRefreshHz: Double?,
                                       clientLongEdge: Int?, tuning: StreamTuning) -> SCStreamConfiguration? {
        let maximum = CaptureRatePolicy.maximumDimension(quality: quality, fps: fps, clientLongEdge: clientLongEdge,
                                                         tuning: tuning)
        guard let dimensions = CapturePixelDimensions.fitted(
            contentSize: contentSize,
            pointPixelScale: pointPixelScale, quality: quality, fps: fps, maximumDimension: maximum
        ) else { return nil }
        let configuration = SCStreamConfiguration()
        let fitted = budget?.fitted(width: dimensions.width, height: dimensions.height, fps: fps)
        configuration.width = fitted?.width ?? dimensions.width
        configuration.height = fitted?.height ?? dimensions.height
        configuration.minimumFrameInterval = RemoteCaptureConfiguration.minimumFrameInterval(
            for: tuning, targetFPS: fps, displayRefreshHz: displayRefreshHz)
        configuration.queueDepth = CaptureRatePolicy.queueDepth(for: fps)
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return configuration
    }

    private func properties(_ configuration: SCStreamConfiguration) -> [String: String] {
        let interval = configuration.minimumFrameInterval
        return [
            "width": "\(configuration.width)", "height": "\(configuration.height)",
            "interval": "\(interval.value)/\(interval.timescale) \(interval.flags.rawValue)",
            "queueDepth": "\(configuration.queueDepth)", "showsCursor": "\(configuration.showsCursor)",
            "capturesAudio": "\(configuration.capturesAudio)", "pixelFormat": "\(configuration.pixelFormat)",
            "sourceRect": "\(configuration.sourceRect)", "destinationRect": "\(configuration.destinationRect)",
            "scalesToFit": "\(configuration.scalesToFit)",
            "preservesAspectRatio": "\(configuration.preservesAspectRatio)",
            "capturesShadowsOnly": "\(configuration.capturesShadowsOnly)",
            "shouldBeOpaque": "\(configuration.shouldBeOpaque)",
            "captureResolution": "\(configuration.captureResolution.rawValue)"
        ]
    }

    private struct BuilderCase {
        var display: DisplayGeometry
        var quality: StreamQuality
        var fps: Int
        var refresh: Double?
        var client: Int?
        var budget: H264FrameBudget?
        var tuning: StreamTuning
    }

    private func builderCases() -> [BuilderCase] {
        var native = StreamTuning.tuned
        native.captureAtNativeRate = true
        var uncapped = StreamTuning.tuned
        uncapped.capToClientPixels = false
        let displays = [CGSize(width: 2560, height: 1440), CGSize(width: 1470, height: 956),
                        CGSize(width: 1842, height: 1192), CGSize(width: 1200, height: 1800),
                        CGSize(width: 1280, height: 720), CGSize(width: 0.5, height: 100)]
        var cases: [BuilderCase] = []
        for (index, size) in displays.enumerated() {
            let display = DisplayGeometry(size: size, pointPixelScale: index == 0 || index == 4 ? 1 : 2)
            for quality in StreamQuality.allCases {
                for fps in [60, 120] {
                    for refresh: Double? in [nil, 60, 120, 144] {
                        for client: Int? in [nil, 1179, 2622, 3000] {
                            for budget: H264FrameBudget? in [nil, .level(52), .level(31)] {
                                for tuning in [StreamTuning.tuned, native, uncapped] {
                                    cases.append(BuilderCase(display: display, quality: quality, fps: fps,
                                                             refresh: refresh, client: client, budget: budget,
                                                             tuning: tuning))
                                }
                            }
                        }
                    }
                }
            }
        }
        return cases
    }

    func testWholeDisplayConfigurationIsUnchangedFromThePreviousBuilder() {
        var compared = 0
        for (index, test) in builderCases().enumerated() {
            let showsCursor = index % 2 == 0
            let label = "\(test.display) \(test.quality) \(test.fps) fps \(String(describing: test.refresh)) Hz "
                + "client \(String(describing: test.client)) \(String(describing: test.budget)) \(test.tuning.summary)"
            let previous = previousConfiguration(
                contentSize: test.display.size, pointPixelScale: test.display.pointPixelScale, quality: test.quality,
                showsCursor: showsCursor, budget: test.budget, fps: test.fps, displayRefreshHz: test.refresh,
                clientLongEdge: test.client, tuning: test.tuning)
            let output = RemoteCaptureConfiguration.outputSize(
                contentSize: test.display.size, pointPixelScale: test.display.pointPixelScale, quality: test.quality,
                budget: test.budget, fps: test.fps, clientLongEdge: test.client, tuning: test.tuning)
            guard let previous else {
                XCTAssertNil(output, label)
                continue
            }
            guard let output else {
                XCTFail(label)
                continue
            }
            compared += 1
            for region in [nil, Policy.wholeDisplay(test.display, output: output)] {
                let current = RemoteCaptureConfiguration.streamConfiguration(
                    output: output, region: region, showsCursor: showsCursor, fps: test.fps,
                    displayRefreshHz: test.refresh, tuning: test.tuning)
                XCTAssertEqual(properties(current), properties(previous), label)
                XCTAssertEqual(current.minimumFrameInterval, previous.minimumFrameInterval, label)
            }
        }
        XCTAssertGreaterThan(compared, 1000)
    }

    func testCropConfigurationChangesOnlyTheSourceRectOutputSizeAndAspectFit() {
        let output = size(2048, 1152)
        let crop = CaptureRegion(epoch: 5, x: 512, y: 288, width: 1536, height: 864,
                                 outputWidth: 1536, outputHeight: 864)
        let whole = RemoteCaptureConfiguration.streamConfiguration(output: output, region: nil, showsCursor: false,
                                                                   fps: 120, displayRefreshHz: 144, tuning: .tuned)
        let cropped = RemoteCaptureConfiguration.streamConfiguration(output: output, region: crop, showsCursor: false,
                                                                     fps: 120, displayRefreshHz: 144, tuning: .tuned)
        XCTAssertEqual(cropped.sourceRect, CGRect(x: 512, y: 288, width: 1536, height: 864))
        XCTAssertEqual(cropped.width, 1536)
        XCTAssertEqual(cropped.height, 864)
        XCTAssertFalse(cropped.preservesAspectRatio)
        XCTAssertTrue(whole.preservesAspectRatio, "ScreenCaptureKit's default, kept for the whole display")
        XCTAssertEqual(whole.width, 2048)
        XCTAssertEqual(whole.height, 1152)
        XCTAssertEqual(cropped.minimumFrameInterval, CMTime(value: 1, timescale: 120), "144 Hz thinned to 120")
        XCTAssertEqual(cropped.queueDepth, 8)
        var unchanged = properties(cropped)
        var reference = properties(whole)
        for key in ["width", "height", "sourceRect", "preservesAspectRatio"] {
            unchanged[key] = nil
            reference[key] = nil
        }
        XCTAssertEqual(unchanged, reference)
    }
}
