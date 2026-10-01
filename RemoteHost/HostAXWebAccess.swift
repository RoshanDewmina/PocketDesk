import AppKit
import ApplicationServices
import os

/// How an app draws its UI, which decides whether it exposes an Accessibility tree unprompted.
enum HostAppEngine: String, Sendable {
    case native, electron, chromium

    var isWeb: Bool { self != .native }

    /// Reads only the bundle's layout. Electron apps ship `app.asar` (the Codex app also renames its
    /// framework, so the asar is the reliable mark); Chrome-family browsers keep "(Renderer)" helpers
    /// inside "<Name> Framework.framework".
    static func classify(bundleURL: URL?, fileManager: FileManager = .default) -> HostAppEngine {
        guard let bundleURL else { return .native }
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        if fileManager.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path) ||
            fileManager.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) {
            return .electron
        }
        let items = (try? fileManager.contentsOfDirectory(atPath: frameworks.path)) ?? []
        for item in items where item.hasSuffix(" Framework.framework") {
            let helpers = frameworks.appendingPathComponent(item).appendingPathComponent("Versions/Current/Helpers")
            let names = (try? fileManager.contentsOfDirectory(atPath: helpers.path)) ?? []
            if names.contains(where: { $0.hasSuffix("(Renderer).app") }) { return .chromium }
        }
        return .native
    }
}

enum HostAXWebAttribute: String, Sendable {
    case manual = "AXManualAccessibility"
    case enhanced = "AXEnhancedUserInterface"
}

enum HostAXSetOutcome: String, Sendable {
    /// `notAttempted`: the budget was spent or cancelled before the write was sent.
    case applied, unsupported, failed, notAttempted

    init(_ error: AXError) {
        switch error {
        case .success: self = .applied
        case .attributeUnsupported: self = .unsupported
        default: self = .failed
        }
    }
}

/// A boolean attribute as read from an app; `notAttempted` means the budget ran out first.
enum HostAXFlagRead: String, Sendable {
    case on, off, unknown, notAttempted
}

/// A process instance: a pid alone can be reused by a later launch.
struct HostAXProcessKey: Hashable, Sendable {
    let pid: pid_t
    let launched: TimeInterval?
}

/// Chromium and Electron build their Accessibility tree only once an assistive client asks, and keep
/// paying for it (CPU, memory, slower DOM updates) for as long as the process runs. So Farside asks
/// lazily: only for the app that is frontmost when a text-focus probe finds no editable focus, only
/// for a Chromium-based app, and at most once per process.
///
/// Measured on macOS 27 (2026-10-01): Electron (Claude 2.16120, Cursor) accepts `AXManualAccessibility`
/// and has a tree about 2 s later. Chrome 154 and the Codex app answer attributeUnsupported for it and
/// need `AXEnhancedUserInterface`, which some apps also read as "an assistive app is moving windows" and
/// cut window animations for. So that attribute is only the fallback, and never written when already on.
struct HostAXWebActivationPolicy {
    static let capacity = 64
    /// A request that was sent but failed (typically a timeout while the app launches) may be repeated,
    /// at most this many times in all and this far apart, so a hung app does not pay on every tap.
    static let maxAttempts = 3
    static let retryCooldown: TimeInterval = 5

    struct Record: Equatable, Sendable {
        var attempts: Int
        var lastAt: TimeInterval
        /// The last request was sent and failed; another may follow after the cooldown.
        var failed: Bool
    }

    private(set) var records: [HostAXProcessKey: Record] = [:]

    var attempted: Set<HostAXProcessKey> { Set(records.keys) }

    /// Claims one request for a process of a Chromium-based app, returning the record it replaced so an
    /// unsent request can restore it. Nil means no request now. Forgetting everything at capacity can
    /// only repeat an idempotent request for an app that already has its tree.
    mutating func claim(_ key: HostAXProcessKey, engine: HostAppEngine, now: TimeInterval) -> Record?? {
        guard engine.isWeb else { return nil }
        let previous = records[key]
        if let previous {
            guard previous.failed, previous.attempts < Self.maxAttempts,
                  now - previous.lastAt >= Self.retryCooldown else { return nil }
        } else if records.count >= Self.capacity {
            records.removeAll(keepingCapacity: true)
        }
        records[key] = Record(attempts: (previous?.attempts ?? 0) + 1, lastAt: now, failed: false)
        return .some(previous)
    }

    mutating func finish(_ key: HostAXProcessKey, failed: Bool) {
        records[key]?.failed = failed
    }

