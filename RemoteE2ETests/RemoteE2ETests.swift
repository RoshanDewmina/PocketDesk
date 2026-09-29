import XCTest
import UIKit

/// Farside end-to-end scenarios: the simulator phone app drives the real Mac host (or the stub
/// host in self-test mode). Run through script/e2e/run-e2e.sh, one test method per scenario.
final class RemoteE2ETests: E2ETestCase {

    // MARK: a. Pair, connect, frames, resolution and quality settle

    func test_a_PairConnectStream() throws {
        try waitFor("host registered with a fresh E2E invitation", timeout: 120) {
            host.state.bool("hostRegistered") && host.state.bool("invitationAvailable")
        }
        recorder.check("host in E2E mode (\(host.state.string("mode") ?? "?"))", host.state.string("launchID") != nil)
        recorder.check("one-time token present before pairing", FileManager.default.fileExists(atPath: E2EPaths.token))
        let start = marks()
        launchPhone(reset: true)
        try waitFor("phone E2E state", timeout: 20) { !phone.state.isEmpty }
        recorder.check("phone published E2E state", true,
                       FileManager.default.fileExists(atPath: E2EPaths.phoneState) ? "file + accessibility" : "accessibility only")
        let pairingStarted = Date()
        try pairViaPaste()
        try waitFor("host auto-approval with the one-time token", timeout: 45) {
            !host.events.since(start.hostEvents, type: "pairing.autoApproved").isEmpty
        }
        recorder.check("host approved the phone only through the one-time token", true)
        recorder.check("token consumed after use", !FileManager.default.fileExists(atPath: E2EPaths.token))
        try waitFor("controllable session after pairing", timeout: 60) { phone.ready }
        recorder.metrics["pairToControlSeconds"] = Date().timeIntervalSince(pairingStarted)
        recorder.check("phone connected with control", true, String(format: "%.1f s after entering the code",
                                                                    Date().timeIntervalSince(pairingStarted)))
        recorder.check("manual approval never requested",
                       host.events.since(start.hostEvents, type: "pairing.awaitingManualApproval").isEmpty)

        try waitFor("host encoding and sending frames", timeout: 30) {
            (host.state.object("stats").double("sentFPS") ?? 0) > 1
        }
        try waitFor("phone decoding frames", timeout: 30) {
            (phone.state.object("stats").double("decodedFPS") ?? 0) > 1 && phone.state.bool("fresh")
        }
        let hostStats = host.state.object("stats"), phoneStats = phone.state.object("stats")
        recorder.metrics["hostStats"] = hostStats
        recorder.metrics["phoneStats"] = phoneStats
        recorder.check("frames arriving", true, "host sent \(hostStats.double("sentFPS") ?? 0) fps, phone decoded \(phoneStats.double("decodedFPS") ?? 0) fps, route \(hostStats.string("route") ?? "?"), codec \(hostStats.string("codec") ?? "?")")

        var samples: [String] = []
        var settled = false
        let settleStart = Date()
        while Date().timeIntervalSince(settleStart) < 25 {
            let h = host.state.object("stats"), p = phone.state
            let ps = p.object("stats")
            let sample = "\(h.int("sentWidth") ?? 0)x\(h.int("sentHeight") ?? 0)>\(ps.int("receivedWidth") ?? 0)x\(ps.int("receivedHeight") ?? 0) q=\(p.string("appliedQuality") ?? "-")/\(p.string("requestedQuality") ?? "-")"
            samples.append(sample)
            let sameSize = h.int("sentWidth") != nil && h.int("sentWidth") == ps.int("receivedWidth") && h.int("sentHeight") == ps.int("receivedHeight")
            let qualityApplied = p.string("appliedQuality") != nil && p.string("appliedQuality") == p.string("requestedQuality")
            if samples.count >= 3, Set(samples.suffix(3)).count == 1, sameSize, qualityApplied { settled = true; break }
            pause(1)
        }
        recorder.metrics["resolutionSamples"] = samples
        recorder.metrics["settleSeconds"] = Date().timeIntervalSince(settleStart)
        recorder.check("resolution and quality settled", settled, samples.last ?? "no samples")
        checkPictureVisible("after pairing")
        if let pointer = host.pointer, let display = host.display, !display.contains(pointer) {
            throw E2EFailure("The Mac pointer is on another display (pointer \(pointer), captured display \(display)), so the phone correctly draws none. Move it onto the captured display and leave the Mac alone during the run. \(host.summary())")
        }
        try waitFor("phone drawing the Mac pointer from telemetry", timeout: 10) {
            let pointer = phone.state.object("pointer")
            return pointer.bool("hostSupported") && pointer.bool("drawn")
        }
        recorder.check("phone-drawn pointer active", true, "cursorInVideo=\(host.state.bool("cursorInVideo"))")
        attachScreenshot("connected")
    }

    // MARK: b. Pointer, clicks, drag, two-finger scroll, pinch zoom and auto-follow

