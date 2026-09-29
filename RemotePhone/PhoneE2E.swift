import SwiftUI
import CryptoKit

/// Live viewport geometry the E2E harness needs to map Mac points to screen points.
struct E2EViewportReport: Equatable {
    var contentRect: CGRect = .zero
    var scale: CGFloat = 0
    var zoom: CGFloat = 1
    var mode = ""
    var safeRect: CGRect = .zero
    var canvasFrame: CGRect = .zero
    var dockFrame: CGRect = .zero
    var keyboardOpen = false
    var panMode = false
    var showControls = false
    var controlsCollapsed = true
}

/// Reports the viewport to the E2E harness; a no-op outside a DEBUG E2E launch.
struct E2EViewportReporter: ViewModifier {
    let report: E2EViewportReport

    func body(content: Content) -> some View {
        #if DEBUG
        content.onChange(of: report, initial: true) { _, value in PhoneE2E.active?.viewport = value }
        #else
        content
        #endif
    }
}

/// Publishes E2E state as an accessibility value for the UI test; a no-op outside E2E.
struct E2EStateProbeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .topLeading) {
            if let e2e = PhoneE2E.active { E2EStateProbe(e2e: e2e) }
        }
        #else
        content
        #endif
    }
}

#if DEBUG
private struct E2EStateProbe: View {
    @ObservedObject var e2e: PhoneE2E

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .accessibilityElement()
            .accessibilityIdentifier("e2e.state")
            .accessibilityLabel("E2E state")
            .accessibilityValue(e2e.stateJSON)
            .allowsHitTesting(false)
    }
}

/// Debug-only end-to-end harness mode for the phone (script/e2e/README.md).
///
/// Active only in a DEBUG build launched with `--farside-e2e` and `FARSIDE_E2E=1`. It keeps its own
/// trust (Keychain account `phone.e2e`), sends the harness's one-time token inside the encrypted
/// pairing proof, and publishes observable state to /private/tmp/farside-e2e/phone and to the
/// `e2e.state` accessibility element. Commands from the harness only reach the same admitted
/// input path a person uses.
@MainActor
final class PhoneE2E: ObservableObject {
    static let active: PhoneE2E? = bootstrap()

    let runID: String
    let token: String?
    let voiceTranscript: String?
    let pairStore = PairStore(account: "phone.e2e")
    let recorder: E2ERecorder?
    @Published private(set) var stateJSON = "{}"
    var viewport = E2EViewportReport()
    private weak var model: PhoneRemoteModel?
    private var timer: Timer?
    private var frames: UInt64 = 0
    private var lastFrameAt: TimeInterval?
    private var lastStats: [String: Any]?
    private var maxRenderGapMs: Double = 0
    private var stallsOver1s = 0
    private var statsWindows = 0
    private var clipboardFromMac: [String: Any]?
    private var commandOffset: UInt64 = 0
    private var cpu = E2ECPUMeter()
    private var lastConnected = false
    private var connectedSessions = 0
    private var disconnects = 0
    private var lastStatus = ""

    private static func bootstrap() -> PhoneE2E? {
        let options = E2ELaunchOptions.current
        guard options.requested else { return nil }
        guard options.environment[E2E.environmentFlag] == "1" else {
            refuse("--farside-e2e requires FARSIDE_E2E=1")
        }
        let token = options.value(after: E2E.tokenArgument)
        if let token, !E2EFiles.isToken(token) { refuse("--farside-e2e-token must be 64 lowercase hex characters") }
        let runID = options.environment[E2E.runVariable] ?? "unspecified"
        guard E2EFiles.isIdentifier(runID) else { refuse("FARSIDE_E2E_RUN_ID is malformed") }
        // The simulator shares the Mac filesystem; if the harness directory is unavailable the
        // state is still published through the accessibility element.
        var recorder: E2ERecorder?
        if let common = try? options.validatedCommon(),
           (try? E2EFiles.validatePrivateDirectory(common.directory)) != nil {
            recorder = try? E2ERecorder(directory: common.directory + "/phone", role: "phone", runID: runID)
        }
        let e2e = PhoneE2E(runID: runID, token: token,
                           voiceTranscript: options.value(after: E2E.voiceArgument), recorder: recorder)
        if options.has(E2E.resetArgument) {
            try? e2e.pairStore.delete()
            recorder?.event("pairing.reset")
        }
        return e2e
    }

