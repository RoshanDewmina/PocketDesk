import CoreGraphics
import ScreenCaptureKit
import XCTest
import WebRTC

/// Idea 2 (LATENCY-PLAN §2.2): the low-resolution whole-display backdrop. Both flags default off and
/// either one off leaves the session exactly as today: no request, no channel, no second capture.
final class BackdropNegotiationTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let suite = "BackdropTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testBothFlagsDefaultOffParseFromDefaultsAndTheHostArmReachesTheSummary() throws {
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.backdropTrackKey))
        let defaults = try defaults("flags")
        let today = StreamTuning.resolve(defaults: defaults)
        XCTAssertFalse(today.backdropTrack)
        XCTAssertEqual(today, StreamTuning.tuned)
        XCTAssertFalse(today.summary.contains("backdrop"), today.summary)
        defaults.set("YES", forKey: StreamTuning.backdropTrackKey)
        let on = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(on.backdropTrack, "a launch argument arrives as a string")
        XCTAssertTrue(on.summary.contains("backdrop track"), on.summary)
        defaults.set(false, forKey: StreamTuning.backdropTrackKey)
        XCTAssertEqual(StreamTuning.resolve(defaults: defaults), StreamTuning.tuned)

        XCTAssertFalse(BackdropRequest.isEnabled(defaults))
        defaults.set("YES", forKey: BackdropRequest.defaultsKey)
        XCTAssertTrue(BackdropRequest.isEnabled(defaults))
        defaults.set(false, forKey: BackdropRequest.defaultsKey)
        XCTAssertFalse(BackdropRequest.isEnabled(defaults))
    }

    func testThePhoneRequestRidesItsOwnFieldInsideEveryOlderMacsBounds() throws {
        let defaults = try defaults("phone")
        let quiet = MacShareBlocker.Handshake.phoneRequest(StillTextPreferences.requestedFeatures(defaults), defaults: defaults)
        XCTAssertNil(quiet.backdrop, "off by default")
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(quiet)).contains(SessionFeature.backdrop))

        defaults.set(true, forKey: BackdropRequest.defaultsKey)
        let request = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement, SessionFeature.textClarity],
                                                             mode: "couch", defaults: defaults)
        XCTAssertEqual(request.backdrop, true)
        XCTAssertEqual([request.first60, request.shortcutChips, request.phoneLoadWindows, request.keysOnDemand], [true, true, true, true],
                       "the size bound is checked with every other opt-in on")
        XCTAssertEqual(request.options?.count, MacShareBlocker.Handshake.maximumOptions)
        XCTAssertTrue(request.requested.contains(SessionFeature.backdrop))
        XCTAssertEqual(request.features, quiet.features + [SessionFeature.videoRefinement], "not a feature")
        XCTAssertLessThanOrEqual(request.features.count, 8)
        XCTAssertLessThanOrEqual(request.options?.count ?? 0, MacShareBlocker.Handshake.maximumOptions, "not an option")
        XCTAssertFalse(request.options?.contains(SessionFeature.backdrop) ?? false)
        let body = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(body.count, 1024)
        let heard = MacShareBlocker.Handshake.features(in: body)
        XCTAssertTrue(heard.contains(SessionFeature.backdrop))
        XCTAssertTrue(heard.contains(SessionFeature.textClarity), "the known options still arrive beside it")
        XCTAssertEqual(MacShareBlocker.Handshake.requestedMode(in: body), .couch)
        struct OldHandshake: Codable { let features: [String]; let mode: String?; let options: [String]?; let keysOnDemand: Bool? }
        let old = try JSONDecoder().decode(OldHandshake.self, from: body)
        XCTAssertEqual(old.features, request.features); XCTAssertEqual(old.options, request.options)
        XCTAssertFalse(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(old)).contains(SessionFeature.backdrop),
                       "an older Mac's own shape never grows the capability")
        var overflow = MacShareBlocker.Handshake(features: Array(repeating: "f", count: 9))
        overflow.backdrop = true
        XCTAssertTrue(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(overflow)).isEmpty)
    }

    func testOnlyANewPhoneAskingAndAMacWithItsFlagOnOpenTheChannel() throws {
        var on = StreamTuning.tuned; on.backdropTrack = true
        let off = StreamTuning.tuned
        let defaults = try defaults("matrix")
        defaults.set(true, forKey: BackdropRequest.defaultsKey)
        let asking = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(
            MacShareBlocker.Handshake.phoneRequest([], defaults: defaults)))
        defaults.set(false, forKey: BackdropRequest.defaultsKey)
        let newQuiet = MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(
            MacShareBlocker.Handshake.phoneRequest([], defaults: defaults)))
        let oldPhone = MacShareBlocker.Handshake.features(in: Data(#"{"features":["blocker.1","video.ltr.1"],"options":["video.clarity.1"],"keysOnDemand":true}"#.utf8))
        let cases: [(name: String, tuning: StreamTuning, phone: Set<String>, opens: Bool)] = [
            ("old phone, flag off", off, oldPhone, false), ("old phone, flag on", on, oldPhone, false),
            ("new phone not asking, flag off", off, newQuiet, false), ("new phone not asking, flag on", on, newQuiet, false),
            ("new phone asking, flag off", off, asking, false), ("new phone asking, flag on", on, asking, true)]
        for item in cases {
            let negotiated = BackdropCapturePolicy.negotiated(isHost: true, peerFeatures: item.phone, requested: [], tuning: item.tuning)
            XCTAssertEqual(negotiated, item.opens, item.name)
            let host = PeerMedia(isHost: true, servers: [], hevc: false, hevc444: false, backdrop: negotiated)
            defer { host.close() }
            XCTAssertEqual(host.backdropLink != nil, item.opens, item.name)
            XCTAssertEqual(BackdropCapturePolicy.runs(negotiated: host.backdropLink != nil, scoped: false), item.opens,
                           "\(item.name): the second capture follows the channel")
            if !item.opens { XCTAssertFalse(host.sendBackdrop(Data([1])), item.name) }
        }
        XCTAssertFalse(BackdropCapturePolicy.runs(negotiated: true, scoped: true), "a window or app session never shows the whole display")
        XCTAssertTrue(BackdropCapturePolicy.negotiated(isHost: false, peerFeatures: [], requested: [SessionFeature.backdrop], tuning: off),
                      "the phone adopts what it asked for")
        XCTAssertFalse(BackdropCapturePolicy.negotiated(isHost: false, peerFeatures: [SessionFeature.backdrop], requested: [], tuning: on))
        XCTAssertLessThanOrEqual(SessionFeature.backdrop.utf8.count, 32)
    }

    func testTheSecondCaptureIsSmallSlowAndCursorless() throws {
        let configuration = try XCTUnwrap(BackdropCapture.configuration(contentSize: CGSize(width: 1920, height: 1243)))
        XCTAssertEqual(configuration.width, 640)
        XCTAssertEqual(configuration.height, 414)
        XCTAssertEqual(configuration.minimumFrameInterval.seconds, 0.25, accuracy: 0.0001)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertFalse(configuration.capturesAudio)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        let portrait = try XCTUnwrap(BackdropCapturePolicy.outputSize(contentSize: CGSize(width: 1117, height: 1728)))
        XCTAssertEqual(portrait.height, 640); XCTAssertEqual(portrait.width % 2, 0)
        XCTAssertNil(BackdropCapture.configuration(contentSize: .zero))
    }
}