    func test_b_PointerClicksDragScrollZoom() throws {
        launchPhone()
        try ensureConnected()
        try prepareTestPad()

        let a = try element("A")
        try steerPointer(to: CGPoint(x: a.midX, y: a.midY), label: "A")
        let agreement = try pointerAgreement()
        recorder.metrics["pointerAgreementPoints"] = agreement
        recorder.check("phone-drawn pointer matches the Mac pointer", agreement <= 3, String(format: "%.2f pt", agreement))
        var before = marks()
        try ensureTestPadClear(relocate: false)
        tapCanvas()
        try expectClick(on: "A", since: before)

        let b = try element("B")
        try steerPointer(to: CGPoint(x: b.midX, y: b.midY), label: "B")
        pause(0.8)
        before = marks()
        try ensureTestPadClear(relocate: false)
        doubleTapCanvas()
        try expectClick(on: "B", clickCount: 2, since: before)

        let c = try element("C")
        try steerPointer(to: CGPoint(x: c.midX, y: c.midY), label: "C")
        pause(0.8)
        before = marks()
        try ensureTestPadClear(relocate: false)
        twoFingerTapCanvas()
        try expectClick(on: "C", button: "right", since: before)

        if synthesizerAvailable {
            let handle = try element("dragHandle")
            try steerPointer(to: CGPoint(x: handle.midX, y: handle.midY), label: "dragHandle")
            pause(0.8)
            before = marks()
            try ensureTestPadClear(relocate: false)
            try doubleTapHoldDrag(by: CGVector(dx: 150, dy: 60))
            try expectHostInput("dragDown", since: before, timeout: 6)
            try expectHostInput("dragUp", since: before, timeout: 6)
            recorder.check("host accepted a held drag (down, moves, up)", true)
            if !config.isStub {
                // The gesture's first tap is itself a click on the handle (a zero-length drag).
                let end = try expectPadEvent("dragEnd", since: before, "Test Pad drag to finish") {
                    ($0.object("delta").double("x") ?? 0) > 15
                }
                let dx = end.object("delta").double("x") ?? 0
                recorder.check("Test Pad handle moved with the drag", dx > 15, String(format: "Δx %.0f pt", dx))
            }

            let scrollArea = try element("scroll")
            try steerPointer(to: CGPoint(x: scrollArea.midX, y: scrollArea.midY), label: "scroll")
            // Start mid-list so either scroll direction visibly moves the view.
            if !config.isStub { try pad.command("scrollTo", ["y": 900]) }
            pause(0.8)
            let offsetBefore = pad.state.double("scrollOffset") ?? 0
            before = marks()
            let region = strokeRegion
            try ensureTestPadClear(relocate: false)
            try twoFingerScroll(center: CGPoint(x: region.midX, y: region.midY + 40), by: CGVector(dx: 0, dy: -140))
            try expectHostInput("scroll", since: before, timeout: 6) { $0.string("phase") == "began" }
            try expectHostInput("scroll", since: before, timeout: 6) { $0.string("phase") == "ended" }
            recorder.check("host accepted a two-finger scroll stream (began…ended)", true)
            if !config.isStub {
                try expectPadEvent("scroll", since: before, "Test Pad scroll events")
                try waitFor("Test Pad scroll offset to change", timeout: 5) {
                    abs((pad.state.double("scrollOffset") ?? 0) - offsetBefore) > 5
                }
                recorder.check("Test Pad scroll view moved", true,
                               String(format: "offset %.0f → %.0f", offsetBefore, pad.state.double("scrollOffset") ?? 0))
            }
        } else {
            recorder.note("multi-touch synthesis unavailable: drag and two-finger scroll not exercised")
        }

        // Pinch zooms the phone view only; then moving the pointer must make the view follow.
        let zoomMarks = marks()
        canvas.pinch(withScale: 2.4, velocity: 2)
        try waitFor("phone view to zoom in", timeout: 5) { (phone.state.object("viewport").double("zoom") ?? 1) > 1.5 }
        pause(0.6)
        let zoom = phone.state.object("viewport").double("zoom") ?? 1
        recorder.check("pinch zoomed the phone view", zoom > 1.5, String(format: "zoom %.2f", zoom))
        let leaked = host.input.since(zoomMarks.host).filter { $0.string("action") != "move" && $0.bool("accepted") }
        recorder.check("pinch sent no clicks or scrolls to the Mac", leaked.isEmpty, "\(leaked.count) inputs")

        let viewportBefore = phone.state.object("viewport").rect("contentRect") ?? .zero
        let canvasFrame = visibleCanvas
        let candidates = ["D", "A", "dragField", "text"]
        var target: (String, CGPoint)?
        for name in candidates {
            guard let frame = pad.element(name) else { continue }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            if let screenPoint = phoneScreenPoint(forGlobal: point), !canvasFrame.insetBy(dx: 30, dy: 90).contains(screenPoint) {
                target = (name, point)
                break
            }
        }
        if let (name, point) = target {
            try steerPointer(to: point, tolerance: 10, maxStrokes: 24, label: "follow-\(name)")
            pause(0.8)
            let viewportAfter = phone.state.object("viewport").rect("contentRect") ?? .zero
            let panned = hypot(viewportAfter.minX - viewportBefore.minX, viewportAfter.minY - viewportBefore.minY)
            let pointerScreen = host.pointer.flatMap { phoneScreenPoint(forGlobal: $0) }
            let visible = pointerScreen.map { canvasFrame.insetBy(dx: 2, dy: 2).contains($0) } ?? false
            recorder.metrics["followPanPoints"] = panned
            recorder.check("view auto-followed the pointer while zoomed", panned > 20 && visible,
                           String(format: "panned %.0f pt, pointer on screen: %@", panned, visible ? "yes" : "no"))
        } else {
            recorder.note("every target was already visible at this zoom; auto-follow not exercised")
        }
        canvas.pinch(withScale: 0.3, velocity: -2)
        try waitFor("phone view back near baseline", timeout: 6) { (phone.state.object("viewport").double("zoom") ?? 1) < 1.2 }
    }

