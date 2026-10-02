import Foundation
import Combine

@MainActor
final class PhoneDiagnostics: ObservableObject {
    @Published private(set) var reports: [SessionDiagnosticReport]
    @Published private(set) var running = false
    @Published private(set) var status = "Connect for an authenticated Test My Mac."
    @Published private(set) var storageFailure = false
    private let store: SessionDiagnosticStore
    private var recorder = DiagnosticSessionRecorder()
    private var testRecorder: DiagnosticSessionRecorder?
    private let uptime: () -> Double
    private var probe: DiagnosticProbeRun?
    private var task: Task<Void, Never>?
    private var testStarted = 0.0
    private var full = false
    static let attemptDiagnosticsKey = "PocketDeskAttemptDiagnostics"
    private static let processAttemptDiagnosticsEnabled = attemptDiagnosticsEnabled(defaults: .standard)
    static func attemptDiagnosticsEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: attemptDiagnosticsKey) == nil || defaults.bool(forKey: attemptDiagnosticsKey)
    }
    private let attemptDiagnosticsEnabled: Bool
    private var attempt: DiagnosticAttempt?
    private var attemptRecorder = DiagnosticSessionRecorder()
    private var pendingAttemptID: UUID?
    private var connectionObservers: Set<AnyCancellable> = []
    private var crashObserver: AnyCancellable?
    private let crashes: CrashDiagnostics
    init(store: SessionDiagnosticStore = SessionDiagnosticStore(), uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         attemptDiagnosticsEnabled: Bool = PhoneDiagnostics.processAttemptDiagnosticsEnabled, crashes: CrashDiagnostics = .shared) {
        self.store = store; self.uptime = uptime; self.attemptDiagnosticsEnabled = attemptDiagnosticsEnabled
        self.crashes = crashes
        reports = store.load()
        crashes.start()
        crashObserver = crashes.reportsChanged.receive(on: DispatchQueue.main).sink { [weak self] in self?.reloadReports() }
        if attemptDiagnosticsEnabled {
            for var report in reports where report.attempt != nil && report.attempt?.reason == nil {
                var summary = report.attempt!
                if summary.events.count >= DiagnosticAttemptSummary.maximumEvents { summary.events.remove(at: 1) }
                summary.events.append(.init(stage: .ended, seconds: summary.events.last?.seconds ?? 0))
                summary.reason = .processInterrupted; report.attempt = summary; report.outcome = .interrupted
                do { try store.save(report) } catch { storageFailure = true }
            }
            reports = store.load()
        }
        reloadReports()
    }
    private func reloadReports() {
        let apple = crashes.reports().map { report in
            SessionDiagnosticReport(kind: .appleDiagnostic, outcome: .collected, seconds: 0, samples: 0, facts: [],
                at: report.createdAt, crash: report, id: report.id, artifact: report.artifact)
        }
        reports = Array((store.load() + apple).sorted { $0.createdAt > $1.createdAt }.prefix(SessionDiagnosticStore.maximumReports))
    }
    /// Integration seam: the coordinator owner binds once after its initializer finishes.
    /// Observing published state never changes authentication, retry or control authority.
    func bind(to coordinator: RemoteCoordinator) {
        connectionObservers.removeAll()
        guard attemptDiagnosticsEnabled else { return }
        coordinator.$status.sink { [weak self, weak coordinator] status in
            guard let self, let coordinator else { return }
            switch status {
            case "Connecting securely…": self.beginAttempt()
            case "Authenticating your Mac…": self.recordAttemptStage(.authenticating)
            case "Approve this phone on your Mac", "Compare this code with your Mac, then choose Allow there": self.recordAttemptStage(.awaitingApproval)
            case "Connecting live desktop…": self.recordAttemptStage(.mediaConnecting)
            default:
                if !coordinator.isRunning {
                    self.finishAttempt(reason: status == "Disconnected" ? .cancelled : .connectionFailed)
                }
            }
        }.store(in: &connectionObservers)
        coordinator.$connected.sink { [weak self] connected in
            if connected { self?.recordAttemptStage(.connected) }
        }.store(in: &connectionObservers)
        coordinator.$reconnecting.sink { [weak self] reconnecting in
            guard reconnecting, let self else { return }
            let wasConnected = self.attempt?.summary.events.contains { $0.stage == .connected } == true
            self.finishAttempt(reason: wasConnected ? .connectionEnded : .connectionFailed)
        }.store(in: &connectionObservers)
    }
    func beginAttempt() {
        guard attemptDiagnosticsEnabled else { return }
        if attempt != nil { finishAttempt(reason: .connectionEnded) }
        attempt = DiagnosticAttempt(started: uptime()); attemptRecorder = DiagnosticSessionRecorder()
        persistAttempt()
    }
    func recordAttemptStage(_ stage: DiagnosticAttemptSummary.Stage) {
        guard attemptDiagnosticsEnabled, var run = attempt else { return }
        let before = run.summary
        run.record(stage, at: uptime()); attempt = run
        if run.summary != before { persistAttempt() }
    }
    func finishAttempt(reason: DiagnosticAttemptSummary.Reason) {
        guard attemptDiagnosticsEnabled, var run = attempt else { return }
        run.finish(reason, at: uptime()); attempt = run
        persistAttempt(); attempt = nil; pendingAttemptID = nil
        attemptRecorder = DiagnosticSessionRecorder()
    }
    private func persistAttempt() {
        guard let attempt else { return }
        let snapshot = attemptRecorder.finish(at: uptime())
        let outcome: SessionDiagnosticReport.Outcome
        switch attempt.summary.reason {
        case nil: outcome = .inProgress
        case .connectionFailed: outcome = .failed
        case .cancelled: outcome = .cancelled
        case .processInterrupted: outcome = .interrupted
        default: outcome = .sessionEnded
        }
        let report = SessionDiagnosticReport(kind: .connectionAttempt, outcome: outcome,
            seconds: attempt.summary.events.last?.seconds ?? 0, samples: snapshot.samples, facts: snapshot.facts,
            attempt: attempt.summary, transport: snapshot.transport, id: pendingAttemptID ?? UUID())
        do {
            try store.save(report)
            pendingAttemptID = report.id; storageFailure = false; reloadReports()
        } catch { storageFailure = true; status = "Couldn’t save the local report. No report was exported." }
    }
    func observe(_ report: StreamStatsReport, estimate: DataUseEstimate? = nil) {
        let now = uptime()
        recorder.observe(report, at: now, estimate: estimate)
        if attempt != nil {
            attemptRecorder.observe(report, at: now, estimate: estimate)
            recordAttemptStage(.statistics)
        }
        if running { testRecorder?.observe(report, at: now, estimate: estimate) }
    }
    func start(full: Bool, session: UUID, epoch: UInt64, authorized: @escaping () -> Bool,
               send: @escaping (ClockProbe) -> Bool, facts: @escaping () -> [DiagnosticFact]) {
        guard !running, authorized() else { return }
        testStarted = uptime(); self.full = full
        testRecorder = DiagnosticSessionRecorder()
        probe = DiagnosticProbeRun(session: session, epoch: epoch, full: full, at: testStarted)
        running = true; status = "Checking authenticated app echoes and current session health…"
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, var run = self.probe {
                let now = self.uptime()
                let next = run.next(session: session, epoch: epoch, authorized: authorized(), at: now, stampMs: MachClock.nowMs())
                self.probe = run
                if let next, !send(next) { self.cancel(); return }
                if run.state != .running { self.finishTest(facts: facts()); return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    func receive(_ echo: ClockProbe, session: UUID, epoch: UInt64, authorized: Bool) {
        probe?.receive(echo, session: session, epoch: epoch, authorized: authorized,
            at: uptime(), stampMs: MachClock.nowMs())
    }
    func cancel() {
        guard running else { return }
        probe?.cancel(); finishTest(facts: [])
    }
    private func finishTest(facts: [DiagnosticFact]) {
        task?.cancel(); task = nil
        guard let probe else { return }
        let outcome: SessionDiagnosticReport.Outcome = probe.state == .completed ? .completed : probe.state == .timedOut ? .timedOut : .cancelled
        let now = uptime()
        let snapshot = (testRecorder ?? DiagnosticSessionRecorder()).finish(kind: full ? .fullPreflight : .lightPreflight, outcome: outcome, at: now, additional: facts + probe.facts)
        save(SessionDiagnosticReport(kind: snapshot.kind, outcome: outcome, seconds: now - testStarted, samples: snapshot.samples, facts: snapshot.facts, transport: snapshot.transport))
        running = false; self.probe = nil; testRecorder = nil
        if !storageFailure {
            status = outcome == .completed ? "Authenticated check complete. See measured facts and unknowns below." : outcome == .timedOut ? "Replies were incomplete. See unanswered probes; this is not a bandwidth result." : "Check cancelled when its authority or scene changed."
        }
    }
    func ended() {
        cancel()
        if recorder.samples > 0 { save(recorder.finish(at: uptime())) }
        recorder = DiagnosticSessionRecorder()
    }
    private func save(_ report: SessionDiagnosticReport) {
        do { try store.save(report); storageFailure = false; reloadReports() }
        catch { storageFailure = true; status = "Couldn’t save the local report. No report was exported." }
    }
    func delete(_ id: UUID) { store.delete(id); crashes.delete(id); reloadReports() }
    func deleteAll() { store.deleteAll(); crashes.deleteAll(); reloadReports() }
    /// Called only by an explicit diagnostics export action; never uploads or writes to the clipboard.
    func exportCrashReport(_ id: UUID) -> Data? { crashes.export(id: id) }
}
