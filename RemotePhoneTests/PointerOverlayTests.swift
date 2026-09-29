import XCTest
import Combine
@testable import PocketDeskRemote

@MainActor
final class PointerOverlayTests: XCTestCase {
    private var now: TimeInterval = 100

    private func makeModel() -> PointerOverlayModel {
        let model = PointerOverlayModel(clock: { [unowned self] in self.now })
        model.reset(sourceSize: CGSize(width: 1440, height: 900))
        return model
    }

    private func sample(_ number: UInt64, x: Double, y: Double, videoCursor: Bool,
                        shape: PointerShape = .arrow, applied: UInt64 = 0) -> PointerSync {
        PointerSync(videoCursor: videoCursor, x: x, y: y, visible: true, shape: shape.rawValue,
                    applied: applied, sample: number)
    }

    func testLegacyHostKeepsTheCapturedCursorOnly() {
        let model = makeModel()
        model.hostCapability(nil)
        XCTAssertFalse(model.hostSupported)
        XCTAssertNil(model.advertisement())
        XCTAssertNil(model.reserveMoveOrdinal(), "Moves to a legacy host stay untagged")
        model.receive(sample(1, x: 10, y: 10, videoCursor: false))
        XCTAssertNil(model.render)
    }

    func testDrawsOnlyAfterHostOmitsCursorAndMovesInstantly() {
        let model = makeModel()
        model.hostCapability(PointerSync(videoCursor: true))
        XCTAssertEqual(model.advertisement(), PointerSync(overlay: false))
        model.receive(sample(1, x: 200, y: 150, videoCursor: true))
        XCTAssertEqual(model.advertisement(), PointerSync(overlay: true))
        XCTAssertNil(model.render, "Video still contains the Mac cursor")

        now += 0.02
        model.receive(sample(2, x: 200, y: 150, videoCursor: false, shape: .iBeam))
        XCTAssertEqual(model.render, .init(point: CGPoint(x: 200, y: 150), shape: .iBeam))

        var followed: [CGPoint] = []
        let subscription = model.followUpdates.sink { followed.append($0) }
        defer { subscription.cancel() }
        let ordinal = try! XCTUnwrap(model.reserveMoveOrdinal())
        model.localMove(ordinal: ordinal, delta: CGSize(width: 12, height: -4), follow: true)
        XCTAssertEqual(model.render?.point, CGPoint(x: 212, y: 146), "No network round trip before the pointer moves")
        XCTAssertEqual(followed, [CGPoint(x: 212, y: 146)])
        model.localMove(ordinal: model.reserveMoveOrdinal()!, delta: CGSize(width: 1, height: 0), follow: false)
        XCTAssertEqual(followed.count, 1, "Drags never pan the view")

        now += 0.05
        model.receive(sample(3, x: 213, y: 146, videoCursor: false, shape: .iBeam, applied: 2))
        XCTAssertEqual(model.render?.point, CGPoint(x: 213, y: 146), "Acknowledged samples cause no correction")
    }

    func testFallbackKeepsDrawingThroughTheRestoreGraceThenHides() {
        let model = makeModel()
        model.hostCapability(PointerSync(videoCursor: false))
        model.receive(sample(1, x: 10, y: 20, videoCursor: false))
        XCTAssertNotNil(model.render)

        now += 1
        model.refresh()
        XCTAssertEqual(model.advertisement(), PointerSync(overlay: false), "Stale telemetry requests the captured cursor")
        XCTAssertNotNil(model.render, "Still drawn until the host confirms the captured cursor")

        model.hostCapability(PointerSync(videoCursor: true))
        now += 0.1
        model.refresh()
        XCTAssertNotNil(model.render)
        now += 0.3
        model.refresh()
        XCTAssertNil(model.render)
    }

    func testGeometryResetAcceptsTheRestartedSampleCounter() {
        let model = makeModel()
        model.hostCapability(PointerSync(videoCursor: false))
        model.receive(sample(9, x: 10, y: 20, videoCursor: false))
        model.reset(sourceSize: CGSize(width: 800, height: 600))
        XCTAssertNil(model.render)
        model.hostCapability(PointerSync(videoCursor: false))
        model.receive(sample(1, x: 799, y: 599, videoCursor: false))
        XCTAssertEqual(model.render?.point, CGPoint(x: 799, y: 599))
    }

    func testGlyphPlacementPutsTheHotSpotOnThePointAtEverySize() {
        for size in PointerSizePreference.allCases {
            for shape in [PointerShape.arrow, .iBeam, .pointingHand, .resizeLeftRight] {
                let metrics = PointerGlyphMetrics(shape: shape, arrowHeight: size.arrowHeight)
                let point = CGPoint(x: 123.5, y: 456.25)
                let center = metrics.center(forHotSpotAt: point)
                XCTAssertEqual(center.x - metrics.canvasSize.width / 2 + metrics.hotSpot.x, point.x, accuracy: 0.001)
                XCTAssertEqual(center.y - metrics.canvasSize.height / 2 + metrics.hotSpot.y, point.y, accuracy: 0.001)
            }
            let arrow = PointerGlyphMetrics(shape: .arrow, arrowHeight: size.arrowHeight)
            XCTAssertEqual(arrow.canvasSize.height - PointerGlyphMetrics.shadowPadding * 2, size.arrowHeight, accuracy: 0.001)
        }
        let heights = PointerSizePreference.allCases.map(\.arrowHeight)
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertGreaterThanOrEqual(PointerSizePreference.medium.arrowHeight, 30,
                                    "The default must be clearly larger than the macOS arrow as streamed at Fit")
    }
}