    // MARK: c. Typing, modifiers, ⌘A/⌘C/⌘V, clipboard both ways, dictation delivery

    func test_c_TypingModifiersClipboardDictation() throws {
        let transcript = "Dictated by Farside E2E \(config.runID.suffix(6))"
        launchPhone(voiceTranscript: transcript)
        try ensureConnected()
        try prepareTestPad()

        let text = try element("text")
        try steerPointer(to: CGPoint(x: text.midX, y: text.midY), label: "text")
        var before = marks()
        try ensureTestPadClear(relocate: false)
        tapCanvas()
        try expectHostInput("click", since: before) { $0.string("target") == "text" }
        recorder.check("click focused the Test Pad text view", true)

        try openPhoneKeyboard()
        let typed = "Farside types 123"
        let field = app.textViews["remote.text"]
        field.tap()
        field.typeText(typed)
        before = marks()
        app.buttons["Send text"].tap()
        try expectHostInput("text", since: before) { $0.string("text") == typed }
        if !config.isStub {
            try waitFor("typed text in the Test Pad", timeout: 5) { pad.state.string("text") == typed }
        }
        recorder.check("typed text delivered", true, typed)

        before = marks()
        for _ in 0..<3 {
            try tapKey("Shift")
            try tapKey("Left arrow")
            pause(0.25)
        }
        try waitFor("three Shift+Left keys accepted", timeout: 5) {
            host.input.since(before.host).filter { $0.string("action") == "key" && $0.string("key") == "left"
                && ($0["modifiers"] as? [String]) == ["shift"] && $0.bool("accepted") }.count == 3
        }
        if !config.isStub {
            try waitFor("three characters selected", timeout: 5) { pad.state.object("selection").int("length") == 3 }
        }
        before = marks()
        try tapKey("Delete")
        try expectHostInput("key", since: before) { $0.string("key") == "delete" }
        if !config.isStub {
            try waitFor("selection deleted", timeout: 5) { pad.state.string("text") == String(typed.dropLast(3)) }
        }
        recorder.check("modifier keys (Shift+Left, Delete) applied", true)

        before = marks()
        try phone.sendKey("a", modifiers: ["command"])
        try expectHostInput("key", since: before) { $0.string("key") == "a" && ($0["modifiers"] as? [String]) == ["command"] }
        if !config.isStub {
            try waitFor("⌘A selected all Test Pad text", timeout: 5) {
                pad.state.object("selection").int("length") == (pad.state.string("text") ?? "").count
            }
        }
        recorder.check("⌘A selects all (sent via the admitted key path; the phone UI has no ⌘A button)", true)

        if phone.state["hostFeatures"].flatMap({ $0 as? [String] })?.contains("clipboard.text.1") == true {
            // The dock's Clip row holds Paste to Mac and Copy from Mac.
            closePhoneKeyboard()
            try revealDock()
            let clip = app.buttons["Clipboard"].firstMatch
            guard clip.waitForExistence(timeout: 3) else { throw E2EFailure("Clipboard dock tile not found") }
            clip.tap()
            let copy = app.buttons["Copy from Mac"].firstMatch
            guard copy.waitForExistence(timeout: 3) else { throw E2EFailure("Copy from Mac not found in the Clip row") }
            let padText = pad.state.string("text") ?? ""
            before = marks()
            try ensureTestPadClear(relocate: false)
            copy.tap()
            try expectHostInput("key", since: before) { $0.string("key") == "c" }
            try waitFor("Mac clipboard to arrive on the phone", timeout: 15) {
                phone.state.object("clipboard").object("fromMac").string("sha256") == E2EDigest.sha256(padText)
            }
            recorder.check("Copy from Mac (⌘C) brought the selection to the phone", true, "\(padText.count) characters")

            let marker = "FARSIDE-E2E-PASTE-\(config.runID.suffix(6))"
            UIPasteboard.general.string = marker
            before = marks()
            let paste = app.buttons["remote.clipboard.paste"].firstMatch
            guard paste.waitForExistence(timeout: 3) else { throw E2EFailure("Paste to Mac control not found") }
            try ensureTestPadClear(relocate: false)
            paste.tap()
            try expectHostInput("key", since: before, timeout: 15) { $0.string("key") == "v" }
            try waitFor("pasted text in the Test Pad", timeout: 10) { (pad.state.string("text") ?? "").contains(marker) }
            recorder.check("Paste to Mac wrote the Mac clipboard and pressed ⌘V", true, marker)
        } else {
            recorder.note("host does not advertise clipboard.text.1 (\(config.mode)); clipboard steps skipped")
        }

        closePhoneKeyboard()
        try revealDock()
        let voice = app.buttons["Voice input"].firstMatch
        guard voice.waitForExistence(timeout: 3) else { throw E2EFailure("Voice input button not found") }
        voice.tap()
        let done = app.buttons["remote.voice.done"]
        try waitFor("synthetic transcript ready to insert", timeout: 8) { done.exists && done.isEnabled }
        before = marks()
        done.tap()
        try expectHostInput("text", since: before, timeout: 8) { $0.string("text") == transcript }
        if !config.isStub {
            try waitFor("dictated text in the Test Pad", timeout: 5) { (pad.state.string("text") ?? "").contains(transcript) }
        }
        recorder.check("dictation Done-to-insert delivery (synthetic transcript; no microphone)", true, transcript)
    }

