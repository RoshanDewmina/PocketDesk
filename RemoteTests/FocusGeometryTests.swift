import Foundation
import CoreGraphics
import XCTest

final class FocusGeometryTests: XCTestCase {
    // MARK: - Global → display-local conversion

    func testRetinaDisplayStaysInPointsAndIsNotDoubled() throws {
        // A 2× display reports its frame in points, and so does Accessibility.
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = try XCTUnwrap(FocusGeometry.make(
            field: CGRect(x: 400, y: 300, width: 320, height: 28), anchor: CGPoint(x: 410, y: 314),
            displayFrame: display, geometrySize: display.size))
        XCTAssertEqual(geometry.rect, CGRect(x: 400, y: 300, width: 320, height: 28))
        XCTAssertEqual(geometry.anchor, CGPoint(x: 410, y: 314))
        XCTAssertEqual(geometry.displaySize, display.size)
    }

    func testGeometryExpressedInPixelsScalesTheRect() throws {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let geometry = try XCTUnwrap(FocusGeometry.make(
            field: CGRect(x: 100, y: 50, width: 200, height: 20), anchor: nil,
            displayFrame: display, geometrySize: CGSize(width: 2880, height: 1800)))
        XCTAssertEqual(geometry.rect, CGRect(x: 200, y: 100, width: 400, height: 40))
        XCTAssertNil(geometry.anchor)
    }

    func testNegativeSecondaryDisplayOriginsBecomeDisplayLocal() throws {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let onLeft = try XCTUnwrap(FocusGeometry.make(
            field: CGRect(x: -1800, y: 900, width: 400, height: 30), anchor: CGPoint(x: -1790, y: 915),
            displayFrame: left, geometrySize: left.size))
        XCTAssertEqual(onLeft.rect, CGRect(x: 120, y: 900, width: 400, height: 30))
        XCTAssertEqual(onLeft.anchor, CGPoint(x: 130, y: 915))

        let above = CGRect(x: 200, y: -1440, width: 2560, height: 1440)
        let onTop = try XCTUnwrap(FocusGeometry.make(
            field: CGRect(x: 260, y: -1400, width: 300, height: 24), anchor: nil,
            displayFrame: above, geometrySize: above.size))
        XCTAssertEqual(onTop.rect, CGRect(x: 60, y: 40, width: 300, height: 24))
    }

