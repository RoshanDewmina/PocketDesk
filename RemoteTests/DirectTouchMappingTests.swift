import Foundation
import CoreGraphics
import XCTest

/// Where a direct touch lands on the Mac, at several zoom levels and in both orientations, on
/// iPhone and iPad canvases with their real safe areas. Expected values come from the plain
/// definitions of Fit (whole display centred in the safe area) and Fill (canvas covered, centred
/// on the canvas), not from the transform's own helpers.
final class DirectTouchMappingTests: XCTestCase {
    private struct Device {
        let name: String
        let canvas: CGSize
        let insets: ViewportInsets
    }

    private let iPhonePortrait = Device(name: "iPhone portrait", canvas: CGSize(width: 402, height: 874),
                                        insets: ViewportInsets(top: 62, bottom: 34))
    private let iPhoneLandscape = Device(name: "iPhone landscape", canvas: CGSize(width: 874, height: 402),
                                         insets: ViewportInsets(left: 62, bottom: 21, right: 62))
    private let iPadPortrait = Device(name: "iPad portrait", canvas: CGSize(width: 834, height: 1210),
                                      insets: ViewportInsets(top: 24, bottom: 20))
    private let iPadLandscape = Device(name: "iPad landscape", canvas: CGSize(width: 1210, height: 834),
                                       insets: ViewportInsets(top: 24, bottom: 20))
    private var devices: [Device] { [iPhonePortrait, iPhoneLandscape, iPadPortrait, iPadLandscape] }

    private let macBookAir = CGSize(width: 1470, height: 956)
    private let externalDisplay = CGSize(width: 1920, height: 1080)

    func testFitBaselineMatchesTheDefinitionOnEveryDevice() {
        for device in devices {
            for source in [macBookAir, externalDisplay] {
                let view = ViewportTransform(sourceSize: source, canvasSize: device.canvas, mode: .fit,
                                             safeInsets: device.insets)
                let safe = safeRect(device)
                let scale = min(safe.width / source.width, safe.height / source.height)
                let origin = CGPoint(x: safe.midX - source.width * scale / 2,
                                     y: safe.midY - source.height * scale / 2)
                for fraction in samples {
                    let expected = CGPoint(x: source.width * fraction.x, y: source.height * fraction.y)
                    let touch = CGPoint(x: origin.x + expected.x * scale, y: origin.y + expected.y * scale)
                    assertMaps(touch, to: expected, in: view, "\(device.name) Fit \(source)")
                }
            }
        }
    }

    func testFillBaselineMatchesTheDefinitionOnEveryDevice() {
        for device in devices {
            let source = macBookAir
            let view = ViewportTransform(sourceSize: source, canvasSize: device.canvas, mode: .fill,
                                         safeInsets: device.insets)
            let scale = max(device.canvas.width / source.width, device.canvas.height / source.height)
            let origin = CGPoint(x: device.canvas.width / 2 - source.width * scale / 2,
                                 y: device.canvas.height / 2 - source.height * scale / 2)
            for fraction in samples {
                let expected = CGPoint(x: source.width * fraction.x, y: source.height * fraction.y)
                let touch = CGPoint(x: origin.x + expected.x * scale, y: origin.y + expected.y * scale)
                guard touch.x >= 0, touch.x <= device.canvas.width, touch.y >= 0, touch.y <= device.canvas.height else {
                    XCTAssertNil(DirectTouchMapping.sourcePoint(for: touch, in: view),
                                 "\(device.name): a cropped point is not on screen, so it cannot be touched")
                    continue
                }
                assertMaps(touch, to: expected, in: view, "\(device.name) Fill")
            }
        }
    }