    // MARK: d. Background, host reboot recovery, signaling restart

    func test_d1_BackgroundShort() throws {
        try runBackground(seconds: config.backgroundShortSeconds)
    }

    func test_d2_BackgroundLong() throws {
        try runBackground(seconds: config.backgroundLongSeconds)
    }

    /// Normal restart: the harness quits its host gracefully (SIGTERM, a clean exit the watchdog
    /// ignores) and opens it again, as after a reboot or an update.
    func test_d3_HostRebootRecovery() throws {
        launchPhone()
        try ensureConnected()
        try prepareTestPad()
        try clickElement("A")
        let quit = Date()
        try harness.request("host.kill", ["signal": "TERM"])
        try waitFor("phone to notice the host quit", timeout: 20) { !phone.state.bool("connected") }
        recorder.metrics["hostQuit.detectSeconds"] = Date().timeIntervalSince(quit)
        try harness.request("host.launch", timeout: 120)
        let relaunched = Date()
        let automatic = (try? waitFor("automatic reconnect after the host restarted", timeout: config.reconnectTimeout) { phone.ready }) != nil
        recorder.metrics["hostRestart.reconnectSeconds"] = Date().timeIntervalSince(relaunched)
        recorder.check("phone reconnected automatically after the host quit and reopened", automatic,
                       automatic ? String(format: "%.1f s", Date().timeIntervalSince(relaunched)) : "needed a user tap: \(phone.summary())")
        if !automatic { try ensureConnected() }
        checkPictureVisible("after the host restarted")
        try prepareTestPad()
        try clickElement("B")
    }

    /// Crash recovery: one kill -9 of the E2E host; the watchdog helper (run by the harness in E2E
    /// mode against the E2E run record only) must reopen it within 10 s and the phone must reconnect
    /// on its own and say once that Farside restarted. One unexpected exit per run keeps the
    /// crash-loop guard (3 in 5 minutes) far away.
    func test_d5_WatchdogRelaunch() throws {
        if config.isStub { throw XCTSkip("The watchdog helper ships only inside the real host app") }
        launchPhone()
        try ensureConnected()
        try prepareTestPad()
        try clickElement("A")
        try harness.request("watchdog.start")
        cleanups.append { [harness = self.harness] in _ = try? harness.request("watchdog.stop") }
        pause(4)
        let previousLaunch = host.state.string("launchID")
        let recoveredNotice = "Your Mac’s Farside restarted — reconnected."
        let noticesBefore = phone.state.object("noticesSeen").int(recoveredNotice) ?? 0
        let response = try harness.request("host.kill", ["signal": "KILL", "awaitRelaunch": true], timeout: 60)
        let relaunchSeconds = response.double("seconds") ?? .infinity
        recorder.metrics["watchdogRelaunchSeconds"] = relaunchSeconds
        recorder.check("watchdog reopened the host within 10 s of kill -9", relaunchSeconds <= 10,
                       String(format: "%.1f s", relaunchSeconds))
        try waitFor("reopened host to report a recovered launch", timeout: 20) {
            host.state.string("launchID") != previousLaunch && host.state.bool("recoveredLaunch")
        }
        recorder.check("host knows it recovered from an unexpected exit", host.state.bool("recoveredFromUnexpectedExit"))
        let reopened = Date()
        let automatic = (try? waitFor("phone reconnect after the watchdog relaunch", timeout: 100) { phone.ready }) != nil
        recorder.metrics["watchdogRelaunch.reconnectSeconds"] = Date().timeIntervalSince(reopened)
        recorder.check("phone reconnected automatically after the watchdog relaunch", automatic,
                       automatic ? "" : "needed a user tap: \(phone.summary())")
        if !automatic { try ensureConnected() }
        checkPictureVisible("after the watchdog relaunch")
        try waitFor("the one-time restart notice", timeout: 10) {
            (phone.state.object("noticesSeen").int(recoveredNotice) ?? 0) > noticesBefore
        }
        let seen = (phone.state.object("noticesSeen").int(recoveredNotice) ?? 0) - noticesBefore
        recorder.check("phone said once that the Mac's Farside restarted", seen == 1, "\(seen) notices")
        try prepareTestPad()
        try clickElement("B")
        try harness.request("watchdog.stop")
    }

