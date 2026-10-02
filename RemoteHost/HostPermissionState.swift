import Foundation

enum HostPermissionStatus: Equatable {
    case unchecked
    case granted
    case denied

    var isGranted: Bool { self == .granted }
}

enum HostDisplayRefreshStatus: Equatable {
    case notChecked
    case checking
    case ready
    case unavailable
    case permissionDenied
    case failed
}

enum HostDisplayEnumeration<Display> {
    case success([Display])
    case failure
}

struct HostPermissionRefreshResult<Display> {
    let screenRecording: HostPermissionStatus
    let accessibility: HostPermissionStatus
    let displays: [Display]
    let displayStatus: HostDisplayRefreshStatus

    static func resolve(
        screenRecordingGranted: Bool,
        accessibilityGranted: Bool,
        displayEnumeration: HostDisplayEnumeration<Display>
    ) -> Self {
        let screenRecording: HostPermissionStatus = screenRecordingGranted ? .granted : .denied
        let accessibility: HostPermissionStatus = accessibilityGranted ? .granted : .denied

        guard screenRecordingGranted else {
            return Self(
                screenRecording: screenRecording,
                accessibility: accessibility,
                displays: [],
                displayStatus: .permissionDenied
            )
        }

        switch displayEnumeration {
        case .failure:
            return Self(
                screenRecording: screenRecording,
                accessibility: accessibility,
                displays: [],
                displayStatus: .failed
            )
        case .success(let displays) where displays.isEmpty:
            return Self(
                screenRecording: screenRecording,
                accessibility: accessibility,
                displays: [],
                displayStatus: .unavailable
            )
        case .success(let displays):
            return Self(
                screenRecording: screenRecording,
                accessibility: accessibility,
                displays: displays,
                displayStatus: .ready
            )
        }
    }
}

struct HostPermissionRefreshGeneration {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        if current == 0 { current = 1 }
        return current
    }

    mutating func invalidate() {
        _ = begin()
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == current
    }
}

enum HostControlPolicy {
    static func isEnabled(
        userConsent: Bool,
        accessibilityPermission: HostPermissionStatus,
        captureHealthy: Bool
    ) -> Bool {
        userConsent && accessibilityPermission.isGranted && captureHealthy
    }
}

struct HostControlConsentState: Equatable {
    static let defaultAllowed = true
    private(set) var isAllowed: Bool

    init(isAllowed: Bool = Self.defaultAllowed) {
        self.isAllowed = isAllowed
    }

    mutating func setAllowed(_ allowed: Bool) {
        isAllowed = allowed
    }
}

// MARK: Input access

/// The two rights behind remote input. Posting events is what control needs; Accessibility (AX)
/// only powers the focus features, such as noticing that a click landed in a text field.
/// Farside never asks for Input Monitoring.
struct HostInputAccess: Equatable {
    var postEvents: HostPermissionStatus
    var accessibility: HostPermissionStatus

    static let unchecked = HostInputAccess(postEvents: .unchecked, accessibility: .unchecked)
}

/// Read on a timer or a notification, never per input event: every event reads the cached value.
struct HostInputAccessCache {
    private(set) var current: HostInputAccess
    private let probe: () -> HostInputAccess
    private let postingGrant: HostPostingGrantSnapshot?
    private let clock: () -> TimeInterval

    init(probe: @escaping () -> HostInputAccess, postingGrant: HostPostingGrantSnapshot? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.probe = probe
        self.postingGrant = postingGrant
        self.clock = clock
        let observedAt = clock()
        current = probe()
        postingGrant?.update(current.postEvents, at: observedAt)
    }

    /// Asks macOS again. True when either right changed.
    @discardableResult
    mutating func refresh() -> Bool {
        let observedAt = clock()
        let next = probe()
        // Equal grants still renew freshness. Use the probe's start time: a blocked check
        // must not publish an old answer as newly observed permission.
        postingGrant?.update(next.postEvents, at: observedAt)
        defer { current = next }
        return next != current
    }
}

/// A bounded observation for the posting queue, separate from UI permission state. The active
/// host probes every 250 ms; starvation expires a granted observation instead of retaining it.
/// This is admission only: macOS still decides whether a CGEvent may enter the event stream.
final class HostPostingGrantSnapshot: @unchecked Sendable {
    static let maximumAge: TimeInterval = 0.5
    static let disabledDefaultsKey = "hostPostingGrantSnapshotDisabled"
    private let lock = NSLock()
    private let enabled: Bool
    private var status: HostPermissionStatus = .unchecked
    private var observedAt: TimeInterval?