final class BackdropSnapshotTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        for row in stride(from: 0, to: height, by: 12) { context.fill(CGRect(x: 20, y: row, width: width / 2, height: 4)) }
        return try XCTUnwrap(context.makeImage())
    }

    func testASnapshotRoundTripsAndFitsOneMessage() throws {
        let encoded = try XCTUnwrap(BackdropSnapshot.encodeImage(try image(width: 640, height: 414)))
        let message = BackdropSnapshot(sequence: 7, displaySize: CGSize(width: 1920, height: 1243), image: encoded).encoded()
        XCTAssertLessThanOrEqual(message.count, BackdropSnapshot.maximumMessageBytes)
        let decoded = try XCTUnwrap(BackdropSnapshot.decode(message))
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertEqual(decoded.displaySize, CGSize(width: 1920, height: 1243))
        let image = try XCTUnwrap(BackdropSnapshot.decodeImage(decoded.image))
        XCTAssertEqual(image.width, 640); XCTAssertEqual(image.height, 414)
        let drawn = BackdropImage(image: image, sequence: 7, displaySize: decoded.displaySize)
        XCTAssertTrue(drawn.matches(display: CGSize(width: 1920, height: 1242.6)))
        XCTAssertFalse(drawn.matches(display: CGSize(width: 1440, height: 900)), "another display's snapshot is never drawn")
    }

    func testMalformedOrOversizedSnapshotsAreRefused() throws {
        let small = try XCTUnwrap(BackdropSnapshot.encodeImage(try image(width: 64, height: 40)))
        var message = BackdropSnapshot(sequence: 1, displaySize: CGSize(width: 100, height: 100), image: small).encoded()
        message[0] = 2
        XCTAssertNil(BackdropSnapshot.decode(message), "unknown version")
        XCTAssertNil(BackdropSnapshot.decode(Data(repeating: 1, count: BackdropSnapshot.headerBytes)), "no image")
        XCTAssertNil(BackdropSnapshot.decode(Data([1]) + Data(repeating: 0, count: BackdropSnapshot.maximumMessageBytes)), "too large")
        XCTAssertNil(BackdropSnapshot.decode(BackdropSnapshot(sequence: 1, displaySize: .zero, image: small).encoded()), "no display")
        let wide = try XCTUnwrap(BackdropSnapshot.encodeImage(try image(width: 1200, height: 40)))
        XCTAssertNil(BackdropSnapshot.decodeImage(wide), "larger than any backdrop")
        XCTAssertNil(BackdropSnapshot.decodeImage(Data("not an image".utf8)))
    }

    func testTheByteBudgetHoldsTheAverageRate() {
        var budget = BackdropByteBudget(bitsPerSecond: 400_000)
        XCTAssertTrue(budget.permits(at: 10))
        budget.spend(60_000, at: 10)
        XCTAssertFalse(budget.permits(at: 10), "one large snapshot may overdraw, the next waits")
        XCTAssertFalse(budget.permits(at: 10.19))
        XCTAssertTrue(budget.permits(at: 10.25))
        budget.spend(10_000, at: 10.25)
        XCTAssertTrue(budget.permits(at: 100), "idle time refills")
        XCTAssertEqual(budget.balance, 50_000, accuracy: 0.001, "but only to one second's allowance")
    }
}

