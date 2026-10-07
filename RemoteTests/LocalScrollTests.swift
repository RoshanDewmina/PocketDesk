import CoreGraphics
import XCTest

final class LocalScrollTests: XCTestCase {
    private let region = CGRect(x: 100, y: 200, width: 400, height: 300)
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1243)

    private func echo(region: CGRect? = nil) -> LocalScrollEcho {
        var echo = LocalScrollEcho(enabled: true)
        echo.setRegion(region ?? self.region)
        return echo
    }

    func testFingerDeltasAccumulateAndMapIntoThePictureCoordinates() throws {
        var echo = echo()
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 6), phase: "began", at: 10))
        XCTAssertTrue(echo.scrolled(CGSize(width: 2, height: 4), phase: "changed", at: 10.008))
        XCTAssertEqual(echo.offset, CGSize(width: 2, height: 10))
        let uniform = try XCTUnwrap(echo.uniform(picture: display, pixels: CGSize(width: 2560, height: 1657)))
        XCTAssertEqual(uniform.rect.x, Float(100.0 / 1920), accuracy: 1e-6)
        XCTAssertEqual(uniform.rect.y, Float(200.0 / 1243), accuracy: 1e-6)
        XCTAssertEqual(uniform.rect.z, Float(400.0 / 1920), accuracy: 1e-6)
        XCTAssertEqual(uniform.rect.w, Float(300.0 / 1243), accuracy: 1e-6)
        XCTAssertEqual(uniform.shift.x, Float(2.0 / 1920), accuracy: 1e-6)
        XCTAssertEqual(uniform.shift.y, Float(10.0 / 1243), accuracy: 1e-6)
        XCTAssertEqual(uniform.shift.z, Float(0.5 / 2560), accuracy: 1e-9, "Half a picture pixel keeps the edge fill inside the region")
        XCTAssertEqual(uniform.shift.w, Float(0.5 / 1657), accuracy: 1e-9)
        // A cropped picture (zoomed in) maps the same Mac points into its own smaller rect.
        let crop = CGRect(x: 50, y: 150, width: 960, height: 621.5)
        let zoomed = try XCTUnwrap(echo.uniform(picture: crop, pixels: CGSize(width: 1206, height: 781)))
        XCTAssertEqual(zoomed.rect.x, Float(50.0 / 960), accuracy: 1e-6)
        XCTAssertEqual(zoomed.shift.y, Float(10.0 / 621.5), accuracy: 1e-6)
    }

    func testRegionIsClippedToThePictureAndAnAreaOffThePictureDrawsUnshifted() throws {
        var echo = echo()
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 5), phase: "began", at: 1))
        let picture = CGRect(x: 300, y: 0, width: 800, height: 400)
        let clipped = try XCTUnwrap(echo.uniform(picture: picture, pixels: CGSize(width: 800, height: 400)))
        XCTAssertEqual(clipped.rect, SIMD4<Float>(0, 0.5, 0.25, 0.5), "Only the overlap of region and picture slides")
        XCTAssertNil(echo.uniform(picture: CGRect(x: 1000, y: 0, width: 400, height: 400), pixels: CGSize(width: 400, height: 400)))
        XCTAssertNil(echo.uniform(picture: .zero, pixels: CGSize(width: 400, height: 400)))
    }

    func testSlideStopsGrowingAfterTwoFramesOfMotionAndNeverPassesHalfTheRegion() {
        var echo = echo()
        XCTAssertEqual(echo.capDuration, 2.0 / 30, accuracy: 1e-9, "Two frames at today's 30 fps")
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 10), phase: "began", at: 1))
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 10), phase: "changed", at: 1.05))
        XCTAssertFalse(echo.scrolled(CGSize(width: 0, height: 10), phase: "changed", at: 1.07), "Past the cap the slide freezes")
        XCTAssertEqual(echo.offset.height, 20)
        // Frames at 60 fps shorten the cap to about 33 ms.
        var fast = self.echo()
        for i in 0..<20 { fast.frameArrived(original: true, at: 5 + Double(i) / 60) }
        XCTAssertEqual(fast.capDuration, 2.0 / 60, accuracy: 0.004)
        var huge = self.echo()
        XCTAssertTrue(huge.scrolled(CGSize(width: 0, height: 900), phase: "began", at: 1))
        XCTAssertEqual(huge.offset.height, 150, "At most half the region's height")
        // A frame starts a new window.
        echo.frameArrived(original: true, at: 1.1)
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 3), phase: "changed", at: 1.11))
        XCTAssertEqual(echo.offset.height, 3)
    }

    func testSlideDrawsStayClearOfTheNextDueFrame() {
        let refresh = 1.0 / 120
        var echo = echo()
        XCTAssertTrue(echo.redrawAllowed(at: 1, refresh: refresh), "No frame seen yet: none is due")
        echo.frameArrived(original: true, at: 1)
        XCTAssertTrue(echo.redrawAllowed(at: 1.009, refresh: refresh), "At 30 fps the refreshes right after a frame are clear")
        XCTAssertFalse(echo.redrawAllowed(at: 1.025, refresh: refresh), "The next frame is due within the coming refresh")
        XCTAssertFalse(echo.redrawAllowed(at: 1.05, refresh: refresh), "A slightly late frame may land any moment")
        XCTAssertTrue(echo.redrawAllowed(at: 1.07, refresh: refresh), "Two intervals without a frame: the stream is quiet")
        var fast = self.echo()
        for i in 0..<30 { fast.frameArrived(original: true, at: Double(i) / 60) }
        XCTAssertFalse(fast.redrawAllowed(at: 29.0 / 60 + refresh, refresh: refresh),
                       "At 60 fps on a 120 Hz display no refresh between frames is clear")
    }

    func testASlideNoFrameReplacesExpiresAndAGestureOutsideTheRegionDoesNotSlide() {
        var echo = echo()
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 6), phase: "began", pointer: CGPoint(x: 150, y: 250), at: 1))
        XCTAssertFalse(echo.expire(at: 1.1))
        XCTAssertTrue(echo.isEchoing)
        XCTAssertTrue(echo.expire(at: 1.01 + LocalScrollEcho.staleAfter), "The Mac sent nothing: drop the slide")
        XCTAssertFalse(echo.isEchoing)
        XCTAssertFalse(echo.expire(at: 2))

        var elsewhere = self.echo()
        XCTAssertFalse(elsewhere.scrolled(CGSize(width: 0, height: 6), phase: "began", pointer: CGPoint(x: 10, y: 10), at: 1),
                       "The region describes another area than the one under the pointer")
        XCTAssertFalse(elsewhere.scrolled(CGSize(width: 0, height: 6), phase: "changed", at: 1.01))
        XCTAssertFalse(elsewhere.wantsChangeCheck)
        elsewhere.setRegion(CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertTrue(elsewhere.scrolled(CGSize(width: 0, height: 6), phase: "changed", at: 1.02),
                      "The Mac's answer for the new spot arrives a round trip later and enables the slide")
        elsewhere.setRegion(CGRect(x: 500, y: 500, width: 200, height: 200))
        XCTAssertFalse(elsewhere.scrolled(CGSize(width: 0, height: 6), phase: "changed", at: 1.03))
    }

    func testANewFrameDropsTheSlideEntirely() {
        var echo = echo()
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 8), phase: "began", at: 1))
        XCTAssertTrue(echo.isEchoing)
        XCTAssertTrue(echo.frameArrived(original: false, at: 1.01), "An interpolated frame is newer content too")
        XCTAssertEqual(echo.offset, .zero)
        XCTAssertNil(echo.uniform(picture: display, pixels: CGSize(width: 1920, height: 1243)))
        XCTAssertFalse(echo.frameArrived(original: true, at: 1.02))
        // A new region from the Mac also drops it.
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 8), phase: "changed", at: 1.03))
        XCTAssertTrue(echo.setRegion(CGRect(x: 0, y: 0, width: 300, height: 300)))
        XCTAssertFalse(echo.isEchoing)
    }

    func testThreeUnchangedFramesWhileTheFingerMovesStopTheEchoUntilTheNextGesture() {
        var echo = echo()
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 4), phase: "began", at: 1))
        // Inside the start grace and before any visible change, frames are still in flight from before.
        for t in [1.05, 1.1, 1.15, 1.2] { echo.observed(changed: false, at: t) }
        XCTAssertFalse(echo.stopped)
        echo.observed(changed: true, at: 1.21)
        echo.frameArrived(original: true, at: 1.215)
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 4), phase: "changed", at: 1.22))
        echo.observed(changed: false, at: 1.23); echo.observed(changed: false, at: 1.24)
        echo.observed(changed: true, at: 1.25)
        echo.observed(changed: false, at: 1.26); echo.observed(changed: false, at: 1.27)
        XCTAssertFalse(echo.stopped, "The frames must be consecutive")
        echo.observed(changed: false, at: 1.28)
        XCTAssertTrue(echo.stopped)
        XCTAssertFalse(echo.isEchoing)
        XCTAssertFalse(echo.scrolled(CGSize(width: 0, height: 4), phase: "changed", at: 1.3))
        XCTAssertNil(echo.uniform(picture: display, pixels: CGSize(width: 1920, height: 1243)))
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 4), phase: "began", at: 2), "A new gesture starts echoing again")
    }

    func testUnchangedFramesLongAfterTheLastDeltaSayNothingAboutTheEnd() {
        var echo = echo()
        XCTAssertTrue(echo.scrolled(CGSize(width: 0, height: 4), phase: "began", at: 1))
        echo.observed(changed: true, at: 1.1)
        for t in [1.5, 1.6, 1.7, 1.8] { echo.observed(changed: false, at: t) }
        XCTAssertFalse(echo.stopped, "A finger resting on the glass is not the end of the content")
        // After the start grace, unchanged frames count even before any change was seen.
        var late = self.echo()
        XCTAssertTrue(late.scrolled(CGSize(width: 0, height: 4), phase: "began", at: 1))
        late.frameArrived(original: true, at: 1.39)
        XCTAssertTrue(late.scrolled(CGSize(width: 0, height: 4), phase: "changed", at: 1.4))
        for t in [1.43, 1.44, 1.45] { late.observed(changed: false, at: t) }
        XCTAssertTrue(late.stopped)
    }

    func testNoEchoWithTheFlagOffTheRegionUnknownOrMomentum() {
        var off = LocalScrollEcho(enabled: false)
        XCTAssertFalse(off.setRegion(region))
        XCTAssertNil(off.region)
        XCTAssertFalse(off.scrolled(CGSize(width: 0, height: 5), phase: "began", at: 1))
        XCTAssertNil(off.uniform(picture: display, pixels: CGSize(width: 1920, height: 1243)))
        XCTAssertFalse(off.wantsChangeCheck)

        var unknown = LocalScrollEcho(enabled: true)
        XCTAssertFalse(unknown.scrolled(CGSize(width: 0, height: 5), phase: "began", at: 1))
        XCTAssertFalse(unknown.scrolled(CGSize(width: 0, height: 5), phase: "changed", at: 1.01))
        XCTAssertNil(unknown.uniform(picture: display, pixels: CGSize(width: 1920, height: 1243)))
        XCTAssertFalse(unknown.setRegion(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10)))
        XCTAssertNil(unknown.region)

        var coasting = echo()
        XCTAssertTrue(coasting.scrolled(CGSize(width: 0, height: 5), phase: "began", at: 1))
        coasting.frameArrived(original: true, at: 1.01)
        XCTAssertFalse(coasting.scrolled(.zero, phase: "ended", at: 1.02))
        for phase in ScrollMomentumPhase.allCases.map(\.rawValue) {
            XCTAssertFalse(coasting.scrolled(CGSize(width: 0, height: 40), phase: phase, at: 1.03), phase)
        }
        XCTAssertFalse(coasting.scrolled(CGSize(width: 0, height: 5), phase: "changed", at: 1.04), "Only a new gesture echoes again")
        XCTAssertFalse(coasting.isEchoing)
    }

    func testRegionChangeDetectionIgnoresEncoderNoiseAndCatchesScrolledText() {
        let still = [UInt8](repeating: 240, count: 576)
        var noisy = still
        for i in stride(from: 0, to: noisy.count, by: 3) { noisy[i] = 238 }
        XCTAssertEqual(LocalScrollEcho.regionChanged(still, noisy), false)
        var text = still
        for i in [5, 77, 300, 401] { text[i] = 30 }
        XCTAssertEqual(LocalScrollEcho.regionChanged(still, text), true)
        XCTAssertNil(LocalScrollEcho.regionChanged(still, Array(still.prefix(10))))
        let points = LocalScrollEcho.samplePoints(in: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertEqual(points.count, LocalScrollEcho.sampleGrid * LocalScrollEcho.sampleGrid)
        XCTAssertTrue(points.allSatisfy { $0.x > 0.25 && $0.x < 0.75 && $0.y > 0.5 && $0.y < 0.75 })
    }

    func testRegionWireFormatIsDisplayLocalOptionalAndOnlyOnCaptureStatus() throws {
        let second = CGRect(x: 1920, y: -200, width: 1440, height: 900)
        let local = try XCTUnwrap(ScrollRegionFrame.displayLocal(CGRect(x: 2000, y: -150.4, width: 3000, height: 400), display: second))
        XCTAssertEqual(local.rect, CGRect(x: 80, y: 49, width: 1360, height: 401), "Clipped to the display and moved into its own points")
        XCTAssertNil(ScrollRegionFrame.displayLocal(CGRect(x: 0, y: 0, width: 500, height: 500), display: second))
        XCTAssertNil(ScrollRegionFrame.displayLocal(CGRect(x: 1930, y: 0, width: 20, height: 400), display: second), "Too small to slide")

        var status = RemoteAction(action: "capture", x: 1, epoch: 3)
        status.scrollRegion = local
        XCTAssertNoThrow(try status.validate())
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: try JSONEncoder().encode(status))
        XCTAssertEqual(decoded.scrollRegion, local)
        let legacy = try JSONDecoder().decode(RemoteAction.self, from: Data(#"{"action":"capture","x":1,"y":0,"text":"","key":"","modifiers":[],"epoch":3}"#.utf8))
        XCTAssertNil(legacy.scrollRegion, "An older Mac never sends it")
        var heartbeat = RemoteAction(action: "heartbeat")
        heartbeat.scrollRegion = local
        XCTAssertThrowsError(try heartbeat.validate())
        status.scrollRegion = ScrollRegionFrame(CGRect(x: 0, y: 0, width: 0, height: 10))
        XCTAssertThrowsError(try status.validate())
        status.scrollRegion = ScrollRegionFrame(CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10))
        XCTAssertThrowsError(try status.validate())
    }

    func testPhoneAsksForTheRegionOnlyWithItsFlagOutsideTheLegacyBounds() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalScrollTests-\(UUID().uuidString)"))
        XCTAssertFalse(LocalScrollSwitch.isEnabled(defaults), "Off by default")
        let quiet = MacShareBlocker.Handshake.phoneRequest([], defaults: defaults)
        XCTAssertNil(quiet.localScroll)
        XCTAssertFalse(quiet.requested.contains(SessionFeature.localScroll))
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(quiet)).contains(SessionFeature.localScroll))
        defaults.set("YES", forKey: LocalScrollSwitch.defaultsKey)
        XCTAssertTrue(LocalScrollSwitch.isEnabled(defaults), "A launch argument arrives as a string")
        let asking = MacShareBlocker.Handshake.phoneRequest([SessionFeature.textClarity, SessionFeature.videoRefinement], defaults: defaults)
        XCTAssertEqual(asking.localScroll, true)
        XCTAssertLessThanOrEqual(asking.features.count, 8)
        XCTAssertLessThanOrEqual(asking.options?.count ?? 0, MacShareBlocker.Handshake.maximumOptions)
        XCTAssertFalse(asking.features.contains(SessionFeature.localScroll))
        XCTAssertFalse(asking.options?.contains(SessionFeature.localScroll) ?? false)
        let body = try JSONEncoder().encode(asking)
        XCTAssertLessThanOrEqual(body.count, 1024)
        XCTAssertTrue(asking.requested.contains(SessionFeature.localScroll))
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: body).contains(SessionFeature.localScroll))
    }

    func testMailboxReportsIdleOnlyWithNothingWaitingOrInFlight() throws {
        let box = NewestFrameMailbox<Int>()
        XCTAssertTrue(box.isIdle)
        box.offer(1)
        XCTAssertFalse(box.isIdle, "A waiting frame replaces the slide itself")
        let first = try XCTUnwrap(box.take(holdUntilPresented: true))
        XCTAssertFalse(box.isIdle)
        box.gpuCompleted(first.id)
        XCTAssertFalse(box.isIdle, "Presentation still owns the drawable")
        box.presented(first.id)
        XCTAssertTrue(box.isIdle)
        box.invalidate()
        XCTAssertFalse(box.isIdle)
    }
}
