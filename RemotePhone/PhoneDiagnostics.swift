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
    init(store: SessionDiagnosticStore = SessionDiagnosticStore(), uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.store = store; self.uptime = uptime; reports = store.load() }
    func observe(_ report: StreamStatsReport, estimate: DataUseEstimate? = nil) {
        let now = uptime()
        recorder.observe(report, at: now, estimate: estimate)
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
        save(SessionDiagnosticReport(kind: snapshot.kind, outcome: outcome, seconds: now - testStarted, samples: snapshot.samples, facts: snapshot.facts))
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
        do { try store.save(report); storageFailure = false; reports = store.load() }
        catch { storageFailure = true; status = "Couldn’t save the local report. No report was exported." }
    }
    func delete(_ id: UUID) { store.delete(id); reports = store.load() }
    func deleteAll() { store.deleteAll(); reports = store.load() }
}