    /// A request that was never sent (cancelled or out of time) does not count as an attempt.
    mutating func release(_ key: HostAXProcessKey, restoring previous: Record? = nil) {
        records[key] = previous
    }

    static func needsEnhancedFallback(after manual: HostAXSetOutcome, enhanced: HostAXFlagRead) -> Bool {
        manual == .unsupported && enhanced != .on
    }
}

struct HostAXWebActivation: Equatable, Sendable {
    let attribute: HostAXWebAttribute
    let outcome: HostAXSetOutcome
}

enum HostAXActivationAttempt: Equatable, Sendable {
    /// Native, already asked, or a failed request still cooling down.
    case skipped
    /// The budget ran out before anything was written; the process stays askable.
    case notSent
    case sent(HostAXWebActivation)
}

final class HostAXWebActivator: @unchecked Sendable {
    static let shared = HostAXWebActivator()

    private let lock = NSLock()
    private var policy = HostAXWebActivationPolicy()
    private var engines: [String: HostAppEngine] = [:]
    /// Processes where Farside turned AXEnhancedUserInterface on, to turn it off again at session end.
    private var enhancedByUs: Set<HostAXProcessKey> = []
    private let classify: (URL?) -> HostAppEngine
    private let clock: () -> TimeInterval

    init(classify: @escaping (URL?) -> HostAppEngine = { HostAppEngine.classify(bundleURL: $0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.classify = classify
        self.clock = clock
    }

    func engine(for bundleURL: URL?) -> HostAppEngine {
        guard let bundleURL else { return .native }
        let path = bundleURL.standardizedFileURL.path
        lock.lock()
        if let known = engines[path] { lock.unlock(); return known }
        lock.unlock()
        let engine = classify(bundleURL)
        lock.lock()
        if engines.count >= 128 { engines.removeAll(keepingCapacity: true) }
        engines[path] = engine
        lock.unlock()
        return engine
    }

    /// The activation that was sent, or nil when nothing was (see `request`).
    func activateIfNeeded(_ key: HostAXProcessKey, engine: HostAppEngine,
                          set: (HostAXWebAttribute) -> HostAXSetOutcome,
                          isOn: (HostAXWebAttribute) -> HostAXFlagRead) -> HostAXWebActivation? {
        if case .sent(let activation) = request(key, engine: engine, set: set, isOn: isOn) { return activation }
        return nil
    }

    /// One request per process; a sent request that failed may be repeated after a cooldown, and one
    /// that was never sent leaves the process askable.
    func request(_ key: HostAXProcessKey, engine: HostAppEngine,
                 set: (HostAXWebAttribute) -> HostAXSetOutcome,
                 isOn: (HostAXWebAttribute) -> HostAXFlagRead) -> HostAXActivationAttempt {
        let now = clock()
        lock.lock()
        let claim = policy.claim(key, engine: engine, now: now)
        lock.unlock()
        guard let previous = claim else { return .skipped }
        func unsent() -> HostAXActivationAttempt {
            lock.lock(); policy.release(key, restoring: previous); lock.unlock()
            HostTextFocusLog.logger.info("AX tree request not sent; process stays askable")
            return .notSent
        }
        let manual = set(.manual)
        guard manual != .notAttempted else { return unsent() }
        var result = HostAXWebActivation(attribute: .manual, outcome: manual)
        if manual == .unsupported {
            let enhanced = isOn(.enhanced)
            guard enhanced != .notAttempted else { return unsent() }
            if HostAXWebActivationPolicy.needsEnhancedFallback(after: manual, enhanced: enhanced) {
                let outcome = set(.enhanced)
                guard outcome != .notAttempted else { return unsent() }
                result = HostAXWebActivation(attribute: .enhanced, outcome: outcome)
                // The Codex app reports notImplemented yet turns it on, so any sent write is remembered.
                if outcome != .unsupported { lock.lock(); enhancedByUs.insert(key); lock.unlock() }
            }
        }
        lock.lock(); policy.finish(key, failed: result.outcome == .failed); lock.unlock()
        HostTextFocusLog.logger.info(
            "AX tree requested engine=\(engine.rawValue, privacy: .public) attribute=\(result.attribute.rawValue, privacy: .public) outcome=\(result.outcome.rawValue, privacy: .public)")
        return .sent(result)
    }

    func isClaimed(_ key: HostAXProcessKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return policy.attempted.contains(key)
    }

    /// At session end, turns AXEnhancedUserInterface off where Farside turned it on and it is still on,
    /// and forgets those processes so the next session can ask again. AXManualAccessibility stays on.
    /// A process whose state could not be read or written (out of budget, an AX error, a failed write)
    /// is kept for the next session end; one that has exited, is already off, or rejects the write is
    /// dropped. Returns the processes turned off.
    func revertEnhanced(isAlive: (HostAXProcessKey) -> Bool = HostAXWebActivator.isAlive,
                        isOn: (HostAXProcessKey) -> HostAXFlagRead,
                        turnOff: (HostAXProcessKey) -> HostAXSetOutcome) -> [HostAXProcessKey] {
        lock.lock()
        let keys = enhancedByUs.sorted { ($0.pid, $0.launched ?? 0) < ($1.pid, $1.launched ?? 0) }
        enhancedByUs.removeAll()
        lock.unlock()
        var reverted: [HostAXProcessKey] = []
        var kept: [HostAXProcessKey] = []
        for key in keys {
            guard isAlive(key) else { lock.lock(); policy.release(key); lock.unlock(); continue }
            switch isOn(key) {
            case .notAttempted, .unknown:
                kept.append(key); continue
            case .off:
                break
            case .on:
                switch turnOff(key) {
                case .notAttempted, .failed: kept.append(key); continue
                case .applied: reverted.append(key)
                case .unsupported: break
                }
            }
            lock.lock(); policy.release(key); lock.unlock()
        }
        if !kept.isEmpty { lock.lock(); enhancedByUs.formUnion(kept); lock.unlock() }
        if !keys.isEmpty {
            HostTextFocusLog.logger.info("AX enhanced UI reverted=\(reverted.count, privacy: .public) kept=\(kept.count, privacy: .public)")
        }
        return reverted
    }

    /// The same process instance is still running; a kept entry for an exited app would never clear.
    static func isAlive(_ key: HostAXProcessKey) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: key.pid), !app.isTerminated else { return false }
        return key.launched == nil || app.launchDate?.timeIntervalSince1970 == key.launched
    }

