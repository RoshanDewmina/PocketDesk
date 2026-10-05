import Foundation
import CoreGraphics
import XCTest

final class NativeGestureEngineTests: XCTestCase {
    func testFollowMotionEndsOnLiftMultitouchPauseAndCancellation() {
        for ending in 0..<4 {
            let log = CommandLog()
            let input = engine(log)
            var stops = 0
            input.onPointerMotionEnded = { stops += 1 }
            input.update([touch(1, 0)], at: 1)
            input.update([touch(1, 20)], at: 1.05)
            switch ending {
            case 0: input.update([], at: 1.06)
            case 1: input.update([touch(1, 20), touch(2, 40)], at: 1.06)
            case 2:
                input.tick(at: 1.35)
                XCTAssertEqual(stops, 0, "A held finger keeps camera follow alive for a valid probe reply")
                input.update([], at: 1.36)
            default: input.cancel()
            }
            XCTAssertEqual(stops, 1)
            input.cancel()
            XCTAssertEqual(stops, 1, "Stopping an ended movement is idempotent")
        }
    }

    func testViewDoubleTapZoomsWithoutAnyMacClick() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 100, 100)], at: 1)
        input.update([], at: 1.05)
        input.update([touch(2, 102, 101)], at: 1.2)
        input.update([], at: 1.25)
        XCTAssertEqual(log.zoomToggles, [CGPoint(x: 102, y: 101)])
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertEqual(log.dragBegins, 0)
    }

    func testViewRepeatedFocusReturnThenPanNeverEmitsMacCommands() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        for base in [1.0, 2.0] {
            input.update([touch(1, 100, 100)], at: base)
            input.update([], at: base + 0.05)
            input.update([touch(2, 102, 101)], at: base + 0.2)
            input.update([], at: base + 0.25)
        }
        input.update([touch(3, 100, 100)], at: 3)
        input.update([touch(3, 170, 110)], at: 3.1)
        input.update([], at: 3.2)
        XCTAssertEqual(log.zoomToggles.count, 2)
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertTrue(log.scrollPhases.isEmpty)
        XCTAssertEqual(log.dragBegins, 0)
    }

    func testViewTwoFingerPanCanBecomePinchWithoutLifting() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 0), touch(2, 100)], at: 1)
        input.update([touch(1, 10), touch(2, 110)], at: 1.1)
        input.update([touch(1, 0), touch(2, 140)], at: 1.2)
        input.update([touch(2, 140)], at: 1.3)
        input.update([touch(2, 180)], at: 1.4)
        input.update([], at: 1.5)
        XCTAssertEqual(log.navigation.count, 2)
        XCTAssertEqual(log.navigation[0].factor, 1, accuracy: 0.001)
        XCTAssertEqual(log.navigation[0].translation.width, 10, accuracy: 0.001)
        XCTAssertEqual(log.navigation[1].factor, 1.4, accuracy: 0.001)
        XCTAssertEqual(log.navigation[1].anchor.x, 60, accuracy: 0.001)
        XCTAssertEqual(log.navigation[1].translation.width, 10, accuracy: 0.001)
        XCTAssertEqual(log.zoomEnds, 1)
        XCTAssertTrue(log.scrollPhases.isEmpty)
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testAPureViewTwoFingerPanStillEndsWithZoomEnded() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 0), touch(2, 100)], at: 1)
        input.update([touch(1, 0, 30), touch(2, 101, 30)], at: 1.05)
        input.update([touch(1, 0, 60), touch(2, 100, 60)], at: 1.1)
        input.update([], at: 1.2)
        XCTAssertEqual(log.navigation.map(\.factor), [1, 1])
        XCTAssertEqual(log.zoomEnds, 1, "the viewport settles after a pure pan as it did before the dead band")
        input.update([touch(1, 0), touch(2, 100)], at: 2)
        input.update([], at: 2.1)
        XCTAssertEqual(log.zoomEnds, 1, "a touch that never moved is not a navigation")
    }

    /// A two-finger scroll in View mode: the fingers drift apart and together by a few percent on the way.
    func testViewTwoFingerScrollWobbleDoesNotZoomUntilTheDeadBandIsCrossed() {
        for deadband in [true, false] {
            let log = CommandLog()
            let input = engine(log, enabled: false, panMode: true, zoomDeadband: deadband)
            input.update([touch(1, 0), touch(2, 100)], at: 1)
            input.update([touch(1, 0, 20), touch(2, 103, 20)], at: 1.05)
            input.update([touch(1, 0, 40), touch(2, 98, 40)], at: 1.1)
            input.update([touch(1, 0, 60), touch(2, 102, 60)], at: 1.15)
            input.update([touch(1, 0, 80), touch(2, 112, 80)], at: 1.2)
            input.update([touch(1, 0, 90), touch(2, 116, 90)], at: 1.25)
            input.update([], at: 1.3)
            XCTAssertEqual(log.navigation.count, 5, "deadband \(deadband)")
            XCTAssertEqual(log.navigation.map(\.translation.height), [20, 20, 20, 20, 10], "the pan is never held back")
            let factors = log.navigation.map(\.factor)
            if deadband {
                XCTAssertEqual(Array(factors[0..<3]), [1, 1, 1], "under 5.5 % the span is ignored")
                XCTAssertEqual(factors[3], 112.0 / 102.0, accuracy: 0.001, "the crossing zooms from the last span, no jump")
                XCTAssertEqual(factors[4], 116.0 / 112.0, accuracy: 0.001)
            } else {
                XCTAssertEqual(factors[0], 1.03, accuracy: 0.001, "the switch restores a zoom on every wobble")
                XCTAssertEqual(factors[1], 98.0 / 103.0, accuracy: 0.001)
            }
            XCTAssertEqual(log.zoomEnds, 1)
            XCTAssertTrue(log.scrollPhases.isEmpty)
        }
    }

    func testAsymmetricPinchKeepsOriginalSourceUnderMovingMidpointInControlAndView() {
        for panMode in [false, true] {
            for reversed in [false, true] {
                let log = CommandLog()
                let input = engine(log, enabled: !panMode, panMode: panMode)
                var viewport = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1080),
                                                 canvasSize: CGSize(width: 844, height: 390), mode: .fill, zoom: 1.5)
                let source = viewport.sourcePoint(fromView: CGPoint(x: 400, y: 180))!
                let leftSource = viewport.sourcePoint(fromView: CGPoint(x: 300, y: 180))!
                let rightSource = viewport.sourcePoint(fromView: CGPoint(x: 500, y: 180))!
                input.onCommand = { command in
                    let accepted = log.record(command)
                    if case .navigate(let factor, let anchor, let translation) = command {
                        // Apply the actual NativeSessionView navigation mapping, away from edge clamps.
                        viewport.setZoom(viewport.zoom * factor, anchoredAt: anchor)
                        viewport.pan(by: translation)
                    }
                    return accepted
                }
                func pair(_ left: CGFloat, _ right: CGFloat) -> [NativeGestureEngine.Touch] {
                    let contacts = [touch(1, left, 180), touch(2, right, 180)]
                    return reversed ? Array(contacts.reversed()) : contacts
                }
                input.update(pair(300, 500), at: 1)
                input.update(pair(300, 508), at: 1.03)
                XCTAssertTrue(log.navigation.isEmpty, "Ambiguous pre-recognition motion stays buffered")
                input.update(pair(300, 530), at: 1.15)
                XCTAssertEqual(log.navigation.count, 1)
                XCTAssertEqual(log.navigation.first?.anchor, CGPoint(x: 400, y: 180))
                XCTAssertEqual(log.navigation.first?.translation, CGSize(width: 15, height: 0))
                XCTAssertEqual(log.navigation.first?.factor ?? 0, 1.15, accuracy: 0.000_001)
                XCTAssertEqual(viewport.viewPoint(fromSource: source).x, 415, accuracy: 0.000_001)
                XCTAssertEqual(viewport.viewPoint(fromSource: leftSource).x, 300, accuracy: 0.000_001,
                               "The stationary finger must retain its original content")
                input.update(pair(290, 560), at: 1.18)
                XCTAssertEqual(log.navigation.count, 2)
                XCTAssertEqual(log.navigation.last?.anchor, CGPoint(x: 415, y: 180))
                XCTAssertEqual(log.navigation.last?.translation, CGSize(width: 10, height: 0))
                XCTAssertEqual(viewport.viewPoint(fromSource: source).x, 425, accuracy: 0.000_001)
                XCTAssertEqual(viewport.viewPoint(fromSource: source).y, 180, accuracy: 0.000_001)
                XCTAssertEqual(viewport.viewPoint(fromSource: leftSource).x, 290, accuracy: 0.000_001)
                XCTAssertEqual(viewport.viewPoint(fromSource: rightSource).x, 560, accuracy: 0.000_001)
                XCTAssertEqual(log.navigation.map(\.factor).reduce(1, *), 1.35, accuracy: 0.000_001)
                input.update([], at: 1.2)
                input.cancel()
                XCTAssertEqual(log.zoomEnds, 1)
                XCTAssertEqual(log.zooms, 0, "Finger pinches use midpoint navigation; hardware zoom commands stay separate")
                XCTAssertEqual(log.trace, ["navigate", "navigate", "zoomEnded"], "Pinch cannot send any remote input")
            }
        }
    }

    func testThreeFingerDirectionsFireOnceAndDoNotLeakAfterUnevenLift() {
        let paths: [(CGFloat, CGFloat, NativeSwipeDirection)] = [(-80,0,.left),(80,0,.right),(0,-80,.up),(0,80,.down)]
        for (dx,dy,direction) in paths {
            let log = CommandLog(); let input = engine(log)
            input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
            input.update([touch(1, 100+dx, 100+dy), touch(2, 130+dx, 100+dy), touch(3, 160+dx, 100+dy)], at: 1.2)
            input.update([touch(1, 100+dx*2, 100+dy*2), touch(2, 130+dx*2, 100+dy*2), touch(3, 160+dx*2, 100+dy*2)], at: 1.3)
            input.update([touch(1, 100)], at: 1.4)
            input.update([], at: 1.5)
            XCTAssertEqual(log.workspaceSwipes, [direction])
            XCTAssertTrue(log.clicks.isEmpty)
            XCTAssertTrue(log.scrollPhases.isEmpty)
            XCTAssertTrue(log.moves.isEmpty)
            XCTAssertEqual(log.clipboardCopies + log.clipboardPastes, 0)
        }
    }

    /// Symmetric radial motion around a fixed centroid; the identifiers keep their fingers.
    private func clipboardTouches(scale: CGFloat = 1, offset: CGSize = .zero) -> [NativeGestureEngine.Touch] {
        [touch(1, 140 - 50 * scale + offset.width, 140 - 30 * scale + offset.height),
         touch(2, 140 + 50 * scale + offset.width, 140 - 30 * scale + offset.height),
         touch(3, 140 + offset.width, 140 + 60 * scale + offset.height)]
    }

    func testThreeFingerPinchCopiesAndSpreadPastesWithoutZoomOrClick() {
        for scale in [CGFloat(0.6), 1.4] {
            for direct in [false, true] {
                let log = CommandLog(); let input = engine(log)
                input.configure(enabled: true, panMode: false, revision: 1, sensitivity: 1,
                                pointerScale: 1, doubleClickInterval: 0.5, direct: direct)
                input.update(Array(clipboardTouches().reversed()), at: 1)
                input.update(clipboardTouches(scale: scale, offset: CGSize(width: 3, height: -2)), at: 1.2)
                input.update([], at: 1.3)
                XCTAssertEqual(log.trace, [scale < 1 ? "clipboardCopy" : "clipboardPaste"])
                XCTAssertTrue(log.navigation.isEmpty && log.workspaceSwipes.isEmpty)
                XCTAssertEqual(log.zoomEnds, 0)
                XCTAssertEqual(log.middle, 0)
            }
        }
    }

    func testThreeFingerClipboardRequiresRadialTravelBeyondSettlingJitter() {
        let log = CommandLog(); let input = engine(log)
        input.update(clipboardTouches(), at: 1)
        input.update(clipboardTouches(scale: 0.92), at: 1.1)
        input.update([], at: 1.2)
        XCTAssertEqual(log.clipboardCopies + log.clipboardPastes, 0)
        XCTAssertEqual(log.middle, 1, "Small finger settling remains a three-finger tap")
    }

    func testThreeFingerClipboardDoesNotReinterpretUnequalParallelSwipeOrRotation() {
        let samples = [
            [touch(1, 170, 110), touch(2, 290, 110), touch(3, 260, 200)],
            // Same shape rotated clockwise around its centroid: no radial scaling.
            [touch(1, 170, 90), touch(2, 170, 190), touch(3, 80, 140)],
            // One wandering finger cannot act for the other two.
            [touch(1, 140, 140), touch(2, 190, 110), touch(3, 140, 200)]
        ]
        for (index, points) in samples.enumerated() {
            let log = CommandLog(); let input = engine(log)
            input.update(clipboardTouches(), at: 1)
            input.update(points, at: 1.2)
            input.update([], at: 1.3)
            XCTAssertEqual(log.clipboardCopies + log.clipboardPastes, 0)
            XCTAssertEqual(log.middle, 0)
            XCTAssertEqual(log.workspaceSwipes, index == 0 ? [.right] : [])
        }
    }

    func testThreeFingerClipboardFiresOnceEvenWhenRejectedReversedOrFingersReplaced() {
        for accepted in [false, true] {
            let log = CommandLog(); log.acceptClipboard = accepted
            let input = engine(log)
            input.update(clipboardTouches(), at: 1)
            input.update(clipboardTouches(scale: 0.6), at: 1.1)
            input.update(clipboardTouches(scale: 1.5), at: 1.2)
            input.update(clipboardTouches(offset: CGSize(width: 90, height: 0)), at: 1.3)
            input.update([touch(1, 140), touch(2, 150)], at: 1.35)
            input.update([touch(1, 140), touch(2, 150), touch(4, 300)], at: 1.4)
            input.update([touch(4, 350)], at: 1.45)
            input.update([], at: 1.5)
            XCTAssertEqual(log.trace, ["clipboardCopy"], "The same contact sequence never retries a rejected command")
        }
    }

    func testThreeFingerClipboardResetsAfterEveryFingerLifts() {
        let log = CommandLog(); let input = engine(log)
        input.update(clipboardTouches(), at: 1)
        input.update(clipboardTouches(scale: 0.6), at: 1.1)
        input.update([], at: 1.2)
        input.update(clipboardTouches(), at: 2)
        input.update(clipboardTouches(scale: 1.4), at: 2.1)
        input.update([], at: 2.2)
        XCTAssertEqual(log.trace, ["clipboardCopy", "clipboardPaste"])
    }

    func testThreeFingerClipboardCancelAndRevisionBlockSurvivingContacts() {
        for ending in 0..<3 {
            let log = CommandLog(); let input = engine(log)
            input.update(clipboardTouches(), at: 1)
            if ending == 0 { input.cancel() }
            else if ending == 1 { input.update(clipboardTouches(), at: 1.05, cancelled: true) }
            else {
                input.configure(enabled: true, panMode: false, revision: 2, sensitivity: 1,
                                pointerScale: 1, doubleClickInterval: 0.5)
            }
            input.update(clipboardTouches(scale: 0.6), at: 1.1)
            input.update([], at: 1.2)
            XCTAssertTrue(log.trace.isEmpty)
            input.update(clipboardTouches(), at: 2)
            input.update(clipboardTouches(scale: 1.4), at: 2.1)
            input.update([], at: 2.2)
            XCTAssertEqual(log.trace, ["clipboardPaste"])
        }
    }

    func testCancelledThreeFingerTapCannotMiddleClick() {
        let log = CommandLog(); let input = engine(log)
        input.update(clipboardTouches(), at: 1)
        input.cancel()
        input.update([], at: 1.1)
        XCTAssertTrue(log.trace.isEmpty)
    }

    func testThreeFingerClipboardRequiresControlAndCannotTakeOverAnExistingPinch() {
        for (enabled, pan) in [(false, false), (true, true)] {
            let log = CommandLog(); let input = engine(log, enabled: enabled, panMode: pan)
            input.update(clipboardTouches(), at: 1)
            input.update(clipboardTouches(scale: 0.6), at: 1.1)
            input.update([], at: 1.2)
            XCTAssertTrue(log.trace.isEmpty)
        }
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 90, 110), touch(2, 190, 110)], at: 1)
        input.update([touch(1, 70, 110), touch(2, 210, 110)], at: 1.1)
        input.update(clipboardTouches(), at: 1.15)
        input.update(clipboardTouches(scale: 0.6), at: 1.2)
        input.update([], at: 1.3)
        XCTAssertEqual(log.navigation.count, 1, "Two-finger zoom retains its original ownership")
        XCTAssertEqual(log.zoomEnds, 1)
        XCTAssertEqual(log.clipboardCopies + log.clipboardPastes, 0)
    }

    func testThreeFingerClipboardKillSwitchDefaultsEnabledAndKeepsSwipesAndMiddleTap() throws {
        let suite = "NativeGestureClipboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = CommandLog(); let input = engine(log)
        input.clipboardGesturesEnabled = { !defaults.bool(forKey: NativeGestureEngine.clipboardGesturesDisabledKey) }
        input.update(clipboardTouches(), at: 1)
        input.update(clipboardTouches(scale: 0.6), at: 1.1)
        input.update([], at: 1.2)
        XCTAssertEqual(log.clipboardCopies, 1, "Missing defaults key enables the gesture")
        defaults.set(true, forKey: NativeGestureEngine.clipboardGesturesDisabledKey)
        input.update(clipboardTouches(), at: 2)
        input.update(clipboardTouches(scale: 1.4), at: 2.1)
        input.update([], at: 2.2)
        XCTAssertEqual(log.clipboardPastes, 0)
        input.update(clipboardTouches(), at: 3)
        input.update(clipboardTouches(offset: CGSize(width: 80, height: 0)), at: 3.1)
        input.update([], at: 3.2)
        input.update(clipboardTouches(), at: 4)
        input.update([], at: 4.1)
        XCTAssertEqual(log.workspaceSwipes, [.right])
        XCTAssertEqual(log.middle, 1)
    }

    func testAThreeFingerSwipeFiresOnceHoweverLongOrFarTheFingersKeepGoing() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 100), touch(2, 130, 100), touch(3, 160, 100)], at: 1)
        input.update([touch(1, 20, 100), touch(2, 50, 100), touch(3, 80, 100)], at: 1.15)
        XCTAssertEqual(log.workspaceSwipes, [.left])
        // Keep sliding, reverse past the origin, pause well past the gesture window, slide again.
        input.update([touch(1, -60, 100), touch(2, -30, 100), touch(3, 0, 100)], at: 1.3)
        input.update([touch(1, 200, 100), touch(2, 230, 100), touch(3, 260, 100)], at: 1.5)
        input.update([touch(1, 200, 100), touch(2, 230, 100), touch(3, 260, 100)], at: 2.6)
        input.update([touch(1, 300, 100), touch(2, 330, 100), touch(3, 360, 100)], at: 2.8)
        input.update([touch(1, 300, 100), touch(2, 330, 100)], at: 2.9)
        input.update([touch(1, 300, 100)], at: 2.95)
        input.update([], at: 3)
        XCTAssertEqual(log.workspaceSwipes, [.left], "One gesture, one shortcut")
        XCTAssertEqual(log.middle, 0)
        XCTAssertTrue(log.clicks.isEmpty && log.moves.isEmpty && log.scrollPhases.isEmpty)
        // The next gesture is a new one.
        input.update([touch(4, 100, 100), touch(5, 130, 100), touch(6, 160, 100)], at: 4)
        input.update([touch(4, 180, 100), touch(5, 210, 100), touch(6, 240, 100)], at: 4.15)
        input.update([], at: 4.3)
        XCTAssertEqual(log.workspaceSwipes, [.left, .right])
    }

    func testThreeFingerGestureRequiresControlAndRejectsIncoherentMovement() {
        for (enabled, pan) in [(false,false), (true,true)] {
            let log = CommandLog(); let input = engine(log, enabled: enabled, panMode: pan)
            input.update([touch(1, 0), touch(2, 30), touch(3, 60)], at: 1)
            input.update([touch(1, 90), touch(2, 120), touch(3, 150)], at: 1.2)
            input.update([], at: 1.3)
            XCTAssertTrue(log.workspaceSwipes.isEmpty)
        }
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0), touch(2, 30), touch(3, 60)], at: 1)
        input.update([touch(1, 210), touch(2, 30), touch(3, 60)], at: 1.2)
        input.update([], at: 1.3)
        XCTAssertTrue(log.workspaceSwipes.isEmpty, "One moving finger is not a workspace swipe")
    }

    func testAddingThirdFingerAfterScrollingCannotSwitchSpaces() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0), touch(2, 30)], at: 1)
        input.update([touch(1, 0, 20), touch(2, 30, 20)], at: 1.1)
        input.update([touch(1, 0, 20), touch(2, 30, 20), touch(3, 60, 20)], at: 1.15)
        input.update([touch(1, 90, 20), touch(2, 120, 20), touch(3, 150, 20)], at: 1.25)
        input.update([], at: 1.3)
        XCTAssertTrue(log.workspaceSwipes.isEmpty)
        XCTAssertEqual(log.scrollPhases, ["began", "cancelled"])
    }

    func testRevisionCancelsPendingWorkspaceSwipe() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0), touch(2, 30), touch(3, 60)], at: 1)
        input.configure(enabled: true, panMode: false, revision: 2, sensitivity: 1, pointerScale: 1, doubleClickInterval: 0.5)
        input.update([touch(1, 90), touch(2, 120), touch(3, 150)], at: 1.2)
        input.update([], at: 1.3)
        XCTAssertTrue(log.workspaceSwipes.isEmpty)
    }

    func testStaggeredThreeFingerLandingWithDriftStillFiresEveryDirection() {
        let paths: [(CGFloat, CGFloat, NativeSwipeDirection)] = [(-80,0,.left),(80,0,.right),(0,-80,.up),(0,80,.down)]
        for secondAndThirdTogether in [true, false] {
            for (dx, dy, direction) in paths {
                let log = CommandLog(); let input = engine(log)
                input.update([touch(1, 100, 300)], at: 1)
                input.update([touch(1, 106, 300)], at: 1.03)
                if !secondAndThirdTogether {
                    input.update([touch(1, 106, 300), touch(2, 140, 290)], at: 1.06)
                }
                input.update([touch(1, 106, 300), touch(2, 140, 290), touch(3, 175, 305)], at: 1.1)
                input.update([touch(1, 106+dx, 300+dy), touch(2, 140+dx, 290+dy), touch(3, 175+dx, 305+dy)], at: 1.25)
                input.update([], at: 1.3)
                XCTAssertEqual(log.workspaceSwipes, [direction],
                               "first finger drifted 6 pt, then \(secondAndThirdTogether ? "two fingers landed together" : "one at a time")")
                XCTAssertTrue(log.clicks.isEmpty)
            }
        }
    }

    func testTwoFingersThatBarelyStartedScrollingCanBecomeASwipe() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300), touch(2, 140, 300)], at: 1)
        input.update([touch(1, 106, 300), touch(2, 146, 300)], at: 1.04)
        input.update([touch(1, 106, 300), touch(2, 146, 300), touch(3, 180, 300)], at: 1.08)
        input.update([touch(1, 186, 300), touch(2, 226, 300), touch(3, 260, 300)], at: 1.25)
        input.update([], at: 1.3)
        XCTAssertEqual(log.workspaceSwipes, [.right])
        XCTAssertEqual(log.scrollPhases, ["began", "cancelled"], "The 6 pt scroll is closed, not left open")
    }

    func testThirdFingerAfterTheLandingWindowCannotSwitchSpaces() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300), touch(2, 140, 300)], at: 1)
        input.update([touch(1, 100, 300), touch(2, 140, 300), touch(3, 180, 300)], at: 1.3)
        input.update([touch(1, 180, 300), touch(2, 220, 300), touch(3, 260, 300)], at: 1.45)
        input.update([], at: 1.5)
        XCTAssertTrue(log.workspaceSwipes.isEmpty)
    }

    func testScrollThatStartsWithASmallSplayIsNotTakenForAPinch() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0, 100), touch(2, 60, 100)], at: 1)
        input.update([touch(1, 0, 92), touch(2, 64, 92)], at: 1.02)
        input.update([touch(1, 0, 84), touch(2, 66, 84)], at: 1.04)
        input.update([touch(1, 0, 70), touch(2, 66, 70)], at: 1.06)
        input.update([], at: 1.1)
        XCTAssertEqual(log.navigation.count, 0)
        XCTAssertEqual(log.scrollPhases.first, "began")
        XCTAssertEqual(log.scrollPhases.last, "ended")

        let pinchLog = CommandLog(); let pinch = engine(pinchLog)
        pinch.update([touch(1, 0, 100), touch(2, 60, 100)], at: 2)
        pinch.update([touch(1, -6, 101), touch(2, 67, 99)], at: 2.02)
        pinch.update([], at: 2.1)
        XCTAssertEqual(pinchLog.navigation.count, 1, "Fingers moving apart still pinch")
        XCTAssertTrue(pinchLog.scrollPhases.isEmpty)
    }

    func testCloseFingersCanScroll() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0, 100), touch(2, 30, 100)], at: 1)
        input.update([touch(1, 0, 94), touch(2, 33, 94)], at: 1.02)
        input.update([touch(1, 0, 80), touch(2, 33, 80)], at: 1.04)
        input.update([], at: 1.1)
        XCTAssertEqual(log.navigation.count, 0, "A 3 pt splay on a 30 pt span is 10% but not a pinch")
        XCTAssertEqual(log.scrollPhases, ["began", "changed", "ended"])
    }

    func testUnequalParallelFingerMotionScrollsAtCloseSkewedAndThumbSpacings() {
        let offsets: [CGPoint] = [CGPoint(x: 0, y: 30), CGPoint(x: 12, y: 0),
                                 CGPoint(x: 6, y: 18), CGPoint(x: 280, y: 50)]
        for offset in offsets {
            for reversed in [false, true] {
                let log = CommandLog(); let input = engine(log)
                func pair(_ firstY: CGFloat, _ secondY: CGFloat, jitter: CGFloat = 0) -> [NativeGestureEngine.Touch] {
                    let touches = [touch(1, 100, 100 + firstY),
                                   touch(2, 100 + offset.x + jitter, 100 + offset.y + secondY)]
                    return reversed ? Array(touches.reversed()) : touches
                }
                input.update(pair(0, 0), at: 1)
                // The physical one-hand regression: both fingers move down, one leads by 11pt.
                // On the 30pt vertical span the old span/centroid test immediately chose pinch.
                input.update(pair(12, 1), at: 1.02)
                XCTAssertEqual(log.navigation.count, 0, "Parallel lead must not zoom: \(offset), reversed \(reversed)")
                input.tick(at: 1.17)
                XCTAssertEqual(log.navigation.count, 0, "A pause with aligned finger motion must retain scroll intent")
                input.update(pair(24, 9, jitter: 2), at: 1.2)
                input.update(pair(36, 24, jitter: -2), at: 1.22)
                input.update([], at: 1.25)
                XCTAssertEqual(log.navigation.count, 0)
                XCTAssertEqual(log.scrollPhases.first, "began")
                XCTAssertEqual(log.scrollPhases.last, "ended")
                XCTAssertEqual(log.scrollPhases.filter { $0 == "began" }.count, 1)
                XCTAssertEqual(log.scrollDeltas.reduce(0) { $0 + $1.height }, 30, accuracy: 0.001,
                               "Include all centroid travel when the scroll is recognized")
                XCTAssertTrue(log.clicks.isEmpty)
                XCTAssertEqual(log.secondary, 0)
            }
        }
    }

    func testStaggeredFingerLandingAndMotionDoNotTurnParallelScrollIntoPinch() {
        let identifiers: [UInt64] = [1, 2]
        for firstID in identifiers {
            let secondID: UInt64 = firstID == 1 ? 2 : 1
            let log = CommandLog(); let input = engine(log)
            input.update([touch(firstID, 100, 100)], at: 1)
            input.update([touch(firstID, 100, 101), touch(secondID, 100, 130)], at: 1.01)
            // Separate contact updates, as when one finger moves before its partner.
            input.update([touch(firstID, 100, 113), touch(secondID, 100, 130)], at: 1.03)
            XCTAssertEqual(log.navigation.count, 0)
            input.update([touch(firstID, 100, 113), touch(secondID, 100, 134)], at: 1.04)
            input.update([touch(firstID, 100, 125), touch(secondID, 100, 145)], at: 1.06)
            input.update([], at: 1.1)
            XCTAssertEqual(log.navigation.count, 0)
            XCTAssertEqual(log.scrollPhases, ["began", "changed", "ended"])
            XCTAssertTrue(log.clicks.isEmpty)
        }
    }

    func testAnchoredPinchWaitsForIntentThenKeepsItsFullScaleInEitherTouchOrder() {
        for firstIsAnchor in [false, true] {
            let directions: [CGFloat] = [-1, 1]
            for direction in directions {
                let log = CommandLog(); let input = engine(log)
                let anchorID: UInt64 = firstIsAnchor ? 1 : 2
                let movingID: UInt64 = firstIsAnchor ? 2 : 1
                func pair(_ movement: CGFloat) -> [NativeGestureEngine.Touch] {
                    [touch(anchorID, 100, 100), touch(movingID, 100 + direction * (60 + movement), 100)]
                }
                let first = firstIsAnchor ? touch(anchorID, 100, 100) : touch(movingID, 100 + direction * 60, 100)
                input.update([first], at: 1)
                input.update(pair(0), at: 1.01)
                input.update(pair(8), at: 1.03)
                XCTAssertEqual(log.navigation.count, 0, "A first-finger lead is ambiguous until anchored intent settles")
                input.update(pair(18), at: 1.15)
                input.update(pair(24), at: 1.18)
                input.update([touch(anchorID, 100, 100)], at: 1.19)
                input.update([], at: 1.2)
                XCTAssertEqual(log.navigation.count, 2, "An intentional stationary-finger pinch remains available")
                XCTAssertEqual(log.navigation.map(\.factor).reduce(1, *), 1.4, accuracy: 0.001)
                XCTAssertEqual(log.zoomEnds, 1)
                XCTAssertTrue(log.scrollPhases.isEmpty)
                XCTAssertTrue(log.clicks.isEmpty)
                XCTAssertEqual(log.secondary, 0)
            }
        }
    }

    func testOpposingFingerPinchesWorkVerticallyAndWithAReverseTouchOrder() {
        for reversed in [false, true] {
            let log = CommandLog(); let input = engine(log)
            let start = [touch(1, 100, 100), touch(2, 100, 130)]
            let spread = [touch(1, 101, 94), touch(2, 99, 137)]
            input.update(reversed ? Array(start.reversed()) : start, at: 1)
            input.update(reversed ? Array(spread.reversed()) : spread, at: 1.02)
            input.update([], at: 1.1)
            XCTAssertEqual(log.navigation.count, 1)
            XCTAssertEqual(log.zoomEnds, 1)
            XCTAssertTrue(log.scrollPhases.isEmpty)
            XCTAssertTrue(log.clicks.isEmpty)
        }
    }

    func testAnchoredPinchSettlesWhileHeldAndEndsOnceOnCancellation() {
        let directions: [CGFloat] = [-1, 1]
        for direction in directions {
            let log = CommandLog(); let input = engine(log)
            input.update([touch(1, 100, 100), touch(2, 160, 100)], at: 1)
            input.update([touch(1, 100, 100), touch(2, 160 + direction * 18, 100)], at: 1.02)
            input.tick(at: 1.08)
            XCTAssertEqual(log.navigation.count, 0)
            input.tick(at: 1.15)
            XCTAssertEqual(log.navigation.count, 1, "An anchored pinch settles without needing another motion event")
            XCTAssertEqual(log.navigation.map(\.factor).first ?? 0, (60 + direction * 18) / 60, accuracy: 0.001)
            input.cancel()
            input.tick(at: 1.2)
            input.update([touch(1, 100, 100), touch(2, 200, 100)], at: 1.3)
            input.update([], at: 1.4)
            input.cancel()
            XCTAssertEqual(log.navigation.count, 1)
            XCTAssertEqual(log.zoomEnds, 1)
            XCTAssertTrue(log.scrollPhases.isEmpty)
            XCTAssertTrue(log.clicks.isEmpty)
        }
    }

    func testRecognizedScrollCannotTurnIntoZoomAndEndsOnceAcrossInterruptions() {
        for ending in 0..<3 {
            let log = CommandLog(); let input = engine(log)
            input.update([touch(1, 100, 100), touch(2, 130, 100)], at: 1)
            input.update([touch(1, 100, 112), touch(2, 130, 110)], at: 1.02)
            // Even strong subsequent separation cannot steal an established scroll's intent.
            input.update([touch(1, 80, 125), touch(2, 150, 120)], at: 1.04)
            switch ending {
            case 0:
                input.update([touch(2, 150, 120)], at: 1.06)
            case 1: input.cancel()
            default:
                input.configure(enabled: true, panMode: false, revision: 2,
                                sensitivity: 1, pointerScale: 1, doubleClickInterval: 0.5)
            }
            input.update([touch(2, 150, 145)], at: 1.08)
            input.update([], at: 1.1)
            input.cancel()
            XCTAssertEqual(log.navigation.count, 0)
            XCTAssertEqual(log.scrollPhases, ["began", "changed", ending == 0 ? "ended" : "cancelled"])
            XCTAssertTrue(log.clicks.isEmpty)
            XCTAssertEqual(log.secondary, 0)
        }
    }

    func testScrollDistanceIsInMacPointsAtTheCurrentZoom() {
        let log = CommandLog(); let input = engine(log, scale: 0.5)
        input.update([touch(1, 0, 100), touch(2, 40, 100)], at: 1)
        input.update([touch(1, 0, 110), touch(2, 40, 110)], at: 1.02)
        input.update([touch(1, 0, 120), touch(2, 40, 120)], at: 1.04)
        input.update([], at: 1.1)
        XCTAssertEqual(log.scrollDeltas.reduce(0) { $0 + $1.height }, 40, accuracy: 0.001,
                       "20 pt of finger travel over a half-size picture scrolls 40 Mac points")
    }

    func testRestingFingersKeepTheScrollStreamAliveUntilTheyMoveAgain() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 0, 100), touch(2, 40, 100)], at: 1)
        input.update([touch(1, 0, 110), touch(2, 40, 110)], at: 1.02)
        input.tick(at: 1.2)
        input.tick(at: 1.28)
        input.tick(at: 1.4)
        input.tick(at: 1.54)
        input.update([touch(1, 0, 120), touch(2, 40, 120)], at: 1.6)
        input.tick(at: 1.7)
        input.update([], at: 1.72)
        XCTAssertEqual(log.scrollPhases, ["began", "changed", "changed", "changed", "ended"])
        XCTAssertEqual(log.scrollDeltas.map(\.height), [10, 0, 0, 10, 0], "Keep-alives carry no distance")
    }

    // MARK: Touch-down landing roll

    /// A finger landing at 120 Hz: it rolls `roll` points (most of it early, as the pad
    /// flattens) over `frames` samples, then rests for `rest` samples.
    private func land(_ input: NativeGestureEngine, id: UInt64, at start: TimeInterval, x: CGFloat,
                      roll: CGFloat, frames: Int = 5, rest: Int = 20) -> TimeInterval {
        var time = start
        for index in 0...(frames + rest) {
            let fraction = CGFloat(min(index, frames)) / CGFloat(frames)
            let eased = 1 - (1 - fraction) * (1 - fraction)
            time = start + Double(index) / 120
            input.update([touch(id, x + roll * eased, 300 + roll * 0.3 * eased)], at: time)
        }
        return time
    }

    /// Frame-analysed on Roshan's phone (29 Sep, 240 fps clip): at a touch-down ~150 ms after a
    /// tap, the pointer jumped most of a small button's width in ~60 ms with no deliberate slide.
    /// The landing roll crossed the 4 pt motion threshold and was sent in one burst through the
    /// speed gain. It must be absorbed, and the touch must still click.
    func testLandingRollDoesNotMoveThePointerAndStillClicks() {
        for scale in [CGFloat(1), 0.27] {
            let log = CommandLog(); let input = engine(log, scale: scale)
            input.update([touch(1, 100, 300)], at: 1)
            input.update([], at: 1.02)
            let end = land(input, id: 2, at: 1.17, x: 160, roll: 7)
            input.update([], at: end + 0.01)
            XCTAssertTrue(log.moves.isEmpty, "A 7 pt landing roll moved the pointer \(log.moves) at view scale \(scale)")
            XCTAssertEqual(log.clicks, [1, 1], "Both touches are clicks")
        }
    }

    func testSlideAfterALandingRollStartsSmoothly() {
        let log = CommandLog(); let input = engine(log)
        var time = land(input, id: 1, at: 1, x: 100, roll: 7, rest: 2)
        for step in 1...36 {
            time += 1.0 / 120
            input.update([touch(1, 107 + CGFloat(step) * 30 / 36, 302.1)], at: time)
        }
        input.update([], at: time + 0.01)
        let largest = log.moves.map { hypot($0.width, $0.height) }.max() ?? 0
        XCTAssertLessThan(largest, 1.5, "No burst when the slide starts: \(log.moves.prefix(3))")
        let travel = log.moves.reduce(0) { $0 + $1.width }
        XCTAssertGreaterThan(travel, 12, "The slide itself still moves the pointer")
        XCTAssertLessThan(travel, 20, "…but the roll before it adds nothing")
    }

    func testQuickFlickStillMovesFromTheFirstFrames() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300)], at: 1)
        for step in 1...6 { input.update([touch(1, 100 + CGFloat(step) * 6, 300)], at: 1 + Double(step) / 120) }
        input.update([], at: 1.06)
        XCTAssertFalse(log.moves.isEmpty, "36 pt in 50 ms is deliberate, not a roll")
        XCTAssertGreaterThan(log.moves.reduce(0) { $0 + $1.width }, 30, "Only the 8 pt landing slop is left out")
    }

    func testDoubleTapHoldDragStartsWithoutAJump() {
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 100, 300)], at: 1)
        input.update([], at: 1.04)
        // Second touch 150 ms later, 3 pt away, rolls 7 pt and rests: a double-tap-and-hold.
        let start = 1.19
        for index in 0...5 {
            let eased = 1 - pow(1 - CGFloat(index) / 5, 2)
            input.update([touch(2, 103 + 7 * eased, 300)], at: start + Double(index) / 120)
        }
        input.tick(at: start + 0.25)
        XCTAssertEqual(log.dragBegins, 1)
        input.update([touch(2, 110.2, 300)], at: start + 0.26)
        let atStart = log.moves.map { hypot($0.width, $0.height) }.max() ?? 0
        XCTAssertLessThan(atStart, 1, "The held item does not jump by the landing roll: \(log.moves)")
        input.update([touch(2, 130.2, 300)], at: start + 0.36)
        input.update([], at: start + 0.4)
        XCTAssertGreaterThan(log.moves.reduce(0) { $0 + $1.width }, 5, "Sliding then drags it")
        XCTAssertEqual(log.dragEnds, 1)
    }

    private func touch(_ id: UInt64, _ x: CGFloat, _ y: CGFloat = 0) -> NativeGestureEngine.Touch {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    private func engine(_ commands: CommandLog, enabled: Bool = true,
                        panMode: Bool = false, scale: CGFloat = 1, zoomDeadband: Bool = true) -> NativeGestureEngine {
        let input = NativeGestureEngine(enabled: enabled, panMode: panMode, revision: 1,
                            sensitivity: 1, pointerScale: scale,
                            doubleClickInterval: 0.5, zoomDeadband: zoomDeadband,
                            onCommand: { commands.record($0) })
        input.clipboardGesturesEnabled = { true }
        return input
    }

    func testPointerMotionCannotBecomeClickAndHasNoClutchJump() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 20)], at: 1.05)
        input.update([], at: 1.06)
        input.update([touch(2, 100)], at: 2)
        input.update([touch(2, 110)], at: 2.05)
        input.update([], at: 2.06)
        XCTAssertEqual(log.clicks, [])
        XCTAssertEqual(log.moves.count, 2)
        XCTAssertTrue(log.moves.allSatisfy { $0.width > 0 && $0.width < 60 })
    }

    func testImmediateSingleThenSecondTapCountTwo() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 10)], at: 1)
        input.update([], at: 1.04)
        input.update([touch(2, 12)], at: 1.2)
        input.update([], at: 1.25)
        input.update([touch(3, 12)], at: 1.35)
        input.update([], at: 1.4)
        XCTAssertEqual(log.clicks, [1, 2, 1])
    }

    func testStaggeredSecondaryAndNoPrimaryAfterPinchOrScroll() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 0), touch(2, 20)], at: 1.05)
        input.update([touch(2, 20)], at: 1.10)
        input.update([], at: 1.15)
        XCTAssertEqual(log.secondary, 1)
        XCTAssertEqual(log.clicks, [])

        input.update([touch(3, 0), touch(4, 20)], at: 2)
        input.update([touch(3, -8), touch(4, 28)], at: 2.02)
        input.update([touch(4, 28)], at: 2.04)
        input.update([], at: 2.06)
        XCTAssertEqual(log.navigation.count, 1)
        XCTAssertEqual(log.secondary, 1)
        XCTAssertEqual(log.clicks, [])

        input.update([touch(5, 0), touch(6, 20)], at: 3)
        input.update([touch(5, 0, 10), touch(6, 20, 10)], at: 3.02)
        input.update([touch(6, 20, 10)], at: 3.04)
        input.update([], at: 3.06)
        XCTAssertEqual(log.scrollPhases, ["began", "ended"])
        XCTAssertEqual(log.clicks, [])
    }

    func testRemainingFingerMovementInvalidatesSecondary() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0), touch(2, 20)], at: 1)
        input.update([touch(2, 20)], at: 1.02)
        input.update([touch(2, 40)], at: 1.04)
        input.update([], at: 1.06)
        XCTAssertEqual(log.secondary, 0)
    }

    func testPinchOwnershipSurvivesFingerReplacementUntilAllLift() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0), touch(2, 20)], at: 1)
        input.update([touch(1, -8), touch(2, 28)], at: 1.02)
        input.update([touch(2, 28)], at: 1.04)
        input.update([touch(2, 28), touch(3, 40)], at: 1.06)
        input.update([touch(3, 40)], at: 1.08)
        input.update([], at: 1.1)
        XCTAssertEqual(log.navigation.count, 1)
        XCTAssertEqual(log.zoomEnds, 1, "A pinch settles exactly once, however its fingers lift")
        XCTAssertEqual(log.secondary, 0)
        XCTAssertEqual(log.clicks, [])
    }

    func testDoubleTapHoldDragsAndReleasesOnceOnEndOrCancellation() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([], at: 1.02)
        input.update([touch(2, 0)], at: 1.12)
        input.tick(at: 1.35)
        input.update([touch(2, 15)], at: 1.38)
        input.update([], at: 1.4)
        XCTAssertEqual(log.clicks, [1])
        XCTAssertEqual(log.dragBegins, 1)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.moves.count, 1)

        input.update([touch(3, 0)], at: 2)
        input.update([], at: 2.02)
        input.update([touch(4, 0)], at: 2.12)
        input.tick(at: 2.35)
        input.cancel()
        input.update([], at: 2.4)
        XCTAssertEqual(log.dragBegins, 2)
        XCTAssertEqual(log.dragEnds, 2)
        XCTAssertEqual(log.clicks, [1, 1])
    }

    func testTitleBarDoubleTapHoldOwnsHorizontalMovementUntilLift() {
        // The Mac pointer already rests on a title bar. These are phone contact points,
        // so holding the second tap must press before relative window-drag movement.
        let log = CommandLog(); let input = engine(log)
        input.update([touch(1, 140, 220)], at: 1)
        input.update([], at: 1.04)
        input.update([touch(2, 142, 220)], at: 1.14)
        input.update([touch(2, 143, 220)], at: 1.18)
        input.tick(at: 1.38)
        input.tick(at: 1.9)
        XCTAssertEqual(log.trace, ["click1", "dragBegan2"])
        input.update([touch(2, 163, 220)], at: 2)
        input.update([touch(2, 193, 220)], at: 2.05)
        input.update([], at: 2.1)
        input.cancel()
        XCTAssertEqual(log.trace, ["click1", "dragBegan2", "move", "move", "dragEnded"])
        XCTAssertTrue(log.moves.allSatisfy { $0.width > 0 && $0.height == 0 })
        XCTAssertEqual(log.dragBeginIDs, log.dragEndIDs, "Release the same admitted button hold exactly once")
        XCTAssertEqual(log.dragCounts, [2])
        XCTAssertEqual(log.secondary, 0)
        XCTAssertTrue(log.scrollPhases.isEmpty)
    }

    func testRejectedDragBeginCannotEmitMoveOrRelease() {
        let log = CommandLog()
        log.acceptDrag = false
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([], at: 1.02)
        input.update([touch(2, 0)], at: 1.1)
        input.tick(at: 1.35)
        input.update([touch(2, 20)], at: 1.4)
        input.update([], at: 1.5)
        XCTAssertEqual(log.dragBegins, 1)
        XCTAssertEqual(log.dragEnds, 0)
        XCTAssertEqual(log.moves.count, 0)
        XCTAssertEqual(log.clicks, [1])
    }

    func testRevisionCancelsDragAndRequiresAllFingersToLift() {
        let log = CommandLog()
        let input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([], at: 1.02)
        input.update([touch(2, 0)], at: 1.1)
        input.tick(at: 1.35)
        input.configure(enabled: true, panMode: false, revision: 2,
                        sensitivity: 1, pointerScale: 1, doubleClickInterval: 0.5)
        input.update([touch(2, 20)], at: 1.4)
        input.update([], at: 1.5)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.clicks, [1])
        XCTAssertEqual(log.moves.count, 0)
    }

    func testGainUsesVelocityAndScaleIndependentOfCallbackRate() {
        func travel(steps: Int, scale: CGFloat = 1) -> CGFloat {
            let log = CommandLog()
            let input = engine(log, scale: scale)
            input.update([touch(1, 0)], at: 1)
            for i in 1...steps {
                input.update([touch(1, CGFloat(i) * 80 / CGFloat(steps))],
                             at: 1 + Double(i) * 0.2 / Double(steps))
            }
            input.update([], at: 1.21)
            return log.moves.reduce(0) { $0 + $1.width }
        }
        XCTAssertEqual(travel(steps: 4), travel(steps: 20), accuracy: 0.04)
        XCTAssertEqual(travel(steps: 20, scale: 2) * 2, travel(steps: 20), accuracy: 0.04)
    }

    func testCoalescedSingleFingerPreservesVariableSpeedAndReversalPath() {
        let samples: [NativeGestureEngine.MotionSample] = [
            .init(point: CGPoint(x: 12, y: 0), time: 1.01),
            .init(point: CGPoint(x: 28, y: 0), time: 1.02),
            .init(point: CGPoint(x: 20, y: 0), time: 1.03),
            .init(point: CGPoint(x: 19, y: 0), time: 1.04)
        ]
        let individual = CommandLog(), batched = CommandLog()
        let first = engine(individual), second = engine(batched)
        first.update([touch(1, 0)], at: 1)
        second.update([touch(1, 0)], at: 1)
        for sample in samples { first.update([.init(id: 1, point: sample.point)], at: sample.time) }
        second.updateCoalescedMotion(id: 1, samples: samples, final: samples.last!)
        XCTAssertEqual(individual.moves, batched.moves)
        XCTAssertEqual(batched.moves.count, 4)
        XCTAssertTrue(batched.moves.contains { $0.width < 0 })
        XCTAssertEqual(batched.clicks, [])
    }

    func testCoalescedMotionRejectsOldSamplesAndContactReplacementOrMultiTouch() {
        let log = CommandLog(), input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 20)], at: 1.02)
        let count = log.moves.count
        let old = NativeGestureEngine.MotionSample(point: CGPoint(x: 200, y: 0), time: 1.01)
        let final = NativeGestureEngine.MotionSample(point: CGPoint(x: 30, y: 0), time: 1.03)
        input.updateCoalescedMotion(id: 2, samples: [old], final: final)
        XCTAssertEqual(log.moves.count, count)
        input.updateCoalescedMotion(id: 1, samples: [old, final, final], final: final)
        XCTAssertEqual(log.moves.count, count + 1)
        input.update([touch(1, 30), touch(2, 60)], at: 1.04)
        input.updateCoalescedMotion(id: 1, samples: [], final: .init(point: CGPoint(x: 80, y: 0), time: 1.05))
        XCTAssertEqual(log.moves.count, count + 1)
        input.update([], at: 1.06, cancelled: true)
        input.updateCoalescedMotion(id: 1, samples: [], final: .init(point: CGPoint(x: 80, y: 0), time: 1.07))
        XCTAssertEqual(log.moves.count, count + 1)
    }

    func testCoalescedMotionKeepsTapSlopAndExactlyOneOwnedDragRelease() {
        let log = CommandLog(), input = engine(log)
        input.update([touch(1, 0)], at: 1)
        input.updateCoalescedMotion(id: 1, samples: [.init(point: CGPoint(x: 3, y: 0), time: 1.01)],
                                   final: .init(point: CGPoint(x: 7, y: 0), time: 1.02))
        input.update([], at: 1.03)
        XCTAssertEqual(log.moves.count, 0)
        XCTAssertEqual(log.clicks, [1])
        input.update([touch(2, 0)], at: 1.1)
        input.tick(at: 1.35)
        input.updateCoalescedMotion(id: 2, samples: [.init(point: CGPoint(x: 12, y: 0), time: 1.36)],
                                   final: .init(point: CGPoint(x: 20, y: 0), time: 1.37))
        input.update([], at: 1.38, cancelled: true)
        XCTAssertEqual(log.dragBegins, 1)
        XCTAssertEqual(log.dragEnds, 1)
        XCTAssertEqual(log.clicks, [1])
        let count = log.moves.count
        input.updateCoalescedMotion(id: 2, samples: [], final: .init(point: CGPoint(x: 50, y: 0), time: 1.39))
        XCTAssertEqual(log.moves.count, count)
    }

    func testPanModeAndViewOnlySuppressRemoteInput() {
        let log = CommandLog()
        let input = engine(log, enabled: false, panMode: true)
        input.update([touch(1, 0)], at: 1)
        input.update([touch(1, 20)], at: 1.1)
        input.update([], at: 1.2)
        XCTAssertEqual(log.pans, 1)
        XCTAssertEqual(log.clicks, [])
        XCTAssertEqual(log.moves.count, 0)
    }
}

