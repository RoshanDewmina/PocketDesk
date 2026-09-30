import XCTest
import AppKit
import CoreVideo

final class PrivacyCurtainPolicyTests: XCTestCase {
    private var live: PrivacyCurtainInputs {
        PrivacyCurtainInputs(preference: true, sessionLive: true, captureHealthy: true,
                             accessibilityGranted: true)
    }

    func testRaisesOnlyForALiveHealthySessionWithThePreferenceOn() {
        XCTAssertEqual(PrivacyCurtainPolicy.desired(live, currentlyUp: false), .up)
        var off = live; off.preference = false
        XCTAssertEqual(PrivacyCurtainPolicy.desired(off, currentlyUp: false), .down, "Opt-in, default off")
        var waiting = live; waiting.captureHealthy = false
        XCTAssertEqual(PrivacyCurtainPolicy.desired(waiting, currentlyUp: false), .down,
                       "Raised only against a live picture so the stream can be verified")
    }

    func testEveryLiftTriggerLowersACurtainThatIsUp() {
        let triggers: [(String, (inout PrivacyCurtainInputs) -> Void)] = [
            ("session end", { $0.sessionLive = false }),
            ("Stop Sharing", { $0.sessionLive = false }),
            ("phone paused", { $0.phonePaused = true }),
            ("screen locked", { $0.screenLocked = true }),
            ("Esc ×3 at the Mac", { $0.locallyDismissed = true }),
            ("stream check failed", { $0.raiseFailed = true }),
            ("Accessibility revoked", { $0.accessibilityGranted = false }),
            ("stopped after repeated crashes", { $0.safeMode = true }),
            ("preference off", { $0.preference = false }),
            ("picture lost", { $0.captureHealthy = false; $0.unhealthyFor = 6 })
        ]
        for (name, apply) in triggers {
            var inputs = live
            apply(&inputs)
            XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: true), .down, name)
        }
    }

    func testBriefHiccupsAndDisplaySleepKeepTheCurtain() {
        var hiccup = live
        hiccup.captureHealthy = false
        hiccup.unhealthyFor = 2
        XCTAssertEqual(PrivacyCurtainPolicy.desired(hiccup, currentlyUp: true), .up)
        hiccup.unhealthyFor = 60
        hiccup.displayAsleep = true
        XCTAssertEqual(PrivacyCurtainPolicy.desired(hiccup, currentlyUp: true), .up,
                       "A sleeping display stays covered so waking it never exposes the desktop")
    }

    func testReconfiguringKeepsARaisedCurtainUpThroughLostPicture() {
        var inputs = PrivacyCurtainInputs(preference: true, sessionLive: true, captureHealthy: false, unhealthyFor: 9,
                                          accessibilityGranted: true)
        inputs.displayReconfiguring = true
        XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: true), .up, "Big Text changes never uncover the Mac")
    }

    func testReconfiguringNeverRaisesACurtainThatIsDown() {
        var inputs = PrivacyCurtainInputs(preference: true, sessionLive: true, captureHealthy: false, accessibilityGranted: true)
        inputs.displayReconfiguring = true
        XCTAssertEqual(PrivacyCurtainPolicy.desired(inputs, currentlyUp: false), .down)
    }

    func testProtocolStateTellsThePhoneWhy() {
        XCTAssertEqual(PrivacyCurtainPolicy.protocolState(live, up: true), .up)
        XCTAssertEqual(PrivacyCurtainPolicy.protocolState(live, up: false), .pending)
        var inputs = live
        inputs.preference = false
        XCTAssertEqual(PrivacyCurtainPolicy.protocolState(inputs, up: false), .off)
        inputs = live; inputs.locallyDismissed = true
        XCTAssertEqual(PrivacyCurtainPolicy.protocolState(inputs, up: false), .liftedLocally)
        inputs = live; inputs.raiseFailed = true
        XCTAssertEqual(PrivacyCurtainPolicy.protocolState(inputs, up: false), .failed)
        inputs = live; inputs.accessibilityGranted = false
        XCTAssertEqual(PrivacyCurtainPolicy.protocolState(inputs, up: false), .unavailable)
        XCTAssertTrue(PrivacyCurtainState.liftedLocally.preferenceOn)
        XCTAssertFalse(PrivacyCurtainState.off.preferenceOn)
    }

    func testThreeSeparateLocalEscapePressesLift() {
        var tap = EscapeTripleTap()
        XCTAssertFalse(tap.register(at: 1.0, isRepeat: false, injected: false))
        XCTAssertFalse(tap.register(at: 1.3, isRepeat: true, injected: false), "Holding Esc is not three presses")
        XCTAssertFalse(tap.register(at: 1.4, isRepeat: false, injected: true), "The phone's Esc never lifts it")
        XCTAssertFalse(tap.register(at: 1.6, isRepeat: false, injected: false))
        XCTAssertTrue(tap.register(at: 2.2, isRepeat: false, injected: false))

        var slow = EscapeTripleTap()
        XCTAssertFalse(slow.register(at: 0, isRepeat: false, injected: false))
        XCTAssertFalse(slow.register(at: 1.5, isRepeat: false, injected: false))
        XCTAssertFalse(slow.register(at: 3.0, isRepeat: false, injected: false), "Presses must fall within two seconds")
        XCTAssertTrue(slow.register(at: 3.4, isRepeat: false, injected: false))
    }

    func testInjectedEventsAreTaggedAndRecognised() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        XCTAssertFalse(RemoteInputTag.isInjected(event, ownPID: 1))
        RemoteInputTag.mark(event)
        XCTAssertTrue(RemoteInputTag.isInjected(event, ownPID: 1))
        XCTAssertFalse(RemoteInputTag.isInjected(nil))
    }
}

