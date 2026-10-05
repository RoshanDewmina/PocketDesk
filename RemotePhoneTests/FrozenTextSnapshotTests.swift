import XCTest
@testable import PocketDeskRemote

final class FrozenTextSnapshotTests: XCTestCase {
    func testCropIncludesOnlyVisiblePlacementWithNonzeroOrigin() throws {
        let crop = try XCTUnwrap(FrozenTextSnapshot.normalizedCrop(visible: CGRect(x: 100, y: 50, width: 200, height: 100),
            placement: CGRect(x: 50, y: 0, width: 400, height: 200)))
        XCTAssertEqual(crop, CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertNil(FrozenTextSnapshot.normalizedCrop(visible: .zero, placement: .zero))
        XCTAssertNil(FrozenTextSnapshot.normalizedCrop(visible: CGRect(x: 1000, y: 0, width: 50, height: 50),
            placement: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }
}