final class CommandLog {
    var zoomToggles: [CGPoint] = []
    var navigation: [(factor: CGFloat, anchor: CGPoint, translation: CGSize)] = []
    var workspaceSwipes: [NativeSwipeDirection] = []
    var clicks: [Int] = []
    var secondary = 0
    var middle = 0
    var clipboardCopies = 0
    var clipboardPastes = 0
    var acceptClipboard = true
    var moves: [CGSize] = []
    var points: [CGPoint] = []
    var scrollPhases: [String] = []
    var scrollDeltas: [CGSize] = []
    var zooms = 0
    var zoomFactors: [CGFloat] = []
    var zoomEnds = 0
    var pans = 0
    var dragBegins = 0
    var dragBeginIDs: [String] = []
    var dragCounts: [Int] = []
    var dragEnds = 0
    var dragEndIDs: [String] = []
    var auxiliary: [AuxiliaryMouseButton] = []
    var acceptDrag = true
    var precision: [PrecisionPhase] = []
    var precisionPoints: [CGPoint] = []
    var acceptPrecision = true
    /// Rejects `pointTo` for points matching this predicate, as a letterbox band would.
    var rejectPoint: (CGPoint) -> Bool = { _ in false }
    /// Every command in order, for checking that the pointer moves before it clicks.
    var trace: [String] = []