    func test_d4_SignalingRestart() throws {
        launchPhone()
        try ensureConnected()
        try prepareTestPad()
        try clickElement("A")
        let stopped = Date()
        try harness.request("service.stop")
        try waitFor("phone to lose the session when signaling stops", timeout: 20) { !phone.state.bool("connected") }
        recorder.metrics["serviceStop.detectSeconds"] = Date().timeIntervalSince(stopped)
        pause(2)
        try harness.request("service.start")
        let restarted = Date()
        let automatic = (try? waitFor("automatic reconnect after the signaling restart", timeout: config.reconnectTimeout) { phone.ready }) != nil
        recorder.metrics["serviceRestart.reconnectSeconds"] = Date().timeIntervalSince(restarted)
        recorder.check("phone and host reconnected automatically after the signaling restart", automatic,
                       automatic ? "" : "\(phone.summary()) \(host.summary())")
        if !automatic { try ensureConnected() }
        checkPictureVisible("after the signaling restart")
        try prepareTestPad()
        try clickElement("B")
    }

    private func runBackground(seconds: Double) throws {
        launchPhone()
        try ensureConnected()
        try prepareTestPad()
        try clickElement("A")
        let sessionsBefore = phone.state.int("connectedSessions") ?? 0
        let before = marks()
        XCUIDevice.shared.press(.home)
        let away = Date()
        if seconds >= 4 {
            pause(min(3, seconds / 2))
            if !config.isStub {
                recorder.metrics["hostPausedWhileBackgrounded"] = host.state.bool("phonePaused")
            }
        }
        pause(max(0, seconds - Date().timeIntervalSince(away)))
        let leaked = host.input.since(before.host).filter { $0.bool("accepted") && $0.string("action") != "release" }
        recorder.check("no input reached the Mac while backgrounded", leaked.isEmpty, "\(leaked.count) accepted inputs")
        let returned = Date()
        app.activate()
        try waitFor("controllable session after returning from \(Int(seconds)) s in the background", timeout: 45) { phone.ready }
        let resume = Date().timeIntervalSince(returned)
        let reconnected = (phone.state.int("connectedSessions") ?? 0) > sessionsBefore
        recorder.metrics["backgroundSeconds"] = seconds
        recorder.metrics["resumeSeconds"] = resume
        recorder.metrics["reconnected"] = reconnected
        recorder.check("session resumed after \(Int(seconds)) s in the background without re-pairing",
                       phone.state.bool("paired") && resume < 30,
                       String(format: "%.1f s, %@", resume, reconnected ? "reconnected" : "held session resumed"))
        checkPictureVisible("after \(Int(seconds)) s in the background")
        try prepareTestPad()
        try clickElement("B")
    }

    // MARK: e. Native full screen and Spaces

    func test_e_FullScreenSpaces() throws {
        if config.isStub { throw XCTSkip("Spaces and full screen need the real host injecting input") }
        guard config.spaceKeysEnabled else {
            throw XCTSkip("Mission Control 'Move left/right a space' shortcuts are disabled on this Mac")
        }
        launchPhone()
        try ensureConnected()
        try prepareTestPad()
        cleanups.append { [pad = self.pad, harness = self.harness] in
            if pad.state.bool("fullscreen") { _ = try? pad.command("exitFullScreen", timeout: 10) }
            _ = try? harness.request("testpad.activate")
        }
        recorder.check("Test Pad starts in a window on the current Space", !pad.state.bool("fullscreen") && pad.state.bool("onActiveSpace"))

        try pressFullScreenButton()
        try waitFor("Test Pad in native full screen", timeout: 15) { pad.state.bool("fullscreen") && pad.state.bool("onActiveSpace") }
        pause(1.5)
        try waitFor("stream still fresh after entering full screen", timeout: 10) { phone.ready }
        recorder.check("entered full screen from the phone; stream followed", true)

        var before = marks()
        try threeFingerSwipe(right: true)
        let swipe = try expectHostInput("key", since: before) { $0.string("key") == "left" && ($0["modifiers"] as? [String]) == ["control"] }
        try waitFor("Mac moved to the previous Space", timeout: 8) { !pad.state.bool("onActiveSpace") }
        recorder.check("three-finger swipe right moved one Space left", true, "fence=\(swipe.string("fence") ?? "?")")
        pause(1)
        try waitFor("stream fresh on the other Space", timeout: 10) { phone.state.bool("fresh") }

        try revealDock()
        app.buttons["Controls"].tap()
        let next = app.buttons["Next Space"].firstMatch
        let content = app.descendants(matching: .any)["remote.controls.content"].firstMatch
        for _ in 0..<5 where !(next.exists && next.isHittable) { content.swipeUp() }
        before = marks()
        next.tap()
        try expectHostInput("key", since: before) { $0.string("key") == "right" && ($0["modifiers"] as? [String]) == ["control"] }
        app.buttons["Done"].firstMatch.tap()
        try waitFor("back on the Test Pad's full-screen Space", timeout: 8) {
            pad.state.bool("onActiveSpace") && pad.state.bool("fullscreen") && host.state.bool("testPadFrontmost")
        }
        recorder.check("Controls › Next Space (⌃→) returned to the Test Pad", true)
        pause(1)
        try waitFor("stream fresh after returning", timeout: 10) { phone.ready }
        try clickElement("A")
        recorder.check("input lands in the full-screen Test Pad after Space switching", true)

        try pressFullScreenButton()
        try waitFor("Test Pad back in a window", timeout: 15) { !pad.state.bool("fullscreen") && pad.state.bool("onActiveSpace") }
        recorder.check("exited full screen on the original Space", true)
    }

