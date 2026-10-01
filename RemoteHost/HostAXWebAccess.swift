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
    case applied, unsupported, failed

    init(_ error: AXError) {
        switch error {
        case .success: self = .applied
        case .attributeUnsupported: self = .unsupported
        default: self = .failed
        }
    }
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

    static func needsEnhancedFallback(after manual: HostAXSetOutcome, enhancedAlreadyOn: Bool?) -> Bool {
        manual == .unsupported && enhancedAlreadyOn != true
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

    /// Nil when this process was already asked or needs nothing. A failed request is not retried for the
    /// same process: a hung app would otherwise pay for it on every tap.
    func activateIfNeeded(_ key: HostAXProcessKey, engine: HostAppEngine,
                          set: (HostAXWebAttribute) -> HostAXSetOutcome,
                          isOn: (HostAXWebAttribute) -> Bool?) -> HostAXWebActivation? {
        lock.lock()
        let claimed = policy.claim(key, engine: engine)
        lock.unlock()
        guard claimed else { return nil }
        let manual = set(.manual)
        var result = HostAXWebActivation(attribute: .manual, outcome: manual)
        if HostAXWebActivationPolicy.needsEnhancedFallback(after: manual, enhancedAlreadyOn: isOn(.enhanced)) {
            result = HostAXWebActivation(attribute: .enhanced, outcome: set(.enhanced))
        }
        HostTextFocusLog.logger.info(
            "AX tree requested engine=\(engine.rawValue, privacy: .public) attribute=\(result.attribute.rawValue, privacy: .public) outcome=\(result.outcome.rawValue, privacy: .public)")
        return result
    }

    /// Writes one boolean attribute on an application element. Never touches any element's value.
    static func set(_ attribute: HostAXWebAttribute, on app: AXUIElement, budget: HostAXBudget) -> HostAXSetOutcome {
        guard budget.arm(app) else { return .failed }
        return HostAXSetOutcome(AXUIElementSetAttributeValue(app, attribute.rawValue as CFString, kCFBooleanTrue))
    }

    static func isOn(_ attribute: HostAXWebAttribute, on app: AXUIElement, budget: HostAXBudget) -> Bool? {
        guard budget.arm(app) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute.rawValue as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}

enum HostTextFocusLog {
    static let logger = Logger(subsystem: "com.roshan.PocketDesk", category: "textFocus")
}