final class CurtainCaptureExclusionTests: XCTestCase {
    private struct Window: Equatable { let id: CGWindowID }

    func testEveryCurtainWindowMustBeFoundOrNothingIsExcluded() {
        let shareable = [Window(id: 10), Window(id: 11), Window(id: 12), Window(id: 90)]
        XCTAssertEqual(CaptureWindowExclusion.windows(for: [11, 12], in: shareable, id: \.id),
                       [Window(id: 11), Window(id: 12)])
        XCTAssertNil(CaptureWindowExclusion.windows(for: [11, 13], in: shareable, id: \.id),
                     "Excluding only one display's curtain would leave the other in the stream")
        XCTAssertNil(CaptureWindowExclusion.windows(for: [], in: shareable, id: \.id))
    }

    private func buffer(format: OSType, luma: UInt8, width: Int = 64, height: Int = 36) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        if format == kCVPixelFormatType_32BGRA {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
            memset(base, Int32(luma), CVPixelBufferGetBytesPerRow(pixels) * height)
        } else {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
            memset(base, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * height)
        }
        return pixels
    }

    func testCanaryDetectsTheCurtainAppearingInTheStream() throws {
        let desktop = try XCTUnwrap(CaptureLumaSignature(pixelBuffer: buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: 150)))
        let curtain = try XCTUnwrap(CaptureLumaSignature(pixelBuffer: buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: 20)))
        let bgraCurtain = try XCTUnwrap(CaptureLumaSignature(pixelBuffer: buffer(format: kCVPixelFormatType_32BGRA, luma: 5)))
        XCTAssertEqual(desktop.samples.count, 64)
        XCTAssertTrue(CurtainCanary.looksLikeCurtain(curtain))
        XCTAssertTrue(CurtainCanary.looksLikeCurtain(bgraCurtain))
        XCTAssertFalse(CurtainCanary.looksLikeCurtain(desktop))
        XCTAssertTrue(CurtainCanary.exclusionFailed(before: desktop, after: curtain))
        XCTAssertFalse(CurtainCanary.exclusionFailed(before: desktop, after: desktop), "Excluded: the stream is unchanged")
        XCTAssertFalse(CurtainCanary.exclusionFailed(before: curtain, after: curtain),
                       "An already dark desktop cannot prove a failure")
        XCTAssertFalse(CurtainCanary.exclusionFailed(before: nil, after: curtain))
    }

    func testCurtainTextDoesNotHideTheDarkCurtain() throws {
        var samples = [UInt8](repeating: 20, count: 64)
        for index in [27, 28, 35, 36] { samples[index] = 220 }
        let signature = try XCTUnwrap(CaptureLumaSignature(samples: samples))
        XCTAssertTrue(CurtainCanary.looksLikeCurtain(signature))
    }
}

