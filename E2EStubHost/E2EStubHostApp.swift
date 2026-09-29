import AppKit
import CoreGraphics
import CoreVideo

#if DEBUG
/// Farside E2E stub host: a synthetic Mac host for self-testing the E2E harness without the
/// installed app. It pairs through the same coordinator, token approval and protocol as the real
/// host, streams generated frames and applies phone input to a virtual pointer only. It never
/// captures the screen or injects events. Same launch contract as the real host's E2E mode.
@main
enum StubHostMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StubHostDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class StubHostDelegate: NSObject, NSApplicationDelegate {
    private var host: StubHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            do {
                let host = try StubHost(options: .current)
                self.host = host
                host.start()
            } catch {
                let message = "Farside E2E stub host refused: \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
                if (try? E2EFiles.ensurePrivateDirectory(E2E.root + "/host")) != nil {
                    try? E2EFiles.writePrivate(Data(message.utf8), to: E2E.root + "/host/refused.txt")
                }
                exit(78)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { host?.terminating() }
    }
}

/// File-backed trust so the stub keeps its pairing across a kill and relaunch.
final class E2EFilePairStore: PairPersistence {
    let path: String
    init(path: String) { self.path = path }
    func save<T: Encodable>(_ value: T) throws { try E2EFiles.writePrivate(JSONEncoder().encode(value), to: path) }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    func delete() throws { try? FileManager.default.removeItem(atPath: path) }
}

@MainActor
final class StubHost {
    private let directory: String
    private let runID: String
    private let launchID: String
    private let signalURL: String
    private let recorder: E2ERecorder
    private let store: E2EFilePairStore
    private let coordinator: RemoteCoordinator
    private let testPad = E2ETestPadGeometry()
    private let display: CGRect
    private var pointer: CGPoint
    private var epoch: UInt64 = 0
    private var freshness = NativeInputFreshness()
    private var telemetry = HostPointerTelemetryPolicy()
    private var paused = false
    private var sessionActive = false
    private var held = false
    private var appliedQuality: StreamQuality = .sharp
    private var lastStats: [String: Any]?
    private var accepted: [String: Int] = [:]
    private var rejected: [String: Int] = [:]
    private var timers: [Timer] = []
    private var sessionTimers: [Timer] = []
    private var frameIndex: UInt64 = 0
    private var pool: CVPixelBufferPool?
    private var cpu = E2ECPUMeter()
    private var lastConnected = false
    private var lastStatus = ""
    private var lastRegistered = false
    private var lastInvitation: PairInvitation?
    private var moveBatch = 0

    init(options: E2ELaunchOptions) throws {
        guard let common = try options.validatedCommon() else { throw E2EConfigError("--farside-e2e is required") }
        try E2EFiles.validatePrivateDirectory(common.directory)
        directory = common.directory
        runID = common.runID
        launchID = options.environment["FARSIDE_E2E_LAUNCH_ID"].flatMap { E2EFiles.isIdentifier($0) ? $0 : nil }
            ?? UUID().uuidString
        signalURL = try options.validatedSignalURL()
        try E2EFiles.ensurePrivateDirectory(directory + "/secrets")
        try E2EFiles.ensurePrivateDirectory(directory + "/stubhost")
        try? FileManager.default.removeItem(atPath: directory + "/host/refused.txt")
        recorder = try E2ERecorder(directory: directory + "/host", role: "host", runID: runID)
        store = E2EFilePairStore(path: directory + "/stubhost/pair.json")
        if options.has(E2E.resetArgument) { try? store.delete() }
        if let pair = try? store.read(HostPair.self), pair.invitation.server != signalURL { try? store.delete() }
        // Loopback-only media: this unsigned app must never talk to local-network addresses.
        E2EMedia.loopbackOnly = true
        coordinator = RemoteCoordinator(isHost: true, store: store)
        display = CGDisplayBounds(CGMainDisplayID())
        pointer = CGPoint(x: display.midX, y: display.midY)
    }

