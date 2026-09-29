import XCTest

/// Base class for the Farside end-to-end scenarios: launching the phone in E2E mode, reaching a
/// controllable session, phone gestures (including multi-finger ones), closed-loop pointer
/// steering onto Test Pad targets, and expectations against the Test Pad and host logs.
class E2ETestCase: XCTestCase {
    var config: E2ERunConfig!
    var app: XCUIApplication!
    let harness = HarnessClient()
    let pad = TestPadClient()
    let host = HostClient()
    var phone: PhoneClient!
    var recorder: ScenarioRecorder!
    var cleanups: [() -> Void] = []
    private var lastFailure: String?
    private var lastTap: (time: Date, point: CGPoint)?

    /// Scenario id used for the result file, derived from `test_<id>_Description`.
    var scenario: String {
        let method = name.split(separator: " ").last.map { String($0.dropLast()) } ?? name
        let parts = method.split(separator: "_")
        return parts.count >= 2 ? String(parts[1]) : method
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        config = try E2ERunConfig.load()
        recorder = ScenarioRecorder(scenario: scenario)
        app = XCUIApplication()
        phone = PhoneClient(app: app)
        XCUIDevice.shared.orientation = .portrait
        recorder.note("mode=\(config.mode) run=\(config.runID)")
    }

    override func record(_ issue: XCTIssue) {
        lastFailure = [lastFailure, issue.compactDescription].compactMap { $0 }.joined(separator: " | ")
        super.record(issue)
    }

    override func tearDown() {
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups.removeAll()
        let skipped = testRun?.hasBeenSkipped ?? false
        let failed = (testRun?.totalFailureCount ?? 0) > 0
        if failed { attachScreenshot("failure") }
        recorder.metrics["finalHost"] = host.summary()
        recorder.metrics["finalPhone"] = phone.summary()
        recorder.write(status: skipped ? "skipped" : failed ? "failed" : "passed", failure: lastFailure)
        super.tearDown()
    }

    // MARK: Waiting

    func waitFor(_ what: String, timeout: TimeInterval, interval: TimeInterval = 0.2,
                 _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try condition() { return }
            dismissSystemAlerts()
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        if try condition() { return }
        throw E2EFailure("Timed out after \(Int(timeout)) s waiting for \(what). \(phone.summary()) \(host.summary())")
    }

    func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(scenario) \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Picture

    /// Frames arriving is not enough: a Metal view can receive every frame and draw none (build
    /// 20260929.2 showed a black stage with a working session). The stage between the top pills and
    /// the dock must show the Mac's picture rather than the empty Farside void (about 5 of 255).
    func checkPictureVisible(_ moment: String) {
        var share = 0.0
        for attempt in 0..<5 {
            share = litShareOfStage()
            if share >= 0.1 { break }
            if attempt < 4 { pause(0.5) }
        }
        recorder.metrics["stageLitShare.\(moment)"] = share
        recorder.check("Mac picture visible on the phone (\(moment))", share >= 0.1,
                       String(format: "%.0f%% of the stage is lit (an empty stage is 0%%, pointer included)", share * 100))
        if share < 0.1 { attachScreenshot("black stage \(moment)") }
    }

    /// Share of the stage brighter than the void, downsampled to 48 x 48. The band stops above where
    /// the open dock starts: its lighter panel alone lit 20% of a taller band on the black build.
    private func litShareOfStage() -> Double {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let height = CGFloat(image.height)
        let band = CGRect(x: 0, y: height * 0.1, width: CGFloat(image.width), height: height * 0.5).integral
        guard let stage = image.cropping(to: band) else { return 0 }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(stage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        var lit = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luma = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
            if luma > 15 { lit += 1 }
        }
        return Double(lit) / Double(side * side)
    }

    private var lastAlertCheck = Date.distantPast