final class BackdropCompositeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1300)
    private let feather: CGFloat = 8

    func testTheWholeDisplayPictureNeedsNoBackdrop() {
        XCTAssertNil(BackdropComposite.coverage(bounds: bounds, crisp: bounds, visible: CGRect(x: 400, y: 300, width: 400, height: 800),
                                                cropped: false, featherPoints: feather))
    }

    func testACropCoveringTheViewShowsTheBackdropOnlyOutsideItAndFeathersInnerEdges() throws {
        let crisp = CGRect(x: 300, y: 200, width: 600, height: 1000)
        let coverage = try XCTUnwrap(BackdropComposite.coverage(bounds: bounds, crisp: crisp,
            visible: CGRect(x: 350, y: 250, width: 400, height: 860), cropped: true, featherPoints: feather))
        XCTAssertEqual(coverage.crisp, crisp)
        XCTAssertEqual(coverage.visible, CGRect(x: 350, y: 250, width: 400, height: 860), "only the visible part is drawn")
        XCTAssertFalse(coverage.uncovered)
        XCTAssertEqual(coverage.feather, BackdropEdges(top: 8, left: 8, bottom: 8, right: 8))
    }

    func testAPanPastTheCropIsUncoveredAndADisplayEdgeIsNotFeathered() throws {
        let crisp = CGRect(x: 0, y: 0, width: 600, height: 1300)
        let coverage = try XCTUnwrap(BackdropComposite.coverage(bounds: bounds, crisp: crisp,
            visible: CGRect(x: 300, y: 0, width: 400, height: 860), cropped: true, featherPoints: feather))
        XCTAssertTrue(coverage.uncovered, "the right 100 pt has no crisp pixels")
        XCTAssertEqual(coverage.feather, BackdropEdges(top: 0, left: 0, bottom: 0, right: 8))
        let inBand = try XCTUnwrap(BackdropComposite.coverage(bounds: bounds, crisp: crisp,
            visible: CGRect(x: 190, y: 0, width: 405, height: 860), cropped: true, featherPoints: feather))
        XCTAssertTrue(inBand.uncovered, "the feather band itself is not fully sharp")
        XCTAssertFalse(try XCTUnwrap(BackdropComposite.coverage(bounds: bounds, crisp: crisp,
            visible: CGRect(x: 190, y: 0, width: 400, height: 860), cropped: true, featherPoints: feather)).uncovered)
    }

    func testAStaleCropOutsideTheViewLeavesEverythingToTheBackdrop() throws {
        let coverage = try XCTUnwrap(BackdropComposite.coverage(bounds: bounds, crisp: CGRect(x: 2100, y: 0, width: 300, height: 300),
            visible: CGRect(x: 0, y: 0, width: 400, height: 800), cropped: true, featherPoints: feather))
        XCTAssertEqual(coverage.crisp, .zero)
        XCTAssertTrue(coverage.uncovered)
        XCTAssertEqual(coverage.feather, BackdropEdges())
    }

    func testTheFeatherNeverExceedsHalfASmallCrop() throws {
        let coverage = try XCTUnwrap(BackdropComposite.coverage(bounds: bounds, crisp: CGRect(x: 100, y: 100, width: 10, height: 6),
            visible: .null, cropped: true, featherPoints: feather))
        XCTAssertEqual(coverage.feather, BackdropEdges(top: 3, left: 5, bottom: 3, right: 5))
        XCTAssertEqual(coverage.visible, bounds, "with no known view, all of it")
        XCTAssertFalse(coverage.uncovered, "nothing visible, nothing uncovered")
    }

    func testCoverageFollowsTheViewportsOwnPlacement() throws {
        var view = ViewportTransform(sourceSize: CGSize(width: 1920, height: 1243), canvasSize: CGSize(width: 402, height: 874), mode: .fit)
        XCTAssertNil(BackdropComposite.coverage(viewport: view, region: nil, displayScale: 3), "Fit, whole display")
        view.setZoom(4, anchoredAt: CGPoint(x: 201, y: 437))
        let region = CaptureRegion(epoch: 5, x: 700, y: 400, width: 500, height: 450, outputWidth: 1000, outputHeight: 900)
        let coverage = try XCTUnwrap(BackdropComposite.coverage(viewport: view, region: region, displayScale: 3))
        XCTAssertEqual(coverage.bounds.size, view.contentRect.size)
        XCTAssertEqual(coverage.crisp, view.picturePlacement(for: region).intersection(coverage.bounds))
        XCTAssertEqual(coverage.feather.left, 24 / 3, "24 phone pixels")
        XCTAssertNil(BackdropComposite.coverage(viewport: view, region: CaptureRegion(epoch: 0, x: 0, y: 0, width: 1920, height: 1243,
            outputWidth: 2560, outputHeight: 1656), displayScale: 3), "an echoed whole display is not a crop")
    }
}

