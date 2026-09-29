#if DEBUG
import AppKit
import CoreGraphics

/// Debug-only end-to-end harness mode for the Mac host (script/e2e/README.md).
///
/// Active only in a DEBUG build launched with `--farside-e2e` and `FARSIDE_E2E=1`, plus a valid
/// private harness directory and a loopback signaling URL; otherwise the host exits instead of
/// running half-configured. In E2E mode the host:
/// - keeps its own trust (Keychain account `host.e2e`) and preferences (suite
///   `com.roshan.PocketDesk.RemoteHost.e2e`), so the owner's real pairing is never read or replaced;
/// - approves a new phone only when its encrypted proof carries the harness's one-time token from a
///   0600 file, and deletes that file on use;
/// - fences injected input to the Farside Test Pad window;
/// - publishes observable state under /private/tmp/farside-e2e/host.
@MainActor
final class HostE2E {
    static let active: HostE2E? = bootstrap()

    let directory: String
    let runID: String
    let launchID: String
    let signalURL: String
    let allowSpaceKeys: Bool
    let pairStore: PairStore
    let defaults: UserDefaults
    let recorder: E2ERecorder
    let testPad = E2ETestPadGeometry()
    private var secretsDirectory: String { directory + "/secrets" }
    private weak var model: RemoteHostModel?
    private var timer: Timer?
    private var lastInvitationCode = ""
    private var lastPairingAttempt: TimeInterval = -.infinity
    private var last: (connected: Bool, registered: Bool, awaiting: Bool, status: String, epoch: UInt64)?
    private var lastStats: [String: Any]?
    private var cpu = E2ECPUMeter()
    private var accepted: [String: Int] = [:]
    private var rejected: [String: Int] = [:]
    private var moveBatch = (count: 0, accepted: 0, adjusted: 0, rejected: 0, since: TimeInterval(0))
    private var lastFenceRejection: String?

    private static func bootstrap() -> HostE2E? {
        let options = E2ELaunchOptions.current
        guard options.requested else { return nil }
        do { return try HostE2E(options: options) } catch { refuse(error) }
    }

    /// A half-configured E2E launch must never run as the real host.
    static func refuse(_ error: Error) -> Never {
        let message = "Farside E2E mode refused: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
        if (try? E2EFiles.validatePrivateDirectory(E2E.root)) != nil,
           (try? E2EFiles.ensurePrivateDirectory(E2E.root + "/host")) != nil {
            try? E2EFiles.writePrivate(Data(message.utf8), to: E2E.root + "/host/refused.txt")
        }
        exit(78)
    }

    private init(options: E2ELaunchOptions) throws {
        guard let common = try options.validatedCommon() else { throw E2EConfigError("not requested") }
        try E2EFiles.validatePrivateDirectory(common.directory)
        directory = common.directory
        runID = common.runID
        launchID = options.environment["FARSIDE_E2E_LAUNCH_ID"].flatMap { E2EFiles.isIdentifier($0) ? $0 : nil }
            ?? UUID().uuidString
        signalURL = try options.validatedSignalURL()
        allowSpaceKeys = options.environment[E2E.spaceKeysVariable] == "1"
        try E2EFiles.ensurePrivateDirectory(common.directory + "/secrets")
        try? FileManager.default.removeItem(atPath: common.directory + "/host/refused.txt")
        recorder = try E2ERecorder(directory: common.directory + "/host", role: "host", runID: common.runID)
        pairStore = PairStore(account: "host.e2e")
        guard let suite = UserDefaults(suiteName: "com.roshan.PocketDesk.RemoteHost.e2e") else {
            throw E2EConfigError("E2E preferences suite unavailable")
        }
        defaults = suite
        let preferences = HostPreferences(defaults: suite)
        preferences.allowControl = true
        preferences.keepAwake = true
        preferences.sharingEnabled = true
        preferences.accessibilitySkipped = false
        preferences.serviceAddress = signalURL
        if options.has(E2E.resetArgument) {
            try? pairStore.delete()
            recorder.event("pairing.reset", ["reason": "reset argument"])
        } else if let pair = try? pairStore.read(HostPair.self), pair.invitation.server != signalURL {
            try? pairStore.delete()
            recorder.event("pairing.reset", ["reason": "stored pairing used another signaling URL"])
        }
        try? FileManager.default.removeItem(atPath: secretsDirectory + "/" + E2E.invitationFileName)
    }