@MainActor
final class PrivacyCurtainControllerTests: XCTestCase {
    /// Tiny, far off-screen windows: the real curtain is never shown by these tests.
    private func offscreenWindows(_ count: Int = 2) -> () -> [NSWindow] {
        {
            (0..<count).map { index in
                let window = NSWindow(contentRect: NSRect(x: -30_000 - Double(index) * 20, y: -30_000, width: 8, height: 8),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.ignoresMouseEvents = true
                window.alphaValue = 0
                window.isReleasedWhenClosed = false
                return window
            }
        }
    }

    private func hooks(exclude: Bool = true, before: CaptureLumaSignature? = nil,
                       after: CaptureLumaSignature? = nil, seen: ((Set<CGWindowID>) -> Void)? = nil)
        -> PrivacyCurtainController.CaptureHooks {
        var calls = 0
        return .init(exclude: { ids in seen?(ids); return exclude },
                     signature: { calls += 1; return calls == 1 ? before : after })
    }

    func testRaisesOnlyAfterEveryWindowIsExcludedFromCapture() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows(2))
        var excluded: Set<CGWindowID> = []
        let result = await curtain.raise(hooks: hooks(seen: { excluded = $0 }), settle: .zero, verifyAfter: .zero)
        XCTAssertEqual(result, .raised)
        XCTAssertEqual(curtain.phase, .up)
        XCTAssertEqual(excluded.count, 2)
        XCTAssertEqual(excluded, curtain.windowIDs, "The filter excludes exactly the curtain's windows")
        curtain.lift()
        XCTAssertEqual(curtain.phase, .down)
        XCTAssertTrue(curtain.windowIDs.isEmpty)
    }

    func testFailedExclusionNeverShowsTheCurtain() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows())
        let result = await curtain.raise(hooks: hooks(exclude: false), settle: .zero, verifyAfter: .zero)
        XCTAssertEqual(result, .exclusionFailed)
        XCTAssertEqual(curtain.phase, .down)
        XCTAssertTrue(curtain.windowIDs.isEmpty)
    }

    func testCanaryFailureLiftsTheCurtain() async throws {
        let desktop = try XCTUnwrap(CaptureLumaSignature(samples: [UInt8](repeating: 160, count: 64)))
        let dark = try XCTUnwrap(CaptureLumaSignature(samples: [UInt8](repeating: 18, count: 64)))
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows())
        var phases: [PrivacyCurtainController.Phase] = []
        curtain.onPhaseChange = { phases.append($0) }
        let result = await curtain.raise(hooks: hooks(before: desktop, after: dark), settle: .zero, verifyAfter: .zero)
        XCTAssertEqual(result, .verificationFailed)
        XCTAssertEqual(curtain.phase, .down)
        XCTAssertEqual(phases, [.up, .down])
    }

    func testThreeLocalEscapesLiftAndReportIt() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows())
        var lifted = 0
        curtain.onLocalLift = { lifted += 1 }
        _ = await curtain.raise(hooks: hooks(), settle: .zero, verifyAfter: .zero)
        XCTAssertFalse(curtain.handleKeyDown(keyCode: 53, timestamp: 1, isRepeat: false, injected: true))
        XCTAssertFalse(curtain.handleKeyDown(keyCode: 12, timestamp: 1.1, isRepeat: false, injected: false))
        XCTAssertFalse(curtain.handleKeyDown(keyCode: 53, timestamp: 1.2, isRepeat: false, injected: false))
        XCTAssertFalse(curtain.handleKeyDown(keyCode: 53, timestamp: 1.4, isRepeat: false, injected: false))
        XCTAssertEqual(curtain.phase, .up)
        XCTAssertTrue(curtain.handleKeyDown(keyCode: 53, timestamp: 1.6, isRepeat: false, injected: false))
        XCTAssertEqual(lifted, 1)
        XCTAssertEqual(curtain.phase, .down)
        XCTAssertFalse(curtain.handleKeyDown(keyCode: 53, timestamp: 1.7, isRepeat: false, injected: false))
    }

    func testLiftingWhileRaisingCancelsCleanly() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows())
        let slowHooks = PrivacyCurtainController.CaptureHooks(
            exclude: { _ in try? await Task.sleep(for: .milliseconds(80)); return true },
            signature: { nil })
        let raising = Task { await curtain.raise(hooks: slowHooks, settle: .zero, verifyAfter: .zero) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(curtain.phase, .raising)
        curtain.lift()
        let result = await raising.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(curtain.phase, .down)
        XCTAssertTrue(curtain.windowIDs.isEmpty, "A lift during raising leaves no windows behind")
    }

    func testDisplayChangesLiftTheCurtain() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows())
        _ = await curtain.raise(hooks: hooks(), settle: .zero, verifyAfter: .zero)
        XCTAssertEqual(curtain.phase, .up)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<20 where curtain.phase != .down { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(curtain.phase, .down)
    }

    func testPlannedDisplayChangeKeepsTheCurtain() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows())
        _ = await curtain.raise(hooks: hooks(), settle: .zero, verifyAfter: .zero)
        curtain.followsScreenChanges = false
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(curtain.phase, .up)
        curtain.followsScreenChanges = true
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<20 where curtain.phase != .down { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(curtain.phase, .down, "Changes nobody planned still lift it")
    }

    func testRefitLiftsWhenTheScreenCountNoLongerMatches() async {
        let curtain = PrivacyCurtainController(makeWindows: offscreenWindows(NSScreen.screens.count + 1))
        _ = await curtain.raise(hooks: hooks(), settle: .zero, verifyAfter: .zero)
        XCTAssertEqual(curtain.phase, .up)
        curtain.refitToScreens()
        XCTAssertEqual(curtain.phase, .down, "A display added or removed would be left uncovered")
    }
}

