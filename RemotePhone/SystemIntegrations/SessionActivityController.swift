import ActivityKit
import Foundation
import os

/// The parts of ActivityKit the controller uses, so its behavior is testable without a device.
@MainActor
protocol SessionActivityClient: AnyObject {
    var isEnabled: Bool { get }
    /// Starts the activity, first ending any this client already had. False when the system refused.
    func start(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState,
               staleDate: Date?) async -> Bool
    func update(state: FarsideSessionAttributes.ContentState, staleDate: Date?) async
    func end(reason: FarsideSessionAttributes.EndReason) async
    /// Ends every session activity this client did not start: leftovers from a crash or an earlier launch.
    func endStrays() async
}

@MainActor
final class ActivityKitSessionClient: SessionActivityClient {
    private var activity: Activity<FarsideSessionAttributes>?
    private let log = Logger(subsystem: "com.roshan.PocketDesk.Remote", category: "live-activity")

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState,
               staleDate: Date?) async -> Bool {
        if let previous = activity {
            activity = nil
            await previous.end(nil, dismissalPolicy: .immediate)
        }
        do {
            // No push token yet: nothing can push to this activity until the service exists. When it
            // does, request with `.token` and forward `pushTokenUpdates` to it.
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: staleDate),
                                            pushType: nil)
            return true
        } catch {
            log.error("Live Activity was not started: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func update(state: FarsideSessionAttributes.ContentState, staleDate: Date?) async {
        await activity?.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(reason: FarsideSessionAttributes.EndReason) async {
        guard let activity else { return }
        self.activity = nil
        await SessionActivityStore.end(activity, reason: reason)
    }

    func endStrays() async {
        for other in Activity<FarsideSessionAttributes>.activities where other.id != activity?.id {
            await other.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Keeps one Live Activity in step with the session: starts it after the handshake, moves it through
/// Live, Paused and Reconnecting, and ends it with the reason. It cannot keep the app alive, so it
/// also tells the system when to distrust its own content: a paused state goes stale just after the
/// hold ends, and a live one goes stale unless the running app keeps refreshing it, so an app that
/// died never leaves a frozen "Live" on the Lock Screen.
@MainActor
final class SessionActivityController {
    private var machine = SessionActivityMachine()
    private let client: any SessionActivityClient
    private var chain: Task<Void, Never>?
    private var generation = 0
    private var keepAliveTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var startedAtUnix = 0
    private let log = Logger(subsystem: "com.roshan.PocketDesk.Remote", category: "live-activity")

    var preferences: () -> AgentAlertPreferences = { AgentAlertPreferences() }
    /// The paired Mac: an opaque id and its name. Nil when nothing is paired.
    var identity: () -> (macId: String, name: String)? = { nil }
    var now: () -> Date = { Date() }
    /// A drop shorter than this never shows "Reconnecting".
    var reconnectDelay: TimeInterval = 1.5
    var keepAliveInterval: TimeInterval? = SessionActivityMachine.keepAlive

    init(client: any SessionActivityClient) {
        self.client = client
    }

    var hasActivity: Bool { machine.hasActivity }
    var currentState: FarsideSessionAttributes.ContentState? { machine.current }

    /// Waits for every queued change. Tests use it; the app never needs to.
    func settle() async {
        await chain?.value
    }

    func apply(_ snapshot: SessionSnapshot) {
        generation += 1
        let mine = generation
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await self?.run(snapshot, generation: mine)
        }
    }

    private func run(_ snapshot: SessionSnapshot, generation mine: Int) async {
        if machine.isReconnectingCandidate(snapshot) {
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            guard mine == generation else { return }
        }
        guard preferences().sessionLiveActivity || machine.hasActivity else { return }
        if !preferences().sessionLiveActivity {
            machine.activityWasEnded()
            stopKeepAlive()
            await client.end(reason: .user)
            return
        }
        guard let command = machine.reduce(snapshot) else { return }
        switch command {
        case .start(let state):
            await start(with: state)
        case .update(let state):
            await client.update(state: state, staleDate: SessionActivityMachine.staleDate(for: state, now: now()))
            armKeepAlive()
        case .end(let reason):
            stopKeepAlive()
            await client.end(reason: reason)
        }
    }

    private func start(with state: FarsideSessionAttributes.ContentState) async {
        cancelPreview()
        guard client.isEnabled, let identity = identity() else {
            machine.activityWasEnded()
            return
        }
        let preferences = preferences()
        let started = now()
        startedAtUnix = Int(started.timeIntervalSince1970)
        let attributes = FarsideSessionAttributes(
            macId: identity.macId,
            macLabel: preferences.showMacNameOnLockScreen ? identity.name : "Your Mac",
            sessionId: String(UUID().uuidString.prefix(8)).lowercased(),
            startedAtUnix: startedAtUnix,
            preview: nil)
        await client.endStrays()
        let ok = await client.start(attributes: attributes, state: state,
                                    staleDate: SessionActivityMachine.staleDate(for: state, now: started))
        if ok { armKeepAlive() } else { machine.activityWasEnded() }
    }

    /// A launch has no session, so any session activity still showing is a leftover: end it.
    func reconcileOnLaunch() async {
        await client.endStrays()
    }

    // MARK: Keep alive

    private func armKeepAlive() {
        stopKeepAlive()
        guard let interval = keepAliveInterval,
              let phase = machine.current?.phase, phase == .live || phase == .reconnecting else { return }
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.keepAliveTick() }
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    /// Re-issues the current state with a fresh stale date. Only a running app can do this, which is the point.
    func keepAliveTick() async {
        guard let state = machine.current, state.phase == .live || state.phase == .reconnecting else {
            stopKeepAlive()
            return
        }
        await client.update(state: state, staleDate: SessionActivityMachine.staleDate(for: state, now: now()))
    }

    // MARK: Preview

    /// A labelled sample for the Settings "Preview Live Activity" button: it walks through every state
    /// and connects to nothing. A real session replaces it.
    func startPreview(hold phase: FarsideSessionAttributes.Phase? = nil) {
        guard !machine.hasActivity, client.isEnabled else { return }
        cancelPreview()
        let preferences = preferences()
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = self.now()
            let attributes = FarsideSessionAttributes(
                macId: "m_preview",
                macLabel: preferences.showMacNameOnLockScreen ? (self.identity()?.name ?? "Your Mac") : "Your Mac",
                sessionId: "preview",
                startedAtUnix: Int(started.timeIntervalSince1970) - 754,
                preview: true)
            let steps: [(FarsideSessionAttributes.ContentState, TimeInterval)]
            if let phase {
                steps = [(Self.previewState(phase, now: started), 0)]
            } else {
                steps = [(.live(route: .direct), 4),
                         (.paused(graceEnds: started.addingTimeInterval(13), route: .direct), 5),
                         (.reconnecting(route: .direct), 4)]
            }
            // A sample never goes stale on its own while someone is looking at it.
            let staleDate = started.addingTimeInterval(600)
            guard let first = steps.first,
                  await self.client.start(attributes: attributes, state: first.0, staleDate: staleDate) else { return }
            if phase != nil { return }
            for (index, step) in steps.enumerated() {
                if index > 0 {
                    await self.client.update(state: step.0, staleDate: staleDate)
                }
                try? await Task.sleep(nanoseconds: UInt64(step.1 * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self.client.end(reason: .user)
        }
    }

    private static func previewState(_ phase: FarsideSessionAttributes.Phase, now: Date) -> FarsideSessionAttributes.ContentState {
        switch phase {
        case .live: .live(route: .direct)
        case .paused: .paused(graceEnds: now.addingTimeInterval(24), route: .direct)
        case .reconnecting: .reconnecting(route: .direct)
        case .ended: .ended(.timeout)
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    func stopPreview() async {
        cancelPreview()
        if !machine.hasActivity { await client.end(reason: .user) }
    }
}