    func attach(_ model: RemoteHostModel) {
        self.model = model
        model.connection.e2eProofApprover = { [weak self] body in self?.approve(proof: body) ?? false }
        let bundle = Bundle.main
        recorder.event("host.launched", [
            "launchID": launchID,
            "bundlePath": bundle.bundlePath,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "signalURL": signalURL,
            "allowSpaceKeys": allowSpaceKeys,
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "accessibility": AXIsProcessTrusted()
        ])
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func event(_ type: String, _ fields: [String: Any] = [:]) { recorder.event(type, fields) }

    // MARK: Pairing

    private func approve(proof body: Data?) -> Bool {
        switch E2EPairingToken.consume(proof: body, secretsDirectory: secretsDirectory) {
        case .accepted:
            recorder.event("pairing.autoApproved")
            return true
        case .rejected(let reason):
            recorder.event("pairing.proofRejected", ["reason": reason])
            return false
        }
    }

    private func maintainPairing(_ model: RemoteHostModel) {
        let now = ProcessInfo.processInfo.systemUptime
        if !model.hasPairedPhone, model.canPair, model.serviceAddress != nil,
           !model.connection.awaitingApproval,
           model.pairingCode.isEmpty || model.pairingExpired,
           now - lastPairingAttempt >= 3 {
            lastPairingAttempt = now
            model.beginPairing()
            recorder.event("pairing.codeRequested", ["issued": !model.pairingCode.isEmpty])
        }
        let code = model.hasPairedPhone || model.pairingExpired ? "" : model.pairingCode
        guard code != lastInvitationCode else { return }
        lastInvitationCode = code
        let path = secretsDirectory + "/" + E2E.invitationFileName
        if code.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            do {
                try E2EFiles.writePrivate(Data(code.utf8), to: path)
                recorder.event("pairing.codeIssued", ["expiresIn": model.pairingExpires.map { $0.timeIntervalSinceNow } as Any])
            } catch {
                recorder.event("pairing.codeWriteFailed", ["error": String(describing: error)])
            }
        }
    }

    // MARK: Observable state