    func start() {
        coordinator.restore()
        coordinator.e2eProofApprover = { [weak self] body in
            guard let self else { return false }
            switch E2EPairingToken.consume(proof: body, secretsDirectory: self.directory + "/secrets") {
            case .accepted:
                self.recorder.event("pairing.autoApproved")
                return true
            case .rejected(let reason):
                self.recorder.event("pairing.proofRejected", ["reason": reason])
                return false
            }
        }
        coordinator.onAuthenticated = { [weak self] in self?.beginSession() }
        coordinator.onEnded = { [weak self] in self?.endSession() }
        coordinator.onControl = { [weak self] data in self?.receive(data) }
        recorder.event("host.launched", ["launchID": launchID, "mode": "stub", "signalURL": signalURL,
                                         "bundlePath": Bundle.main.bundlePath])
        ensurePairingAndStart()
        schedule(0.1, into: &timers) { [weak self] in self?.tick() }
    }

    func terminating() {
        recorder.event("host.terminating")
        coordinator.stop()
        recorder.flush()
    }

    private func ensurePairingAndStart() {
        if coordinator.hostPair?.paired != true {
            do {
                _ = try coordinator.createPair(server: signalURL, name: "Farside E2E Stub Mac")
                recorder.event("pairing.codeRequested", ["issued": true])
            } catch {
                recorder.event("pairing.codeWriteFailed", ["error": String(describing: error)])
                return
            }
        }
        coordinator.start()
    }

    private func tick() {
        let invitationPath = directory + "/secrets/" + E2E.invitationFileName
        if let pair = coordinator.hostPair, !pair.paired {
            if pair.invitation.expires.timeIntervalSinceNow < 2, !coordinator.awaitingApproval, !coordinator.connected {
                ensurePairingAndStart()
            }
            // Compare the invitation itself: its encoded code need not be byte-stable.
            if pair.invitation != lastInvitation, let code = try? pair.invitation.code() {
                lastInvitation = pair.invitation
                try? E2EFiles.writePrivate(Data(code.utf8), to: invitationPath)
                recorder.event("pairing.codeIssued")
            }
        } else if lastInvitation != nil {
            lastInvitation = nil
            try? FileManager.default.removeItem(atPath: invitationPath)
        }
        // Like the real host, a coordinator that exhausted its retry budget stays stopped.
        if coordinator.connected != lastConnected {
            lastConnected = coordinator.connected
            recorder.event(lastConnected ? "session.connected" : "session.disconnected", ["epoch": epoch])
        }
        if coordinator.status != lastStatus {
            lastStatus = coordinator.status
            recorder.event("coordinator.status", ["status": coordinator.status])
        }
        if coordinator.hostRegistered != lastRegistered {
            lastRegistered = coordinator.hostRegistered
            recorder.event(lastRegistered ? "service.registered" : "service.unregistered")
        }
        if moveBatch > 0 {
            recorder.event("input", ["action": "move", "count": moveBatch, "accepted": true, "pointer": pointer,
                                     "target": testPad.element(at: pointer) as Any], log: "input.jsonl")
            moveBatch = 0
        }
        let metrics = E2EProcessMetrics.sample()
        let uptime = ProcessInfo.processInfo.systemUptime
        recorder.writeState([
            "mode": "stub", "launchID": launchID, "signalURL": signalURL,
            "status": coordinator.connected ? "controlling" : coordinator.hostRegistered ? "ready" : "starting",
            "coordinatorStatus": coordinator.status, "diagnostics": coordinator.diagnostics,
            "hostRegistered": coordinator.hostRegistered, "connected": coordinator.connected,
            "awaitingApproval": coordinator.awaitingApproval, "paired": coordinator.hostPair?.paired == true,
            "active": coordinator.isRunning, "captureHealthy": sessionActive && !paused,
            "allowControl": true, "inputEnabled": true, "held": held, "screenRecording": false, "accessibility": false,
            "display": display, "epoch": epoch, "pointer": pointer, "phonePaused": paused,
            "appliedQuality": appliedQuality.rawValue, "cursorInVideo": !telemetry.wantsCursorHidden(at: uptime),
            "testPadFrontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == E2E.testPadBundleID,
            "stats": lastStats ?? [:], "inputAccepted": accepted, "inputRejected": rejected,
            "footprintBytes": metrics.footprintBytes, "residentBytes": metrics.residentBytes,
            "cpuSeconds": metrics.cpuSeconds, "cpuPercent": cpu.percent(now: uptime, cpuSeconds: metrics.cpuSeconds) as Any,
            "invitationAvailable": lastInvitation != nil
        ])
    }

