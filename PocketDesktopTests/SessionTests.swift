import XCTest
@testable import PocketDesktop

@MainActor
final class SessionTests: XCTestCase {
    func testPointerStaysFiniteAndWithinViewportWhenViewportHasNoSize() {
        let session = DemoSession()
        session.viewport = .zero

        for delta in [CGSize(width: 10_000, height: -10_000), CGSize(width: -10_000, height: 10_000)] {
            session.move(delta)
            XCTAssertTrue(session.cursor.x.isFinite)
            XCTAssertTrue(session.cursor.y.isFinite)
            XCTAssertGreaterThanOrEqual(session.cursor.x, 0)
            XCTAssertLessThanOrEqual(session.cursor.x, 1)
            XCTAssertGreaterThanOrEqual(session.cursor.y, 0)
            XCTAssertLessThanOrEqual(session.cursor.y, 1)
        }
    }

    func testClickOnlyOpensDocumentWhenPointerIsInsideItsRegisteredTarget() {
        let session = DemoSession()
        session.viewport = CGSize(width: 200, height: 100)
        session.targets = ["Ideas": CGRect(x: 20, y: 20, width: 40, height: 30)]

        session.cursor = CGPoint(x: 0.8, y: 0.8)
        session.click()
        XCTAssertEqual(session.selected, "Welcome", "Clicking the desktop must not open an arbitrary document.")

        session.cursor = CGPoint(x: 0.2, y: 0.3)
        session.click()
        XCTAssertEqual(session.selected, "Ideas")
    }

    func testContextMenuConsumesClicksAndDispatchesItsOwnActions() {
        let session = DemoSession()
        session.viewport = CGSize(width: 200, height: 100)
        session.targets = [
            "Ideas": CGRect(x: 0, y: 0, width: 200, height: 100),
            "menu-focus": CGRect(x: 20, y: 20, width: 40, height: 30)
        ]

        session.contextMenu = true
        session.cursor = CGPoint(x: 0.2, y: 0.3)
        session.click()
        XCTAssertTrue(session.focusWindow, "The menu action must win over the document beneath it.")
        XCTAssertEqual(session.selected, "Welcome")
        XCTAssertFalse(session.contextMenu)

        session.contextMenu = true
        session.cursor = CGPoint(x: 0.8, y: 0.8)
        session.click()
        XCTAssertFalse(session.contextMenu, "Clicking outside the menu should dismiss it.")
        XCTAssertEqual(session.selected, "Welcome", "Dismissal must not also activate the underlying document.")
        XCTAssertTrue(session.focusWindow)
    }

    func testCommandASelectsWithoutDestroyingTextUntilReplacementOrDeletion() {
        let session = DemoSession()
        session.document = "Keep this until an editing action"
        let original = session.document

        session.command = true
        session.insert("a")
        XCTAssertEqual(session.document, original)
        XCTAssertTrue(session.selectAll)

        session.insert("Replacement")
        XCTAssertEqual(session.document, "Replacement")
        XCTAssertFalse(session.selectAll)

        session.command = true
        session.insert("a")
        XCTAssertEqual(session.document, "Replacement")
        session.delete()
        XCTAssertEqual(session.document, "")
        XCTAssertFalse(session.selectAll)
    }

    func testOpeningAnotherDocumentResetsPreviousScrollPosition() {
        let session = DemoSession()
        session.scroll = 240
        session.activate("Ideas")
        XCTAssertEqual(session.selected, "Ideas")
        XCTAssertEqual(session.scroll, 0)

        session.scroll = 120
        session.activate("menu-welcome")
        XCTAssertEqual(session.selected, "Welcome")
        XCTAssertEqual(session.scroll, 0, "Opening through a menu must also restore the document's starting position.")
    }
}