    private func tick() {
        guard let model else { return }
        maintainPairing(model)
        let snapshot = model.e2eSnapshot()
        let connected = model.connection.connected
        let registered = model.connection.hostRegistered
        let awaiting = model.connection.awaitingApproval
        let status = model.connection.status
        let epoch = snapshot["epoch"] as? UInt64 ?? 0
        if let last {
            if last.connected != connected {
                recorder.event(connected ? "session.connected" : "session.disconnected",
                               ["epoch": epoch, "status": status])
            }
            if last.registered != registered { recorder.event(registered ? "service.registered" : "service.unregistered") }
            if last.awaiting != awaiting && awaiting { recorder.event("pairing.awaitingManualApproval") }
            if last.status != status { recorder.event("coordinator.status", ["status": status]) }
            if last.epoch != epoch { recorder.event("session.epoch", ["epoch": epoch]) }
        } else {
            recorder.event("coordinator.status", ["status": status])
        }
        last = (connected, registered, awaiting, status, epoch)
        flushMoveBatch(force: false)

        let metrics = E2EProcessMetrics.sample()
        let uptime = ProcessInfo.processInfo.systemUptime
        var state = snapshot
        state["launchID"] = launchID
        state["mode"] = "real"
        state["signalURL"] = signalURL
        state["pointer"] = CGEvent(source: nil)?.location ?? .zero
        state["frontmostBundleID"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        state["testPadFrontmost"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == E2E.testPadBundleID
        state["stats"] = lastStats ?? [:]
        state["footprintBytes"] = metrics.footprintBytes
        state["residentBytes"] = metrics.residentBytes
        state["cpuSeconds"] = metrics.cpuSeconds
        state["cpuPercent"] = cpu.percent(now: uptime, cpuSeconds: metrics.cpuSeconds) as Any
        state["inputAccepted"] = accepted
        state["inputRejected"] = rejected
        state["lastFenceRejection"] = lastFenceRejection as Any
        state["allowSpaceKeys"] = allowSpaceKeys
        state["invitationAvailable"] = !lastInvitationCode.isEmpty
        recorder.writeState(state)
    }

    func recordStats(_ report: StreamStatsReport) {
        guard let dictionary = E2EJSON.dictionary(report) else { return }
        lastStats = dictionary
        recorder.event("stats", dictionary, log: "stats.jsonl")
    }

    // MARK: Input fence and log

    /// Returns the action to inject, or a rejection reason. Pure decisions live in
    /// `HostE2EInputFence` so they can be unit tested without a window server.
    func fence(_ action: RemoteAction, held: Bool) -> (RemoteAction?, String) {
        let environment = HostE2EFenceEnvironment.live(testPad: testPad)
        let verdict = HostE2EInputFence.decide(action, held: held, allowSpaceKeys: allowSpaceKeys,
                                               environment: environment)
        switch verdict {
        case .allow:
            return (action, "allow")
        case .adjust(let dx, let dy):
            var adjusted = action
            adjusted.x = dx
            adjusted.y = dy
            return (adjusted, "adjusted")
        case .reject(let reason):
            lastFenceRejection = "\(action.action): \(reason)"
            if action.action != "move" {
                recorder.event("input.fenceRejected", ["action": action.action, "reason": reason])
            }
            return (nil, "rejected: " + reason)
        }
    }

    func recordInput(_ action: RemoteAction, accepted wasAccepted: Bool, fence verdict: String, clickPoint: CGPoint?) {
        if wasAccepted { accepted[action.action, default: 0] += 1 } else { rejected[action.action, default: 0] += 1 }
        let pointer = clickPoint ?? CGEvent(source: nil)?.location ?? .zero
        if action.action == "move" {
            if moveBatch.count == 0 { moveBatch.since = ProcessInfo.processInfo.systemUptime }
            moveBatch.count += 1
            if wasAccepted { moveBatch.accepted += 1 }
            if verdict == "adjusted" { moveBatch.adjusted += 1 }
            if verdict.hasPrefix("rejected") { moveBatch.rejected += 1 }
            flushMoveBatch(force: false)
            return
        }
        flushMoveBatch(force: true)
        var line: [String: Any] = [
            "action": action.action, "accepted": wasAccepted, "fence": verdict,
            "pointer": pointer, "target": testPad.element(at: pointer) as Any,
            "epoch": action.epoch
        ]
        if let count = action.interaction?.clickCount { line["clickCount"] = count }
        if let phase = action.interaction?.phase { line["phase"] = phase }
        if ["scroll"].contains(action.action) { line["dx"] = action.x; line["dy"] = action.y }
        if action.action == "key" { line["key"] = action.key; line["modifiers"] = action.modifiers }
        if action.action == "text" { line["text"] = String(action.text.prefix(256)); line["length"] = action.text.count }
        recorder.event("input", line, log: "input.jsonl")
    }

    private func flushMoveBatch(force: Bool) {
        guard moveBatch.count > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - moveBatch.since >= 0.5 else { return }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        recorder.event("input", [
            "action": "move", "count": moveBatch.count, "accepted": moveBatch.accepted > 0,
            "acceptedCount": moveBatch.accepted, "adjusted": moveBatch.adjusted, "rejected": moveBatch.rejected,
            "pointer": pointer, "target": testPad.element(at: pointer) as Any
        ], log: "input.jsonl")
        moveBatch = (0, 0, 0, 0, now)
    }

    func terminating() {
        flushMoveBatch(force: true)
        recorder.event("host.terminating")
        timer?.invalidate()
        recorder.flush()
    }
}
#endif