    // MARK: Session

    private func beginSession() {
        stopSessionTimers()
        epoch &+= 1
        paused = false
        sessionActive = true
        held = false
        freshness.expireTokens()
        telemetry.reset()
        if let peer = coordinator.media {
            peer.onStreamStatistics = { [weak self] report in
                Task { @MainActor in
                    guard let self, let dictionary = E2EJSON.dictionary(report) else { return }
                    self.lastStats = dictionary
                    self.recorder.event("stats", dictionary, log: "stats.jsonl")
                }
            }
        }
        recorder.event("capture.begin", ["display": display, "synthetic": true, "epoch": epoch])
        send(RemoteAction(action: "geometry", x: display.width, y: display.height, epoch: epoch))
        send(RemoteAction(action: "viewing", x: 1, epoch: epoch))
        schedule(0.25, into: &sessionTimers) { [weak self] in self?.sendStatus() }
        schedule(1.0 / 30.0, into: &sessionTimers) { [weak self] in self?.pushFrame() }
        schedule(1.0 / 60.0, into: &sessionTimers) { [weak self] in self?.samplePointer() }
        sendStatus()
    }

    private func endSession() {
        if sessionActive { recorder.event("capture.end") }
        sessionActive = false
        held = false
        stopSessionTimers()
        freshness.invalidate()
    }

    private func stopSessionTimers() {
        sessionTimers.forEach { $0.invalidate() }
        sessionTimers.removeAll()
    }

    private func send(_ action: RemoteAction) {
        _ = coordinator.sendControl(action)
    }

    private func sendStatus() {
        guard coordinator.connected, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let capability = freshness.capability(epoch: epoch, now: now, doubleClickInterval: 0.5)
        send(RemoteAction(action: "capture", x: 1, epoch: epoch, interaction: capability,
                          pointerSync: PointerSync(videoCursor: !telemetry.wantsCursorHidden(at: now)),
                          streamQuality: appliedQuality, features: [SessionFeature.backgroundPause]))
    }

    private func samplePointer() {
        guard coordinator.connected, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let local = CGPoint(x: pointer.x - display.minX, y: pointer.y - display.minY)
        guard let sync = telemetry.sample(observed: local, shape: .arrow,
                                          videoCursor: !telemetry.wantsCursorHidden(at: now), at: now) else { return }
        send(RemoteAction(action: "pointer", epoch: epoch, pointerSync: sync))
    }

    // MARK: Input