    /// Accepts the local-network style prompts the simulator may show; never touches the Mac.
    /// Checked at most every 3 s: each accessibility query is slow under load.
    func dismissSystemAlerts() {
        guard Date().timeIntervalSince(lastAlertCheck) > 3 else { return }
        lastAlertCheck = Date()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        for label in ["Allow", "Allow While Using App", "OK"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); recorder?.note("dismissed simulator alert via \(label)"); return }
        }
    }

    // MARK: Phone app

    private var launchedVoiceTranscript: String?

    func launchPhone(reset: Bool = false, voiceTranscript: String? = nil) {
        launchedVoiceTranscript = voiceTranscript
        var arguments = ["--farside-e2e"]
        if let token = E2EFile.text(E2EPaths.token), token.count == 64 { arguments += ["--farside-e2e-token", token] }
        if reset { arguments.append("--farside-e2e-reset-pairing") }
        if let voiceTranscript { arguments += ["--farside-e2e-voice-transcript", voiceTranscript] }
        app.launchArguments = arguments
        app.launchEnvironment = ["FARSIDE_E2E": "1", "FARSIDE_E2E_DIR": E2EPaths.root, "FARSIDE_E2E_RUN_ID": config.runID]
        app.launch()
    }

    /// Reaches a live session with control, pairing through the paste flow if needed.
    func ensureConnected(timeout: TimeInterval = 120) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastAction = Date.distantPast
        try waitFor("phone E2E state after launch", timeout: 20) { !phone.state.isEmpty }
        let initial = phone.state
        let stalePairing = initial.bool("paired") && (
            (config.signalURL != nil && initial.string("invitationServer") != config.signalURL)
            || (host.state.string("launchID") != nil && !host.state.bool("paired")))
        if stalePairing {
            recorder.note("phone kept a pairing from another run; relaunching it with a reset")
            launchPhone(reset: true, voiceTranscript: launchedVoiceTranscript)
            try waitFor("phone E2E state after reset", timeout: 20) { !phone.state.isEmpty }
        }
        var viewOnlySince: Date?
        while Date() < deadline {
            if phone.ready { return }
            dismissSystemAlerts()
            let state = phone.state
            // Live, healthy video but no geometry/viewing ever applied: the session can never
            // become controllable. Fail fast and say so instead of timing out generically.
            if state.bool("connected") && state.bool("fresh") && state.bool("captureHealthy")
                && (state.int("geometryEpoch") ?? 0) == 0 && !state.bool("controlAllowed") {
                viewOnlySince = viewOnlySince ?? Date()
                if Date().timeIntervalSince(viewOnlySince!) > 10 {
                    throw E2EFailure("Session connected with live video, but the phone never received the host's geometry/viewing messages (epoch 0, view-only) for 10 s; the host sends them once when the control channel opens. \(phone.summary()) \(host.summary())")
                }
            } else {
                viewOnlySince = nil
            }
            if Date().timeIntervalSince(lastAction) > 6 {
                if !state.isEmpty && !state.bool("paired") && app.buttons["Paste a pairing code"].exists {
                    lastAction = Date()
                    try pairViaPaste()
                    continue
                }
                for label in ["Reconnect", "Connect"] {
                    let button = app.buttons[label].firstMatch
                    if button.exists && button.isHittable {
                        lastAction = Date()
                        recorder.note("tapped \(label) to reach a session")
                        button.tap()
                        break
                    }
                }
            }
            pause(0.5)
        }
        throw E2EFailure("Phone never reached a controllable session in \(Int(timeout)) s. \(phone.summary()) \(host.summary())")
    }

    func pairViaPaste() throws {
        try waitFor("a fresh invitation from the host", timeout: 150) {
            host.state.bool("invitationAvailable") && (E2EFile.age(E2EPaths.invitation) ?? .infinity) < 90
        }
        guard let code = E2EFile.text(E2EPaths.invitation), code.hasPrefix("pocketdesk:") else {
            throw E2EFailure("Invitation file is missing or malformed")
        }
        let paste = app.buttons["Paste a pairing code"]
        if paste.waitForExistence(timeout: 5) {
            paste.tap()
        } else {
            app.buttons["Help and more"].tap()
            app.buttons["Paste Pairing Code"].tap()
        }
        let field = app.descendants(matching: .any)["Pairing code"].firstMatch
        guard field.waitForExistence(timeout: 5) else { throw E2EFailure("Pairing code field did not appear") }
        field.tap()
        field.typeText(code)
        let pair = app.buttons["Pair Mac"]
        guard pair.waitForExistence(timeout: 3), pair.isEnabled else { throw E2EFailure("Pair Mac stayed disabled after entering the code") }
        pair.tap()
        recorder.note("entered invitation through Paste Code (\(code.count) characters)")
    }

    // MARK: Test Pad

    /// Resets the Test Pad and makes it frontmost; the host fence refuses input otherwise.
    func prepareTestPad() throws {
        try pad.command("reset")
        try harness.request("testpad.activate")
        if !config.isStub {
            try waitFor("Farside Test Pad frontmost on the Mac", timeout: 10) { host.state.bool("testPadFrontmost") }
        }
        try ensureTestPadClear()
    }

    /// Never click while a system alert, crash report or any other window covers the Test Pad:
    /// move it to another corner, or stop the scenario with a clear reason.
    /// Refuses to click while another window overlaps the Test Pad. With `relocate`, first moves (and
    /// if needed shrinks) the Test Pad clear of it; pass false once the pointer has been steered, since
    /// moving the window then would leave the pointer off its target.
    func ensureTestPadClear(relocate: Bool = true) throws {
        var covered = pad.state["coveredBy"] as? [String] ?? []
        guard !covered.isEmpty else { return }
        if config.isStub {
            recorder.note("Test Pad partly covered by \(covered.joined(separator: ", ")) (stub mode sends no real clicks)")
            return
        }
        if relocate && !pad.state.bool("fullscreen") {
            let blockers = covered.joined(separator: ", ")
            let moved = (try? pad.command("avoidCover"))?.bool("ok") ?? false
            if moved {
                _ = try? waitFor("Test Pad clear of \(blockers)", timeout: 4) {
                    (pad.state["coveredBy"] as? [String] ?? []).isEmpty
                }
            }
            covered = pad.state["coveredBy"] as? [String] ?? []
            if covered.isEmpty {
                recorder.note("moved the Test Pad clear of \(blockers)")
                return
            }
        }
        attachScreenshot("test pad covered")
        throw E2EFailure("Blocked by system dialog: the Farside Test Pad is covered by \(covered.joined(separator: ", ")); refusing to click anything.")
    }

    func element(_ name: String) throws -> CGRect {
        guard let frame = pad.element(name), frame.width > 4, frame.height > 4 else {
            throw E2EFailure("Test Pad element \(name) is not published in testpad-state.json")
        }
        return frame
    }

    // MARK: Canvas geometry

    var canvas: XCUIElement { app.descendants(matching: .any)["remote.canvas"].firstMatch }

    /// Screen region where strokes and taps land on the desktop canvas, clear of the dock.
    /// The on-screen part of the canvas. In fill or zoomed modes the trackpad surface is as large as
    /// the Mac picture and extends past the screen edges, so its frame alone can place touches off-screen.
    var visibleCanvas: CGRect {
        let frame = canvas.frame
        let window = app.windows.firstMatch.frame
        let visible = window.width > 0 ? frame.intersection(window) : frame
        return visible.isNull || visible.width < 40 ? frame : visible
    }

    var strokeRegion: CGRect {
        let frame = visibleCanvas
        let viewport = phone.state.object("viewport")
        var region = frame.insetBy(dx: 40, dy: 0)
        region.origin.y = frame.minY + 90
        var bottom = frame.maxY - 130
        if let dock = viewport.rect("dockFrame"), dock.height > 0 { bottom = min(bottom, dock.minY - 24) }
        if viewport.bool("keyboardOpen") { bottom = min(bottom, frame.minY + frame.height * 0.42) }
        region.size.height = max(80, bottom - region.minY)
        return region
    }

    func screen(_ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }

    /// A tap clicks at the Mac pointer wherever the finger lands; keep taps in a quiet spot.
    func tapCanvas() {
        let region = strokeRegion
        let point = CGPoint(x: region.midX, y: region.minY + region.height * 0.3)
        screen(point).tap()
        lastTap = (Date(), point)
    }

    func doubleTapCanvas() {
        let region = strokeRegion
        let point = CGPoint(x: region.midX, y: region.minY + region.height * 0.3)
        screen(point).doubleTap()
        lastTap = (Date(), point)
    }

    func twoFingerTapCanvas() {
        let region = strokeRegion
        let point = CGPoint(x: region.midX, y: region.minY + region.height * 0.3)
        if E2ETouchSynthesizer.isAvailable() {
            let paths = [-22.0, 22.0].map { dx -> E2ETouchPath in
                let path = E2ETouchPath(point: CGPoint(x: point.x + dx, y: point.y), atOffset: 0)
                path.lift(atOffset: 0.08)
                return path
            }
            if (try? E2ETouchSynthesizer.perform(paths, name: "two-finger tap")) != nil {
                lastTap = (Date(), point)
                return
            }
        }
        canvas.twoFingerTap()
        lastTap = (Date(), point)
    }

    /// A drag that begins near a recent tap would become the double-tap-drag gesture.
    private func respectTapGap(start: CGPoint) {
        guard let lastTap else { return }
        let elapsed = Date().timeIntervalSince(lastTap.time)
        if elapsed < 0.7 && hypot(start.x - lastTap.point.x, start.y - lastTap.point.y) < 40 {
            pause(0.7 - elapsed)
        }
    }

    // MARK: Gestures

    var synthesizerAvailable: Bool { E2ETouchSynthesizer.isAvailable() }

    func requireSynthesizer() throws {
        guard synthesizerAvailable else {
            throw XCTSkip("XCTest multi-touch event synthesis is unavailable in this Xcode; multi-finger scenarios skipped")
        }
    }

    /// One-finger stroke at an even speed (points per second in screen space).
    func stroke(from start: CGPoint, by delta: CGVector, speed: CGFloat = 160) throws {
        respectTapGap(start: start)
        let length = hypot(delta.dx, delta.dy)
        let duration = max(0.25, Double(length / speed))
        if synthesizerAvailable {
            let steps = max(8, Int(duration * 60))
            let path = E2ETouchPath(point: start, atOffset: 0)
            for index in 1...steps {
                let fraction = CGFloat(index) / CGFloat(steps)
                path.move(to: CGPoint(x: start.x + delta.dx * fraction, y: start.y + delta.dy * fraction),
                          atOffset: 0.04 + duration * Double(fraction))
            }
            path.lift(atOffset: 0.08 + duration)
            try E2ETouchSynthesizer.perform([path], name: "stroke")
        } else {
            screen(start).press(forDuration: 0.02, thenDragTo: screen(CGPoint(x: start.x + delta.dx, y: start.y + delta.dy)),
                                withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: 0)
        }
    }

    func twoFingerScroll(center: CGPoint, by delta: CGVector, duration: TimeInterval = 0.6) throws {
        try requireSynthesizer()
        let steps = max(10, Int(duration * 60))
        let paths = [-36.0, 36.0].map { dx -> E2ETouchPath in
            let start = CGPoint(x: center.x + dx, y: center.y)
            let path = E2ETouchPath(point: start, atOffset: 0)
            for index in 1...steps {
                let fraction = CGFloat(index) / CGFloat(steps)
                path.move(to: CGPoint(x: start.x + delta.dx * fraction, y: start.y + delta.dy * fraction),
                          atOffset: 0.03 + duration * Double(fraction))
            }
            path.lift(atOffset: 0.06 + duration)
            return path
        }
        try E2ETouchSynthesizer.perform(paths, name: "two-finger scroll")
    }

    /// Three-finger horizontal swipe: left or right, as a Mac trackpad Space switch.
    func threeFingerSwipe(right: Bool) throws {
        try requireSynthesizer()
        let region = strokeRegion
        let center = CGPoint(x: region.midX, y: region.midY)
        let distance: CGFloat = right ? 170 : -170
        let startX = center.x - distance / 2
        let duration = 0.3
        let paths = [(-48.0, -20.0), (0.0, 0.0), (48.0, 20.0)].map { offset -> E2ETouchPath in
            let start = CGPoint(x: startX + offset.0, y: center.y + offset.1)
            let path = E2ETouchPath(point: start, atOffset: 0)
            for index in 1...12 {
                let fraction = CGFloat(index) / 12
                path.move(to: CGPoint(x: start.x + distance * fraction, y: start.y), atOffset: 0.03 + duration * Double(fraction))
            }
            path.lift(atOffset: 0.06 + duration)
            return path
        }
        try E2ETouchSynthesizer.perform(paths, name: "three-finger swipe")
    }

    /// Tap, then touch again and hold within the double-click interval, then move: a Mac drag.
    func doubleTapHoldDrag(by delta: CGVector) throws {
        try requireSynthesizer()
        let region = strokeRegion
        let point = CGPoint(x: region.minX + region.width * 0.3, y: region.minY + region.height * 0.35)
        let tap = E2ETouchPath(point: point, atOffset: 0)
        tap.lift(atOffset: 0.06)
        let second = CGPoint(x: point.x + 2, y: point.y + 2)
        let hold = E2ETouchPath(point: second, atOffset: 0.22)
        let steps = 40
        for index in 1...steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            hold.move(to: CGPoint(x: second.x + delta.dx * fraction, y: second.y + delta.dy * fraction),
                      atOffset: 0.6 + 0.9 * Double(fraction))
        }
        hold.lift(atOffset: 1.65)
        try E2ETouchSynthesizer.perform([tap, hold], name: "double-tap drag")
        lastTap = (Date(), point)
    }

    // MARK: Pointer steering

    /// Moves the Mac pointer (read from the host) onto a global point with phone strokes, learning
    /// the effective gain as it goes. Only the product's own pointer path is used.
    func steerPointer(to target: CGPoint, tolerance: CGFloat = 6, maxStrokes: Int = 16, label: String = "") throws {
        var gain: CGFloat?
        for attempt in 0..<maxStrokes {
            try waitFor("phone able to send input", timeout: 15) { phone.state.bool("canControl") }
            guard let before = try settledHostPointer() else { throw E2EFailure("Host did not publish a pointer position") }
            let delta = CGVector(dx: target.x - before.x, dy: target.y - before.y)
            let distance = hypot(delta.dx, delta.dy)
            if distance <= tolerance {
                recorder.metrics["steer.\(label.isEmpty ? "\(Int(target.x)),\(Int(target.y))" : label)"] = attempt
                return
            }
            let scale = CGFloat(phone.state.object("viewport").double("scale") ?? 0.5)
            let expected = gain ?? (0.62 / max(scale, 0.05))
            var finger = CGVector(dx: delta.dx / expected, dy: delta.dy / expected)
            let region = strokeRegion
            let maxLength = min(260, min(region.width, region.height) * 0.8)
            let fingerLength = hypot(finger.dx, finger.dy)
            if fingerLength > maxLength { finger = CGVector(dx: finger.dx * maxLength / fingerLength, dy: finger.dy * maxLength / fingerLength) }
            if hypot(finger.dx, finger.dy) < 6 {
                let factor = 6 / max(hypot(finger.dx, finger.dy), 0.01)
                finger = CGVector(dx: finger.dx * factor, dy: finger.dy * factor)
            }
            let start = CGPoint(x: region.midX - finger.dx / 2, y: region.midY - finger.dy / 2)
            try stroke(from: start, by: finger, speed: distance < 40 ? 60 : 160)
            guard let after = try settledHostPointer() else { continue }
            let moved = hypot(after.x - before.x, after.y - before.y)
            let length = hypot(finger.dx, finger.dy)
            if length > 15, moved > 2 {
                let observed = moved / length
                gain = gain.map { $0 * 0.4 + observed * 0.6 } ?? observed
            }
        }
        let canvases = app.descendants(matching: .any).matching(identifier: "remote.canvas").allElementsBoundByIndex.map { "\($0.frame)" }
        recorder.note("steering diagnostics: canvas elements \(canvases), stroke region \(strokeRegion), phone viewport \(phone.state.object("viewport"))")
        throw E2EFailure("Pointer did not reach \(label) at \(target) after \(maxStrokes) strokes; last \(host.pointer.map { "\($0)" } ?? "unknown"). \(phone.summary()) \(host.summary())")
    }

    /// Host pointer once it stops changing across two separate state publications (every 100 ms);
    /// rereading one unchanged file is not evidence the pointer settled.
    func settledHostPointer(timeout: TimeInterval = 2) throws -> CGPoint? {
        var previous: (t: Double, point: CGPoint)?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = host.state
            if let t = state.double("t"), let point = state.point("pointer") {
                if let prior = previous, t != prior.t {
                    if hypot(point.x - prior.point.x, point.y - prior.point.y) < 0.5 { return point }
                    previous = (t, point)
                } else if previous == nil {
                    previous = (t, point)
                }
            }
            pause(0.12)
        }
        return previous?.point
    }

    /// Phone-drawn pointer (predicted, reconciled) against the host's authoritative position.
    func pointerAgreement() throws -> CGFloat {
        guard let global = try settledHostPointer(), let display = host.display else { throw E2EFailure("Host pointer unavailable") }
        var worst: CGFloat = .infinity
        try waitFor("phone-drawn pointer to agree with the Mac", timeout: 3) {
            let pointer = phone.state.object("pointer")
            guard pointer.bool("drawn"), let x = pointer.double("x"), let y = pointer.double("y") else { return false }
            worst = hypot(CGFloat(x) - (global.x - display.minX), CGFloat(y) - (global.y - display.minY))
            return worst <= 3
        }
        return worst
    }

    /// Screen position on the phone of a global Mac point, from the published viewport.
    func phoneScreenPoint(forGlobal point: CGPoint) -> CGPoint? {
        let viewport = phone.state.object("viewport")
        guard let display = host.display, let content = viewport.rect("contentRect"),
              let canvasFrame = viewport.rect("canvasFrame"), let scale = viewport.double("scale"), scale > 0 else { return nil }
        return CGPoint(x: canvasFrame.minX + content.minX + (point.x - display.minX) * scale,
                       y: canvasFrame.minY + content.minY + (point.y - display.minY) * scale)
    }

    // MARK: Expectations

    struct Marks { let pad: Int; let host: Int; let hostEvents: Int; let phoneEvents: Int }

    func marks() -> Marks {
        Marks(pad: pad.log.mark(), host: host.input.mark(), hostEvents: host.events.mark(), phoneEvents: phone.events.mark())
    }

    @discardableResult
    func expectHostInput(_ action: String, since marks: Marks, timeout: TimeInterval = 5,
                         where predicate: @escaping (JSONObject) -> Bool = { _ in true }) throws -> JSONObject {
        var found: JSONObject?
        try waitFor("host to accept \(action)", timeout: timeout) {
            found = host.input.since(marks.host).first {
                $0.string("action") == action && $0.bool("accepted") && predicate($0)
            }
            return found != nil
        }
        return found!
    }

    @discardableResult
    func expectPadEvent(_ type: String, since marks: Marks, timeout: TimeInterval = 5, _ what: String,
                        where predicate: @escaping (JSONObject) -> Bool = { _ in true }) throws -> JSONObject {
        var found: JSONObject?
        try waitFor(what, timeout: timeout) {
            found = pad.log.since(marks.pad, type: type).first(where: predicate)
            return found != nil
        }
        return found!
    }

    /// A click on a Test Pad element: host accepted it at that element, and (real host) the
    /// Test Pad itself received it with the expected button and count.
    func expectClick(on element: String, button: String = "left", clickCount: Int = 1, since marks: Marks) throws {
        let action = button == "right" ? "right" : "click"
        let hostLine = try expectHostInput(action, since: marks) { $0.string("target") == element }
        recorder.check("host accepted \(button) click on \(element)", true, "fence=\(hostLine.string("fence") ?? "?")")
        guard !config.isStub else { return }
        try expectPadEvent("click", since: marks, "Test Pad \(button) click on \(element) (count ≥ \(clickCount))") {
            $0.string("element") == element && $0.string("button") == button && ($0.int("clickCount") ?? 0) >= clickCount
        }
        recorder.check("Test Pad received \(button) click on \(element)", true, "clickCount≥\(clickCount)")
    }

    /// Steers onto an element's centre, taps, and verifies the click landed there.
    func clickElement(_ name: String) throws {
        try ensureTestPadClear()
        let frame = try element(name)
        try steerPointer(to: CGPoint(x: frame.midX, y: frame.midY), label: name)
        let before = marks()
        tapCanvas()
        try expectClick(on: name, since: before)
    }
}
