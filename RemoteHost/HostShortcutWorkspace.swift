import AppKit
import ApplicationServices

/// Retained launch-specific context; it is consumed once, then checked on the executor posting queue.
final class HostShortcutWorkspace: @unchecked Sendable {
    struct Ticket: @unchecked Sendable {
        let app: NSRunningApplication
        let launch: Date
        let bundleID: String
        let issuedAt: TimeInterval
        let generation: UInt64
        let session: UUID
        let epoch: UInt64
    }
    private let lock = NSRecursiveLock()
    private var requests = ScopedChordRequestLedger()
    private var generation: UInt64 = 0
    private var context: (id: String, ticket: Ticket)?
    var currentGeneration: UInt64 { lock.withLock { generation } }
    func retire() { lock.withLock { generation &+= 1; context = nil; requests.retire() } }
    func admitRequest(_ id: String) -> Bool { lock.withLock { requests.insert(id) } }
    func issue(bundleID: String, session: UUID, epoch: UInt64) -> ScopedChordReply {
        lock.withLock {
            context = nil
            guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
                  !app.isTerminated, app.bundleIdentifier == bundleID, let launch = app.launchDate else { return .init(outcome: .rejected) }
            let id = InputCausalEnvelope.identity()
            let ticket = Ticket(app: app, launch: launch, bundleID: bundleID, issuedAt: ProcessInfo.processInfo.systemUptime,
                                generation: generation, session: session, epoch: epoch)
            context = (id, ticket)
            return .init(outcome: .ready, context: id, bundleID: bundleID)
        }
    }
    func consume(id: String, session: UUID, epoch: UInt64) -> Ticket? {
        lock.withLock {
            guard let saved = context, saved.id == id, saved.ticket.session == session, saved.ticket.epoch == epoch else { return nil }
            context = nil
            return saved.ticket
        }
    }
    func posting(_ ticket: Ticket, operation: () -> RemoteInputOutcome) -> RemoteInputOutcome {
        lock.withLock {
            guard ticket.generation == generation, !ticket.app.isTerminated, AXIsProcessTrusted(),
                  !HostScreenLock.isLocked(), !Self.secure(), let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == ticket.bundleID,
                  ScopedChordPolicy.current(issuedAt: ticket.issuedAt, now: ProcessInfo.processInfo.systemUptime,
                    expectedPID: ticket.app.processIdentifier, currentPID: app.processIdentifier,
                    expectedLaunch: ticket.launch, currentLaunch: app.launchDate, generation: ticket.generation,
                    currentGeneration: generation, secure: HostSecureFocus.secureEventInputEnabled()) else { return RemoteInputOutcome() }
            // Global event routing can race a local focus change. This certifies posting, not task completion.
            return operation()
        }
    }
    private static func secure() -> Bool {
        if HostSecureFocus.secureEventInputEnabled() { return true }
        guard let app = NSWorkspace.shared.frontmostApplication else { return true }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(owner, 0.03)
        var focus: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focus)
        if read == .noValue { return false }
        guard read == .success, let focus, CFGetTypeID(focus) == AXUIElementGetTypeID() else { return true }
        let element = focus as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, 0.03)
        var role: CFTypeRef?
        let subrole = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        if subrole == .noValue || subrole == .attributeUnsupported { return false }
        guard subrole == .success else { return true }
        return role as? String == kAXSecureTextFieldSubrole as String
    }
}