    private func receive(_ data: Data) {
        guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch action.action {
        case "heartbeat":
            if let probe = action.clock, !probe.isEcho, (try? probe.validate()) != nil {
                let received = min(MachClock.nowMs(), coordinator.media?.controlArrivalMs ?? .infinity)
                send(RemoteAction(action: "heartbeat", epoch: action.epoch,
                                  clock: ClockProbe(phoneMs: probe.phoneMs, hostReceivedMs: received, hostSentMs: MachClock.nowMs())))
            }
            if action.epoch == epoch, let quality = action.streamQuality { appliedQuality = quality }
            if action.pointerProbe == nil && action.textFocusProbe == nil, action.epoch == epoch {
                telemetry.phoneHeartbeat(action.pointerSync, at: now)
            }
            return
        case "pause":
            guard action.epoch == epoch, !paused else { return }
            paused = true
            held = false
            recorder.event("session.paused")
            return
        case "resume":
            guard action.epoch == epoch, paused else { return }
            recorder.event("session.resumed")
            beginSession()
            return
        case "release":
            held = false
            log(action, accepted: true)
            return
        default:
            break
        }
        if action.action == "move" { telemetry.moveProcessed(ordinal: action.pointerSync?.move) }
        guard action.epoch == epoch, !paused else { log(action, accepted: false, reason: "stale epoch or paused"); return }
        let admission = freshness.admit(action, epoch: epoch, now: now)
        guard admission != .terminate else {
            log(action, accepted: false, reason: "freshness terminate")
            recorder.event("input.terminated", ["action": action.action])
            return
        }
        switch action.action {
        case "move":
            pointer = CGPoint(x: min(display.maxX - 1, max(display.minX, pointer.x + action.x)),
                              y: min(display.maxY - 1, max(display.minY, pointer.y + action.y)))
            telemetry.moveInjected(at: CGPoint(x: pointer.x - display.minX, y: pointer.y - display.minY), now: now)
            accepted["move", default: 0] += 1
            moveBatch += 1
            return
        case "dragDown": held = true
        case "dragUp": held = false
        case "text": send(RemoteAction(action: "textResult", x: 1, key: action.key, epoch: epoch))
        default: break
        }
        log(action, accepted: true)
    }

    private func log(_ action: RemoteAction, accepted wasAccepted: Bool, reason: String? = nil) {
        if wasAccepted { accepted[action.action, default: 0] += 1 } else { rejected[action.action, default: 0] += 1 }
        var line: [String: Any] = ["action": action.action, "accepted": wasAccepted, "fence": "stub",
                                   "pointer": pointer, "target": testPad.element(at: pointer) as Any, "epoch": action.epoch]
        if let reason { line["reason"] = reason }
        if let count = action.interaction?.clickCount { line["clickCount"] = count }
        if let phase = action.interaction?.phase { line["phase"] = phase }
        if action.action == "scroll" { line["dx"] = action.x; line["dy"] = action.y }
        if action.action == "key" { line["key"] = action.key; line["modifiers"] = action.modifiers }
        if action.action == "text" { line["text"] = String(action.text.prefix(256)); line["length"] = action.text.count }
        recorder.event("input", line, log: "input.jsonl")
    }

    // MARK: Synthetic video

    private func pushFrame() {
        guard coordinator.connected, !paused, let media = coordinator.media else { return }
        let width = 1280, height = max(2, Int((CGFloat(width) * display.height / max(1, display.width)).rounded()) & ~1)
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        frameIndex &+= 1
        let scale = CGFloat(width) / display.width
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
        for x in stride(from: 0, to: width, by: 64) { context.stroke(CGRect(x: x, y: 0, width: 0, height: height)) }
        if let snapshot = testPad.snapshot() {
            let colors: [String: CGColor] = ["A": CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1),
                                             "B": CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1),
                                             "C": CGColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 1),
                                             "D": CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1)]
            if let window = snapshot.window {
                context.setFillColor(CGColor(gray: 0.18, alpha: 1))
                context.fill(window.offsetBy(dx: -display.minX, dy: -display.minY).applying(.init(scaleX: scale, y: scale)))
            }
            for (name, frame) in snapshot.elements {
                context.setFillColor(colors[name] ?? CGColor(gray: 0.35, alpha: 1))
                context.fill(frame.offsetBy(dx: -display.minX, dy: -display.minY).applying(.init(scaleX: scale, y: scale)))
            }
        }
        let barX = CGFloat(frameIndex % 120) / 120 * CGFloat(width - 40)
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: barX, y: 0, width: 40, height: 24))
        BenchMarkerRenderer.draw(BenchMarker(hostTimeMs: MachClock.nowMs(), chartSeed: 0, flash: false, motion: true),
                                 layout: BenchMarker.layout(width: Double(width), height: Double(height)), in: context)
        media.pushFrame(buffer, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
    }

    private func schedule(_ interval: TimeInterval, into list: inout [Timer], _ block: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(timer, forMode: .common)
        list.append(timer)
    }
}
#else
@main
enum StubHostMain {
    static func main() { fatalError("The Farside E2E stub host is a Debug-only test tool.") }
}
#endif