    func testZoomKeepsTheAnchorAndScalesDistancesExactly() {
        for device in devices {
            for zoom: CGFloat in [1.5, 2, 3] {
                // Fill overflows the safe area on both axes, so zooming about its centre is never clamped.
                var view = ViewportTransform(sourceSize: macBookAir, canvasSize: device.canvas, mode: .fill,
                                             safeInsets: device.insets)
                let anchor = CGPoint(x: safeRect(device).midX, y: safeRect(device).midY)
                let anchored = view.sourcePoint(fromView: anchor)!
                view.setZoom(zoom, anchoredAt: anchor)
                XCTAssertEqual(view.scale, view.fillScale * zoom, accuracy: 1e-9, "\(device.name) \(zoom)×")
                assertMaps(anchor, to: anchored, in: view, "\(device.name) \(zoom)× anchor")
                let offset = CGSize(width: 37, height: -23)
                let moved = CGPoint(x: anchor.x + offset.width, y: anchor.y + offset.height)
                let expected = CGPoint(x: anchored.x + offset.width / view.scale,
                                       y: anchored.y + offset.height / view.scale)
                assertMaps(moved, to: expected, in: view, "\(device.name) \(zoom)× offset")
            }
        }
    }

    func testPanShiftsTheTargetByTheTranslation() {
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: iPhonePortrait.canvas, mode: .fill,
                                     safeInsets: iPhonePortrait.insets)
        view.setZoom(2, anchoredAt: CGPoint(x: 201, y: 437))
        let touch = CGPoint(x: 150, y: 500)
        let before = view.sourcePoint(fromView: touch)!
        let offsetBefore = view.offset
        view.pan(by: CGSize(width: -40, height: 25))
        let applied = CGSize(width: view.offset.x - offsetBefore.x, height: view.offset.y - offsetBefore.y)
        XCTAssertEqual(applied.width, -40, accuracy: 1e-9)
        XCTAssertEqual(applied.height, 25, accuracy: 1e-9)
        let expected = CGPoint(x: before.x - applied.width / view.scale, y: before.y - applied.height / view.scale)
        assertMaps(touch, to: expected, in: view, "after pan")
    }

    func testEveryVisiblePointRoundTripsWithinAQuantum() {
        for device in devices {
            for mode in [ViewportMode.fit, .fill] {
                for zoom: CGFloat in [1, 2.25] {
                    var view = ViewportTransform(sourceSize: externalDisplay, canvasSize: device.canvas, mode: mode,
                                                 safeInsets: device.insets)
                    view.setZoom(zoom, anchoredAt: CGPoint(x: device.canvas.width * 0.4, y: device.canvas.height * 0.55))
                    let visible = view.contentRect.intersection(CGRect(origin: .zero, size: device.canvas))
                    for i in 0...8 {
                        for j in 0...8 {
                            let touch = CGPoint(x: visible.minX + visible.width * CGFloat(i) / 8,
                                                y: visible.minY + visible.height * CGFloat(j) / 8)
                            guard let mapped = DirectTouchMapping.sourcePoint(for: touch, in: view) else {
                                XCTFail("\(device.name) \(mode) \(zoom)×: visible picture must be touchable at \(touch)")
                                continue
                            }
                            let back = view.viewPoint(fromSource: mapped)
                            XCTAssertEqual(back.x, touch.x, accuracy: view.scale / DirectTouchMapping.quantum,
                                           "\(device.name) \(mode) \(zoom)×")
                            XCTAssertEqual(back.y, touch.y, accuracy: view.scale / DirectTouchMapping.quantum)
                            XCTAssertTrue((0...externalDisplay.width).contains(mapped.x))
                            XCTAssertTrue((0...externalDisplay.height).contains(mapped.y))
                        }
                    }
                }
            }
        }
    }

    func testRotationKeepsTheCentreTargetUnderTheSafeCentre() {
        var view = ViewportTransform(sourceSize: macBookAir, canvasSize: iPhonePortrait.canvas, mode: .fill,
                                     safeInsets: iPhonePortrait.insets)
        view.setZoom(1.8, anchoredAt: CGPoint(x: 120, y: 300))
        let portraitCentre = CGPoint(x: safeRect(iPhonePortrait).midX, y: safeRect(iPhonePortrait).midY)
        let focus = view.sourcePoint(fromView: portraitCentre)!
        view.resize(sourceSize: macBookAir, canvasSize: iPhoneLandscape.canvas, safeInsets: iPhoneLandscape.insets)
        let landscapeCentre = CGPoint(x: safeRect(iPhoneLandscape).midX, y: safeRect(iPhoneLandscape).midY)
        let target = DirectTouchMapping.sourcePoint(for: landscapeCentre, in: view)!
        XCTAssertEqual(target.x, focus.x, accuracy: 0.5, "Rotating must not change what the centre touch hits")
        XCTAssertEqual(target.y, focus.y, accuracy: 0.5)
    }

    func testLetterboxAndOutsideTouchesHaveNoTarget() {
        let portrait = ViewportTransform(sourceSize: macBookAir, canvasSize: iPhonePortrait.canvas, mode: .fit,
                                         safeInsets: iPhonePortrait.insets)
        XCTAssertNil(DirectTouchMapping.sourcePoint(for: CGPoint(x: 201, y: portrait.contentRect.minY - 1), in: portrait))
        XCTAssertNil(DirectTouchMapping.sourcePoint(for: CGPoint(x: 201, y: portrait.contentRect.maxY + 1), in: portrait))
        XCTAssertNil(DirectTouchMapping.sourcePoint(for: CGPoint(x: -1, y: 450), in: portrait))
        XCTAssertNil(DirectTouchMapping.sourcePoint(for: CGPoint(x: CGFloat.nan, y: 450), in: portrait))

        let iPad = ViewportTransform(sourceSize: CGSize(width: 1080, height: 1920), canvasSize: iPadLandscape.canvas,
                                     mode: .fit, safeInsets: iPadLandscape.insets)
        XCTAssertGreaterThan(iPad.contentRect.minX, 1, "A portrait monitor is pillarboxed in iPad landscape")
        XCTAssertNil(DirectTouchMapping.sourcePoint(for: CGPoint(x: iPad.contentRect.minX - 2, y: 400), in: iPad))
        XCTAssertNotNil(DirectTouchMapping.sourcePoint(for: CGPoint(x: iPad.contentRect.minX + 2, y: 400), in: iPad))
    }

    func testEdgesMapInsideTheDisplayAndQuantizeToTelemetrySteps() {
        let view = ViewportTransform(sourceSize: macBookAir, canvasSize: iPadPortrait.canvas, mode: .fit,
                                     safeInsets: iPadPortrait.insets)
        let rect = view.contentRect
        XCTAssertEqual(DirectTouchMapping.sourcePoint(for: CGPoint(x: rect.minX, y: rect.minY), in: view), .zero)
        XCTAssertEqual(DirectTouchMapping.sourcePoint(for: CGPoint(x: rect.maxX, y: rect.maxY), in: view),
                       CGPoint(x: macBookAir.width, y: macBookAir.height))
        let odd = DirectTouchMapping.sourcePoint(for: CGPoint(x: rect.minX + 100.3, y: rect.minY + 77.7), in: view)!
        XCTAssertEqual((odd.x * 64).rounded(), odd.x * 64, "Positions travel in 1/64 pt")
        XCTAssertEqual((odd.y * 64).rounded(), odd.y * 64)
    }

    // MARK: - Helpers

    private let samples: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1),
                                      CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.013, y: 0.987)]

    private func safeRect(_ device: Device) -> CGRect {
        CGRect(x: device.insets.left, y: device.insets.top,
               width: device.canvas.width - device.insets.left - device.insets.right,
               height: device.canvas.height - device.insets.top - device.insets.bottom)
    }

    private func assertMaps(_ touch: CGPoint, to expected: CGPoint, in view: ViewportTransform, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let mapped = DirectTouchMapping.sourcePoint(for: touch, in: view) else {
            XCTFail("\(context): no target for \(touch)", file: file, line: line)
            return
        }
        // Half a quantum of rounding plus floating-point noise.
        let tolerance = 1 / DirectTouchMapping.quantum
        XCTAssertEqual(mapped.x, expected.x, accuracy: tolerance, "\(context) x", file: file, line: line)
        XCTAssertEqual(mapped.y, expected.y, accuracy: tolerance, "\(context) y", file: file, line: line)
    }
}