    init(enabled: Bool = !UserDefaults.standard.bool(forKey: HostPostingGrantSnapshot.disabledDefaultsKey)) {
        self.enabled = enabled
    }

    func update(_ status: HostPermissionStatus, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.status = now.isFinite ? status : .unchecked
        observedAt = now.isFinite ? now : nil
    }

    func isGranted(at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, status.isGranted, let observedAt else { return false }
        return (0..<Self.maximumAge).contains(now - observedAt)
    }

    func allowsPosting(at now: TimeInterval, legacyProbe: () -> Bool) -> Bool {
        enabled ? isGranted(at: now) : legacyProbe()
    }
}

// MARK: Capture approval

/// macOS stopped or declined the capture although the Screen Recording grant exists. Farside stays
/// registered and says so, and checks again on a backoff until capture is allowed, then shares again.
struct HostCaptureApproval: Equatable {
    static let firstCheck: TimeInterval = 5
    static let longestCheck: TimeInterval = 60

    private(set) var pendingSince: TimeInterval?
    private(set) var nextCheckAt: TimeInterval?
    private var interval = firstCheck

    var isPending: Bool { pendingSince != nil }

    mutating func begin(at now: TimeInterval) {
        if pendingSince == nil { pendingSince = now }
        interval = Self.firstCheck
        nextCheckAt = now + interval
    }

    func isDue(at now: TimeInterval) -> Bool {
        nextCheckAt.map { now >= $0 } ?? false
    }

    /// A check that still found capture refused waits twice as long, up to a minute.
    mutating func checkFailed(at now: TimeInterval) {
        guard isPending else { return }
        interval = min(Self.longestCheck, interval * 2)
        nextCheckAt = now + interval
    }

    /// Someone is at the Mac: check on the next tick.
    mutating func checkSoon(at now: TimeInterval) {
        guard isPending else { return }
        nextCheckAt = now
    }

    mutating func clear() {
        self = HostCaptureApproval()
    }
}

// MARK: OS update re-grant

/// A macOS update can turn off a permission that was on. This remembers what was granted on which
/// OS build, so Setup can say the update, not the person, turned it off. It never reads or changes
/// the privacy database; it compares what the public checks reported before and after.
struct HostOSPermissionRecord: Codable, Equatable {
    var osVersion: String
    var screenRecording: Bool
    var control: Bool
    /// Set while grants lost in an update are still missing; the grants above are the ones to restore.
    var updatedFrom: String?
}

enum HostUpgradeRegrant {
    struct Outcome: Equatable {
        var record: HostOSPermissionRecord
        /// Panes to switch on again because the update turned them off, in Setup's order.
        var missing: [HostSystemSettingsPane]
    }

    static func evaluate(record: HostOSPermissionRecord?, osVersion: String, screenRecording: Bool,
                         control: Bool) -> Outcome {
        let current = HostOSPermissionRecord(osVersion: osVersion, screenRecording: screenRecording, control: control)
        guard let record, record.osVersion != osVersion || record.updatedFrom != nil else {
            return Outcome(record: current, missing: [])
        }
        var missing: [HostSystemSettingsPane] = []
        if record.screenRecording && !screenRecording { missing.append(.screenRecording) }
        if record.control && !control { missing.append(.accessibility) }
        guard !missing.isEmpty else { return Outcome(record: current, missing: []) }
        var kept = record
        kept.updatedFrom = record.updatedFrom ?? record.osVersion
        kept.osVersion = osVersion
        return Outcome(record: kept, missing: missing)
    }
}

// MARK: Menu bar icon

/// The person can remove the menu bar icon (Command-drag, or System Settings → Menu Bar). Farside
/// keeps running and sharing, and reopening it from Finder or Spotlight shows Settings, where
/// "Show in menu bar" puts the icon back.
enum HostMenuBarIconPolicy {
    enum Destination: Equatable { case setup, settings }

    /// Where a reopen from Finder or Spotlight goes when no window is visible.
    static func reopenDestination(needsSetup: Bool, iconShown: Bool) -> Destination {
        iconShown && needsSetup ? .setup : .settings
    }
}
