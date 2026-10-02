import XCTest
import SwiftUI
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

final class PhoneCommandAccessibilityTests: XCTestCase {
    func testAccessibleCommandsUseTwoColumnsOnlyWhenExplicitlyEnabledAtAccessibilitySizes() {
        for size in [DynamicTypeSize.accessibility1, .accessibility5] {
            XCTAssertTrue(PhoneCommandAccessibility.usesKeyList(typeSize: size, enabled: true))
            XCTAssertFalse(PhoneCommandAccessibility.usesKeyList(typeSize: size, enabled: false))
        }
        XCTAssertFalse(PhoneCommandAccessibility.usesKeyList(typeSize: .xxxLarge, enabled: true))
        XCTAssertEqual(PhoneCommandAccessibility.columns(compact: true, accessible: true), 2)
        XCTAssertEqual(PhoneCommandAccessibility.columns(compact: false, accessible: true), 2)
        XCTAssertEqual(PhoneCommandAccessibility.columns(compact: true, accessible: false), 8)
        XCTAssertEqual(PhoneCommandAccessibility.columns(compact: false, accessible: false), 4)
        XCTAssertEqual(PhoneCommandAccessibility.headingSize(scaled: 120, base: 30, accessible: true), 120)
        XCTAssertEqual(PhoneCommandAccessibility.headingSize(scaled: 120, base: 30, accessible: false), 48)
    }
    func testTouchTargetsAndDefaultOffKeyListBothRestoreTheirLegacyState() {
        XCTAssertEqual(PhoneCommandAccessibility.target(40, enabled: true), 44)
        XCTAssertEqual(PhoneCommandAccessibility.target(42, enabled: true), 44)
        XCTAssertEqual(PhoneCommandAccessibility.target(46, enabled: true), 46)
        XCTAssertEqual(PhoneCommandAccessibility.target(40, enabled: false), 40)
        let defaults = UserDefaults(suiteName: "b8-command-tests")!
        defer { defaults.removePersistentDomain(forName: "b8-command-tests") }
        defaults.removePersistentDomain(forName: "b8-command-tests")
        XCTAssertFalse(PhoneCommandAccessibility.resolve(defaults, key: PhoneCommandAccessibility.keyListKey, defaultValue: false))
        XCTAssertTrue(PhoneCommandAccessibility.resolve(defaults, key: PhoneCommandAccessibility.targetsKey, defaultValue: true))
        defaults.set("YES", forKey: PhoneCommandAccessibility.keyListKey)
        XCTAssertTrue(PhoneCommandAccessibility.resolve(defaults, key: PhoneCommandAccessibility.keyListKey, defaultValue: false))
        defaults.set("NO", forKey: PhoneCommandAccessibility.targetsKey)
        XCTAssertFalse(PhoneCommandAccessibility.resolve(defaults, key: PhoneCommandAccessibility.targetsKey, defaultValue: true))
        for flag in [true, false] {
            for key in [PhoneCommandAccessibility.keyListKey, PhoneCommandAccessibility.targetsKey] {
                defaults.set(flag, forKey: key)
                XCTAssertEqual(PhoneCommandAccessibility.resolve(defaults, key: key, defaultValue: !flag), flag)
            }
        }
    }
}