    func testFieldIsClippedToTheCapturedDisplayAndAnchorClamped() throws {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let geometry = try XCTUnwrap(FocusGeometry.make(
            field: CGRect(x: 1300, y: 880, width: 400, height: 60), anchor: CGPoint(x: 1600, y: 950),
            displayFrame: display, geometrySize: display.size))
        XCTAssertEqual(geometry.rect, CGRect(x: 1300, y: 880, width: 140, height: 20))
        XCTAssertEqual(geometry.anchor, CGPoint(x: 1440, y: 900))
        XCTAssertNoThrow(try geometry.validate())
        XCTAssertNil(FocusGeometry.make(field: CGRect(x: 1500, y: 0, width: 100, height: 20), anchor: nil,
                                        displayFrame: display, geometrySize: display.size),
                     "A field on another display is never reported against this one")
        XCTAssertNil(FocusGeometry.make(field: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), anchor: nil,
                                        displayFrame: display, geometrySize: display.size))
    }

    func testCroppedCaptureDoesNotChangeTheRectButItsFramesLandOnIt() throws {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let geometry = try XCTUnwrap(FocusGeometry.make(
            field: CGRect(x: 700, y: 600, width: 300, height: 30), anchor: nil,
            displayFrame: display, geometrySize: display.size))
        var view = ViewportTransform(sourceSize: display.size, canvasSize: CGSize(width: 390, height: 844), mode: .fill)
        view.setZoom(2, anchoredAt: CGPoint(x: 195, y: 422))
        let region = CaptureRegion(epoch: 3, x: 600, y: 500, width: 500, height: 300, outputWidth: 1000, outputHeight: 600)
        let frames = view.framePlacement(for: region)
        let field = view.viewRect(fromSource: geometry.rect)
        // The crop's frames are placed by the region, so the field's pixels sit exactly where its rect maps.
        let inFrame = CGRect(x: frames.minX + (geometry.x - region.x) / region.width * frames.width,
                             y: frames.minY + (geometry.y - region.y) / region.height * frames.height,
                             width: geometry.width / region.width * frames.width,
                             height: geometry.height / region.height * frames.height)
        XCTAssertEqual(field.minX, inFrame.minX, accuracy: 0.001)
        XCTAssertEqual(field.minY, inFrame.minY, accuracy: 0.001)
        XCTAssertEqual(field.width, inFrame.width, accuracy: 0.001)
    }

    // MARK: - Wire format

    func testReplyCarriesGeometryOnlyOnAnEditableProbeReply() throws {
        let probe = String(repeating: "b", count: 32)
        let rect = FocusGeometry(displayWidth: 1440, displayHeight: 900, x: 10, y: 20, width: 100, height: 24)
        let reply = RemoteAction(action: "heartbeat", epoch: 4, textFocusProbe: probe, textFocusEditable: true,
                                 textFocusRect: rect)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.textFocusRect, rect)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusProbe: probe, textFocusEditable: false,
                                              textFocusRect: rect).validate())
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusRect: rect).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", textFocusRect: rect).validate())
        var outside = rect
        outside.x = 1400
        XCTAssertThrowsError(try RemoteAction(action: "heartbeat", textFocusProbe: probe, textFocusEditable: true,
                                              textFocusRect: outside).validate())
        let json = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        for word in ["title", "label", "value", "text\":\"S"] { XCTAssertFalse(json.contains(word)) }
    }

    func testRefreshProbesRideOnlyOnTextAndKeysThatAskForGeometry() {
        let probe = String(repeating: "c", count: 32)
        let token = NativeInteraction(token: "fresh", clickCount: nil)
        XCTAssertNoThrow(try RemoteAction(action: "text", text: "hi", key: "req", epoch: 2, interaction: token,
                                          textFocusProbe: probe, textFocusGeometry: true).validate())
        XCTAssertNoThrow(try RemoteAction(action: "key", key: "return", epoch: 2, interaction: token,
                                          textFocusProbe: probe, textFocusGeometry: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "text", text: "hi", epoch: 2, interaction: token,
                                              textFocusProbe: probe).validate(),
                             "An older-style probe on text is not a refresh")
        XCTAssertThrowsError(try RemoteAction(action: "move", epoch: 2, interaction: token,
                                              textFocusProbe: probe, textFocusGeometry: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", epoch: 2, textFocusGeometry: true).validate())
        XCTAssertTrue(SessionFeature.host.contains(SessionFeature.focusGeometry))
    }

    // MARK: - Reveal math

    func testKeyboardRevealBringsTheFieldAboveTheBarWithoutZooming() throws {
        var view = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                     canvasSize: CGSize(width: 393, height: 852), mode: .fill,
                                     safeInsets: ViewportInsets(top: 59, bottom: 34))
        view.setZoom(1.6, anchoredAt: CGPoint(x: 196, y: 426))
        view.updateSafeInsets(ViewportInsets(top: 59, bottom: 336))
        let zoom = view.zoom
        let field = CGRect(x: 640, y: 760, width: 150, height: 30)
        let bar = CGRect(x: 0, y: 410, width: 393, height: 106)
        let usable = PointerFollowGeometry.usable(safeRect: view.safeRect, barTop: bar.minY)
        XCTAssertFalse(usable.contains(view.viewRect(fromSource: field)), "Precondition: the keyboard covers it")
        XCTAssertTrue(view.reveal(sourceRect: field, in: usable, margin: 16, transient: true))
        XCTAssertEqual(view.zoom, zoom, "Revealing never changes the user's zoom")
        XCTAssertTrue(usable.insetBy(dx: 15.9, dy: 15.9).contains(view.viewRect(fromSource: field)))
        XCTAssertFalse(view.reveal(sourceRect: field, in: usable, margin: 16), "A second pass is a no-op")
    }

    func testClosingTheKeyboardReturnsToThePreKeyboardViewAfterATransientReveal() {
        var view = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                     canvasSize: CGSize(width: 393, height: 852), mode: .fill,
                                     safeInsets: ViewportInsets(top: 59, bottom: 34))
        view.setZoom(1.6, anchoredAt: CGPoint(x: 196, y: 426))
        let before = (view.offset, view.zoom)
        view.updateSafeInsets(ViewportInsets(top: 59, bottom: 336))
        let usable = PointerFollowGeometry.usable(safeRect: view.safeRect, barTop: 410)
        XCTAssertTrue(view.reveal(sourceRect: CGRect(x: 640, y: 760, width: 150, height: 30), in: usable,
                                  margin: 16, transient: true))
        view.updateSafeInsets(ViewportInsets(top: 59, bottom: 34))
        XCTAssertEqual(view.offset, before.0)
        XCTAssertEqual(view.zoom, before.1)
    }

    func testRevealWorksAtFitWhereTheBarCoversTheLowerDesktop() {
        var view = ViewportTransform(sourceSize: CGSize(width: 1440, height: 900),
                                     canvasSize: CGSize(width: 852, height: 393), mode: .fit,
                                     safeInsets: ViewportInsets(left: 59, bottom: 21, right: 59))
        view.updateSafeInsets(ViewportInsets(left: 59, bottom: 200, right: 59))
        let usable = PointerFollowGeometry.usable(safeRect: view.safeRect, barTop: 110)
        let field = CGRect(x: 600, y: 840, width: 240, height: 24)
        XCTAssertTrue(view.reveal(sourceRect: field, in: usable, margin: 8))
        XCTAssertTrue(usable.contains(view.viewRect(fromSource: field)))
        XCTAssertEqual(view.zoom, 1)
    }

    func testLargeFieldShowsTheAnchoredPartAndLeadingEdgeWithoutOne() {
        let field = CGRect(x: 100, y: 100, width: 800, height: 600)
        let span = CGSize(width: 300, height: 200)
        XCTAssertEqual(FocusReveal.region(field: field, anchor: CGPoint(x: 500, y: 650), span: span),
                       CGRect(x: 350, y: 500, width: 300, height: 200))
        XCTAssertEqual(FocusReveal.region(field: field, anchor: nil, span: span),
                       CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(FocusReveal.region(field: CGRect(x: 10, y: 10, width: 50, height: 20), anchor: nil, span: span),
                       CGRect(x: 10, y: 10, width: 50, height: 20))
    }
}

/// The keyboard reveal's usable rect, built the way the session builds it from the bar's frame.
enum PointerFollowGeometry {
    static func usable(safeRect: CGRect, barTop: CGFloat) -> CGRect {
        CGRect(x: safeRect.minX, y: safeRect.minY, width: safeRect.width,
               height: max(1, min(safeRect.maxY, barTop - 12) - safeRect.minY))
    }
}
