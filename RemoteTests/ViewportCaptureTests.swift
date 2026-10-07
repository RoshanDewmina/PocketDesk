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

    /// `phoneNative: false` is the rule before the phone-native crop, kept behind `CropPhoneNativeSwitch`.
    /// `nearNative: false` is the engagement rule of build 20261002.2 (kept behind `CropNearNativeSwitch`),
    /// so the crop maths below is checked at every zoom; `keepBand` defaults on, the behaviour the golden
    /// replay (G04, testSmallPinchAndPanReplayKeepsCoveredRegionAndEncoderSizeStable) demands.
    private func region(_ viewport: ViewportRegion?, on display: DisplayGeometry? = nil,
                        output: CapturePixelDimensions, tuning: StreamTuning = .tuned,
                        previous: CaptureRegion? = nil, phoneNative: Bool = true,
                        nearNative: Bool = false, keepBand: Bool = true, cropEngaged: Bool? = nil) -> CaptureRegion {
        Policy.region(for: viewport, display: display ?? asus, output: output, tuning: tuning, previous: previous,
                      phoneNative: phoneNative, nearNative: nearNative, keepBand: keepBand, cropEngaged: cropEngaged)
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
        XCTAssertTrue(region(centered(zoom: 1.1, on: asus), output: whole, phoneNative: false).isWholeDisplay,
                      "wider than the display")
        // 70 % of the display, but 2512x1424 (97 %) once the margin and the output's aspect are added.
        let wide = ViewportRegion(epoch: 1, x: 200, y: 120, width: 2160, height: 1200,
                                  pixelWidth: 2622, pixelHeight: 1456, zoom: 1.2)
        XCTAssertTrue(region(wide, output: whole, phoneNative: false).isWholeDisplay)
        let nearlyAll = ViewportRegion(epoch: 1, x: 24, y: 14, width: 2512, height: 1412,
                                       pixelWidth: 2622, pixelHeight: 1474, zoom: 1.04)
        XCTAssertTrue(region(nearlyAll, output: whole, phoneNative: false).isWholeDisplay)

        // Phone-native: the crop keeps the viewport's aspect and spans the display's width instead of
        // giving up, so both lighter zooms now crop; only a crop of 95 % or more is still the whole display.
        XCTAssertEqual(region(centered(zoom: 1.1, on: asus), output: whole),
                       CaptureRegion(epoch: 1, x: 88, y: 166, width: 2384, height: 1104,
                                     outputWidth: 2256, outputHeight: 1040))
        XCTAssertEqual(region(wide, output: whole),
                       CaptureRegion(epoch: 1, x: 200, y: 120, width: 2160, height: 1200,
                                     outputWidth: 2048, outputHeight: 1136),
                       "the margin yields to the 2048x1152 budget before the visible rect does")
        XCTAssertTrue(region(nearlyAll, output: whole).isWholeDisplay)
    }

    // MARK: Crop geometry

    func testReadingZoomOnTheASUSCropsOneToOneOnMacroblocksAndEchoesTheEpoch() throws {
        let whole = try output(asus, fps: 120)
        // 1311x603 pt visible, +8 % a side is 1521x700, widened to 16:9 is 1521x856, aligned 1536x864.
        let crop = region(centered(zoom: 2, on: asus, epoch: 7), output: whole, phoneNative: false)
        XCTAssertEqual(crop, CaptureRegion(epoch: 7, x: 512, y: 288, width: 1536, height: 864,
                                           outputWidth: 1536, outputHeight: 864))
        XCTAssertNoThrow(try crop.validate())
    }

    func testLightZoomKeepsTheWholeDisplayOutputSize() throws {
        let whole = try output(asus, fps: 120)
        let crop = region(centered(zoom: 1.25, on: asus), output: whole, phoneNative: false)
        XCTAssertEqual(crop, CaptureRegion(epoch: 1, x: 56, y: 32, width: 2448, height: 1376,
                                           outputWidth: 2048, outputHeight: 1152),
                       "the crop has more pixels than the output, so the encoder's frame size is unchanged")
    }

    func testRetinaCropAlignsDisplayPixelsNotPoints() throws {
        let at120 = try output(air, fps: 120)
        // 2940 x (2048 / 2940) evaluates to 2047.99..., which CapturePixelDimensions rounds down to 2046.
        XCTAssertEqual(at120, size(2046, 1330))
        XCTAssertTrue(region(centered(zoom: 2, on: air), on: air, output: at120, phoneNative: false).isWholeDisplay,
                      "1311 pt of a 1470 pt display is a 3041 px crop, wider than the panel")
        XCTAssertEqual(region(centered(zoom: 2, on: air), on: air, output: at120),
                       CaptureRegion(epoch: 1, x: 79, y: 174, width: 1312, height: 608,
                                     outputWidth: 2416, outputHeight: 1120),
                       "phone-native: the margin is trimmed to fit the 2046x1330 budget, so it crops")
        XCTAssertEqual(region(centered(zoom: 2.5, on: air), on: air, output: at120, phoneNative: false),
                       CaptureRegion(epoch: 1, x: 123, y: 82, width: 1224, height: 792,
                                     outputWidth: 2046, outputHeight: 1330))
        XCTAssertEqual(region(centered(zoom: 3, on: air), on: air, output: at120, phoneNative: false),
                       CaptureRegion(epoch: 1, x: 227, y: 146, width: 1016, height: 664,
                                     outputWidth: 2032, outputHeight: 1328))

        let at60 = try output(air, fps: 60)
        XCTAssertEqual(at60, size(2560, 1664))
        XCTAssertEqual(region(centered(zoom: 2.5, on: air), on: air, output: at60, phoneNative: false),
                       CaptureRegion(epoch: 1, x: 123, y: 82, width: 1224, height: 792,
                                     outputWidth: 2448, outputHeight: 1584))
    }

    func testPanInsideTheMarginKeepsTheCropAndEchoesTheNewEpoch() throws {
        let whole = try output(asus, fps: 120)
        let first = region(centered(zoom: 2, on: asus, epoch: 1), output: whole, phoneNative: false)
        var panned = centered(zoom: 2, on: asus, epoch: 2)
        panned.x += 50
        let second = region(panned, output: whole, previous: first, phoneNative: false)
        XCTAssertEqual(second, CaptureRegion(epoch: 2, x: 512, y: 288, width: 1536, height: 864,
                                             outputWidth: 1536, outputHeight: 864))
        XCTAssertFalse(Policy.needsReconfiguration(from: first, to: second))
    }

    func testPanPastTheMarginReCropsAtTheSameOutputSize() throws {
        let whole = try output(asus, fps: 120)
        let first = region(centered(zoom: 2, on: asus, epoch: 1), output: whole, phoneNative: false)
        var panned = centered(zoom: 2, on: asus, epoch: 2)
        panned.x += 200
        let second = region(panned, output: whole, previous: first, phoneNative: false)
        XCTAssertEqual(second, CaptureRegion(epoch: 2, x: 712, y: 288, width: 1536, height: 864,
                                             outputWidth: 1536, outputHeight: 864))
        XCTAssertTrue(Policy.needsReconfiguration(from: first, to: second))
    }

    func testViewportPartlyOutsideTheDisplayIsClampedIntoIt() throws {
        let whole = try output(asus, fps: 120)
        var right = centered(zoom: 2, on: asus)
        right.x = 2000
        XCTAssertEqual(region(right, output: whole, phoneNative: false),
                       CaptureRegion(epoch: 1, x: 1312, y: 368, width: 1248, height: 704,
                                     outputWidth: 1248, outputHeight: 704))
        var left = centered(zoom: 2, on: asus)
        left.x = -300
        XCTAssertEqual(region(left, output: whole, phoneNative: false),
                       CaptureRegion(epoch: 1, x: 0, y: 368, width: 1248, height: 704,
                                     outputWidth: 1248, outputHeight: 704))
    }

    func testCropIsNeverSmallerThanAQuarterOfTheDisplayLongEdge() throws {
        let whole = try output(asus, fps: 120)
        XCTAssertEqual(region(centered(zoom: 10, on: asus), output: whole, phoneNative: false),
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
                        let crop = region(viewport, on: display, output: whole, phoneNative: false)
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
            let next = region(viewport, output: whole, previous: previous, phoneNative: false)
            sizes.append(size(next.outputWidth, next.outputHeight))
            previous = next
        }
        XCTAssertEqual(sizes, [size(1536, 864), size(1536, 864), size(1536, 864), size(1232, 688),
                               size(1456, 816), whole, whole])
        XCTAssertEqual(previous?.isWholeDisplay, true)
        XCTAssertEqual(region(centered(zoom: 2.1, on: asus), output: whole, previous: nil, phoneNative: false).outputWidth,
                       1456,
                       "without a previous region (quality change, restart) nothing is held")
    }

    // MARK: Phone-native crop

    /// The M4 Air panel at "More Space": 1920x1243 pt @2x, captured 3840x2486 px.
    private let moreSpace = DisplayGeometry(size: CGSize(width: 1920, height: 1243), pointPixelScale: 2)

    /// An iPhone 17 (2622x1206 px, 874x402 pt at 3x) showing the display's centre at `zoom` px per point.
    private func iPhone17(zoom: Double, portrait: Bool, on display: DisplayGeometry,
                          epoch: UInt64 = 1) -> ViewportRegion {
        let pixelWidth = portrait ? 1206 : 2622
        let pixelHeight = portrait ? 2622 : 1206
        let width = Double(pixelWidth) / zoom
        let height = Double(pixelHeight) / zoom
        return ViewportRegion(epoch: epoch, x: (Double(display.size.width) - width) / 2,
                              y: (Double(display.size.height) - height) / 2, width: width, height: height,
                              pixelWidth: pixelWidth, pixelHeight: pixelHeight, zoom: zoom)
    }

    /// Fit asks for the whole display, as `ViewportTransform.captureRequest` does at the mode's own size.
    private func iPhone17Fit(portrait: Bool, on display: DisplayGeometry) -> ViewportRegion {
        let canvas = portrait ? CGSize(width: 402, height: 874) : CGSize(width: 874, height: 402)
        let points = min(canvas.width / display.size.width, canvas.height / display.size.height)
        return ViewportRegion(epoch: 1, x: 0, y: 0, width: Double(display.size.width),
                              height: Double(display.size.height), pixelWidth: portrait ? 1206 : 2622,
                              pixelHeight: portrait ? 2622 : 1206, zoom: (Double(points) * 3 * 10_000).rounded() / 10_000)
    }

    private func sharpness(_ region: CaptureRegion, _ viewport: ViewportRegion,
                           on display: DisplayGeometry) throws -> Double {
        try XCTUnwrap(Policy.deliveredSharpness(region: region, viewport: viewport, display: display))
    }

    func testIPhone17OnMoreSpaceCropsWheneverItWouldUpscaleAndGetsPhoneNativePixels() throws {
        let whole = try output(moreSpace, fps: 60)
        XCTAssertEqual(whole, size(2560, 1656))
        let wholePerPoint = Double(whole.width) / Double(moreSpace.size.width)
        var lines: [String] = []
        for portrait in [false, true] {
            for zoom: Double? in [nil, 1.3, 1.5, 2, 3] {
                let viewport = zoom.map { iPhone17(zoom: $0, portrait: portrait, on: moreSpace) }
                    ?? iPhone17Fit(portrait: portrait, on: moreSpace)
                let crop = region(viewport, on: moreSpace, output: whole)
                let old = region(viewport, on: moreSpace, output: whole, phoneNative: false)
                let after = try sharpness(crop, viewport, on: moreSpace)
                let before = try sharpness(old, viewport, on: moreSpace)
                let label = "\(portrait ? "portrait" : "landscape") zoom \(viewport.zoom)"
                lines.append(String(format: "%@: before %.3f (%ldx%ld%@) after %.3f (%ldx%ld%@)", label, before,
                                    old.outputWidth, old.outputHeight, old.isWholeDisplay ? " whole" : " crop", after,
                                    crop.outputWidth, crop.outputHeight, crop.isWholeDisplay ? " whole" : " crop"))
                XCTAssertNoThrow(try crop.validate(), label)
                XCTAssertGreaterThanOrEqual(after, min(before, 1) - 1e-9, label)
                if viewport.zoom > wholePerPoint { XCTAssertFalse(crop.isWholeDisplay, "the phone would upscale: \(label)") }
                guard !crop.isWholeDisplay else {
                    XCTAssertLessThanOrEqual(viewport.zoom, 1, label)
                    continue
                }
                XCTAssertGreaterThanOrEqual(after, min(1, moreSpace.pointPixelScale / viewport.zoom) - 1e-9, label)
                XCTAssertLessThanOrEqual(crop.outputWidth * crop.outputHeight, whole.width * whole.height, label)
                XCTAssertEqual(crop.outputWidth % 16, 0, label)
                XCTAssertEqual(crop.outputHeight % 16, 0, label)
                XCTAssertEqual(crop.outputHeight > crop.outputWidth, portrait, label)
                XCTAssertLessThan(abs(Double(crop.outputWidth) / Double(crop.outputHeight) / (crop.width / crop.height) - 1),
                                  0.01, "no stretch: \(label)")
                XCTAssertTrue(crop.rect.contains(viewport.rect.intersection(moreSpace.bounds)), label)
            }
        }
        print("iPhone 17 on 1920x1243 @2x, 2560x1656 budget\n" + lines.joined(separator: "\n"))

        func phoneNative(_ zoom: Double, portrait: Bool) -> CaptureRegion {
            region(iPhone17(zoom: zoom, portrait: portrait, on: moreSpace), on: moreSpace, output: whole)
        }
        XCTAssertEqual(phoneNative(1.5, portrait: false), CaptureRegion(epoch: 1, x: 0, y: 153, width: 1920, height: 936,
                                                                 outputWidth: 2880, outputHeight: 1408),
                       "spans the display's width at 1.5x, downscaled to the phone's 1.5 px per point")
        XCTAssertEqual(phoneNative(2, portrait: false), CaptureRegion(epoch: 1, x: 204, y: 273, width: 1512, height: 696,
                                                               outputWidth: 3024, outputHeight: 1392),
                       "1:1, its margin trimmed from 8 % to fit the 2560x1656 budget")
        XCTAssertEqual(phoneNative(3, portrait: false), CaptureRegion(epoch: 1, x: 452, y: 385, width: 1016, height: 472,
                                                               outputWidth: 2032, outputHeight: 944))
        XCTAssertEqual(phoneNative(1.5, portrait: true), CaptureRegion(epoch: 1, x: 492, y: 0, width: 936, height: 1243,
                                                                outputWidth: 1408, outputHeight: 1872),
                       "the full 2486 px height, the output still in macroblocks")
        XCTAssertEqual(phoneNative(2, portrait: true), CaptureRegion(epoch: 1, x: 608, y: 0, width: 704, height: 1243,
                                                              outputWidth: 1408, outputHeight: 2496),
                       "taller than the whole output's 1656: only its area is capped")
        XCTAssertEqual(phoneNative(3, portrait: true), CaptureRegion(epoch: 1, x: 724, y: 113, width: 472, height: 1016,
                                                              outputWidth: 944, outputHeight: 2032))
    }

    func testKillSwitchKeepsThePreviousCropAndOutputRules() throws {
        XCTAssertEqual(CropPhoneNativeSwitch.defaultsKey, "PocketDeskCropPhoneNative")
        XCTAssertTrue(CropPhoneNativeSwitch.isOn, "on unless the defaults key says NO")
        let whole = try output(moreSpace, fps: 60)
        func old(_ zoom: Double, portrait: Bool, output: CapturePixelDimensions? = nil) -> CaptureRegion {
            region(iPhone17(zoom: zoom, portrait: portrait, on: moreSpace), on: moreSpace, output: output ?? whole,
                   phoneNative: false)
        }
        for zoom in [1.3, 1.5] { XCTAssertTrue(old(zoom, portrait: false).isWholeDisplay, "\(zoom)") }
        XCTAssertEqual(old(2, portrait: false), CaptureRegion(epoch: 1, x: 196, y: 129, width: 1528, height: 984,
                                                              outputWidth: 2560, outputHeight: 1656))
        XCTAssertEqual(old(3, portrait: false), CaptureRegion(epoch: 1, x: 452, y: 293, width: 1016, height: 656,
                                                              outputWidth: 2032, outputHeight: 1312))
        for zoom in [1.3, 1.5, 2] { XCTAssertTrue(old(zoom, portrait: true).isWholeDisplay, "\(zoom)") }
        XCTAssertEqual(old(3, portrait: true), CaptureRegion(epoch: 1, x: 176, y: 113, width: 1568, height: 1016,
                                                             outputWidth: 2560, outputHeight: 1656))

        // Today's device evidence: a 1760x1120 px crop sent at 1280x816 at a 0.5 size rung.
        let rung = RemoteCaptureConfiguration.scaled(whole, by: 0.5)
        XCTAssertEqual(rung, size(1280, 816))
        XCTAssertEqual(Policy.outputSize(source: size(1760, 1120), whole: rung, held: nil), size(1280, 816))
        let viewport = iPhone17(zoom: 2, portrait: false, on: moreSpace)
        let before = old(2, portrait: false, output: rung)
        XCTAssertEqual(before, CaptureRegion(epoch: 1, x: 196, y: 133, width: 1528, height: 976,
                                             outputWidth: 1280, outputHeight: 816))
        let after = region(viewport, on: moreSpace, output: rung)
        XCTAssertEqual(after, CaptureRegion(epoch: 1, x: 304, y: 317, width: 1312, height: 608,
                                            outputWidth: 1488, outputHeight: 688),
                       "the same budget spent on the visible rect: the margin yields first")
        XCTAssertLessThanOrEqual(after.outputWidth * after.outputHeight, rung.width * rung.height)
        XCTAssertEqual(try sharpness(before, viewport, on: moreSpace), 0.419, accuracy: 0.001)
        XCTAssertEqual(try sharpness(after, viewport, on: moreSpace), 0.567, accuracy: 0.001)
    }

    func testDeliveredSharpnessIsStreamPixelsPerPhonePixel() throws {
        let fit = iPhone17Fit(portrait: false, on: moreSpace)
        XCTAssertEqual(fit.zoom, 0.9702)
        let whole = Policy.wholeDisplay(moreSpace, output: size(2560, 1656))
        XCTAssertEqual(try sharpness(whole, fit, on: moreSpace), 2560.0 / 1920 / 0.9702, accuracy: 1e-12)
        XCTAssertNil(Policy.deliveredSharpness(region: whole, viewport: nil, display: moreSpace))
        let crop = CaptureRegion(epoch: 3, x: 204, y: 273, width: 1512, height: 696, outputWidth: 3024, outputHeight: 1392)
        XCTAssertEqual(try sharpness(crop, iPhone17(zoom: 2, portrait: false, on: moreSpace), on: moreSpace), 1)
        XCTAssertEqual(try sharpness(crop, iPhone17(zoom: 3, portrait: false, on: moreSpace), on: moreSpace),
                       2.0 / 3, accuracy: 1e-12)
        let live = CaptureRegion(epoch: 9, x: 100, y: 100, width: 880, height: 560, outputWidth: 1280, outputHeight: 816)
        XCTAssertEqual(try sharpness(live, iPhone17(zoom: 2, portrait: false, on: moreSpace), on: moreSpace),
                       1280.0 / 880 / 2, accuracy: 1e-12)
        var broken = fit
        for zoom in [0, -1, Double.nan, Double.infinity] {
            broken.zoom = zoom
            XCTAssertNil(Policy.deliveredSharpness(region: crop, viewport: broken, display: moreSpace), "\(zoom)")
        }

        XCTAssertNoThrow(try HostStreamSummary(sharpness: 1.25).validate())
        XCTAssertNoThrow(try HostStreamSummary(sharpness: 0).validate())
        XCTAssertNoThrow(try HostStreamSummary(sharpness: 1000).validate())
        for bad in [-0.01, 1000.5, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try HostStreamSummary(sharpness: bad).validate(), "\(bad)")
        }
        var report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        report.sharpness = 1.003
        XCTAssertEqual(report.hostSummary.sharpness, 1.003)
        XCTAssertNoThrow(try report.hostSummary.validate())
        report.sharpness = .nan
        XCTAssertNil(report.hostSummary.sharpness)
        report.sharpness = 5000
        XCTAssertEqual(report.hostSummary.sharpness, 1000)
    }

    /// The rule: phone-native, held while the new size is within 90 %...110 % of the held one on both
    /// sides, fits the budget and is in whole macroblocks.
    func testPhoneNativeOutputHoldsWithinTheBandAndNeverOverTheBudget() {
        let budget = size(2560, 1656)
        func output(_ source: CapturePixelDimensions, zoom: Double = 2, budget: CapturePixelDimensions? = nil,
                    held: CapturePixelDimensions? = nil) -> CapturePixelDimensions {
            Policy.phoneNativeOutputSize(source: source, zoom: zoom, display: moreSpace, budget: budget ?? self.size(2560, 1656),
                                         held: held)
        }
        XCTAssertEqual(output(size(1408, 2496)), size(1408, 2496), "1:1 at 2 px per point, portrait kept")
        XCTAssertEqual(output(size(3840, 1872), zoom: 1.5), size(2880, 1408), "0.75 of the crop, rounded up")
        XCTAssertEqual(output(size(3840, 1872), zoom: 3), size(2944, 1424), "1:1 is 7.2 Mpx: scaled to the budget")
        XCTAssertEqual(output(size(3056, 1408)), size(3024, 1392), "4.30 Mpx over the 4.24 Mpx budget")
        XCTAssertEqual(output(size(4800, 400)), size(4096, 336), "the encoders' 4096 edge")
        XCTAssertEqual(output(size(2486, 1408)), size(2496, 1408), "a full-height crop rounds up to macroblocks")
        XCTAssertLessThanOrEqual(output(size(3840, 1872), zoom: 3).width * output(size(3840, 1872), zoom: 3).height,
                                 budget.width * budget.height)

        let held = size(3024, 1392)
        XCTAssertEqual(output(size(2912, 1344), held: held), held)
        XCTAssertEqual(output(size(3040, 1408), zoom: 1.9, held: held), held)
        XCTAssertEqual(output(size(2560, 1184), held: held), size(2560, 1184), "below 90 %: shrinks")
        XCTAssertEqual(output(size(3840, 1872), zoom: 1.5, held: size(2560, 1184)), size(2880, 1408),
                       "never held more than 10 % under phone-native")

        let edge = size(1600, 800)
        XCTAssertEqual(output(size(1440, 720), held: edge), edge, "exactly 90 % holds")
        XCTAssertEqual(output(size(1424, 720), held: edge), size(1424, 720))
        XCTAssertEqual(output(size(1744, 864), held: edge), edge)
        XCTAssertEqual(output(size(1760, 864), held: edge), size(1760, 864), "exactly 110 % grows")
        XCTAssertEqual(output(size(1600, 880), held: edge), size(1600, 880), "either side leaving the band")

        XCTAssertEqual(output(size(1600, 816), budget: size(1280, 816), held: edge), size(1424, 720),
                       "a held size over a smaller budget is dropped")
        XCTAssertEqual(output(size(2048, 1328), held: size(2046, 1330)), size(2048, 1328),
                       "a held size not in macroblocks is dropped")
    }

    func testPhoneNativeZoomSequenceStaysWithinTheBandOfPhoneNative() throws {
        let whole = try output(moreSpace, fps: 60)
        var previous: CaptureRegion?
        var epoch: UInt64 = 0
        var sizes: [CapturePixelDimensions] = []
        for zoom in [2, 2.1, 2.05, 2.25, 1.9, 1.5, 3] {
            epoch += 1
            let viewport = iPhone17(zoom: zoom, portrait: false, on: moreSpace, epoch: epoch)
            let next = region(viewport, on: moreSpace, output: whole, previous: previous)
            sizes.append(size(next.outputWidth, next.outputHeight))
            XCTAssertGreaterThanOrEqual(try sharpness(next, viewport, on: moreSpace),
                                        min(1, 2 / zoom) / Policy.growFrom - 1e-9, "\(zoom)")
            XCTAssertLessThanOrEqual(next.outputWidth * next.outputHeight, whole.width * whole.height)
            previous = next
        }
        XCTAssertEqual(sizes, [size(3024, 1392), size(3024, 1392), size(3024, 1392), size(2704, 1248),
                               size(3008, 1392), size(3008, 1392), size(2032, 944)])
    }

    /// Defensive host gate for accepted heartbeat requests. The phone normally suppresses this
    /// covered trace while fingers move; this does not establish end-to-end physical smoothness.
    /// A 5 % pinch with a 12 pt pan remains inside the initial padded crop. Output hysteresis alone
    /// is insufficient: changing the source rectangle also makes status/video races visible.
    func testSmallPinchAndPanReplayKeepsCoveredRegionAndEncoderSizeStable() throws {
        let whole = try output(moreSpace, fps: 60)
        let first = region(iPhone17(zoom: 2.5, portrait: false, on: moreSpace),
                           on: moreSpace, output: whole)
        XCTAssertFalse(first.isWholeDisplay)
        var previous = first
        var regionChanges = 0, encoderChanges = 0
        for step in 1...24 {
            var viewport = iPhone17(zoom: 2.5 + Double(step) / 192, portrait: false,
                                    on: moreSpace, epoch: UInt64(step + 1))
            viewport.x += Double(step) / 2
            XCTAssertTrue(first.rect.contains(viewport.rect), "fixture must stay inside the original safety margin")
            let next = region(viewport, on: moreSpace, output: whole, previous: previous)
            if previous.rect != next.rect { regionChanges += 1 }
            if previous.outputWidth != next.outputWidth || previous.outputHeight != next.outputHeight {
                encoderChanges += 1
            }
            XCTAssertTrue(next.rect.contains(viewport.rect), "holding a region must preserve visible coverage")
            previous = next
        }
        XCTAssertLessThanOrEqual(encoderChanges, 1, "one settled encoder change at most for this small gesture")
        XCTAssertLessThanOrEqual(regionChanges, 1,
                                 "covered pinch/pan must not repeatedly reconfigure and race region status against video")
    }

    func testScrollFixesDefaultOffSupportsTemporaryBooleanLaunchOverrides() throws {
        let name = "ScrollFixesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain) }
        XCTAssertFalse(ScrollFixesSwitch.enabled(defaults: defaults))
        defaults.set(true, forKey: ScrollFixesSwitch.defaultsKey)
        XCTAssertTrue(ScrollFixesSwitch.enabled(defaults: defaults))
        defaults.setVolatileDomain([ScrollFixesSwitch.defaultsKey: "NO"], forName: UserDefaults.argumentDomain)
        XCTAssertFalse(ScrollFixesSwitch.enabled(defaults: defaults))
        defaults.setVolatileDomain([ScrollFixesSwitch.defaultsKey: "YES"], forName: UserDefaults.argumentDomain)
        XCTAssertTrue(ScrollFixesSwitch.enabled(defaults: defaults))
        // On the tested Foundation runtime, removeVolatileDomain leaves this
        // argument dictionary visible; replacing it models a launch without it.
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        defaults.removeObject(forKey: ScrollFixesSwitch.defaultsKey)
        XCTAssertFalse(ScrollFixesSwitch.enabled(defaults: defaults), "Ordinary launch returns to the stored default")
    }

    func testGoldenCoveredPinchReplayRequiresTheOptInKeepBand() throws {
        let whole = try output(moreSpace, fps: 60)
        func changes(keepBand: Bool) -> Int {
            var previous = region(iPhone17(zoom: 2.5, portrait: false, on: moreSpace),
                                  on: moreSpace, output: whole, keepBand: keepBand)
            var count = 0
            for step in 1...24 {
                var viewport = iPhone17(zoom: 2.5 + Double(step) / 192, portrait: false,
                                        on: moreSpace, epoch: UInt64(step + 1))
                viewport.x += Double(step) / 2
                let next = region(viewport, on: moreSpace, output: whole,
                                  previous: previous, keepBand: keepBand)
                if previous.rect != next.rect { count += 1 }
                previous = next
            }
            return count
        }
        XCTAssertGreaterThan(changes(keepBand: false), 1, "The default-off package retains the existing churn")
        XCTAssertLessThanOrEqual(changes(keepBand: true), 1, "G04's replay validates the opt-in keep-band rule")
    }

    /// Replay actual builder/cache admission, including size changes and a return to an earlier crop.
    /// This checks host region/frame consistency; RTP frames already in flight remain a DEVICE gate.
    func testReplayConfigurationMatchesEveryEchoedRegion() throws {
        let whole = try output(moreSpace, fps: 60)
        var previous = Policy.wholeDisplay(moreSpace, output: whole)
        for (index, zoom) in [2.5, 2.625, 2.5, 3.5, 2.5].enumerated() {
            var viewport = iPhone17(zoom: zoom, portrait: false, on: moreSpace, epoch: UInt64(index + 1))
            viewport.x += index == 3 ? 100 : 0
            let next = region(viewport, on: moreSpace, output: whole, previous: previous)
            let config = RemoteCaptureConfiguration.streamConfiguration(
                output: whole, region: next, showsCursor: false, fps: 60,
                displayRefreshHz: 60, tuning: .tuned)
            XCTAssertEqual(config.sourceRect, next.rect)
            XCTAssertEqual(config.width, next.outputWidth)
            XCTAssertEqual(config.height, next.outputHeight)
            XCTAssertTrue(next.rect.contains(viewport.rect))
            if previous.rect != next.rect {
                // Neither matching dimensions nor a post-request callback proves which source
                // rectangle these pixels show. A delayed old frame must not be refreshed as next.
                for duringUpdate in [false, true] {
                    XCTAssertTrue(CaptureFrameCachePolicy.shouldDiscard(
                        cachedDimensions: size(next.outputWidth, next.outputHeight),
                        frameArrivedDuringUpdate: duringUpdate, cachedDisplayTime: UInt64(index + 101),
                        updateRequestedAt: UInt64(index + 100), previous: previous, next: next))
                }
            }
            previous = next
        }
    }

    func testPhoneNativeGeometryOnTheASUS() throws {
        let whole = try output(asus, fps: 120)
        let first = region(centered(zoom: 2, on: asus, epoch: 1), output: whole)
        XCTAssertEqual(first, CaptureRegion(epoch: 1, x: 512, y: 368, width: 1536, height: 704,
                                            outputWidth: 1536, outputHeight: 704),
                       "1311x603 pt, +8 % a side, at the viewport's own aspect, 1:1 on a 1x display")
        var panned = centered(zoom: 2, on: asus, epoch: 2)
        panned.x += 50
        let inside = region(panned, output: whole, previous: first)
        XCTAssertEqual(inside, CaptureRegion(epoch: 2, x: 512, y: 368, width: 1536, height: 704,
                                             outputWidth: 1536, outputHeight: 704))
        XCTAssertFalse(Policy.needsReconfiguration(from: first, to: inside))
        panned.x += 150
        let past = region(panned, output: whole, previous: first)
        XCTAssertEqual(past, CaptureRegion(epoch: 2, x: 712, y: 368, width: 1536, height: 704,
                                           outputWidth: 1536, outputHeight: 704))
        XCTAssertTrue(Policy.needsReconfiguration(from: first, to: past))

        var right = centered(zoom: 2, on: asus)
        right.x = 2000
        XCTAssertEqual(region(right, output: whole), CaptureRegion(epoch: 1, x: 1904, y: 368, width: 656, height: 704,
                                                                   outputWidth: 656, outputHeight: 704))
        var left = centered(zoom: 2, on: asus)
        left.x = -300
        XCTAssertEqual(region(left, output: whole), CaptureRegion(epoch: 1, x: 0, y: 368, width: 1184, height: 704,
                                                                  outputWidth: 1184, outputHeight: 704))
        XCTAssertEqual(region(centered(zoom: 10, on: asus), output: whole),
                       CaptureRegion(epoch: 1, x: 960, y: 568, width: 640, height: 304,
                                     outputWidth: 640, outputHeight: 304), "a quarter of the long edge")

        var previous: CaptureRegion?
        var epoch: UInt64 = 0
        var sizes: [CapturePixelDimensions] = []
        for zoom: Double? in [2, 2.1, 2, 2.5, 2.1, 1.25, nil] {
            epoch += 1
            let next = region(zoom.map { centered(zoom: $0, on: asus, epoch: epoch) }, output: whole, previous: previous)
            sizes.append(size(next.outputWidth, next.outputHeight))
            previous = next
        }
        XCTAssertEqual(sizes, [size(1536, 704), size(1536, 704), size(1536, 704), size(1232, 560),
                               size(1456, 672), size(2256, 1040), whole])
    }

    // MARK: Near-native and keep-band rules (b7-scroll)

    /// Roshan's 2 Oct recording: 1280x828 pt @2x streamed at 2560x1656, the phone at 2.35 px per point
    /// (1.15x of landscape Fill) re-cropped 10 times and recreated the encoder 7 times in 12 s. The whole
    /// display was already at its own 2 px per point there, so no crop could add a single pixel.
    func testCropGainRuleStreamsTheWholeDisplayUnlessACropAddsFifteenPercentAndReleasesWithHysteresis() throws {
        let bigText = DisplayGeometry(size: CGSize(width: 1280, height: 828), pointPixelScale: 2)
        let bigTextWhole = try output(bigText, fps: 60)
        XCTAssertEqual(bigTextWhole, size(2560, 1656))
        let recording = iPhone17(zoom: 2.35, portrait: false, on: bigText)
        let previousCrop = region(recording, on: bigText, output: bigTextWhole, nearNative: false)
        XCTAssertFalse(previousCrop.isWholeDisplay, "the switch restores the crop of 20261002.2")
        XCTAssertEqual(try sharpness(previousCrop, recording, on: bigText),
                       try sharpness(Policy.wholeDisplay(bigText, output: bigTextWhole), recording, on: bigText), accuracy: 0.001,
                       "that crop delivered exactly what the whole display delivers")
        XCTAssertTrue(region(recording, on: bigText, output: bigTextWhole, nearNative: true).isWholeDisplay)
        XCTAssertTrue(region(recording, on: bigText, output: bigTextWhole, previous: previousCrop, nearNative: true).isWholeDisplay,
                      "released even from an engaged crop: no gain at all")
        XCTAssertTrue(region(iPhone17(zoom: 4, portrait: false, on: bigText), on: bigText, output: bigTextWhole, nearNative: true).isWholeDisplay,
                      "at any zoom: the display has no more pixels to give")
        let rung2 = CapturePixelDimensions(width: 1920, height: 1242)
        XCTAssertFalse(region(recording, on: bigText, output: rung2, nearNative: true).isWholeDisplay,
                       "a size rung below the display's pixels is where a crop adds sharpness (2 / 1.5)")

        let whole = try output(moreSpace, fps: 60)
        func at(_ zoom: Double, previous: CaptureRegion?) -> CaptureRegion {
            region(iPhone17(zoom: zoom, portrait: false, on: moreSpace), on: moreSpace, output: whole,
                   previous: previous, nearNative: true)
        }
        let crop = at(2, previous: nil)
        XCTAssertFalse(crop.isWholeDisplay)
        let wholeRegion = Policy.wholeDisplay(moreSpace, output: whole)
        // The whole display gives 1.333 px per point; a phone-native crop gives the zoom: 1.38 -> 1.035,
        // 1.45 -> 1.09, 1.6 -> 1.2.
        XCTAssertTrue(at(1.38, previous: nil).isWholeDisplay)
        XCTAssertTrue(at(1.38, previous: crop).isWholeDisplay, "released under 1.05")
        XCTAssertTrue(at(1.45, previous: nil).isWholeDisplay, "not engaged under 1.15")
        XCTAssertTrue(at(1.45, previous: wholeRegion).isWholeDisplay)
        XCTAssertFalse(at(1.45, previous: crop).isWholeDisplay, "a crop stays engaged between 1.05 and 1.15")
        XCTAssertFalse(at(1.6, previous: nil).isWholeDisplay)
        XCTAssertFalse(at(1.6, previous: wholeRegion).isWholeDisplay)
        XCTAssertEqual(try sharpness(at(1.6, previous: nil), iPhone17(zoom: 1.6, portrait: false, on: moreSpace), on: moreSpace), 1,
                       accuracy: 0.01, "the crop that does engage is still phone-native")
        var sequence: [Bool] = []
        var previous: CaptureRegion?
        for zoom in [1.5, 1.6, 1.7, 1.65, 1.62, 1.85, 1.45, 1.38, 1.45] {
            let next = at(zoom, previous: previous)
            sequence.append(next.isWholeDisplay)
            previous = next
        }
        XCTAssertEqual(sequence, [true, false, false, false, false, false, false, true, true],
                       "one flip per crossing of the band, none inside it")
    }

    func testCropGainHysteresisSurvivesARungChangeAndIsJudgedOnTheTarget() throws {
        let whole = try output(moreSpace, fps: 60)
        let crop = region(iPhone17(zoom: 2, portrait: false, on: moreSpace), on: moreSpace, output: whole, nearNative: true)
        XCTAssertFalse(crop.isWholeDisplay)
        // 1.45 px/pt gives 1.09: released only without the engaged state that `previous` carries.
        let wobble = iPhone17(zoom: 1.45, portrait: false, on: moreSpace)
        XCTAssertTrue(region(wobble, on: moreSpace, output: whole, previous: nil, nearNative: true).isWholeDisplay)
        XCTAssertFalse(region(wobble, on: moreSpace, output: whole, previous: nil, nearNative: true, cropEngaged: true).isWholeDisplay,
                       "a rung or quality change passes previous nil; the engaged state still holds the crop")
        XCTAssertTrue(region(wobble, on: moreSpace, output: whole, previous: crop, nearNative: true, cropEngaged: false).isWholeDisplay)
        // The held output may lag the phone-native target by 10 %: the gain is judged on the target.
        var held = crop
        held.outputWidth = Int(Double(crop.outputWidth) * 0.91) / 16 * 16
        held.outputHeight = Int(Double(crop.outputHeight) * 0.91) / 16 * 16
        let judged = region(iPhone17(zoom: 1.6, portrait: false, on: moreSpace), on: moreSpace, output: whole,
                            previous: held, nearNative: true)
        XCTAssertFalse(judged.isWholeDisplay, "1.6 px/pt is 1.2x however the held size lags")
    }

    /// The shipping combination (`PocketDeskScrollFixes` on): both rules together.
    func testCropGainAndKeepBandTogetherOnTheASUSAndOnMoreSpace() throws {
        let asusWhole = try output(asus, fps: 120)
        // A 1x display: a crop delivers 1 px per point, the whole display asusWhole.width / 2560.
        XCTAssertEqual(region(centered(zoom: 2, on: asus), output: asusWhole, nearNative: true, keepBand: true).isWholeDisplay,
                       Double(asusWhole.width) > 2560 / Policy.cropGainEngage,
                       "whole only while the stream is within 15 % of the panel's own pixels (\(asusWhole.width) wide)")
        let whole = try output(moreSpace, fps: 60)
        var previous: CaptureRegion?
        var changes = 0, wholes = 0
        for (epoch, zoom) in [2.0, 2.05, 1.95, 2.1, 2.0, 1.9, 3.0, 2.9, 1.45, 1.38].enumerated() {
            let next = region(iPhone17(zoom: zoom, portrait: false, on: moreSpace, epoch: UInt64(epoch + 1)), on: moreSpace,
                              output: whole, previous: previous, nearNative: true, keepBand: true)
            if let previous, Policy.needsReconfiguration(from: previous, to: next) { changes += 1 }
            if next.isWholeDisplay { wholes += 1 }
            XCTAssertNoThrow(try next.validate())
            if !next.isWholeDisplay {
                XCTAssertEqual(next.outputWidth % 16, 0); XCTAssertEqual(next.outputHeight % 16, 0)
                XCTAssertLessThanOrEqual(next.outputWidth * next.outputHeight, whole.width * whole.height)
                XCTAssertTrue(next.rect.contains(iPhone17(zoom: zoom, portrait: false, on: moreSpace).rect.intersection(moreSpace.bounds)))
            }
            previous = next
        }
        XCTAssertEqual(changes, 3, "2x -> 3x, 3x -> 1.45x (released under 1.05 at 1.38) and the whole display: everything else held")
        XCTAssertEqual(wholes, 1)
    }

    func testAFrameNearAReconfigurationIsTaggedByDisplayTimeAndSizeOrNotAtAll() {
        typealias Frames = CaptureFrameRegionPolicy
        let a = CaptureRegion(epoch: 29, x: 32, y: 268, width: 1216, height: 560, outputWidth: 2432, outputHeight: 1200)
        let b = CaptureRegion(epoch: 33, x: 32, y: 148, width: 1216, height: 600, outputWidth: 2432, outputHeight: 1200)
        let c = CaptureRegion(epoch: 55, x: 36, y: 340, width: 1208, height: 488, outputWidth: 2416, outputHeight: 976)
        let move = Frames.Switch(previous: a, next: b, requestedMs: 1000)
        XCTAssertEqual(Frames.region(displayMs: 990, bufferWidth: 2432, bufferHeight: 1200, applied: a, inFlight: move, lastSwitch: nil), a,
                       "shown before the request: the old crop")
        XCTAssertNil(Frames.region(displayMs: 1010, bufferWidth: 2432, bufferHeight: 1200, applied: a, inFlight: move, lastSwitch: nil),
                     "same size, after the request, completion pending: unknown")
        XCTAssertNil(Frames.region(displayMs: 0, bufferWidth: 2432, bufferHeight: 1200, applied: a, inFlight: move, lastSwitch: nil))
        let resize = Frames.Switch(previous: b, next: c, requestedMs: 2000)
        XCTAssertEqual(Frames.region(displayMs: 2010, bufferWidth: 2416, bufferHeight: 976, applied: b, inFlight: resize, lastSwitch: nil), c,
                       "the new size can only be the new crop")
        XCTAssertEqual(Frames.region(displayMs: 2010, bufferWidth: 2432, bufferHeight: 1200, applied: b, inFlight: resize, lastSwitch: nil), b)
        XCTAssertNil(Frames.region(displayMs: 2010, bufferWidth: 1600, bufferHeight: 640, applied: b, inFlight: resize, lastSwitch: nil))
        // After the completion: a late frame shown before the request is still the old crop.
        XCTAssertEqual(Frames.region(displayMs: 1990, bufferWidth: 2432, bufferHeight: 1200, applied: c, inFlight: nil, lastSwitch: resize), b)
        XCTAssertEqual(Frames.region(displayMs: 2020, bufferWidth: 2416, bufferHeight: 976, applied: c, inFlight: nil, lastSwitch: resize), c)
        XCTAssertNil(Frames.region(displayMs: 2020, bufferWidth: 2432, bufferHeight: 1200, applied: c, inFlight: nil, lastSwitch: resize),
                     "the applied crop's size is the only one a frame may carry now")
        XCTAssertEqual(Frames.region(displayMs: 3000, bufferWidth: 2416, bufferHeight: 976, applied: c, inFlight: nil, lastSwitch: nil), c)
    }

    func testKeepBandKeepsACropAcrossAZoomWobbleAndAnEdgeShrink() throws {
        let whole = try output(asus, fps: 120)
        let first = region(centered(zoom: 2, on: asus, epoch: 1), output: whole, keepBand: true)
        XCTAssertEqual(first, CaptureRegion(epoch: 1, x: 512, y: 368, width: 1536, height: 704,
                                            outputWidth: 1536, outputHeight: 704))
        // Two-finger navigation wobbles the zoom by a few percent on every sample.
        let wobble = region(centered(zoom: 2.1, on: asus, epoch: 2), output: whole, previous: first, keepBand: true)
        XCTAssertEqual(wobble.rect, first.rect)
        XCTAssertEqual(size(wobble.outputWidth, wobble.outputHeight), size(1536, 704))
        XCTAssertFalse(Policy.needsReconfiguration(from: first, to: wobble))
        XCTAssertNotEqual(region(centered(zoom: 2.1, on: asus, epoch: 2), output: whole, previous: first, keepBand: false).rect,
                          first.rect, "the switch restores the exact-size rule")
        // At a display edge the visible rect loses the safe inset (21 pt of 603 at the bottom in landscape).
        var edge = centered(zoom: 2, on: asus, epoch: 3)
        edge.height *= 0.92
        let shrunk = region(edge, output: whole, previous: first, keepBand: true)
        XCTAssertFalse(Policy.needsReconfiguration(from: first, to: shrunk))
        // A real zoom leaves the band and re-crops.
        let zoomed = region(centered(zoom: 2.3, on: asus, epoch: 4), output: whole, previous: first, keepBand: true)
        XCTAssertTrue(Policy.needsReconfiguration(from: first, to: zoomed))
        XCTAssertTrue(zoomed.rect.contains(centered(zoom: 2.3, on: asus).rect))
        // A pan past the margin still re-crops: the old crop no longer contains the view.
        var panned = centered(zoom: 2.05, on: asus, epoch: 5)
        panned.x += 200
        XCTAssertTrue(Policy.needsReconfiguration(from: first, to: region(panned, output: whole, previous: first, keepBand: true)))
    }

    func testEveryPhoneNativeCropIsAlignedFitsTheEncodersAndIsAsSharpAsTheBudgetAllows() throws {
        let hevc = try XCTUnwrap(OwnedHEVCConfiguration(parameters: ["profile-id": "1", "tier-flag": "1",
                                                                      "level-id": "153", "tx-mode": "SRST"]))
        func macroblocks(_ width: Int, _ height: Int) -> Int { ((width + 15) / 16) * ((height + 15) / 16) }
        var crops = 0
        var budgetBound = 0
        for (display, fps) in [(asus, 120), (asus, 60), (air, 120), (air, 60), (moreSpace, 60), (moreSpace, 120)] {
            let full = try output(display, fps: fps)
            let scale = display.pointPixelScale
            for budget in [full, RemoteCaptureConfiguration.scaled(full, by: 0.5)] {
                let budgetArea = budget.width * budget.height
                let sender = SenderOutputFormat.make(width: budget.width, height: budget.height, budget: .level(52),
                                                     targetFPS: fps, ladder: nil)
                XCTAssertEqual(sender, SenderOutputFormat(width: budget.width, height: budget.height, fps: fps))
                for portrait in [false, true] {
                    for zoom in [1.2, 1.5, 2, 2.5, 3, 4, 6, 10, 20] {
                        for fractionX in [0.0, 0.25, 0.5, 0.75, 1.0] {
                            for fractionY in [0.0, 0.5, 1.0] {
                                var viewport = iPhone17(zoom: zoom, portrait: portrait, on: display)
                                viewport.x = (Double(display.size.width) - viewport.width) * fractionX
                                viewport.y = (Double(display.size.height) - viewport.height) * fractionY
                                let crop = region(viewport, on: display, output: budget)
                                let label = "\(display.size)@\(scale) \(fps) fps budget \(budget) "
                                    + "\(portrait ? "portrait" : "landscape") zoom \(zoom) at \(fractionX),\(fractionY)"
                                XCTAssertNoThrow(try crop.validate(), label)
                                guard !crop.isWholeDisplay else { continue }
                                crops += 1
                                let x = crop.x * scale, y = crop.y * scale
                                let width = crop.width * scale, height = crop.height * scale
                                XCTAssertEqual(x, x.rounded(), label)
                                XCTAssertEqual(y, y.rounded(), label)
                                XCTAssertEqual(Int(x) % 2, 0, label)
                                XCTAssertEqual(Int(y) % 2, 0, label)
                                XCTAssertTrue(Int(width) % 16 == 0 || width == display.pixelWidth, label)
                                XCTAssertTrue(Int(height) % 16 == 0 || height == display.pixelHeight, label)
                                XCTAssertTrue(display.bounds.contains(crop.rect), label)
                                let visible = viewport.rect.intersection(display.bounds)
                                XCTAssertTrue(crop.rect.insetBy(dx: -1e-9, dy: -1e-9).contains(visible), label)
                                XCTAssertLessThan(width * height, 0.95 * display.pixelWidth * display.pixelHeight, label)
                                let longEdge = max(display.pixelWidth, display.pixelHeight)
                                XCTAssertGreaterThanOrEqual(max(width, height), 0.25 * longEdge - 1e-9, label)
                                if width < display.pixelWidth, height < display.pixelHeight {
                                    XCTAssertLessThan(abs((width / height) / (visible.width / visible.height) - 1), 0.05,
                                                      "the viewport's aspect: \(label)")
                                }
                                let out = size(crop.outputWidth, crop.outputHeight)
                                XCTAssertEqual(out.width % 16, 0, label)
                                XCTAssertEqual(out.height % 16, 0, label)
                                XCTAssertLessThan(abs(Double(out.width) / Double(out.height) / (width / height) - 1), 0.05,
                                                  label)
                                XCTAssertLessThanOrEqual(out.width * out.height, budgetArea, label)
                                XCTAssertLessThanOrEqual(macroblocks(out.width, out.height),
                                                         macroblocks(budget.width, budget.height), label)
                                XCTAssertTrue(H264LevelPolicy.fits(width: out.width, height: out.height, fps: fps), label)
                                XCTAssertTrue(hevc.fits(width: out.width, height: out.height, fps: fps), label)
                                XCTAssertEqual(SenderOutputFormat.make(width: out.width, height: out.height,
                                                                       budget: .level(52), targetFPS: fps, ladder: nil),
                                               SenderOutputFormat(width: out.width, height: out.height, fps: fps),
                                               "the sender never rescales it: \(label)")
                                let delivered = try sharpness(crop, viewport, on: display)
                                let native = delivered >= min(1, scale / zoom) - 1e-9
                                if !native { budgetBound += 1 }
                                XCTAssertTrue(native || Double(out.width * out.height) >= 0.9 * Double(budgetArea),
                                              "\(delivered) without spending the budget: \(label)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(crops, 1000)
        XCTAssertGreaterThan(budgetBound, 0)
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

// MARK: Displayed-pixels cap (LATENCY-PLAN §4)

extension ViewportCaptureTests {
    private typealias Displayed = DisplayedPixelsPolicy

    private var capOn: StreamTuning {
        var tuning = StreamTuning.tuned
        tuning.displayedPixelsCap = true
        return tuning
    }

    /// The whole-display output as the session composes it: mode and client cap, displayed edge, level fit.
    private func composed(_ display: DisplayGeometry, displayed: Int?, tuning: StreamTuning? = nil,
                          fps: Int = 60) throws -> CapturePixelDimensions {
        try XCTUnwrap(RemoteCaptureConfiguration.outputSize(
            contentSize: display.size, pointPixelScale: display.pointPixelScale, quality: .sharp,
            budget: .level(52), fps: fps, clientLongEdge: 2622, tuning: tuning ?? capOn, displayedLongEdge: displayed))
    }

    /// `region` with the session's split budget, under the same switch values as the `region` helper.
    private func cappedRegion(for viewport: ViewportRegion, display: DisplayGeometry, output: CapturePixelDimensions,
                              budget: CapturePixelDimensions, tuning: StreamTuning, previous: CaptureRegion?,
                              nearNative: Bool = false, cropEngaged: Bool? = nil) -> CaptureRegion {
        Policy.region(for: viewport, display: display, output: output, budget: budget, tuning: tuning, previous: previous,
                      phoneNative: true, nearNative: nearNative, keepBand: true, cropEngaged: cropEngaged)
    }

    func testDisplayedEdgeFollowsTheFitZoomOnMoreSpaceAndANativeMode() throws {
        let portrait = iPhone17Fit(portrait: true, on: moreSpace)
        let landscape = iPhone17Fit(portrait: false, on: moreSpace)
        XCTAssertEqual(portrait.zoom, 0.6281, accuracy: 1e-9)
        XCTAssertEqual(landscape.zoom, 0.9702, accuracy: 1e-9)
        XCTAssertEqual(Displayed.targetLongEdge(viewport: portrait, display: moreSpace, tuning: capOn), 1216,
                       "1920 pt × 0.628 = 1206, up to whole macroblocks")
        XCTAssertEqual(Displayed.targetLongEdge(viewport: landscape, display: moreSpace, tuning: capOn), 1872)
        var wire = portrait
        (wire.pixelWidth, wire.pixelHeight) = (1206, 781)
        XCTAssertEqual(Displayed.targetLongEdge(viewport: wire, display: moreSpace, tuning: capOn), 1216,
                       "the phone sends the display rect × zoom, landscape-shaped in either orientation; only zoom counts")

        let fill = iPhone17(zoom: 2.11, portrait: true, on: moreSpace)
        XCTAssertEqual(Displayed.targetLongEdge(viewport: fill, display: moreSpace, tuning: capOn), 3840,
                       "past 2 px per point the backing itself")
        XCTAssertEqual(try composed(moreSpace, displayed: 3840), size(2560, 1656), "then the mode cap")

        var headroom = capOn
        headroom.displayedPixelsScale = 0.85
        XCTAssertEqual(Displayed.targetLongEdge(viewport: portrait, display: moreSpace, tuning: headroom), 1040)

        let native = DisplayGeometry(size: CGSize(width: 1280, height: 828), pointPixelScale: 2)
        let nativeFit = iPhone17Fit(portrait: true, on: native)
        XCTAssertEqual(nativeFit.zoom, 0.9422, accuracy: 1e-9)
        XCTAssertEqual(Displayed.targetLongEdge(viewport: nativeFit, display: native, tuning: capOn), 1216)

        XCTAssertNil(Displayed.targetLongEdge(viewport: portrait, display: moreSpace, tuning: .tuned), "flag off")
        XCTAssertNil(Displayed.targetLongEdge(viewport: nil, display: moreSpace, tuning: capOn), "an older phone")
        var invalid = portrait
        invalid.zoom = .nan
        XCTAssertNil(Displayed.targetLongEdge(viewport: invalid, display: moreSpace, tuning: capOn))
        invalid = portrait
        invalid.pixelWidth = 0
        XCTAssertNil(Displayed.targetLongEdge(viewport: invalid, display: moreSpace, tuning: capOn))
        XCTAssertNil(Displayed.targetLongEdge(viewport: portrait, display: DisplayGeometry(size: .zero, pointPixelScale: 2),
                                              tuning: capOn))
    }

    func testComposedWholeOutputAtTheDisplayedEdgeIsWhatScreenCaptureKitIsAskedFor() throws {
        XCTAssertEqual(try composed(moreSpace, displayed: nil), size(2560, 1656), "today")
        XCTAssertEqual(try composed(moreSpace, displayed: 1216), size(1216, 786),
                       "3840x2486 × 1216/3840: the height floors to even pixels, not macroblocks")
        XCTAssertEqual(try composed(moreSpace, displayed: 1872), size(1872, 1210))
        XCTAssertEqual(try composed(moreSpace, displayed: 1040), size(1040, 672))
        XCTAssertEqual(try composed(moreSpace, displayed: 1216, fps: 120), size(1216, 786))
        var floor = capOn
        floor.outputLongEdgeOverride = 604
        XCTAssertEqual(try composed(moreSpace, displayed: 1216, tuning: floor), size(604, 390), "the floor arm wins")
        XCTAssertEqual(try composed(moreSpace, displayed: nil, tuning: floor), size(604, 390))

        let portrait = iPhone17Fit(portrait: true, on: moreSpace)
        let whole = try composed(moreSpace, displayed: 1216)
        let region = cappedRegion(for: portrait, display: moreSpace, output: whole,
                                   budget: try composed(moreSpace, displayed: nil), tuning: capOn, previous: nil)
        XCTAssertEqual(region, CaptureRegion(epoch: 0, x: 0, y: 0, width: 1920, height: 1243,
                                             outputWidth: 1216, outputHeight: 786))
        XCTAssertEqual(try sharpness(region, portrait, on: moreSpace), 1216 / 1920 / 0.6281, accuracy: 1e-9,
                       "about one stream pixel per displayed phone pixel instead of 2.1")
    }

    func testDisplayedEdgeHoldsInsideTheBandAndChangesOnlyAfterItsDwell() {
        let held = Displayed.Hold(edge: 1216)
        XCTAssertEqual(Displayed.resolve(target: nil, held: nil, now: 0), Displayed.Decision(edge: nil, hold: nil, deadline: nil),
                       "cap off: today's output")
        let lost = Displayed.resolve(target: nil, held: held, now: 0)
        XCTAssertEqual(lost.edge, 1216, "a lost viewport is a grow, not an undamped jump")
        XCTAssertEqual(lost.deadline, 0.25)
        XCTAssertEqual(Displayed.resolve(target: nil, held: lost.hold, now: 0.25),
                       Displayed.Decision(edge: nil, hold: nil, deadline: nil))
        XCTAssertEqual(Displayed.resolve(target: 1216, held: lost.hold, now: 0.1),
                       Displayed.Decision(edge: 1216, hold: held, deadline: nil), "the viewport is back within the dwell")
        XCTAssertEqual(Displayed.resolve(target: 1216, held: nil, now: 0),
                       Displayed.Decision(edge: 1216, hold: held, deadline: nil), "the first viewport applies at once")
        for target in [1104, 1150, 1216, 1300, 1328] {
            XCTAssertEqual(Displayed.resolve(target: target, held: held, now: 0),
                           Displayed.Decision(edge: 1216, hold: held, deadline: nil), "\(target) is inside the band")
        }

        let grow = Displayed.resolve(target: 1872, held: held, now: 10)
        XCTAssertEqual(grow.edge, 1216)
        XCTAssertEqual(grow.deadline, 10.25)
        let growing = Displayed.resolve(target: 1872, held: grow.hold, now: 10.2)
        XCTAssertEqual(growing.edge, 1216, "still inside the grow dwell")
        XCTAssertEqual(growing.deadline, 10.25, "measured from when the target first left the band")
        XCTAssertEqual(Displayed.resolve(target: 1872, held: growing.hold, now: 10.25),
                       Displayed.Decision(edge: 1872, hold: Displayed.Hold(edge: 1872), deadline: nil))

        let shrink = Displayed.resolve(target: 1216, held: Displayed.Hold(edge: 1872), now: 20)
        XCTAssertEqual(shrink.edge, 1872)
        XCTAssertEqual(shrink.deadline, 21)
        XCTAssertEqual(Displayed.resolve(target: 1216, held: shrink.hold, now: 20.99).edge, 1872)
        XCTAssertEqual(Displayed.resolve(target: 1216, held: shrink.hold, now: 21).edge, 1216,
                       "applied by the dwell's own update, with no further viewport")

        let back = Displayed.resolve(target: 1216, held: grow.hold, now: 10.1)
        XCTAssertEqual(back, Displayed.Decision(edge: 1216, hold: held, deadline: nil), "back inside the band: nothing pending")
        XCTAssertEqual(Displayed.resolve(target: 1872, held: back.hold, now: 10.3).deadline, 10.55, "a new excursion restarts the dwell")

        let reversed = Displayed.resolve(target: 1000, held: grow.hold, now: 10.1)
        XCTAssertEqual(reversed.edge, 1216)
        XCTAssertEqual(reversed.deadline, 11.1, "a reversal waits the shrink dwell from the reversal")
    }

    func testDwellRequestStartsAnUpdateWhenTheGateIsIdleAndQueuesBehindOneInFlight() {
        var gate = ConfigurationUpdateGate()
        XCTAssertEqual(gate.request(at: 1, immediate: true), .start, "idle gate: the dwell applies at once")
        XCTAssertEqual(gate.request(at: 1.01, immediate: true), .none)
        XCTAssertEqual(gate.finished(at: 1.2, immediate: true), .start, "in flight: applied when it finishes")
    }

    func testSessionStartSeedsTheDisplayedEdgeSoTheFirstViewportReconfiguresNothing() throws {
        let portrait = iPhone17Fit(portrait: true, on: moreSpace)
        let edge = try XCTUnwrap(Displayed.initialEdge(viewport: portrait, windowScoped: false, display: moreSpace,
                                                       tuning: capOn))
        XCTAssertEqual(edge, 1216)
        let output = try composed(moreSpace, displayed: edge)
        XCTAssertEqual(output, size(1216, 786), "the capped size on the first configuration")
        let initial = Policy.wholeDisplay(moreSpace, output: output)
        let first = cappedRegion(for: portrait, display: moreSpace, output: output,
                                  budget: try composed(moreSpace, displayed: nil), tuning: capOn, previous: initial)
        XCTAssertFalse(Policy.needsReconfiguration(from: initial, to: first), "the replayed viewport only publishes")
        let decision = Displayed.resolve(target: Displayed.targetLongEdge(viewport: portrait, display: moreSpace, tuning: capOn),
                                         held: Displayed.Hold(edge: edge), now: 0)
        XCTAssertEqual(decision.edge, edge)

        XCTAssertNil(Displayed.initialEdge(viewport: portrait, windowScoped: true, display: moreSpace, tuning: capOn))
        XCTAssertNil(Displayed.initialEdge(viewport: portrait, windowScoped: false, display: moreSpace, tuning: .tuned))
        XCTAssertNil(Displayed.initialEdge(viewport: nil, windowScoped: false, display: moreSpace, tuning: capOn))
        var elsewhere = portrait
        elsewhere.x = 3000
        XCTAssertNil(Displayed.initialEdge(viewport: elsewhere, windowScoped: false, display: moreSpace, tuning: capOn),
                     "a viewport off the new display falls back to the uncapped size")
        XCTAssertEqual(try composed(moreSpace, displayed: nil), size(2560, 1656))
    }

    func testCropsAreSizedFromTheUncappedBudgetExactlyAsBefore() throws {
        let budget = try composed(moreSpace, displayed: nil)
        var crops = 0
        for portrait in [false, true] {
            for zoom in [1.05, 1.2, 1.3, 1.5, 2, 3] {
                let viewport = iPhone17(zoom: zoom, portrait: portrait, on: moreSpace)
                let edge = try XCTUnwrap(Displayed.targetLongEdge(viewport: viewport, display: moreSpace, tuning: capOn))
                let capped = try composed(moreSpace, displayed: edge)
                let label = "\(portrait ? "portrait" : "landscape") zoom \(zoom)"
                let before = region(viewport, on: moreSpace, output: budget)
                let after = cappedRegion(for: viewport, display: moreSpace, output: capped, budget: budget,
                                          tuning: capOn, previous: nil)
                guard !before.isWholeDisplay else {
                    XCTAssertTrue(after.isWholeDisplay, label)
                    XCTAssertEqual(after.outputWidth, capped.width, label)
                    continue
                }
                XCTAssertEqual(after, before, "bit for bit: \(label)")
                crops += 1
                for held in [before, region(iPhone17(zoom: zoom * 1.04, portrait: portrait, on: moreSpace),
                                            on: moreSpace, output: budget)] {
                    XCTAssertEqual(cappedRegion(for: viewport, display: moreSpace, output: capped, budget: budget,
                                                 tuning: capOn, previous: held),
                                   region(viewport, on: moreSpace, output: budget, previous: held), "held: \(label)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(crops, 8, "the comparison covers real crops")
    }

    func testWithScrollFixesNoCropEngagesWhileTheCappedWholeIsAtDisplayedDensity() throws {
        let budget = try composed(moreSpace, displayed: nil)
        for zoom in [1.05, 1.2, 1.3] {
            let viewport = iPhone17(zoom: zoom, portrait: true, on: moreSpace)
            let edge = try XCTUnwrap(Displayed.targetLongEdge(viewport: viewport, display: moreSpace, tuning: capOn))
            let capped = try composed(moreSpace, displayed: edge)
            XCTAssertLessThan(capped.width, budget.width, "zoom \(zoom)")
            for engaged in [false, true] {
                let result = cappedRegion(for: viewport, display: moreSpace, output: capped, budget: budget, tuning: capOn,
                                           previous: nil, nearNative: true, cropEngaged: engaged)
                XCTAssertTrue(result.isWholeDisplay, "zoom \(zoom), engaged \(engaged)")
                XCTAssertEqual(result.outputWidth, capped.width)
            }
        }
        let zoomed = iPhone17(zoom: 2, portrait: true, on: moreSpace)
        let edge = try XCTUnwrap(Displayed.targetLongEdge(viewport: zoomed, display: moreSpace, tuning: capOn))
        let capped = try composed(moreSpace, displayed: edge)
        XCTAssertEqual(capped, budget, "past the mode cap's density the cap changes nothing")
        XCTAssertEqual(cappedRegion(for: zoomed, display: moreSpace, output: capped, budget: budget, tuning: capOn,
                                     previous: nil, nearNative: true),
                       region(zoomed, on: moreSpace, output: budget, nearNative: true))
    }

    func testAHeldEdgeFromBeforeAPinchNeitherEngagesNorDropsACrop() throws {
        let budget = try composed(moreSpace, displayed: nil)
        let fitEdge = try composed(moreSpace, displayed: 1216)
        let pinched = iPhone17(zoom: 1.2, portrait: true, on: moreSpace)
        for engaged in [false, true] {
            let stale = cappedRegion(for: pinched, display: moreSpace, output: fitEdge, budget: budget, tuning: capOn,
                                     previous: nil, nearNative: true, cropEngaged: engaged)
            let today = region(pinched, on: moreSpace, output: budget, nearNative: true, cropEngaged: engaged)
            XCTAssertEqual(stale.isWholeDisplay, today.isWholeDisplay, "the gain is judged on the budget, engaged \(engaged)")
            XCTAssertTrue(stale.isWholeDisplay)
        }

        let zoomed = iPhone17(zoom: 1.5, portrait: true, on: moreSpace)
        let crop = region(zoomed, on: moreSpace, output: budget)
        XCTAssertFalse(crop.isWholeDisplay)
        let wobble = iPhone17(zoom: 1.56, portrait: true, on: moreSpace)
        for output in [fitEdge, try composed(moreSpace, displayed: 2304), budget] {
            XCTAssertEqual(cappedRegion(for: wobble, display: moreSpace, output: output, budget: budget, tuning: capOn,
                                        previous: crop),
                           region(wobble, on: moreSpace, output: budget, previous: crop),
                           "a new displayed edge keeps the held crop: \(output)")
        }
    }

    func testTheWidenedCropRuleAlsoTakesItsAspectAndSizeFromTheBudget() throws {
        let budget = try composed(moreSpace, displayed: nil)
        for zoom in [1.3, 2, 3] {
            let viewport = iPhone17(zoom: zoom, portrait: false, on: moreSpace)
            let before = region(viewport, on: moreSpace, output: budget, phoneNative: false)
            let after = Policy.region(for: viewport, display: moreSpace, output: try composed(moreSpace, displayed: 1216),
                                      budget: budget, tuning: capOn, previous: nil, phoneNative: false,
                                      nearNative: false, keepBand: true)
            if before.isWholeDisplay { XCTAssertTrue(after.isWholeDisplay) } else { XCTAssertEqual(after, before, "zoom \(zoom)") }
        }
    }
}
