import Foundation

enum AwayModeLimits {
    static let idleBeforeCover: TimeInterval = 120
    static let batteryGraceWithoutPhone: TimeInterval = 5 * 60
    static let batteryFloorWithPhone = 20
    static let expiryWithoutPhone: TimeInterval = 24 * 60 * 60
    static let lockConfirmTimeout: TimeInterval = 2
}

/// Why Away mode cannot arm right now, in the order the Mac explains them.
enum AwayUnavailableReason: String, Equatable, CaseIterable {
    case sharingOff, macLocked, needsAccessibility, managed, onBattery, safeMode
}

enum AwayEndReason: String, Equatable, CaseIterable {
    case touched, screensChanged, phoneRequest, stopSharing, quit, expiry, battery, lostRequirement, relaunchedAfterExit
}

struct AwayConditions: Equatable {
    var enabled = false
    /// The person wants sharing on. Internal stop/restart cycles keep this true.
    var sharingWanted = false
    /// Sharing is running now. Needed to arm, not to stay armed.
    var sharingActive = false
    var accessibility = false
    var onACPower = true
    var batteryPercent: Int?
    var managed = false
    var screenLocked = false
    var phoneConnected = false
    var safeMode = false
}

enum AwayPhase: Equatable {
    case off
    case armedPresent
    case armedCovered
    case locking(AwayEndReason)
    case lockFailed(AwayEndReason)
}

enum AwayEffect: Equatable {
    case lock(AwayEndReason)
}

struct AwayModeMachine: Equatable {
    private(set) var phase: AwayPhase = .off
    private(set) var conditions = AwayConditions()
    private(set) var lastLocalInputAt: TimeInterval = 0
    private(set) var lastPhoneAt: TimeInterval = 0
    private(set) var onBatterySince: TimeInterval?
    private(set) var lockRequestedAt: TimeInterval?
    /// Whether the cover stays up while locking and after a failed lock.
    private(set) var lockCovers = false

    init() {}

    static func unavailableReason(_ conditions: AwayConditions) -> AwayUnavailableReason? { nil }

    var isArmed: Bool { phase == .armedPresent || phase == .armedCovered }
    var wantsCover: Bool { false }
    var holdsDisplayAwake: Bool { false }
    var protocolState: AwayModeState { .off }

    func coversIn(now: TimeInterval) -> TimeInterval? { nil }
    func batteryEndsIn(now: TimeInterval) -> TimeInterval? { nil }

    @discardableResult mutating func update(_ conditions: AwayConditions, now: TimeInterval) -> AwayEffect? { nil }
    @discardableResult mutating func tick(now: TimeInterval) -> AwayEffect? { nil }
    @discardableResult mutating func localInput(now: TimeInterval) -> AwayEffect? { nil }
    mutating func coverNow(now: TimeInterval) {}
    @discardableResult mutating func end(_ reason: AwayEndReason, now: TimeInterval) -> AwayEffect? { nil }
    mutating func turnOffAtMac() {}
    mutating func lockConfirmed() {}
}

/// What the Mac's settings and popover show about Away mode.
struct HostAwayReadout: Equatable {
    enum Phase: Equatable { case off, armed, covered, locking, lockFailed }

    /// The release gate allows Away mode on this build or Mac.
    var available = false
    var enabled = false
    var phase: Phase = .off
    var unavailable: AwayUnavailableReason?
    var coversAt: Date?
    var batteryEndsAt: Date?
    var lowPowerMode = false
}
