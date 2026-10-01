import Foundation
import CoreGraphics
import IOKit.ps
import IOKit.pwr_mgt

struct HostKeepAwakeBackend {
    let acquire: () -> UInt32?
    let release: (UInt32) -> Bool

    /// Keeps the display lit while a phone is connected.
    static let system = assertion(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                  name: "PocketDesk active remote access")
    /// Keeps the Mac reachable while sharing; the display may still sleep.
    static let idleSystem = assertion(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                      name: "PocketDesk remote access")

    static func assertion(_ type: CFString, name: String) -> HostKeepAwakeBackend {
        HostKeepAwakeBackend(
            acquire: {
                var assertionID: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &assertionID
                )
                return result == kIOReturnSuccess ? assertionID : nil
            },
            release: { assertionID in
                IOPMAssertionRelease(IOPMAssertionID(assertionID)) == kIOReturnSuccess
            }
        )
    }
}

enum HostPowerPolicy {
    /// Idle reachability follows the owner's preference and pauses on battery. A live, unpaused phone
    /// automatically holds the display on, including idle view-only/audio sessions.
    static func assertions(keepAwake: Bool, sharing: Bool, phoneConnected: Bool, awayArmed: Bool = false,
                           onBattery: Bool = false) -> (system: Bool, display: Bool) {
        (sharing && ((keepAwake && !onBattery) || awayArmed), sharing && (phoneConnected || awayArmed))
    }
}

extension HostPowerSnapshot {
    /// Battery only with a battery reading behind it: a Mac without one, or a failed read, counts as on power.
    var onBatteryPower: Bool { !onACPower && batteryPercent != nil }
}

/// Follows the power source so keep-awake can pause on battery and resume on power.
@MainActor
final class HostBatteryWatch {
    private let power: HostPowerSourceReading
    private(set) var onBattery: Bool
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?
    private var retainedSelf: Unmanaged<HostBatteryWatch>?

    init(power: HostPowerSourceReading = SystemPowerSource()) {
        self.power = power
        onBattery = power.snapshot().onBatteryPower
    }

    func refresh() {
        let now = power.snapshot().onBatteryPower
        guard now != onBattery else { return }
        onBattery = now
        onChange?()
    }

    func start() {
        guard retainedSelf == nil else { return }
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let watch = Unmanaged<HostBatteryWatch>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watch.refresh() }
        }
        if let created = IOPSNotificationCreateRunLoopSource(callback, retained.toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
            source = created
        }
        refresh()
    }

    func stop() {
        guard let retained = retainedSelf else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        retainedSelf = nil
        retained.release()
    }
}

/// Display sleep alone keeps sharing registered so a phone can connect and wake it. System
/// sleep, fast user switching and screen lock still tear sharing down.
enum HostSleepPolicy {
    enum Event: Equatable {
        case systemWillSleep, systemDidWake, sessionResigned, sessionActivated
        case screenLocked, screenUnlocked, displaySlept, displayWoke
    }

    enum Response: Equatable {
        case tearDown(HostPresence)
        case recover
        case displayAsleep
        case displayAwake
    }

    static func response(to event: Event) -> Response {
        switch event {
        case .systemWillSleep: .tearDown(.sleeping)
        case .sessionResigned: .tearDown(.switchedUser)
        case .screenLocked: .tearDown(.locked)
        case .systemDidWake, .sessionActivated, .screenUnlocked: .recover
        case .displaySlept: .displayAsleep
        case .displayWoke: .displayAwake
        }
    }
}

/// `sessionDidResignActive` covers only fast user switching; a plain lock is detected through
/// the widely used lock notifications plus a session-dictionary check.
enum HostScreenLock {
    static let locked = Notification.Name("com.apple.screenIsLocked")
    static let unlocked = Notification.Name("com.apple.screenIsUnlocked")

    static func isLocked(_ session: [String: Any]? = CGSessionCopyCurrentDictionary() as? [String: Any]) -> Bool {
        (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}

/// Powers the display on as remote user activity; the declaration expires on its own.
final class HostDisplayWake {
    private var assertionID: IOPMAssertionID = 0

    @discardableResult
    func declareRemoteActivity() -> Bool {
        IOPMAssertionDeclareUserActivity("PocketDesk remote session" as CFString, kIOPMUserActiveRemote, &assertionID)
            == kIOReturnSuccess
    }
}

final class HostKeepAwake {
    private let backend: HostKeepAwakeBackend
    private var assertionID: UInt32?

    var isActive: Bool { assertionID != nil }

    init(backend: HostKeepAwakeBackend = .system) {
        self.backend = backend
    }

    @discardableResult
    func start() -> Bool {
        if assertionID != nil { return true }
        assertionID = backend.acquire()
        return assertionID != nil
    }

    @discardableResult
    func stop() -> Bool {
        guard let assertionID else { return true }
        for _ in 0..<3 {
            if backend.release(assertionID) {
                self.assertionID = nil
                return true
            }
        }
        return false
    }

    deinit {
        _ = stop()
    }
}

enum HostActiveAccessPolicy {
    static func isRunning(
        status: String,
        hostRegistered: Bool,
        connected: Bool,
        awaitingApproval: Bool
    ) -> Bool {
        if hostRegistered || connected || awaitingApproval { return true }
        if status.hasPrefix("Connecting") || status.contains("retrying") { return true }
        return ["new", "checking", "connected"].contains(status)
    }
}
