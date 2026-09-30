import Foundation

enum SessionMode: String, Codable, Equatable, CaseIterable {
    case picture, couch
}

enum SessionModeRefusal: String, Equatable, CaseIterable {
    case notLocal, controlOff, screenRecording
}

enum SessionModeStatus {
    static let refused = "refused"
}

/// The `acceptedAck` body, inside the pairing cipher. Picture sends no body, so an older Mac sees nothing new.
struct SessionModeRequest: Codable, Equatable {
    static let maximumBodyBytes = 256
    var mode: String

    static func body(for mode: SessionMode) -> Data? { nil }
    static func mode(fromAcceptedAckBody body: Data?) -> SessionMode { .picture }
}

enum CouchCopy {
    static let entryTitle = "Couch mode"
    static let entryCaption = "Trackpad and keys. No picture."
    static let checking = "Checking you’re on the same network…"
    static let notLocal = "Couch mode works on the same Wi-Fi or Ethernet network. Join your Mac’s network and try again."
    static let controlOff = "Control is off on your Mac. Turn on Allow control in Farside’s menu."
    static let updateMac = "Update Farside on your Mac to use Couch mode. Showing the picture instead."
    static let notAnswering = "Your Mac isn’t answering. Input paused."
    static let needsScreenRecording = "Your Mac needs Screen Recording to show the picture."
    static let showingPicture = "Showing your Mac’s screen…"
    static let restHeadline = "Look at your Mac. This is its trackpad."
    static let restDeadpan = "The picture is the one on your wall."
    static let hud = "iPhone is steering this Mac · Couch mode, no picture shared"
    static let connectWithPicture = "Connect with picture"
    /// Coordinator status when the phone itself stops a Couch attempt that did not get a local route.
    static let phoneRefusedStatus = "Couch mode needs the same network as your Mac."

    static func refusal(_ reason: SessionModeRefusal) -> String { "" }
}

extension RemoteAction {
    static let modeAction = "mode"

    func validateSessionMode() throws -> Bool { false }
}