final class BackdropFadeTests: XCTestCase {
    private func crop(_ epoch: UInt64, x: Double) -> CaptureRegion {
        CaptureRegion(epoch: epoch, x: x, y: 100, width: 500, height: 400, outputWidth: 1000, outputHeight: 800)
    }

    func testANewCropFadesThePreviousCoverageOutOverAHundredAndFiftyMilliseconds() {
        var fade = BackdropFade()
        XCTAssertNil(fade.observe(crop(1, x: 100), at: 1), "entering a crop fades nothing")
        XCTAssertEqual(fade.observe(crop(2, x: 300), at: 2), crop(1, x: 100))
        XCTAssertEqual(fade.fading, [BackdropFade.Entry(region: crop(1, x: 100), startedAt: 2)])
        XCTAssertEqual(BackdropFade.duration, 0.15)
        XCTAssertEqual(BackdropFade.opacity(startedAt: 2, at: 2), 1)
        XCTAssertEqual(BackdropFade.opacity(startedAt: 2, at: 2.075), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BackdropFade.opacity(startedAt: 2, at: 2.15), 0, accuracy: 0.0001)
        XCTAssertEqual(BackdropFade.opacity(startedAt: 2, at: 3), 0)
        fade.prune(at: 2.149)
        XCTAssertEqual(fade.fading.count, 1)
        fade.prune(at: 2.151)
        XCTAssertTrue(fade.fading.isEmpty)
    }

