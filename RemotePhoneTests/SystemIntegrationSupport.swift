import Foundation
import UserNotifications
import XCTest
@testable import PocketDeskRemote

/// A signaling connection the tests script: what it was asked to do, and what the "service" says back.
@MainActor
final class FakeSignalingTransport: SignalingTransport {
    struct Connect {
        var invitation: PairInvitation
        var hostToken: String?
        var features: [String]
    }

    var onMessage: ((RelayMessage) -> Void)?
    var onClose: (() -> Void)?
    var connectError: Error?
    /// Delivered on the next main-queue turn after `connect`, like a real service's first reply.
    var replies: [RelayMessage] = []
    /// Close the connection after `connect`, as a dropped socket would.
    var dropsAfterConnect = false
    private(set) var connects: [Connect] = []
    private(set) var sent: [RelayMessage] = []
    private(set) var closeCount = 0

    func connect(invitation: PairInvitation, hostToken: String?, features: [String]) throws {
        if let connectError { throw connectError }
        connects.append(Connect(invitation: invitation, hostToken: hostToken, features: features))
        let scripted = replies
        let drops = dropsAfterConnect
        Task { @MainActor [weak self] in
            for reply in scripted { self?.onMessage?(reply) }
            if drops { self?.onClose?() }
        }
    }

    func send(_ message: RelayMessage) { sent.append(message) }
    func close() { closeCount += 1 }
}

enum TestPairing {
    static func invitation(name: String = "Studio Mac") throws -> PairInvitation {
        try HostPair.create(server: "ws://127.0.0.1:9/signal", name: name).invitation
    }

    static func mac(name: String = "Studio Mac", withInvitation: Bool = true) throws -> PairedMac {
        let invitation = try invitation(name: name)
        return PairedMac(id: PairedMacs.opaqueID(room: invitation.room), name: name,
                         invitation: withInvitation ? invitation : nil)
    }
}

/// A handler that records what the End session intent asked for.
@MainActor
final class RecordingSessionHandler: SessionIntentHandling {
    var outcome: SessionEndOutcome = .ended
    private(set) var endRequests = 0

    func endSessionFromIntent() async -> SessionEndOutcome {
        endRequests += 1
        return outcome
    }
}

/// A notification center the tests drive: what was scheduled and removed, and what iOS "answers".
@MainActor
final class FakeNotificationCenter: AgentNotificationScheduling {
    var categories: Set<UNNotificationCategory> = []
    var accessValue: NotificationAccess = .notDetermined
    var timeSensitiveValue: UNNotificationSetting = .enabled
    var grantsPermission = true
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []
    private(set) var authorizationRequests = 0

    func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }

    func access() async -> (access: NotificationAccess, timeSensitive: UNNotificationSetting) {
        (accessValue, timeSensitiveValue)
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        accessValue = grantsPermission ? .allowed : .denied
        return grantsPermission
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        added.append(request)
        return true
    }

    func removePending(_ identifiers: [String]) { removedPending += identifiers }
    func removeDelivered(_ identifiers: [String]) { removedDelivered += identifiers }
    func pendingIdentifiers() async -> [String] { added.map(\.identifier) }
}

/// Isolated defaults so a test never sees, or changes, the real app's choices.
func makeTestDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "FarsideTests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}