final class CurtainProtocolTests: XCTestCase {
    func testCurtainRequestsAndStateAreValidatedAndBackwardCompatible() throws {
        XCTAssertNoThrow(try RemoteAction(action: "curtain", epoch: 3, curtain: "up").validate())
        XCTAssertNoThrow(try RemoteAction(action: "curtain", epoch: 3, curtain: "down").validate())
        XCTAssertThrowsError(try RemoteAction(action: "curtain", epoch: 3).validate())
        XCTAssertThrowsError(try RemoteAction(action: "curtain", epoch: 3, curtain: "sideways").validate())
        XCTAssertThrowsError(try RemoteAction(action: "curtain", x: 1, epoch: 3, curtain: "up").validate())
        XCTAssertThrowsError(try RemoteAction(action: "wake", epoch: 3, curtain: "up").validate())
        XCTAssertThrowsError(try RemoteAction(action: "click", epoch: 3, curtain: "up").validate())

        let status = RemoteAction(action: "capture", x: 1, epoch: 3, features: SessionFeature.host,
                                  curtain: PrivacyCurtainState.up.rawValue,
                                  hostEvent: HostLifecycleEvent.recovered.rawValue)
        XCTAssertNoThrow(try status.validate())
        XCTAssertTrue(SessionFeature.host.contains("curtain.1"))
        XCTAssertThrowsError(try RemoteAction(action: "viewing", epoch: 3, hostEvent: "recovered").validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", epoch: 3, hostEvent: "not-a-token").validate())

        // A phone built before these fields decodes the same status and simply ignores them.
        let json = try JSONEncoder().encode(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["curtain"] as? String, "up")
        var legacy = object
        legacy["futureField"] = "ignored"
        let decoded = try JSONDecoder().decode(RemoteAction.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.hostEvent, "recovered")

        let oldHostStatus = RemoteAction(action: "capture", x: 1, epoch: 3,
                                         features: [SessionFeature.clipboardText, SessionFeature.backgroundPause])
        XCTAssertNil(oldHostStatus.curtain, "An older Mac reports no curtain; the phone hides the control")
    }

    func testPhoneNoticesExplainCurtainChanges() {
        XCTAssertEqual(PhoneSessionNotice.curtainChange(from: .up, to: .liftedLocally), PhoneSessionNotice.curtainLiftedLocally)
        XCTAssertEqual(PhoneSessionNotice.curtainChange(from: .pending, to: .failed), PhoneSessionNotice.curtainFailed)
        XCTAssertNil(PhoneSessionNotice.curtainChange(from: .up, to: .up))
        XCTAssertNil(PhoneSessionNotice.curtainChange(from: .off, to: .liftedLocally),
                     "Only a curtain that was up can be lifted at the Mac")
        XCTAssertNil(PhoneSessionNotice.curtainChange(from: .up, to: .off))
        XCTAssertEqual(PhoneSessionNotice.hostRecovered, "Your Mac’s Farside restarted — reconnected.")
    }
}
