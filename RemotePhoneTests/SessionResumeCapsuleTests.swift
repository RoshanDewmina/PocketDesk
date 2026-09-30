import XCTest
import CoreGraphics
@testable import PocketDeskRemote

@MainActor
final class SessionResumeCapsuleTests: XCTestCase {
    private let display = CGSize(width: 1440, height: 900)
    private let portrait = CGSize(width: 390, height: 844)
    private let saved = Date(timeIntervalSince1970: 1_000_000)

    private func zoomedView(mode: ViewportMode = .fill) -> ViewportTransform {
        var view = ViewportTransform(sourceSize: display, canvasSize: portrait, mode: mode)
        view.setZoom(2, anchoredAt: CGPoint(x: 195, y: 422))
        view.center(onSourcePoint: CGPoint(x: 900, y: 500))
        return view
    }

    private func capsule(_ viewport: ResumeViewport, id: UInt32? = 7, size: CGSize? = nil,
                         mac: String = "mac-a", at date: Date? = nil) -> SessionResumeCapsule {
        SessionResumeCapsule(macKey: mac, displayID: id, displaySize: size ?? display, viewport: viewport,
                             savedAt: date ?? saved)
    }

    func testAZoomedViewComesBackOnAFreshViewport() throws {
        let before = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: true))
        XCTAssertFalse(before.atBaseline)
        var fresh = ViewportTransform(sourceSize: display, canvasSize: portrait, mode: .fit)
        fresh.restore(before)
        XCTAssertEqual(fresh.mode, .fill)
        XCTAssertEqual(fresh.zoom, 2, accuracy: 0.0001)
        let after = try XCTUnwrap(fresh.resumeViewport(viewOnly: true))
        XCTAssertTrue(after.matches(before), "Same mode, zoom and centre point")
    }

    func testTheCentrePointSurvivesARotation() throws {
        let before = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false))
        var landscape = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 844, height: 390), mode: .fill)
        landscape.restore(before)
        let after = try XCTUnwrap(landscape.resumeViewport(viewOnly: false))
        XCTAssertEqual(after.focus.x, before.focus.x, accuracy: 0.001)
        XCTAssertEqual(after.focus.y, before.focus.y, accuracy: 0.001)
    }

    func testABaselineViewRestoresOnlyItsMode() throws {
        let fit = ViewportTransform(sourceSize: display, canvasSize: portrait, mode: .fit)
        let resume = try XCTUnwrap(fit.resumeViewport(viewOnly: false))
        XCTAssertTrue(resume.isDefaultView)
        var fresh = ViewportTransform(sourceSize: display, canvasSize: portrait, mode: .fill)
        fresh.restore(resume)
        XCTAssertEqual(fresh.mode, .fit)
        XCTAssertTrue(fresh.isAtBaseline, "Restoring a baseline view never turns it into a manual pan")
        XCTAssertFalse(try XCTUnwrap(fit.resumeViewport(viewOnly: true)).isDefaultView, "View mode is worth restoring")
    }

    func testTheSameMacAndDisplayRestores() throws {
        let resume = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: true))
        let decision = capsule(resume).decision(macKey: "mac-a", displayID: 7, displaySize: display,
                                                now: saved.addingTimeInterval(60), mayStillSwitchDisplay: false)
        guard case .restore(let restored) = decision else { return XCTFail("\(decision)") }
        XCTAssertTrue(restored.matches(resume))
    }

    func testAChangedDisplayGeometryVoidsTheCapsule() throws {
        let resume = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false))
        let resized = CGSize(width: 1680, height: 1050)
        XCTAssertEqual(capsule(resume).decision(macKey: "mac-a", displayID: 7, displaySize: resized,
                                                now: saved, mayStillSwitchDisplay: true), .discard)
        XCTAssertEqual(capsule(resume, id: nil).decision(macKey: "mac-a", displayID: nil, displaySize: resized,
                                                         now: saved, mayStillSwitchDisplay: false), .discard)
    }

    func testAnotherDisplayWaitsOnlyWhileTheSessionMayStillSwitch() throws {
        let resume = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false))
        let entry = capsule(resume, id: 7)
        XCTAssertEqual(entry.decision(macKey: "mac-a", displayID: 3, displaySize: display,
                                      now: saved, mayStillSwitchDisplay: true), .wait)
        XCTAssertEqual(entry.decision(macKey: "mac-a", displayID: 3, displaySize: display,
                                      now: saved, mayStillSwitchDisplay: false), .discard)
        if case .restore = entry.decision(macKey: "mac-a", displayID: nil, displaySize: display,
                                          now: saved, mayStillSwitchDisplay: false) {} else {
            XCTFail("An older Mac that names no display is matched by size")
        }
    }

    func testAnotherMacAnExpiredOrDamagedCapsuleIsDiscarded() throws {
        let resume = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false))
        XCTAssertEqual(capsule(resume).decision(macKey: "mac-b", displayID: 7, displaySize: display,
                                                now: saved, mayStillSwitchDisplay: true), .discard)
        let late = saved.addingTimeInterval(SessionResumeCapsule.lifetime + 1)
        XCTAssertEqual(capsule(resume).decision(macKey: "mac-a", displayID: 7, displaySize: display,
                                                now: late, mayStillSwitchDisplay: true), .discard)
        XCTAssertEqual(capsule(resume).decision(macKey: "mac-a", displayID: 7, displaySize: display,
                                                now: saved.addingTimeInterval(-60), mayStillSwitchDisplay: true), .discard,
                       "A clock that moved backwards is not trusted")
        var damaged = capsule(resume)
        damaged.focusX = 3
        XCTAssertNil(damaged.viewport)
        XCTAssertEqual(damaged.decision(macKey: "mac-a", displayID: 7, displaySize: display,
                                        now: saved, mayStillSwitchDisplay: false), .discard)
        damaged = capsule(resume)
        damaged.mode = "stretch"
        XCTAssertNil(damaged.viewport)
    }

    func testTheCapsuleHoldsViewportNumbersOnly() throws {
        let resume = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: true))
        let data = try JSONEncoder().encode(capsule(resume))
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = Set(try XCTUnwrap(object as? [String: Any]).keys)
        XCTAssertEqual(keys, ["macKey", "displayID", "displayWidth", "displayHeight", "mode", "zoom",
                              "focusX", "focusY", "atBaseline", "viewOnly", "savedAt"],
                       "No draft, text, input or screen content")
    }

    func testTheStoreKeepsOneCapsuleAndForgetsIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "resume-\(UUID().uuidString)"))
        let store = SessionResumeStore(defaults: defaults)
        XCTAssertNil(store.load())
        let resume = try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false))
        store.save(capsule(resume))
        XCTAssertEqual(store.load(), capsule(resume))
        store.save(nil)
        XCTAssertNil(store.load())
        defaults.set(Data("not json".utf8), forKey: SessionResumeStore.defaultsKey)
        XCTAssertNil(store.load(), "A damaged record is ignored")
    }

    func testEndingOnPurposeForgetsTheViewAndKeepsTheLocalDraft() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "resume-\(UUID().uuidString)"))
        let store = SessionResumeStore(defaults: defaults)
        store.save(capsule(try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false))))
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), resumeStore: store)
        model.draft = "unsent reply"
        model.disconnect()
        XCTAssertNil(store.load(), "End session starts the next one fresh")
        XCTAssertNil(model.viewportResume)
        XCTAssertEqual(model.draft, "unsent reply", "The draft stays on this iPhone and is never sent by itself")
    }

    func testNothingIsRecordedWithoutALiveFreshSession() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "resume-\(UUID().uuidString)"))
        let store = SessionResumeStore(defaults: defaults)
        let model = PhoneRemoteModel(background: FakeBackgroundExecution(), resumeStore: store)
        model.recordViewport(try XCTUnwrap(zoomedView().resumeViewport(viewOnly: false)))
        model.enterBackground()
        XCTAssertNil(store.load())
    }
}
