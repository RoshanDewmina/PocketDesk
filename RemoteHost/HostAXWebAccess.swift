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

    private(set) var attempted: Set<HostAXProcessKey> = []

    /// True exactly once per process of a Chromium-based app. Forgetting everything at capacity can only
    /// repeat an idempotent request for an app that already has its tree.
    mutating func claim(_ key: HostAXProcessKey, engine: HostAppEngine) -> Bool {
        guard engine.isWeb, !attempted.contains(key) else { return false }
        if attempted.count >= Self.capacity { attempted.removeAll(keepingCapacity: true) }
        attempted.insert(key)
        return true
    }

    /// A request that was never sent (cancelled or out of time) must not use up the process's one ask.
    mutating func release(_ key: HostAXProcessKey) {
        attempted.remove(key)
    }

    static func needsEnhancedFallback(after manual: HostAXSetOutcome, enhanced: HostAXFlagRead) -> Bool {
        manual == .unsupported && enhanced != .on
    }
}

struct HostAXWebActivation: Equatable, Sendable {
    let attribute: HostAXWebAttribute
    let outcome: HostAXSetOutcome
}

final class HostAXWebActivator: @unchecked Sendable {
    static let shared = HostAXWebActivator()

    private let lock = NSLock()
    private var policy = HostAXWebActivationPolicy()
    private var engines: [String: HostAppEngine] = [:]
    /// Processes where Farside turned AXEnhancedUserInterface on, to turn it off again at session end.
    private var enhancedByUs: Set<HostAXProcessKey> = []
    private let classify: (URL?) -> HostAppEngine

    init(classify: @escaping (URL?) -> HostAppEngine = { HostAppEngine.classify(bundleURL: $0) }) {
        self.classify = classify
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

    /// Nil when this process was already asked, needs nothing, or the request could not be sent. A
    /// request that was sent and failed is not repeated for the same process: a hung app would
    /// otherwise pay for it on every tap. One that was never sent leaves the process askable.
    func activateIfNeeded(_ key: HostAXProcessKey, engine: HostAppEngine,
                          set: (HostAXWebAttribute) -> HostAXSetOutcome,
                          isOn: (HostAXWebAttribute) -> HostAXFlagRead) -> HostAXWebActivation? {
        lock.lock()
        let claimed = policy.claim(key, engine: engine)
        lock.unlock()
        guard claimed else { return nil }
        let manual = set(.manual)
        guard manual != .notAttempted else { return unclaim(key) }
        var result = HostAXWebActivation(attribute: .manual, outcome: manual)
        if manual == .unsupported {
            let enhanced = isOn(.enhanced)
            guard enhanced != .notAttempted else { return unclaim(key) }
            if HostAXWebActivationPolicy.needsEnhancedFallback(after: manual, enhanced: enhanced) {
                let outcome = set(.enhanced)
                guard outcome != .notAttempted else { return unclaim(key) }
                result = HostAXWebActivation(attribute: .enhanced, outcome: outcome)
                // The Codex app reports notImplemented yet turns it on, so any sent write is remembered.
                if outcome != .unsupported { lock.lock(); enhancedByUs.insert(key); lock.unlock() }
            }
        }
        HostTextFocusLog.logger.info(
            "AX tree requested engine=\(engine.rawValue, privacy: .public) attribute=\(result.attribute.rawValue, privacy: .public) outcome=\(result.outcome.rawValue, privacy: .public)")
        return result
    }

    func isClaimed(_ key: HostAXProcessKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return policy.attempted.contains(key)
    }

    private func unclaim(_ key: HostAXProcessKey) -> HostAXWebActivation? {
        lock.lock(); policy.release(key); lock.unlock()
        HostTextFocusLog.logger.info("AX tree request not sent; process stays askable")
        return nil
    }

    /// At session end, turns AXEnhancedUserInterface off where Farside turned it on and it is still on,
    /// and forgets those processes so the next session can ask again. AXManualAccessibility stays on.
    /// Processes the budget did not reach are kept for the next session end. Returns the processes
    /// turned off.
    func revertEnhanced(isOn: (HostAXProcessKey) -> HostAXFlagRead,
                        turnOff: (HostAXProcessKey) -> HostAXSetOutcome) -> [HostAXProcessKey] {
        lock.lock()
        let keys = enhancedByUs.sorted { ($0.pid, $0.launched ?? 0) < ($1.pid, $1.launched ?? 0) }
        enhancedByUs.removeAll()
        lock.unlock()
        var reverted: [HostAXProcessKey] = []
        var kept: [HostAXProcessKey] = []
        for key in keys {
            let flag = isOn(key)
            if flag == .notAttempted { kept.append(key); continue }
            if flag == .on {
                let outcome = turnOff(key)
                if outcome == .notAttempted { kept.append(key); continue }
                if outcome == .applied { reverted.append(key) }
            }
            lock.lock(); policy.release(key); lock.unlock()
        }
        if !kept.isEmpty { lock.lock(); enhancedByUs.formUnion(kept); lock.unlock() }
        if !keys.isEmpty {
            HostTextFocusLog.logger.info("AX enhanced UI reverted=\(reverted.count, privacy: .public) kept=\(kept.count, privacy: .public)")
        }
        return reverted
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
    case noSession, native, alreadyAsked, laneBusy, notSent
    case requested(HostAXWebActivation)

    var reason: String {
        switch self {
        case .noSession: "noSession"
        case .native: "native"
        case .alreadyAsked: "alreadyAsked"
        case .laneBusy: "laneBusy"
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
        let (activator, set, isOn) = (activator, set, isOn)
        // Classifying reads the bundle from disk, so it happens on the lane too, never on main.
        return await broker.run(waitForLane: HostTextFocusProbe.lanePatience) { budget -> HostAXPrewarmOutcome? in
            let engine = activator.engine(for: bundleURL)
            guard engine.isWeb else { return .native }
            guard let activation = activator.activateIfNeeded(key, engine: engine,
                                                              set: { set($0, true, pid, budget) },
                                                              isOn: { isOn($0, pid, budget) }) else {
                return activator.isClaimed(key) ? .alreadyAsked : .notSent
            }
            return .requested(activation)
        } ?? .laneBusy
    }

    /// Session end: undo AXEnhancedUserInterface where Farside set it. A busy lane leaves it for the next end.
    func sessionEnded() async -> [HostAXProcessKey] {
        let (activator, set, isOn) = (activator, set, isOn)
        return await broker.run(waitForLane: HostTextFocusProbe.lanePatience) { budget -> [HostAXProcessKey]? in
            activator.revertEnhanced(isOn: { isOn(.enhanced, $0.pid, budget) },
                                     turnOff: { set(.enhanced, false, $0.pid, budget) })
        } ?? []
    }
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