    /// The full-screen control is a standard button: its evidence is the button action, not a
    /// target click.
    private func pressFullScreenButton() throws {
        let frame = try element("fullscreenButton")
        try steerPointer(to: CGPoint(x: frame.midX, y: frame.midY), tolerance: 4, label: "fullscreenButton")
        pause(0.8)
        let before = marks()
        try ensureTestPadClear(relocate: false)
        tapCanvas()
        try expectHostInput("click", since: before) { $0.string("target") == "fullscreenButton" }
        try expectPadEvent("fullscreenButton", since: before, "Test Pad full-screen button pressed")
    }

    // MARK: g. Three-finger swipes in every direction, and a scroll that rests mid-way

    /// Stub host: each three-finger swipe, landed together or staggered with drift, sends exactly
    /// one ⌃-arrow and nothing else. Both hosts: fingers resting mid-scroll keep the stream alive
    /// (zero-distance keep-alives), so the scroll after the rest is still accepted.
    /// On the real host the input fence refuses ⌃↑/⌃↓ and ⌃←/⌃→ would switch Spaces (scenario e
    /// covers that), so the swipe half runs against the stub only.
    func test_g_ThreeFingerSwipesAndScrollRest() throws {
        try requireSynthesizer()
        launchPhone()
        try ensureConnected()
        try prepareTestPad()

        if config.isStub {
            let swipes: [(CGVector, String, String)] = [
                (CGVector(dx: -150, dy: 0), "right", "left"), (CGVector(dx: 150, dy: 0), "left", "right"),
                (CGVector(dx: 0, dy: -150), "up", "up"), (CGVector(dx: 0, dy: 150), "down", "down")
            ]
            for staggered in [false, true] {
                for (delta, key, direction) in swipes {
                    pause(0.7)
                    let before = marks()
                    try threeFingerSwipe(by: delta, staggered: staggered)
                    try expectHostInput("key", since: before) {
                        $0.string("key") == key && ($0["modifiers"] as? [String]) == ["control"]
                    }
                    pause(0.5)
                    let lines = host.input.since(before.host).filter { $0.bool("accepted") }
                    let keys = lines.filter { $0.string("action") == "key" }
                    let leaked = lines.filter { ["click", "right", "double", "middle", "dragDown", "text"].contains($0.string("action") ?? "") }
                    recorder.check("three-finger swipe \(direction)\(staggered ? ", staggered landing" : "") sends ⌃\(key) once",
                                   keys.count == 1 && leaked.isEmpty, "keys=\(keys.count) leaked=\(leaked.map { $0.string("action") ?? "?" })")
                }
            }
        } else {
            recorder.note("real host: swipes are covered by scenario e; only the resting scroll runs here")
        }

        let scrollArea = try element("scroll")
        try steerPointer(to: CGPoint(x: scrollArea.midX, y: scrollArea.midY), label: "scroll")
        if !config.isStub { try pad.command("scrollTo", ["y": 900]) }
        pause(0.8)
        let before = marks()
        try ensureTestPadClear(relocate: false)
        let region = strokeRegion
        try twoFingerScrollWithRest(center: CGPoint(x: region.midX, y: region.midY + 40),
                                    first: CGVector(dx: 0, dy: -70), rest: 1.0, then: CGVector(dx: 0, dy: -70))
        try expectHostInput("scroll", since: before, timeout: 8) { $0.string("phase") == "ended" }
        let scrolls = host.input.since(before.host).filter { $0.string("action") == "scroll" }
        let isKeepAlive: (JSONObject) -> Bool = {
            $0.string("phase") == "changed" && ($0.double("dx") ?? 1) == 0 && ($0.double("dy") ?? 1) == 0
        }
        let lastKeepAlive = scrolls.lastIndex(where: isKeepAlive)
        let resumed = lastKeepAlive.map { index in
            scrolls[(index + 1)...].contains { $0.string("phase") == "changed" && !isKeepAlive($0) && $0.bool("accepted") }
        } ?? false
        recorder.check("resting fingers keep the scroll stream alive",
                       scrolls.filter(isKeepAlive).count >= 2 && scrolls.filter(isKeepAlive).allSatisfy { $0.bool("accepted") },
                       "\(scrolls.filter(isKeepAlive).count) keep-alives over a 1 s rest")
        recorder.check("scrolling after the rest continues the same stream", resumed)
        recorder.check("the stream still ends cleanly",
                       scrolls.contains { $0.string("phase") == "ended" && $0.bool("accepted") })
    }

    // MARK: f. Soak