    func record(_ command: NativeGestureCommand) -> Bool {
        switch command {
        case .zoomToggle(let anchor): zoomToggles.append(anchor); trace.append("zoomToggle")
        case .navigate(let factor, let anchor, let translation): navigation.append((factor, anchor, translation)); trace.append("navigate")
        case .workspaceSwipe(let direction): workspaceSwipes.append(direction); trace.append("workspace")
        case .click(let count): clicks.append(count); trace.append("click\(count)")
        case .secondaryClick: secondary += 1; trace.append("right")
        case .middleClick: middle += 1; trace.append("middle")
        case .clipboardCopy: clipboardCopies += 1; trace.append("clipboardCopy"); return acceptClipboard
        case .clipboardPaste: clipboardPastes += 1; trace.append("clipboardPaste"); return acceptClipboard
        case .auxiliaryClick(let button): auxiliary.append(button); trace.append("aux-\(button.rawValue)")
        case .move(let delta): moves.append(delta); trace.append("move")
        case .pointTo(let point):
            guard !rejectPoint(point) else { trace.append("pointTo-rejected"); return false }
            points.append(point); trace.append("pointTo")
        case .scroll(let delta, let phase, _): scrollPhases.append(phase); scrollDeltas.append(delta); trace.append("scroll-\(phase)")
        case .zoom(let factor, _): zooms += 1; zoomFactors.append(factor); trace.append("zoom")
        case .zoomEnded: zoomEnds += 1; trace.append("zoomEnded")
        case .pan: pans += 1; trace.append("pan")
        case .dragBegan(let id, let count): dragBegins += 1; dragBeginIDs.append(id); dragCounts.append(count); trace.append("dragBegan\(count)"); return acceptDrag
        case .dragEnded(let id): dragEnds += 1; dragEndIDs.append(id); trace.append("dragEnded")
        case .precision(let phase, let point):
            precision.append(phase); precisionPoints.append(point); trace.append("precision-\(phase)")
            return phase != .began || acceptPrecision
        }
        return true
    }
}