    /// Writes one boolean attribute on an application element. Never touches any element's value.
    static func set(_ attribute: HostAXWebAttribute, _ value: Bool = true, on app: AXUIElement,
                    budget: HostAXBudget) -> HostAXSetOutcome {
        guard budget.arm(app) else { return .notAttempted }
        return HostAXSetOutcome(AXUIElementSetAttributeValue(app, attribute.rawValue as CFString,
                                                             value ? kCFBooleanTrue : kCFBooleanFalse))
    }

    static func isOn(_ attribute: HostAXWebAttribute, on app: AXUIElement, budget: HostAXBudget) -> HostAXFlagRead {
        guard budget.arm(app) else { return .notAttempted }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute.rawValue as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unknown }
        return CFBooleanGetValue((value as! CFBoolean)) ? .on : .off
    }
}

enum HostTextFocusLog {
    static let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "textFocus")
}

enum HostAXPrewarmOutcome: Equatable, Sendable {
    case noSession, notTrusted, native, alreadyAsked, laneBusy, timedOut, notSent
    case requested(HostAXWebActivation)

    var reason: String {
        switch self {
        case .noSession: "noSession"
        case .native: "native"
        case .alreadyAsked: "alreadyAsked"
        case .notTrusted: "notTrusted"
        case .laneBusy: "laneBusy"
        case .timedOut: "timedOut"
        case .notSent: "notSent"
        case .requested: "requested"
        }
    }
}

/// A cold Electron app builds its tree about 2 s after the request, so asking at the first tap
/// answers that tap "not editable". During a live controlled session the request is made when a
/// Chromium-based app becomes frontmost instead, under the same once-per-process policy and on the
/// same bounded AX lane; never outside a session and never for a native app.
struct HostAXWebPrewarm: Sendable {
    typealias SetAttribute = @Sendable (HostAXWebAttribute, Bool, pid_t, HostAXBudget) -> HostAXSetOutcome
    typealias IsOn = @Sendable (HostAXWebAttribute, pid_t, HostAXBudget) -> HostAXFlagRead

    var activator: HostAXWebActivator = .shared
    var broker: HostAXBroker = .shared
    var set: SetAttribute = { attribute, value, pid, budget in
        HostAXWebActivator.set(attribute, value, on: AXUIElementCreateApplication(pid), budget: budget)
    }
    var isOn: IsOn = { attribute, pid, budget in
        HostAXWebActivator.isOn(attribute, on: AXUIElementCreateApplication(pid), budget: budget)
    }
    var trusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var isAlive: @Sendable (HostAXProcessKey) -> Bool = { HostAXWebActivator.isAlive($0) }

