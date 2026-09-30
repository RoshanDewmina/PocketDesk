import Foundation

enum SessionMode: String, Codable, Equatable, CaseIterable {
    case picture, couch
}

enum SessionModeRefusal: String, Equatable, CaseIterable {
    case notLocal, controlOff, screenRecording, displayUnavailable
}

enum SessionModeStatus {
    static let refused = "refused"
}

/// The `acceptedAck` body, inside the pairing cipher. Mode and the optional display name share one bounded body.
struct SessionModeRequest: Codable, Equatable {
    static let maximumBodyBytes = 256
    var mode: String
    var name: String? = nil

    static func body(for mode: SessionMode, name: String? = nil) -> Data? {
        let clean = name.flatMap(PhoneIdentity.sanitized)
        guard mode != .picture || clean != nil else { return nil }
        let request = SessionModeRequest(mode: mode.rawValue, name: clean)
        if let body = try? JSONEncoder().encode(request), body.count <= maximumBodyBytes { return body }
        return try? JSONEncoder().encode(SessionModeRequest(mode: mode.rawValue))
    }

    static func mode(fromAcceptedAckBody body: Data?) -> SessionMode {
        guard let body, body.count <= maximumBodyBytes,
              let request = try? JSONDecoder().decode(SessionModeRequest.self, from: body),
              let mode = SessionMode(rawValue: request.mode) else { return .picture }
        return mode
    }
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
    static let displayUnavailable = "Couldn’t load your Mac’s display. Still in Couch mode. Try showing the picture again."
    static let showingPicture = "Showing your Mac’s screen…"
    static let restHeadline = "Look at your Mac. This is its trackpad."
    static let restDeadpan = "The picture is the one on your wall."
    static let hud = "iPhone is steering this Mac · Couch mode, no picture shared"
    static let connectWithPicture = "Connect with picture"
    /// Coordinator status when the phone itself stops a Couch attempt that did not get a local route.
    static let phoneRefusedStatus = "Couch mode needs the same network as your Mac."

    static func refusal(_ reason: SessionModeRefusal) -> String {
        switch reason {
        case .notLocal: notLocal
        case .controlOff: controlOff
        case .screenRecording: needsScreenRecording
        case .displayUnavailable: displayUnavailable
        }
    }
}

extension RemoteAction {
    static let modeAction = "mode"

    /// Returns true when this is a complete `mode` request, which bypasses the legacy action list.
    func validateSessionMode() throws -> Bool {
        if action == "capture" {
            if let mode, !ClipboardFrame.isWellFormedStatus(mode) { throw RemoteError.invalidMessage }
            if let modeReason {
                guard mode != nil, ClipboardFrame.isWellFormedStatus(modeReason) else { throw RemoteError.invalidMessage }
            }
            return false
        }
        guard action == Self.modeAction else {
            guard mode == nil, modeReason == nil else { throw RemoteError.invalidMessage }
            return false
        }
        guard let mode, SessionMode(rawValue: mode) != nil, modeReason == nil,
              x == 0, y == 0, text.isEmpty, key.isEmpty, modifiers.isEmpty,
              interaction == nil, pointerLocatorSupported == nil, pointerProbe == nil, pointerLocation == nil,
              pointerSync == nil, streamQuality == nil, textFocusProbe == nil, textFocusEditable == nil,
              clipboard == nil, features == nil, hostState == nil, hostStream == nil, curtain == nil, hostEvent == nil,
              displays == nil, display == nil, agentAlert == nil, clock == nil, screenPixels == nil, viewport == nil,
              phoneLoad == nil, captureRegion == nil, ladder == nil, busy == nil
        else { throw RemoteError.invalidMessage }
        return true
    }
}
