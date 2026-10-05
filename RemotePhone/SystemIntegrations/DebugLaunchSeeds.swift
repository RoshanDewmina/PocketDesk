import Foundation

#if DEBUG
import SwiftUI

/// Launch switches for UI tests and simulator captures. They keep a paired Mac in memory, so a test
/// never touches the Keychain item a real pairing lives in and nothing outlives the run.
///
///     --ui-seed-pairing=Studio Mac    a paired Mac whose service address refuses connections at once
enum DebugLaunchSeeds {
    /// One invitation per process, so the model, the intents and Shortcuts all agree on the Mac's id.
    static let invitation: PairInvitation? = {
        guard let name = LaunchOptions.value("--ui-seed-pairing="), !name.isEmpty else { return nil }
        // Fixed throwaway proof lets simctl sample pushes bind to this UI-only pairing. Port 9
        // refuses signaling; no device pairing or server account can use this launch seed.
        return PairInvitation(server: "ws://127.0.0.1:9/signal", room: String(repeating: "a", count: 64),
                              token: String(repeating: "b", count: 64), key: Data(repeating: 1, count: 32),
                              expires: .distantFuture, name: name)
    }()

    /// A store that starts with the seeded invitation and forgets it when the app quits.
    static func store() -> (any PairPersistence)? {
        if LaunchOptions.has("--ui-first60"), invitation == nil { return InMemoryPairStore(invitation: nil) }
        return invitation.map { InMemoryPairStore(invitation: $0) }
    }

    /// Presents what a notification tap or the Home row would, for captures and UI tests:
    ///
    ///     --ui-agent-settings                    the Agent alerts sheet
    ///     --ui-agent-alert=claude_code[:option]  the sheet a tap opens; options: test, reminder, old
    ///     --ui-agent-banner=codex                the quiet banner shown over a live session
    ///     --ui-session-live                      treat a session as live for alert presentation
    ///     --ui-request-notifications             ask iOS for notification permission, as turning alerts on does
    @MainActor
    static func applyPresentations(to alerts: AgentAlertCenter) {
        if LaunchOptions.has("--ui-session-live") { alerts.isSessionLive = { true } }
        if LaunchOptions.has("--ui-request-notifications") { Task { @MainActor in _ = await alerts.requestAndEnable() } }
        if LaunchOptions.has("--ui-agent-settings") { alerts.showsSettings = true }
        if let spec = LaunchOptions.value("--ui-agent-alert=") {
            let identity = alertPreviewIdentity ?? String(repeating: "a", count: 64)
            let parts = spec.split(separator: ":").map(String.init)
            var payload = AgentAlertPayload(helpRequestID: "h_ui01", kind: AgentKind(wire: parts.first),
                                            pairingIdentity: identity, threadID: "mac-ui",
                                            interruption: .timeSensitive)
            let options = Set(parts.dropFirst())
            payload.isTest = options.contains("test")
            payload.isReminder = options.contains("reminder")
            let asked = Date().addingTimeInterval(options.contains("old") ? -40 * 60 : -90)
            alerts.open(payload, deliveredAt: asked)
        }
        if let spec = LaunchOptions.value("--ui-agent-banner=") {
            let payload = AgentAlertPayload(helpRequestID: "h_ui02", kind: AgentKind(wire: spec), threadID: "mac-ui")
            alerts.showBanner(AgentAlertPresentation(payload: payload, receivedAt: Date()))
        }
    }

    static var alertPreviewIdentity: String? {
        guard LaunchOptions.value("--ui-agent-alert=") != nil else { return nil }
        return invitation?.notificationIdentity ?? String(repeating: "a", count: 64)
    }

    /// Starts a labelled sample Live Activity, held in one state for captures, or walking through all:
    ///
    ///     --ui-live-activity=live|paused|reconnecting|ended|tour
    @MainActor
    static func applyActivity(to controller: SessionActivityController) {
        guard let spec = LaunchOptions.value("--ui-live-activity=") else { return }
        if spec == "tour" {
            controller.startPreview()
        } else if let phase = FarsideSessionAttributes.Phase(rawValue: spec) {
            controller.startPreview(hold: phase)
        }
    }
}

final class InMemoryPairStore: PairPersistence {
    private var data: Data?

    init(invitation: PairInvitation?) {
        data = invitation.flatMap { try? JSONEncoder().encode($0) }
    }

    func save<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }

    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        try data.map { try JSONDecoder().decode(type, from: $0) }
    }

    func delete() throws { data = nil }
}

/// Offline capsule layout only. This owns a separate engine; it never changes the session model.
@MainActor
final class DebugFileTransferFixture: ObservableObject {
    enum Mode: String { case progress, pickerWait = "picker-wait" }
    static let fileName = "Native layout fixture with a deliberately long file name.txt"
    let files: PhoneFileTransfer
    let inbox: SendToMacInbox

    init(mode: Mode) {
        let files = PhoneFileTransfer(destination: { nil }, idleTimer: PhoneIdleTimer { _ in }, clock: { 0 })
        self.files = files
        inbox = SendToMacInbox(root: nil, useBackgroundIO: false)
        // No transport is attached. A local sink consumes one bounded chunk without touching disk.
        files.engine.sendControl = { _ in true }
        files.engine.admit = { _, answer in answer(.success(DebugFileTransferSink())) }
        files.requestFromMac()
        guard mode == .progress else { return }
        guard let request = files.engine.pendingRequest,
              let chunk = FileChunk.encode(transfer: request, offset: 0, payload: Data(repeating: 0, count: 512)) else {
            files.reset()
            files.postUnavailable("Offline transfer fixture could not start.")
            return
        }
        files.engine.receive(.offer(request, name: Self.fileName, bytes: 1024, type: "public.data"))
        // The ordinary I/O callback publishes 50%; UI tests wait for that rendered progress value.
        files.engine.receiveChunk(chunk)
    }

    func stop() { files.reset() }
}

private final class DebugFileTransferSink: FileByteSink {
    func write(_ data: Data) throws {
        guard data.count <= 1024 else { throw FileTransferStatus.tooLarge }
    }
    func commit() throws -> URL { throw FileTransferStatus.unsupported }
    func discard() {}
}

/// StateObject keeps the one fixture alive through rotation; disappearance retires its engine.
@MainActor
struct DebugFileTransferCapsule: View {
    @StateObject private var fixture: DebugFileTransferFixture
    let hidesNotice: Bool

    init(mode: DebugFileTransferFixture.Mode, hidesNotice: Bool) {
        _fixture = StateObject(wrappedValue: DebugFileTransferFixture(mode: mode))
        self.hidesNotice = hidesNotice
    }

    var body: some View {
        FileTransferCapsule(files: fixture.files, inbox: fixture.inbox, hidesNotice: hidesNotice)
            .onDisappear { fixture.stop() }
    }
}
#endif

enum LaunchSeeds {
    /// The pairing store for a launch that seeds one, and nil (the Keychain) for every real launch.
    static func pairingStore() -> (any PairPersistence)? {
        #if DEBUG
        DebugLaunchSeeds.store()
        #else
        nil
        #endif
    }
}
