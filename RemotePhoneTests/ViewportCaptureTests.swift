import XCTest
import UIKit
import CoreVideo
import WebRTC
@testable import PocketDeskRemote

/// G4 on the phone (Docs/perf/PLAN-120FPS-AND-LOAD.md §4): what a heartbeat carries, when a viewport
/// change leaves, and which `capture` status region the picture is placed by.
@MainActor
final class ViewportCaptureTests: XCTestCase {
    private let display = CGSize(width: 1470, height: 956)
    private let interval = ViewportReporter.minimumInterval
    private var models: [PhoneRemoteModel] = []

    override func tearDown() {
        models.forEach { $0.connection.stop() }
        models.removeAll()
        super.tearDown()
    }

    private func connectedModel() -> PhoneRemoteModel {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        models.append(model)
        // Geometry retirement legitimately releases input through the transport.
        model.connection.inputPacketSenderForTesting = { _ in true }
        model.connection.startInputFixtureForTesting(session: "viewport-status-fixture")
        return model
    }

    private func request(x: CGFloat = 367.5, display: CGSize? = nil) -> ViewportCaptureRequest {
        ViewportCaptureRequest(rect: CGRect(x: x, y: 239, width: 735, height: 338), pixelWidth: 2622,
                               pixelHeight: 1206, zoom: 3.5673, displaySize: display ?? self.display)
    }

    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        let receive = try XCTUnwrap(model.connection.onControl)
        receive(try JSONEncoder().encode(action))
    }

    /// A model that has the Mac's geometry (epoch 4) and one `capture` status with these features.
    private func sessionModel(features: [String], pointerSync: PointerSync? = nil) throws -> PhoneRemoteModel {
        let model = connectedModel()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 4), to: model)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 4, pointerSync: pointerSync, features: features),
                    to: model)
        return model
    }

    private func json(_ action: RemoteAction) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(action), as: UTF8.self)
    }

    // MARK: When a change leaves

    private func send(_ reporter: inout ViewportReporter, settled: Bool = false, coverage: CGRect? = nil,
                      at now: TimeInterval) -> ViewportRegion? {
        guard reporter.commit(settled: settled, coverage: coverage, forDisplay: display, at: now) else { return nil }
        return reporter.region(forDisplay: display)
    }

    func testTheFirstChangeLeavesAtOnceThenAtMostEvery100ms() throws {
        var reporter = ViewportReporter()
        XCTAssertEqual(reporter.nextSend(settled: false, at: 10), .none, "nothing to report yet")
        reporter.update(request(x: 100), at: 10)
        XCTAssertEqual(reporter.nextSend(settled: false, at: 10), .now)
        XCTAssertEqual(try XCTUnwrap(send(&reporter, at: 10)).epoch, 1)
        XCTAssertEqual(reporter.nextSend(settled: false, at: 10.01), .none, "nothing new since")
        reporter.update(request(x: 110), at: 10.03)
        XCTAssertEqual(reporter.nextSend(settled: false, at: 10.03), .at(10 + interval))
        reporter.update(request(x: 120), at: 10.09)
        XCTAssertEqual(reporter.nextSend(settled: false, at: 10.09), .at(10 + interval),
                       "a running pan keeps one pending send")
        XCTAssertEqual(reporter.nextSend(settled: false, at: 10 + interval), .now)
        let second = try XCTUnwrap(send(&reporter, at: 10 + interval))
        XCTAssertEqual(second.epoch, 2, "positions that were never sent use no epoch")
        XCTAssertEqual(second.x, 120)
    }

    func testASettledGestureLeavesAtOnce() {
        var reporter = ViewportReporter()
        reporter.update(request(x: 100), at: 5)
        _ = send(&reporter, at: 5)
        reporter.update(request(x: 150), at: 5.02)
        XCTAssertEqual(reporter.nextSend(settled: false, at: 5.02), .at(5 + interval))
        XCTAssertEqual(reporter.nextSend(settled: true, at: 5.02), .now)
        XCTAssertEqual(send(&reporter, settled: true, at: 5.02)?.epoch, 2)
        XCTAssertEqual(reporter.nextSend(settled: true, at: 5.03), .none, "settling with nothing new sends nothing")
    }

    func testAnUnchangedViewportKeepsItsEpochOnEveryHeartbeat() {
        var reporter = ViewportReporter()
        reporter.update(request(x: 100), at: 1)
        XCTAssertEqual(send(&reporter, at: 1)?.epoch, 1)
        XCTAssertEqual(reporter.region(forDisplay: display)?.epoch, 1, "heartbeats repeat what was sent")
        reporter.update(request(x: 100), at: 1.3)
        XCTAssertFalse(reporter.hasUnsentChange, "the same viewport again is not a change")
        XCTAssertNil(send(&reporter, at: 1.5))
        reporter.update(request(x: 200), at: 1.75)
        XCTAssertEqual(reporter.region(forDisplay: display)?.epoch, 1, "a change not yet sent is not repeated")
        XCTAssertEqual(send(&reporter, at: 1.75)?.epoch, 2)
        reporter.update(request(x: 100), at: 2)
        XCTAssertEqual(send(&reporter, at: 2)?.epoch, 3, "going back is a change too")
        XCTAssertEqual(reporter.epoch, 3)
    }

    func testAViewportOfAnotherDisplayIsNeverSent() {
        var reporter = ViewportReporter()
        let external = CGSize(width: 1920, height: 1080)
        reporter.update(request(display: external), at: 1)
        XCTAssertFalse(reporter.commit(settled: true, forDisplay: display, at: 1))
        XCTAssertNil(reporter.region(forDisplay: display))
        XCTAssertTrue(reporter.hasUnsentChange)
        XCTAssertEqual(reporter.epoch, 0)
        XCTAssertTrue(reporter.commit(settled: true, forDisplay: external, at: 1.1))
        XCTAssertEqual(reporter.region(forDisplay: external)?.epoch, 1)
        reporter.update(nil, at: 1.2)
        XCTAssertNil(reporter.region(forDisplay: external))
        XCTAssertEqual(reporter.nextSend(settled: true, at: 1.3), .none)
    }

    func testANewSessionResendsUnderAFreshEpoch() {
        var reporter = ViewportReporter()
        reporter.update(request(), at: 1)
        XCTAssertEqual(send(&reporter, at: 1)?.epoch, 1)
        reporter.sessionEnded()
        XCTAssertEqual(reporter.nextSend(settled: false, coverage: CGRect(origin: .zero, size: display), at: 1.01), .now,
                       "no throttle or hold carried across sessions")
        XCTAssertEqual(send(&reporter, at: 1.01)?.epoch, 2, "an epoch is never reused")
    }

    // MARK: Crop changes during a gesture (recording 15:26:33, 1 Oct)

    func testAPinchInsideTheStreamedAreaWaitsForTheSettle() throws {
        var reporter = ViewportReporter()
        let whole = CGRect(origin: .zero, size: display)
        reporter.update(request(x: 100), at: 1)
        XCTAssertNotNil(send(&reporter, coverage: whole, at: 1))
        for step in 1...6 {
            let now = 1 + Double(step) * 0.05
            reporter.update(request(x: 100 + CGFloat(step)), at: now)
            XCTAssertEqual(reporter.nextSend(settled: false, coverage: whole, at: now),
                           .at(now + ViewportReporter.quietInterval), "the stream still shows every point asked for")
        }
        XCTAssertEqual(reporter.region(forDisplay: display)?.epoch, 1, "heartbeats keep the crop of the last send")
        XCTAssertEqual(reporter.nextSend(settled: true, coverage: whole, at: 1.31), .now)
        let settled = try XCTUnwrap(send(&reporter, settled: true, coverage: whole, at: 1.31))
        XCTAssertEqual(settled.epoch, 2, "one crop change for the whole pinch")
        XCTAssertEqual(settled.x, 106)
    }

    func testAPinchThatRestsGetsItsCropWithoutLiftingAFinger() {
        var reporter = ViewportReporter()
        let whole = CGRect(origin: .zero, size: display)
        reporter.update(request(x: 100), at: 1)
        _ = send(&reporter, coverage: whole, at: 1)
        reporter.update(request(x: 140), at: 2)
        XCTAssertEqual(reporter.nextSend(settled: false, coverage: whole, at: 2.1), .at(2 + ViewportReporter.quietInterval))
        XCTAssertEqual(reporter.nextSend(settled: false, coverage: whole, at: 2.31), .now)
        XCTAssertEqual(send(&reporter, coverage: whole, at: 2.31)?.x, 140)
    }

    func testAPinchOutPastTheCropAsksForTwiceTheVisibleAreaOnce() throws {
        var reporter = ViewportReporter()
        let crop = CGRect(x: 300, y: 200, width: 800, height: 420)
        reporter.update(request(x: 367.5), at: 1)
        _ = send(&reporter, settled: true, coverage: crop, at: 1)
        let outward = ViewportCaptureRequest(rect: CGRect(x: 300, y: 180, width: 880, height: 405), pixelWidth: 2622,
                                             pixelHeight: 1206, zoom: 2.98, displaySize: display)
        reporter.update(outward, at: 2)
        XCTAssertEqual(reporter.nextSend(settled: false, coverage: crop, at: 2), .now, "missing edges cannot wait")
        let widened = try XCTUnwrap(send(&reporter, coverage: crop, at: 2))
        XCTAssertEqual(widened.rect, CGRect(x: 0, y: 0, width: 1470, height: 810))
        XCTAssertEqual(widened.zoom, 1.49, accuracy: 0.000_001)
        XCTAssertEqual(reporter.nextSend(settled: false, coverage: crop, at: 2.15), .at(2 + ViewportReporter.quietInterval),
                       "until the Mac echoes the wider crop, the same request is not sent again")
        XCTAssertEqual(reporter.nextSend(settled: false, coverage: widened.rect, at: 2.15), .at(2 + ViewportReporter.quietInterval))
        XCTAssertEqual(send(&reporter, settled: true, coverage: widened.rect, at: 2.2)?.rect, outward.rect,
                       "the settle asks for exactly what is shown")
    }

    // MARK: What a heartbeat carries

    func testAnOlderMacGetsTodaysHeartbeatPlusScreenPixels() throws {
        let model = try sessionModel(features: [SessionFeature.clipboardText])
        model.viewportChanged(request())
        let heartbeat = model.heartbeatAction(clock: nil, at: 1)
        XCTAssertNil(heartbeat.viewport)
        var expected = RemoteAction(action: "heartbeat", epoch: 4, pointerSync: model.pointerOverlay.advertisement(),
                                    streamQuality: nil, clock: nil)
        expected.screenPixels = model.screenPixels()
        XCTAssertEqual(try json(heartbeat), try json(expected))
        XCTAssertFalse(try json(heartbeat).contains("viewport"))
    }

    func testTheViewportRidesOnHeartbeatsOnlyWhileTheMacAdvertisesIt() throws {
        let model = connectedModel()
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 4), to: model)
        model.viewportChanged(request())
        XCTAssertNil(model.heartbeatAction(at: 1).viewport, "no capture status yet")
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 4, features: [SessionFeature.viewportCapture]),
                    to: model)
        XCTAssertTrue(model.viewportCaptureSupported)
        XCTAssertEqual(model.heartbeatAction(at: 2).viewport, request().region(epoch: 1))
        XCTAssertEqual(model.heartbeatAction(at: 2.25).viewport?.epoch, 1, "unchanged, sent again with its epoch")
        model.viewportChanged(request(x: 400), settled: true)
        XCTAssertEqual(model.heartbeatAction(at: 2.5).viewport, request(x: 400).region(epoch: 2))
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 4, features: []), to: model)
        XCTAssertFalse(model.viewportCaptureSupported)
        XCTAssertNil(model.heartbeatAction(at: 2.75).viewport, "a Mac that stops advertising it gets none")
    }

    func testPhoneLoadRidesOnlyOnLadderHeartbeatsAndExpiresWithoutFreshStatistics() throws {
        let model = try sessionModel(features: [SessionFeature.ladder])
        var report = StreamStatsReport(role: "phone", previous: nil,
                                       current: StreamStatsSample(entries: []), counters: nil)
        report.supersededFrames = 31
        report.decodeMs = 9
        report.presentedFPS = 80
        report.thermalState = 2
        report.lowPowerMode = true
        model.acceptPhoneStats(report, at: 10)
        XCTAssertEqual(model.heartbeatAction(at: 11).phoneLoad,
                       PhoneLoadFeedback(report: report))
        model.enterBackground()
        XCTAssertNil(model.heartbeatAction(at: 11.1).phoneLoad,
                     "a held session must not reuse a pre-pause phone report")
        model.acceptPhoneStats(report, at: 11.2)
        XCTAssertNil(model.heartbeatAction(at: 13.8).phoneLoad, "a frozen report cannot steer the Mac")

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 4, features: []), to: model)
        model.acceptPhoneStats(report, at: 14)
        XCTAssertNil(model.heartbeatAction(at: 14.1).phoneLoad, "an old Mac receives no new field")
    }

    func testAHeartbeatWithAViewportPassesTheMacsValidation() throws {
        let model = try sessionModel(features: [SessionFeature.viewportCapture])
        model.viewportChanged(request())
        let heartbeat = model.heartbeatAction(clock: ClockProbe(phoneMs: 1_000), at: 1)
        XCTAssertNotNil(heartbeat.viewport)
        XCTAssertNoThrow(try heartbeat.validate())
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(heartbeat))
        XCTAssertEqual(decoded.viewport, heartbeat.viewport)
        XCTAssertEqual(decoded.screenPixels, heartbeat.screenPixels)
        XCTAssertEqual(decoded.clock, heartbeat.clock)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testAViewportHeartbeatKeepsThePointerAdvertisement() throws {
        let model = try sessionModel(features: [SessionFeature.viewportCapture],
                                     pointerSync: PointerSync(videoCursor: false))
        model.viewportChanged(request())
        let heartbeat = model.heartbeatAction(at: 1)
        XCTAssertNotNil(heartbeat.viewport)
        XCTAssertNotNil(heartbeat.pointerSync, "a heartbeat without it switches the Mac's pointer telemetry off")
        XCTAssertEqual(heartbeat.pointerSync, model.pointerOverlay.advertisement())
    }

    func testDisconnectedAndStoppedCallbacksCannotEnablePointerOrAdoptCrop() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        model.connection.inputPacketSenderForTesting = { _ in true }
        defer { model.connection.stop() }
        let receive = try XCTUnwrap(model.connection.onControl)
        let features = [SessionFeature.viewportCapture]
        let region = CaptureRegion(epoch: 7, x: 327.5, y: 199, width: 815, height: 418,
                                   outputWidth: 2622, outputHeight: 1345)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 4), to: model)
        let status = RemoteAction(action: "capture", x: 1, epoch: 4,
                                  pointerSync: PointerSync(videoCursor: false),
                                  features: features, captureRegion: region)
        let data = try JSONEncoder().encode(status)
        receive(data)
        XCTAssertNil(model.captureRegion)
        XCTAssertNil(model.cropSummary)
        XCTAssertNil(model.heartbeatAction(at: 1).pointerSync)
        model.connection.startInputFixtureForTesting(session: "viewport-retained-fixture")
        receive(data)
        XCTAssertEqual(model.captureRegion, region)
        XCTAssertNotNil(model.heartbeatAction(at: 1).pointerSync)
        model.connection.stop()
        XCTAssertFalse(model.connection.connected)
        // Use Stop's current geometry epoch so rejection is not merely stale geometry.
        let late = RemoteAction(action: "capture", x: 1, epoch: 0,
                                pointerSync: PointerSync(videoCursor: false),
                                features: features, captureRegion: region)
        receive(try JSONEncoder().encode(late))
        XCTAssertNil(model.captureRegion)
        XCTAssertNil(model.cropSummary)
        XCTAssertNil(model.heartbeatAction(at: 2).pointerSync,
                     "A retained callback cannot enable pointer telemetry after Stop")
    }

    func testAZoomedViewportReachesTheHeartbeatInDisplayPoints() throws {
        let model = try sessionModel(features: [SessionFeature.viewportCapture])
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 874, height: 402), mode: .fill,
                                     safeInsets: ViewportInsets(left: 62, bottom: 21, right: 62))
        view.setZoom(2, anchoredAt: CGPoint(x: 437, y: 201))
        model.viewportChanged(view.captureRequest(displayScale: 3), settled: true)
        let region = try XCTUnwrap(model.heartbeatAction(at: 1).viewport)
        let visible = view.visibleSourceRect
        XCTAssertEqual(region.x, Double(visible.minX), accuracy: 1.0 / 64)
        XCTAssertEqual(region.y, Double(visible.minY), accuracy: 1.0 / 64)
        XCTAssertEqual(region.width, Double(visible.width), accuracy: 1.0 / 32)
        XCTAssertEqual(region.height, Double(visible.height), accuracy: 1.0 / 32)
        XCTAssertEqual(region.pixelWidth, 2622)
        XCTAssertEqual(region.pixelHeight, 1206)
        XCTAssertEqual(region.zoom, Double(view.scale * 3), accuracy: 0.000_051)
        XCTAssertNoThrow(try region.validate())

        view.setMode(.fit)
        model.viewportChanged(view.captureRequest(displayScale: 3), settled: true)
        let whole = try XCTUnwrap(model.heartbeatAction(at: 1.25).viewport)
        XCTAssertEqual(whole.rect, CGRect(origin: .zero, size: display), "Fit asks for the whole display")
        XCTAssertEqual(whole.epoch, 2)
    }

    func testScreenPixelsAreTheNativeBoundsOnEveryHeartbeat() throws {
        let native = CGRect(x: 0, y: 0, width: 1206, height: 2622)
        XCTAssertEqual(PhoneRemoteModel.screenPixels(nativeBounds: native), PixelSize(width: 1206, height: 2622))
        XCTAssertEqual(PhoneRemoteModel.screenPixels(nativeBounds: native)?.longEdge, 2622)
        XCTAssertNil(PhoneRemoteModel.screenPixels(nativeBounds: .zero))
        XCTAssertNil(PhoneRemoteModel.screenPixels(nativeBounds: CGRect(x: 0, y: 0, width: 20_000, height: 2622)))
        XCTAssertNil(PhoneRemoteModel.screenPixels(nativeBounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 2622)))

        for features in [[String](), [SessionFeature.viewportCapture]] {
            let model = try sessionModel(features: features)
            model.viewportChanged(request())
            XCTAssertEqual(model.heartbeatAction(at: 1).screenPixels, model.screenPixels(), "features \(features)")
        }
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        if let screen = UIApplication.shared.connectedScenes.lazy.compactMap({ ($0 as? UIWindowScene)?.screen }).first {
            XCTAssertEqual(model.screenPixels(), PhoneRemoteModel.screenPixels(nativeBounds: screen.nativeBounds))
            XCTAssertNotNil(model.screenPixels())
        } else {
            XCTAssertNil(model.screenPixels(), "no window scene, nothing to report")
        }
    }

    // MARK: Which region the picture is placed by

    func testACaptureStatusRegionIsAdoptedOnlyForTheCurrentGeometry() throws {
        let features = [SessionFeature.viewportCapture]
        let model = try sessionModel(features: features)
        let region = CaptureRegion(epoch: 7, x: 327.5, y: 199, width: 815, height: 418,
                                   outputWidth: 2622, outputHeight: 1345)
        func status(epoch: UInt64 = 4, _ region: CaptureRegion?) -> RemoteAction {
            RemoteAction(action: "capture", x: 1, epoch: epoch, features: features, captureRegion: region)
        }
        XCTAssertNil(model.captureRegion)
        try deliver(status(region), to: model)
        XCTAssertEqual(model.captureRegion, region)
        XCTAssertEqual(model.cropSummary?.caption, "crop 2622×1345 · 2.0×")
        try deliver(status(nil), to: model)
        XCTAssertNil(model.captureRegion, "a status without a region means the whole display")
        try deliver(status(region), to: model)
        var whole = region
        whole.epoch = 0
        try deliver(status(whole), to: model)
        XCTAssertNil(model.captureRegion, "epoch 0 is the whole display")
        try deliver(status(epoch: 3, region), to: model)
        XCTAssertNil(model.captureRegion, "a status about another geometry")
        var malformed = region
        malformed.width = 0
        try deliver(status(malformed), to: model)
        XCTAssertNil(model.captureRegion, "a malformed region")
        try deliver(status(region), to: model)
        XCTAssertEqual(model.captureRegion, region)
        try deliver(RemoteAction(action: "geometry", x: 1920, y: 1080, epoch: 5), to: model)
        XCTAssertNil(model.captureRegion, "a new display starts whole until the Mac says otherwise")
        XCTAssertNil(model.cropSummary)
        XCTAssertNil(PhoneRemoteModel.croppedRegion(nil, statusEpoch: 5, geometryEpoch: 5))
        XCTAssertEqual(PhoneRemoteModel.croppedRegion(region, statusEpoch: 5, geometryEpoch: 5), region)
    }

    func testTheCropCaptionIsCompact() {
        func region(epoch: UInt64 = 2, x: Double = 367.5, y: Double = 239, width: Double = 735, height: Double = 478,
                    output: (Int, Int) = (1280, 720)) -> CaptureRegion {
            CaptureRegion(epoch: epoch, x: x, y: y, width: width, height: height,
                          outputWidth: output.0, outputHeight: output.1)
        }
        XCTAssertNil(CropSummary(nil, displaySize: display))
        XCTAssertNil(CropSummary(region(epoch: 0), displaySize: display), "whole display shows the picture size")
        XCTAssertNil(CropSummary(region(), displaySize: .zero))
        let half = CropSummary(region(), displaySize: display)
        XCTAssertEqual(half?.caption, "crop 1280×720 · 2.0×")
        XCTAssertEqual(half?.spoken, "picture cropped to 1280 by 720, 2.0 times")
        let band = CropSummary(region(x: 0, y: 0, width: 1470, height: 239, output: (2622, 426)), displaySize: display)
        XCTAssertEqual(band?.caption, "crop 2622×426 · 2.0×", "a crop along one axis counts by area")
        XCTAssertEqual(band?.factor ?? 0, 2, accuracy: 1e-12)
    }

    func testThePointerGlyphAndACroppedFrameShareOnePlacement() {
        var view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 874, height: 402), mode: .fill,
                                     safeInsets: ViewportInsets(left: 62, bottom: 21, right: 62))
        view.setZoom(2.5, anchoredAt: CGPoint(x: 300, y: 150))
        let output = CGSize(width: 2622, height: 1206)
        let region = CaptureRegion(epoch: 3, x: 300, y: 200, width: 700, height: 322,
                                   outputWidth: Int(output.width), outputHeight: Int(output.height))
        let frame = view.picturePlacement(for: region)
        let pointers = [CGPoint(x: 300, y: 200), CGPoint(x: 650, y: 361), CGPoint(x: 1000, y: 522),
                        CGPoint(x: 431.25, y: 299.5)]
        for pointer in pointers {
            let glyph = PointerOverlayView.picturePoint(pointer, scale: view.scale)
            let pixel = CGPoint(x: (glyph.x - frame.minX) / frame.width * output.width,
                                y: (glyph.y - frame.minY) / frame.height * output.height)
            let shown = CGPoint(x: region.x + Double(pixel.x / output.width) * region.width,
                                y: region.y + Double(pixel.y / output.height) * region.height)
            XCTAssertEqual(shown.x, pointer.x, accuracy: 1e-9, "the glyph sits on the pixel showing its Mac point")
            XCTAssertEqual(shown.y, pointer.y, accuracy: 1e-9)
        }
        XCTAssertEqual(view.picturePlacement(for: nil), CGRect(origin: .zero, size: view.contentRect.size))
    }

    /// An encoded frame 2 % off the display's aspect (alignment, or a size change racing `sourceSize`)
    /// is drawn where the layer actually puts it; the glyph must still sit on the pixel showing its Mac point.
    func testATwoPercentAspectMismatchKeepsThePointerGlyphOnTarget() throws {
        let view = ViewportTransform(sourceSize: display, canvasSize: CGSize(width: 874, height: 402), mode: .fit,
                                     safeInsets: ViewportInsets(left: 62, bottom: 21, right: 62))
        let placement = view.picturePlacement(for: nil)
        let output = CGSize(width: 294, height: 195) // 1.508 against the display's 1.538
        XCTAssertGreaterThan(abs((output.width / output.height) / (display.width / display.height) - 1), 0.019)
        let id = VideoPresentationIdentity(hostRecordID: "host-A", ownerPairID: "grant-A", sessionID: UUID(), trackID: UUID(),
                                           contentEpoch: 1, geometryEpoch: 1)
        let admission = VideoPresentationAdmission(identity: id, validUntil: ProcessInfo.processInfo.systemUptime + 100)
        let surface = OwnedMetalVideoView(admission: admission, fence: VideoPresentationFence(admission))
        defer { surface.invalidate() }
        surface.frame = placement
        surface.setNeedsLayout(); surface.layoutIfNeeded()
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, Int(output.width), Int(output.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        surface.offer(VideoFrameEnvelope(receiptID: UUID(), identity: id,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true))
        surface.draw(in: surface.metal)
        XCTAssertEqual(surface.metal.drawableSize, output, "the first crop is drawn 1:1")
        let shownRect = surface.pictureRect.offsetBy(dx: placement.minX, dy: placement.minY)
        for pointer in [CGPoint(x: 0, y: 0), CGPoint(x: 735, y: 478), CGPoint(x: 1470, y: 956), CGPoint(x: 120, y: 900)] {
            let glyph = PointerOverlayView.picturePoint(pointer, scale: view.scale)
            let shown = CGPoint(x: (glyph.x - shownRect.minX) / shownRect.width * display.width,
                                y: (glyph.y - shownRect.minY) / shownRect.height * display.height)
            XCTAssertEqual(shown.x, pointer.x, accuracy: 1e-6, "the glyph sits on the pixel showing its Mac point")
            XCTAssertEqual(shown.y, pointer.y, accuracy: 1e-6)
        }
    }

    func testTheVideoFillsItsRegionOnlyWhileCropped() {
        XCTAssertEqual(RemoteVideoSurface.contentMode(fillsFrame: false), .scaleAspectFit,
                       "the whole display renders as before")
        XCTAssertEqual(RemoteVideoSurface.contentMode(fillsFrame: true), .scaleToFill)
    }

    /// The 20261001.1 blank: every viewport echo (new epoch, same rect) and every ladder step (new
    /// output size) retired the content presentation, removing the picture until a new frame drew.
    func testRegionEchoAndLadderStepKeepThePresentation() throws {
        let model = try sessionModel(features: [SessionFeature.viewportCapture])
        func status(_ region: CaptureRegion) throws {
            try deliver(RemoteAction(action: "capture", x: 1, epoch: 4, features: [SessionFeature.viewportCapture],
                                     captureRegion: region), to: model)
        }
        try status(CaptureRegion(epoch: 45, x: 0, y: 283, width: 1504, height: 960, outputWidth: 1920, outputHeight: 1232))
        XCTAssertNotNil(model.captureRegion)
        let content = model.presentationContentEpochForTesting
        try status(CaptureRegion(epoch: 46, x: 0, y: 283, width: 1504, height: 960, outputWidth: 1920, outputHeight: 1232))
        XCTAssertEqual(model.captureRegion?.epoch, 45, "an epoch-only echo does not republish the region")
        try status(CaptureRegion(epoch: 46, x: 0, y: 283, width: 1504, height: 960, outputWidth: 1280, outputHeight: 816))
        XCTAssertEqual(model.captureRegion?.outputWidth, 1280)
        try status(CaptureRegion(epoch: 50, x: 0, y: 243, width: 1568, height: 1000, outputWidth: 1280, outputHeight: 816))
        XCTAssertEqual(model.captureRegion?.epoch, 50)
        XCTAssertEqual(model.presentationContentEpochForTesting, content)
        try deliver(RemoteAction(action: "geometry", x: 1470, y: 956, epoch: 5), to: model)
        XCTAssertNotEqual(model.presentationContentEpochForTesting, content, "a new geometry epoch still retires")
    }
}
