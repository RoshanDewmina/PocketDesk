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
    private(set) var isAllowed = false

    mutating func setAllowed(_ allowed: Bool) {
        isAllowed = allowed
    }

    mutating func pairingIdentityWillChange() {
        isAllowed = false
    }
}