    func appActivated(pid: pid_t, launched: TimeInterval?, bundleURL: URL?,
                      sessionActive: Bool) async -> HostAXPrewarmOutcome {
        let outcome = await outcome(pid: pid, launched: launched, bundleURL: bundleURL, sessionActive: sessionActive)
        HostTextFocusLog.logger.info("prewarm \(outcome.reason, privacy: .public)")
        return outcome
    }

    private func outcome(pid: pid_t, launched: TimeInterval?, bundleURL: URL?,
                         sessionActive: Bool) async -> HostAXPrewarmOutcome {
        guard sessionActive else { return .noSession }
        guard pid > 0, pid != getpid() else { return .native }
        let key = HostAXProcessKey(pid: pid, launched: launched)
        let (activator, set, isOn, trusted) = (activator, set, isOn, trusted)
        let started = Flag()
        // Classifying reads the bundle from disk, so it happens on the lane too, never on main.
        let result = await broker.run(waitForLane: HostTextFocusProbe.lanePatience) { budget -> HostAXPrewarmOutcome? in
            started.set()
            // The session predicate checks the post-events permission; without AX trust a write fails
            // with apiDisabled and would count as a failed attempt.
            guard trusted() else { return .notTrusted }
            let engine = activator.engine(for: bundleURL)
            guard engine.isWeb else { return .native }
            switch activator.request(key, engine: engine, set: { set($0, true, pid, budget) },
                                     isOn: { isOn($0, pid, budget) }) {
            case .skipped: return .alreadyAsked
            case .notSent: return .notSent
            case .sent(let activation): return .requested(activation)
            }
        }
        // The broker discards work that overran its budget; that work may still have written.
        return result ?? (started.isSet ? .timedOut : .laneBusy)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Session end: undo AXEnhancedUserInterface where Farside set it. Skipped while VoiceOver runs (it
    /// needs the attribute on) and when a new session has started since (a quick reconnect must not
    /// lose it under a live session); a busy lane leaves it for the next session end. `stillCurrent`
    /// is checked on the lane, immediately before any write.
    func sessionEnded(voiceOverOn: Bool, stillCurrent: @escaping @Sendable () -> Bool) async -> HostAXRevertResult {
        guard !voiceOverOn else { return log(.voiceOver) }
        guard stillCurrent() else { return log(.newSession) }
        let (activator, set, isOn, isAlive) = (activator, set, isOn, isAlive)
        let result = await broker.run(waitForLane: HostTextFocusProbe.lanePatience) { budget -> HostAXRevertResult? in
            guard stillCurrent() else { return .newSession }
            return .reverted(activator.revertEnhanced(isAlive: isAlive,
                                                      isOn: { isOn(.enhanced, $0.pid, budget) },
                                                      turnOff: { set(.enhanced, false, $0.pid, budget) }))
        } ?? .laneBusy
        return log(result)
    }

    private func log(_ result: HostAXRevertResult) -> HostAXRevertResult {
        HostTextFocusLog.logger.info("session-end revert \(result.reason, privacy: .public)")
        return result
    }
}

enum HostAXRevertResult: Equatable, Sendable {
    case voiceOver, newSession, laneBusy
    case reverted([HostAXProcessKey])

    var reason: String {
        switch self {
        case .voiceOver: "skippedVoiceOver"
        case .newSession: "skippedNewSession"
        case .laneBusy: "laneBusy"
        case .reverted(let keys): "reverted=\(keys.count)"
        }
    }
}

/// Counts sessions so work scheduled at one session's end can tell that another has begun.
final class HostAXSessionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value &+= 1; lock.unlock() }
}

/// When a live controlled session starts (or resumes) with a Chromium app already frontmost, no
/// activation notification arrives, so the start itself is the moment to ask.
struct HostAXPrewarmEdge {
    private(set) var wasActive = false

    /// True only when the live-controlled-session predicate flips from false to true.
    mutating func update(active: Bool) -> Bool {
        defer { wasActive = active }
        return active && !wasActive
    }
}

extension HostAXWebPrewarm {
    func controlStarted(frontmost app: NSRunningApplication?) async -> HostAXPrewarmOutcome {
        guard let app else { return .native }
        return await appActivated(pid: app.processIdentifier, launched: app.launchDate?.timeIntervalSince1970,
                                  bundleURL: app.bundleURL, sessionActive: true)
    }
}
