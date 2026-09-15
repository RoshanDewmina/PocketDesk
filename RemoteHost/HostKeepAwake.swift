import Foundation
import IOKit.pwr_mgt

struct HostKeepAwakeBackend {
    let acquire: () -> UInt32?
    let release: (UInt32) -> Bool

    static let system = HostKeepAwakeBackend(
        acquire: {
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "PocketDesk active remote access" as CFString,
                &assertionID
            )
            return result == kIOReturnSuccess ? assertionID : nil
        },
        release: { assertionID in
            IOPMAssertionRelease(IOPMAssertionID(assertionID)) == kIOReturnSuccess
        }
    )
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