    func testOnlyAMovedCropFadesAndLeavingTheCropClearsEveryFade() {
        var fade = BackdropFade()
        _ = fade.observe(crop(1, x: 100), at: 1)
        XCTAssertNil(fade.observe(crop(2, x: 100), at: 1.01), "a new epoch at the same rect changes nothing on screen")
        XCTAssertEqual(fade.current, crop(2, x: 100))
        for step in 1...5 { _ = fade.observe(crop(UInt64(2 + step), x: 100 + Double(step) * 50), at: 1.02 + Double(step) * 0.01) }
        XCTAssertEqual(fade.fading.count, BackdropFade.maximumFading)
        XCTAssertNil(fade.observe(CaptureRegion(epoch: 0, x: 0, y: 0, width: 1920, height: 1243, outputWidth: 2560, outputHeight: 1656), at: 1.1))
        XCTAssertTrue(fade.fading.isEmpty, "the whole-display picture covers everything")
        XCTAssertNil(fade.current)
        XCTAssertNil(fade.observe(nil, at: 1.2))
    }
}

final class BackdropLinkTests: XCTestCase {
    func testSequencesBelongToThePeerSoACaptureRestartNeverGoesBackwards() {
        let link = BackdropLink()
        XCTAssertEqual([link.nextSequence(), link.nextSequence()], [1, 2])
        XCTAssertEqual(link.nextSequence(), 3, "a second capture on the same peer continues the count")
        XCTAssertEqual(link.readiness, .closed, "no channel reads as closed")
        _ = link.end()
        XCTAssertEqual(link.readiness, .closed)
        XCTAssertFalse(link.send(Data([1])))
    }
}

/// The `backdrop.1` channel on real loopback peers.
@MainActor
final class BackdropChannelLoopbackTests: XCTestCase {
    private var descriptions: [String] = []

    private func connect(hostBackdrop: Bool, phoneBackdrop: Bool) async throws -> (PeerMedia, PeerMedia) {
        let host = PeerMedia(isHost: true, servers: [], backdrop: hostBackdrop)
        let phone = PeerMedia(isHost: false, servers: [], backdrop: phoneBackdrop)
        host.onSignal = { [weak self, weak phone] in if let sdp = $0.sdp { self?.descriptions.append(sdp) }; phone?.receive($0) }
        phone.onSignal = { [weak host] in host?.receive($0) }
        var connected = false
        phone.onState = { if $0 == "connected" { connected = true } }
        host.offer()
        let deadline = Date().addingTimeInterval(15)
        while !connected, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(connected)
        return (host, phone)
    }

    private func snapshot(_ sequence: UInt32) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let image = try XCTUnwrap(BackdropSnapshot.encodeImage(try XCTUnwrap(context.makeImage())))
        return BackdropSnapshot(sequence: sequence, displaySize: CGSize(width: 1920, height: 1243), image: image).encoded()
    }

    func testAnAskingPhoneReceivesDecodedSnapshotsAndTheSessionKeepsOneVideoSection() async throws {
        let (host, phone) = try await connect(hostBackdrop: true, phoneBackdrop: true)
        defer { host.close(); phone.close() }
        var images: [BackdropImage] = []
        phone.backdropLink?.onImage = { images.append($0) }
        let message = try snapshot(4)
        let deadline = Date().addingTimeInterval(5)
        while images.isEmpty, Date() < deadline {
            _ = host.sendBackdrop(message)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image.sequence, 4)
        XCTAssertEqual(image.image.width, 64)
        XCTAssertEqual(image.displaySize, CGSize(width: 1920, height: 1243))
        XCTAssertGreaterThan(host.backdropLink?.sent ?? 0, 0)
        XCTAssertEqual(host.backdropLink?.readiness, .ready)
        let older = try snapshot(3)
        XCTAssertTrue(host.sendBackdrop(older))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(images.allSatisfy { $0.sequence == 4 }, "an older snapshot never replaces a newer one")
        let offer = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(offer.components(separatedBy: "m=video").count - 1, 1, "no second video track")
    }

    func testAPhoneThatDidNotAskClosesTheChannelAndKeepsItsSession() async throws {
        let (host, phone) = try await connect(hostBackdrop: true, phoneBackdrop: false)
        defer { host.close(); phone.close() }
        var states: [String] = []
        phone.onState = { states.append($0) }
        host.onState = { states.append($0) }
        XCTAssertNil(phone.backdropLink)
        let message = try snapshot(1)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            _ = host.sendBackdrop(message)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(host.sendBackdrop(message), "the refused channel is closed")
        XCTAssertEqual(host.backdropLink?.readiness, .closed, "so the Mac stops its second capture")
        XCTAssertNotNil(host.controlBufferedAmount, "control stays open")
        XCTAssertFalse(states.contains("closed") || states.contains("failed"))
    }
}