    /// Continuous pointer motion plus periodic verified clicks. Fails on disconnects, video stalls
    /// over 1 s, missed clicks or a memory trend. The harness relaunches the host right before this
    /// scenario, so the signaling room's lifetime boundary (30 min by default) falls at a known point:
    /// a soak longer than that (`--long`) reports whether the session survives it.
    func test_f_Soak() throws {
        launchPhone()
        try ensureConnected()
        try prepareTestPad()
        let duration = config.soakSeconds
        let home = try element("home")
        try steerPointer(to: CGPoint(x: home.midX, y: home.midY), tolerance: 20, label: "home")
        let registeredAt = host.events.refresh().last(where: { $0.string("type") == "service.registered" })?.double("t")
        let roomAge = registeredAt.map { Date().timeIntervalSince1970 - $0 } ?? 0
        // The service's /ready: renewal on/off, the lease, and renewal counters (no room IDs).
        let readyAtStart = (try? harness.request("service.ready"))?.object("ready").object("renewal") ?? [:]
        let lease = readyAtStart.double("leaseSeconds") ?? config.roomLifetimeSeconds
        let renewalEnabled = readyAtStart.bool("enabled")
        let boundary = lease - roomAge
        let crossesBoundary = duration > boundary + 60
        // Peers renew at half-life, so a soak that outlives it must see at least one renewal.
        let expectsRenewal = renewalEnabled && roomAge + duration > lease / 2 + 60
        recorder.metrics["roomLifetimeSeconds"] = lease
        recorder.metrics["sessionRenewalEnabled"] = renewalEnabled
        recorder.metrics["roomAgeAtSoakStartSeconds"] = roomAge
        recorder.note(String(format: "soak %.0f s; room lease %.0f s ends %.0f s in (%@); renewal %@", duration, lease, boundary,
                             crossesBoundary ? "crossed" : "not reached", renewalEnabled ? "on" : "off"))
        let startPhone = phone.state, startHost = host.state
        let startStalls = startPhone.int("stallsOver1s") ?? 0
        var samples: [JSONObject] = []
        var clicks = 0, clickFailures: [String] = []
        var maxFrameAge = 0.0
        var outages: [JSONObject] = []
        var unexpectedOutages = 0
        let begin = Date()
        var nextClick = begin.addingTimeInterval(15)
        var nextSample = begin
        var nextRecentre = begin.addingTimeInterval(60)
        var angle = 0.0
        let targets = ["A", "B", "C", "D"]
        soak: while Date().timeIntervalSince(begin) < duration {
            let now = Date()
            if now >= nextSample {
                nextSample = now.addingTimeInterval(5)
                let p = phone.state, h = host.state
                let age = p.double("lastFrameAgeMs") ?? 0
                if p.bool("connected") { maxFrameAge = max(maxFrameAge, age) }
                samples.append([
                    "t": now.timeIntervalSince(begin), "connected": p.bool("connected"), "fresh": p.bool("fresh"),
                    "frameAgeMs": age, "decodedFPS": p.object("stats").double("decodedFPS") as Any,
                    "renderGapMaxMs": p.object("stats").double("renderGapMaxMs") as Any,
                    "freezes": p.object("stats").int("freezes") as Any,
                    "hostSentFPS": h.object("stats").double("sentFPS") as Any,
                    "hostEncodeMs": h.object("stats").double("encodeMs") as Any,
                    "phoneFootprint": p.double("footprintBytes") as Any, "hostFootprint": h.double("footprintBytes") as Any,
                    "phoneCPU": p.double("cpuPercent") as Any, "hostCPU": h.double("cpuPercent") as Any
                ])
                if !p.bool("connected") {
                    // Measure the product's own recovery; the test never taps Connect here.
                    let lostAt = now.timeIntervalSince(begin)
                    let nearBoundary = abs(lostAt - boundary) < 90
                    let recovered = (try? waitFor("automatic recovery after the session ended at \(Int(lostAt)) s",
                                                  timeout: config.reconnectTimeout) { phone.ready }) != nil
                    let outage: JSONObject = ["at": lostAt, "nearRoomBoundary": nearBoundary, "recovered": recovered,
                                              "recoverySeconds": Date().timeIntervalSince(now),
                                              "phoneStatus": p.string("status") ?? "", "notice": p.string("sessionNotice") ?? ""]
                    outages.append(outage)
                    recorder.note("session ended at \(Int(lostAt)) s (room boundary: \(nearBoundary)); recovered: \(recovered)")
                    unexpectedOutages += 1
                    if !recovered { break soak }
                    try? prepareTestPad()
                    continue
                }
            }
            if now >= nextClick {
                nextClick = now.addingTimeInterval(15)
                let name = targets[clicks % targets.count]
                clicks += 1
                do { try clickElement(name) } catch { clickFailures.append("\(name) at \(Int(now.timeIntervalSince(begin))) s: \(error)") }
                continue
            }
            if now >= nextRecentre {
                nextRecentre = now.addingTimeInterval(60)
                try? steerPointer(to: CGPoint(x: home.midX, y: home.midY), tolerance: 30, label: "home")
                continue
            }
            // Continuous motion: quarter arcs around the canvas centre.
            let region = strokeRegion
            let radius: CGFloat = 55
            let from = CGPoint(x: region.midX + radius * cos(angle), y: region.midY + radius * sin(angle))
            angle += .pi / 2
            let to = CGPoint(x: region.midX + radius * cos(angle), y: region.midY + radius * sin(angle))
            try? stroke(from: from, by: CGVector(dx: to.x - from.x, dy: to.y - from.y), speed: 220)
        }
        let elapsed = Date().timeIntervalSince(begin)
        let endPhone = phone.state
        let stalls = (endPhone.int("stallsOver1s") ?? 0) - startStalls
        recorder.metrics["soakSeconds"] = elapsed
        recorder.metrics["samples"] = samples
        recorder.metrics["outages"] = outages
        recorder.metrics["clicks"] = clicks
        recorder.metrics["clickFailures"] = clickFailures
        recorder.metrics["maxFrameAgeMs"] = maxFrameAge
        recorder.metrics["maxRenderGapMs"] = endPhone.double("maxRenderGapMs") as Any
        recorder.check("soak ran the full duration", elapsed >= duration * 0.98 && endPhone.bool("connected"),
                       String(format: "%.0f of %.0f s", elapsed, duration))
        // The phone counts every drop of its session at 10 Hz, including blips between 5 s samples.
        let phoneDisconnects = (endPhone.int("disconnects") ?? 0) - (startPhone.int("disconnects") ?? 0)
        recorder.metrics["phoneDisconnects"] = phoneDisconnects
        recorder.check("no disconnects during the soak", unexpectedOutages == 0 && phoneDisconnects == 0,
                       unexpectedOutages == 0 && phoneDisconnects == 0 ? "none"
                           : "\(phoneDisconnects) session drops; outages " + outages.map { "at \(Int($0.double("at") ?? 0)) s" }.joined(separator: ", "))
        if crossesBoundary {
            let boundaryOutages = outages.filter { $0.bool("nearRoomBoundary") }
            let survived = boundaryOutages.isEmpty && elapsed > boundary + 30
            recorder.metrics["survivedRoomBoundary"] = survived
            recorder.check("session survived the \(Int(lease / 60))-minute room lease without a disconnect", survived,
                           boundaryOutages.isEmpty ? String(format: "connected through %.0f s (lease ended %.0f s in)", elapsed, boundary)
                               : "ended at \(Int(boundaryOutages[0].double("at") ?? 0)) s; recovered automatically: \(boundaryOutages[0].bool("recovered"))")
        }
        let readyAtEnd = (try? harness.request("service.ready"))?.object("ready").object("renewal") ?? [:]
        let renewals = (readyAtEnd.int("renewals") ?? 0) - (readyAtStart.int("renewals") ?? 0)
        let refreshes = (readyAtEnd.int("credentialRefreshes") ?? 0) - (readyAtStart.int("credentialRefreshes") ?? 0)
        recorder.metrics["serviceRenewals"] = renewals
        recorder.metrics["serviceCredentialRefreshes"] = refreshes
        if expectsRenewal {
            recorder.check("the service renewed the room lease during the soak", renewals >= 1,
                           "\(renewals) renewals, \(refreshes) credential refreshes")
        } else if !renewalEnabled {
            recorder.note("the service does not offer session renewal (SESSION_RENEWAL=0 or an older service)")
        }
        recorder.check("no video stall over 1 s", stalls == 0 && maxFrameAge < 1000,
                       String(format: "%d stalls, max frame age %.0f ms, max render gap %.0f ms", stalls, maxFrameAge,
                              endPhone.double("maxRenderGapMs") ?? 0))
        recorder.check("every periodic click landed", clickFailures.isEmpty, "\(clicks - clickFailures.count)/\(clicks)")
        for (role, start, end) in [("phone", startPhone, endPhone), ("host", startHost, host.state)] {
            let warm = samples.dropFirst(min(samples.count / 5, 24)).first?["\(role)Footprint"] as? Double
            let first = warm ?? start.double("footprintBytes") ?? 0
            let last = end.double("footprintBytes") ?? 0
            let growth = last - first
            recorder.metrics["\(role)FootprintGrowthMB"] = growth / 1_048_576
            let limit = max(96 * 1_048_576, first * 0.35)
            recorder.check("\(role) memory stable (no leak trend)", growth < limit,
                           String(format: "%.0f → %.0f MB (limit +%.0f MB)", first / 1_048_576, last / 1_048_576, limit / 1_048_576))
        }
    }