    private static func refuse(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("Farside E2E mode refused: \(reason)\n".utf8))
        exit(78)
    }

    private init(runID: String, token: String?, voiceTranscript: String?, recorder: E2ERecorder?) {
        self.runID = runID
        self.token = token
        self.voiceTranscript = voiceTranscript.flatMap { $0.isEmpty || $0.utf16.count > 1024 ? nil : $0 }
        self.recorder = recorder
    }

    func attach(_ model: PhoneRemoteModel) {
        self.model = model
        if let token { model.connection.e2eEnrollmentProof = Data(token.utf8) }
        let write = model.clipboard.writeToPasteboard
        model.clipboard.writeToPasteboard = { [weak self] payload in
            write(payload)
            self?.clipboardReceived(payload.text)
        }
        recorder?.event("phone.launched", ["hasToken": token != nil, "voiceTranscript": voiceTranscript != nil,
                                           "fileOutput": recorder != nil])
        if let recorder {
            let path = recorder.path("commands.jsonl")
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 {
                commandOffset = size
            }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func frameReceived() {
        frames &+= 1
        lastFrameAt = ProcessInfo.processInfo.systemUptime
    }

    func record(_ report: StreamStatsReport) {
        guard let dictionary = E2EJSON.dictionary(report) else { return }
        lastStats = dictionary
        statsWindows += 1
        if let gap = report.renderGapMaxMs {
            maxRenderGapMs = max(maxRenderGapMs, gap)
            if gap > 1000 { stallsOver1s += 1 }
        }
        recorder?.event("stats", dictionary, log: "stats.jsonl")
    }

    private func clipboardReceived(_ text: String) {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        clipboardFromMac = ["length": text.count, "sha256": digest, "at": Date().timeIntervalSince1970]
        recorder?.event("clipboard.fromMac", ["length": text.count, "sha256": digest])
    }

    private func tick() {
        guard let model else { return }
        let connection = model.connection
        if connection.connected != lastConnected {
            lastConnected = connection.connected
            if connection.connected { connectedSessions += 1 } else { disconnects += 1 }
            recorder?.event(connection.connected ? "session.connected" : "session.disconnected",
                            ["status": connection.status])
        }
        if connection.status != lastStatus {
            lastStatus = connection.status
            recorder?.event("coordinator.status", ["status": connection.status])
        }
        pollCommands(model)

        let now = ProcessInfo.processInfo.systemUptime
        let metrics = E2EProcessMetrics.sample()
        let render = model.pointerOverlay.render
        var state: [String: Any] = [
            "connected": connection.connected,
            "coordinatorStatus": connection.status,
            "diagnostics": connection.diagnostics,
            "paired": connection.invitation != nil,
            "invitationServer": connection.invitation?.server as Any,
            "hasVideo": connection.remoteVideo != nil,
            "resumeState": "\(model.resumeState)",
            "contentConcealed": model.contentConcealed,
            "privacyShield": model.privacyShield,
            "macNotice": model.macNotice as Any,
            "error": model.error,
            "geometryEpoch": model.geometryEpoch,
            "sourceSize": model.sourceSize,
            "fresh": model.fresh,
            "captureHealthy": model.captureHealthy,
            "controlAllowed": model.controlAllowed,
            "canControl": model.canControl,
            "nativeInteraction": model.nativeInteractionSupported,
            "hostFeatures": Array(model.hostFeatures).sorted(),
            "hostPresence": model.hostPresence?.rawValue as Any,
            "dragging": model.dragging,
            "requestedQuality": model.streamQuality.rawValue,
            "appliedQuality": model.appliedStreamQuality?.rawValue as Any,
            "qualityStatus": model.streamQualityStatus as Any,
            "frames": frames,
            "lastFrameAgeMs": lastFrameAt.map { (now - $0) * 1000 } as Any,
            "stats": lastStats ?? [:],
            "statsWindows": statsWindows,
            "maxRenderGapMs": maxRenderGapMs,
            "stallsOver1s": stallsOver1s,
            "connectedSessions": connectedSessions,
            "disconnects": disconnects,
            "pointer": [
                "hostSupported": model.pointerOverlay.hostSupported,
                "drawn": render != nil,
                "x": render.map { Double($0.point.x) } as Any,
                "y": render.map { Double($0.point.y) } as Any,
                "shape": render.map { $0.shape.rawValue } as Any
            ] as [String: Any],
            "viewport": [
                "contentRect": viewport.contentRect, "scale": viewport.scale, "zoom": viewport.zoom,
                "mode": viewport.mode, "safeRect": viewport.safeRect, "canvasFrame": viewport.canvasFrame,
                "dockFrame": viewport.dockFrame, "keyboardOpen": viewport.keyboardOpen,
                "panMode": viewport.panMode, "showControls": viewport.showControls,
                "controlsCollapsed": viewport.controlsCollapsed
            ] as [String: Any],
            "clipboard": [
                "activity": "\(model.clipboard.activity)",
                "notice": model.clipboard.notice?.message as Any,
                "fromMac": clipboardFromMac as Any
            ] as [String: Any],
            "textStatus": model.textStatus,
            "voiceDelivery": "\(model.voiceDeliveryStatus)",
            "footprintBytes": metrics.footprintBytes,
            "cpuPercent": cpu.percent(now: now, cpuSeconds: metrics.cpuSeconds) as Any,
            "run": runID,
            "t": Date().timeIntervalSince1970,
            "pid": Int(getpid())
        ]
        state["summary"] = model.streamSummaryLines
        recorder?.writeState(state)
        if let data = E2EJSON.data(state), let json = String(data: data, encoding: .utf8), json != stateJSON {
            stateJSON = json
        }
    }

    /// Harness commands reach only the admitted input path a person uses. Currently: keyboard
    /// shortcuts the phone UI has no dedicated button for (for example ⌘A).
    private func pollCommands(_ model: PhoneRemoteModel) {
        guard let recorder else { return }
        let path = recorder.path("commands.jsonl")
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: commandOffset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        commandOffset += UInt64(complete.count)
        for line in complete.split(separator: 0x0A) {
            guard let command = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let id = command["id"] as? String ?? ""
            switch command["cmd"] as? String {
            case "key":
                let key = command["key"] as? String ?? ""
                let modifiers = command["modifiers"] as? [String] ?? []
                let sent = model.e2eSendKey(key, modifiers: modifiers)
                recorder.event("command", ["id": id, "cmd": "key", "key": key, "modifiers": modifiers, "ok": sent])
            case "ping":
                recorder.event("command", ["id": id, "cmd": "ping", "ok": true])
            default:
                recorder.event("command", ["id": id, "cmd": command["cmd"] as Any, "ok": false, "error": "unknown command"])
            }
        }
    }
}
#endif
