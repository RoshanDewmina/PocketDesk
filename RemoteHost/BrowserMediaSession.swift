import Foundation
import AppKit
import ScreenCaptureKit
import Combine

@MainActor
final class BrowserMediaSession: ObservableObject {
    lazy var controller = BrowserPeerController(canAcquire: { [weak self] in self?.canAcquire() == true }, release: {})
    @Published var endpoint = "http://127.0.0.1:8788"
    @Published var allowControl = false
    @Published private(set) var notice = "Start the private browser service, choose a display, then enable browser access."
    private let capture = RemoteCapture()
    private lazy var input = RemoteInputDriver(isTrusted: { [unowned self] in self.canPostEvents })
    /// The right to post events, refreshed by the status timer rather than read per input event.
    private var canPostEvents = CGPreflightPostEventAccess()
    private let gate = BrowserInputGate()
    private var lease = RemoteInputLease()
    private var display: SCDisplay?
    private var healthy = false
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var revision: UInt64 = 1
    var canAcquire: () -> Bool = { false }

    init() {
        controller.onAuthenticated = { [weak self] peer, mode in self?.begin(peer: peer, mode: mode) }
        controller.onEnded = { [weak self] in self?.endMedia() }
        controller.onControl = { [weak self] bytes in self?.receive(bytes) }
        capture.onHealth = { [weak self] value in
            guard let self else { return }
            if !value { self.gate.invalidateFrames(); self.release() }
            self.healthy = value; self.publishStatus()
        }
        capture.onFailure = { [weak self] _ in self?.stop(); self?.notice = "Screen capture stopped. Check this Mac before reconnecting." }
    }
    func start(display: SCDisplay) {
        guard canAcquire(), CGPreflightScreenCaptureAccess() else { notice = "Browser access needs an idle host and Screen Recording permission."; return }
        self.display = display; revision += 1
        canPostEvents = CGPreflightPostEventAccess()
        if allowControl && !canPostEvents { allowControl = false }
        guard var url = URLComponents(string: endpoint), ["http", "https"].contains(url.scheme ?? ""), url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { notice = "Use the private service's HTTP(S) origin only."; return }
        url.scheme = url.scheme == "https" ? "wss" : "ws"; url.path = "/browser-host"
        controller.start(serverURL: url.string ?? "", display: String(display.displayID), revision: revision, maximumMode: allowControl ? "interactive" : "view")
        notice = "Browser trust is separate from your paired phone. Create an enrollment code when the service is ready."
    }
    func stop() { endMedia(); controller.stop(); allowControl = false }
    func revoke() { endMedia(); controller.revoke(); allowControl = false }
    func changeControl(_ value: Bool) {
        // A mode change needs a fresh host grant, never an in-place escalation.
        if controller.running { stop() }
        canPostEvents = CGPreflightPostEventAccess()
        allowControl = value && canPostEvents
        notice = value && !allowControl ? "Accessibility is required for control; view-only remains available." : "Enable browser access again to apply the new scope."
    }
    private func begin(peer: PeerMedia, mode: String) {
        guard canAcquire(), let display, CGPreflightScreenCaptureAccess() else { stop(); return }
        endMedia(); let run = UUID(); generation = run
        gate.begin(session: controller.sessionID, revision: revision)
        let marker = BrowserFrameMarker(), gate = self.gate
        peer.setFrameTransform { buffer, _ in
            guard let (output, token) = try? marker.mark(buffer) else { return nil }
            gate.record(token: token, at: ProcessInfo.processInfo.systemUptime)
            return output
        }
        input.configure(SCContentFilter(display: display, excludingWindows: [])); input.enabled = false
        publishStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.lease.isExpired(at: ProcessInfo.processInfo.systemUptime) { self.release() }
                self.canPostEvents = CGPreflightPostEventAccess()
                if !self.healthy || !self.canPostEvents || !self.allowControl { self.input.enabled = false; self.release() }
                if !CGPreflightScreenCaptureAccess() { self.stop(); return }
                self.publishStatus()
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let owner = try await self.capture.start(display: display, peer: peer)
                guard !Task.isCancelled, self.generation == run else { _ = self.capture.stop(ifOwnedBy: owner); return }
                self.notice = "Authorized browser connected to the selected display."
            } catch {
                guard self.generation == run else { return }
                self.stop(); self.notice = "Capture could not start. Recheck the installed Mac app's permission and display."
            }
        }
    }
    private func endMedia() {
        generation = UUID(); task?.cancel(); task = nil
        timer?.invalidate(); timer = nil; healthy = false; input.enabled = false
        release(); gate.begin(session: "", revision: revision); _ = capture.stop()
    }
    private func release() {
        if input.held { for _ in 0..<8 { if input.release() { break } } }
        if !input.held { lease.cancel() }
    }
    private func receive(_ bytes: Data) {
        let permitted = controller.mode == "interactive" && allowControl && canPostEvents
        do {
            let action = try gate.accept(bytes, at: ProcessInfo.processInfo.systemUptime, healthy: healthy, control: permitted)
            input.enabled = permitted && healthy
            let result = input.handle(action)
            lease.record(action: action.action, accepted: result.accepted, at: ProcessInfo.processInfo.systemUptime)
            if result.holdEvent == .ended { lease.cancel() }
            if action.action == "text" { send(["type":"textResult", "key":action.key, "accepted":result.accepted]) }
        } catch {
            release()
            // Rejected text stays visibly unsent/uncertain on the browser. Never echo content.
            if let packet = try? JSONSerialization.jsonObject(with: bytes) as? [String:Any],
               let action = packet["action"] as? [String:Any], action["action"] as? String == "text", let key = action["key"] as? String, key.utf8.count <= 32 {
                send(["type":"textResult", "key":key, "accepted":false])
            }
            notice = "Input rejected: check current video, permission and session scope."
            publishStatus()
        }
    }
    private func publishStatus() {
        guard controller.connected, let display else { return }
        send(["type":"status", "session":controller.sessionID, "revision":String(revision), "mode":controller.mode,
              "healthy":healthy, "control":allowControl && canPostEvents && controller.mode == "interactive",
              "width":display.width, "height":display.height])
    }
    private func send(_ value: [String:Any]) { if let bytes = try? JSONSerialization.data(withJSONObject:value) { _ = controller.sendStatus(bytes) } }
}