    // MARK: Phone UI helpers

    func revealDock() throws {
        if app.buttons["Hide controls"].exists { return }
        let handle = app.buttons["Show controls"]
        guard handle.waitForExistence(timeout: 5) else { throw E2EFailure("Dock handle not found") }
        handle.swipeUp()
        if !app.buttons["Hide controls"].waitForExistence(timeout: 3) {
            handle.swipeUp()
            guard app.buttons["Hide controls"].waitForExistence(timeout: 3) else { throw E2EFailure("Dock did not open") }
        }
    }

    func openPhoneKeyboard() throws {
        if app.textViews["remote.text"].waitForExistence(timeout: 2) { return }
        try revealDock()
        app.buttons["Keyboard"].tap()
        guard app.textViews["remote.text"].waitForExistence(timeout: 5) else { throw E2EFailure("Phone keyboard bar did not open") }
    }

    /// Keyboard-bar keys sit in a horizontal scroll row; bring one on screen before tapping it.
    func tapKey(_ label: String) throws {
        let button = app.buttons[label].firstMatch
        guard button.waitForExistence(timeout: 3) else { throw E2EFailure("Keyboard key \(label) not found") }
        let row = app.descendants(matching: .any)["remote.keys"].firstMatch
        var attempts = 0
        while !button.isHittable && attempts < 6 {
            if attempts < 3 { row.swipeLeft() } else { row.swipeRight() }
            attempts += 1
        }
        guard button.isHittable else { throw E2EFailure("Keyboard key \(label) never came on screen") }
        button.tap()
    }

    func closePhoneKeyboard() {
        let hide = app.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
        _ = app.textViews["remote.text"].waitForNonExistence(timeout: 3)
    }
}
