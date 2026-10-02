import XCTest
@testable import PocketDeskRemote

final class DuoSessionLayoutTests: XCTestCase {
    func testLaptopUsesBothSidesOfTheActualHingeIncludingItsMargins() throws {
        let layout = DuoSessionLayout(posture: .partiallyOpen, bounds: CGRect(x: 0, y: 0, width: 669, height: 951),
            divisions: [CGRect(x: 0, y: 461, width: 669, height: 28)])
        let split = try XCTUnwrap(layout.division)
        XCTAssertEqual(split.axis, .vertical)
        XCTAssertEqual(split.picture.maxY, 461)
        XCTAssertEqual(split.trackpad.minY, 489)
        XCTAssertEqual(split.trackpad.maxY, 951)
        XCTAssertTrue(layout.stacked(ordinary: false), "A half fold overrides compact-width and coverage decisions")
    }

    func testBookUsesPictureLeadingAndTrackpadTrailing() throws {
        let layout = DuoSessionLayout(posture: .partiallyOpen, bounds: CGRect(x: 0, y: 0, width: 951, height: 669),
            divisions: [CGRect(x: 460, y: 0, width: 30, height: 669)])
        let split = try XCTUnwrap(layout.division)
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.picture.maxX, 460)
        XCTAssertEqual(split.trackpad.minX, 490)
    }

    func testFlatDelegatesToIPadRuleAndFoldedAlwaysUsesPhoneLayout() {
        let flat = DuoSessionLayout(posture: .unfolded)
        XCTAssertTrue(flat.stacked(ordinary: true))
        XCTAssertFalse(flat.stacked(ordinary: false))
        XCTAssertFalse(DuoSessionLayout(posture: .folded).stacked(ordinary: true))
        XCTAssertTrue(DuoSessionLayout().stacked(ordinary: true), "An older SDK retains geometry-only behavior")
    }

    func testSplitWindowOutsideHingeDoesNotInventATrackpadHalf() {
        let layout = DuoSessionLayout(posture: .partiallyOpen, bounds: CGRect(x: 0, y: 0, width: 400, height: 669),
            divisions: [CGRect(x: 460, y: 0, width: 30, height: 669)])
        XCTAssertNil(layout.division)
        XCTAssertFalse(layout.stacked(ordinary: false))
        XCTAssertTrue(layout.reservedFrames.isEmpty)
    }

    func testInvalidAndAmbiguousRegionsDoNotCreateNegativeGeometry() {
        var layout = DuoSessionLayout(posture: .partiallyOpen, bounds: CGRect(x: 0, y: 0, width: 669, height: 951),
            divisions: [CGRect(x: 0, y: 0, width: 669, height: 28)])
        XCTAssertNil(layout.division)
        layout.divisions = [.null, .infinite]
        XCTAssertNil(layout.division)
        XCTAssertTrue(layout.reservedFrames.isEmpty)
        layout.divisions = [CGRect(x: 0, y: 450, width: 669, height: 28), CGRect(x: 0, y: 470, width: 669, height: 28)]
        XCTAssertNil(layout.division)
    }

    func testOcclusionIsClippedToWindowAndClearsWithNewSnapshot() {
        let layout = DuoSessionLayout(bounds: CGRect(x: 0, y: 0, width: 466, height: 678),
            occlusions: [CGRect(x: 450, y: 0, width: 40, height: 40)])
        XCTAssertEqual(layout.reservedFrames, [CGRect(x: 450, y: 0, width: 16, height: 40)])
        XCTAssertTrue(DuoSessionLayout(bounds: layout.bounds).reservedFrames.isEmpty)
    }
}
