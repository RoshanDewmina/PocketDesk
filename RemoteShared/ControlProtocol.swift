import Foundation

struct RemoteAction: Codable {
    var action: String
    var x: Double = 0
    var y: Double = 0
    var text: String = ""
    var key: String = ""
    var modifiers: [String] = []
    var epoch: UInt64 = 1
    var interaction: NativeInteraction? = nil
    var pointerLocatorSupported: Bool? = nil
    var pointerProbe: String? = nil
    var pointerLocation: PointerLocation? = nil
    var pointerSync: PointerSync? = nil
    var streamQuality: StreamQuality? = nil
    var textFocusProbe: String? = nil
    var textFocusEditable: Bool? = nil
    // Session extensions (clipboard, background pause). Validated in SessionContinuity.swift.
    var clipboard: ClipboardFrame? = nil
    var features: [String]? = nil
    var hostState: String? = nil
    /// Sender-side stream stages for the phone's optional statistics overlay. Older phones ignore it.
    var hostStream: HostStreamSummary? = nil
    // Privacy curtain request ("curtain" action) or state (on "capture"); host lifecycle event.
    var curtain: String? = nil
    var hostEvent: String? = nil
    /// Display selection (`displays`, `display`); validated in DisplaySelection.swift.
    var displays: [DisplayDescriptor]? = nil
    var display: UInt32? = nil
    /// A "needs you" alert from an agent on the Mac, sent once on a `capture` status. Older phones ignore it.
    var agentAlert: AgentAlertFrame? = nil
    /// Clock-sync probe on a heartbeat: the phone sends it, the host echoes it (see `ClockProbe`).
    var clock: ClockProbe? = nil

    func validate() throws {
        // Before the extension early returns, so no other action can carry an unchecked summary.
        try hostStream?.validate()
        guard hostStream == nil || action == "capture" else { throw RemoteError.invalidMessage }
        try clock?.validate()
        guard clock == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        // Also before the early returns, so no other action can carry a display list.
        if try validateDisplaySelection() { return }
        if try validateSessionExtension() { return }
        if try validatePointerSync() { return }
        try interaction?.validate()
        try pointerLocation?.validate()
        if let textFocusProbe {
            guard ["click", "double", "heartbeat"].contains(action),
                  textFocusProbe.utf8.count == 32,
                  textFocusProbe.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw RemoteError.invalidMessage }
            if action != "heartbeat" {
                guard interaction != nil, textFocusEditable == nil else { throw RemoteError.invalidMessage }
            }
        }
        guard textFocusEditable == nil || (action == "heartbeat" && textFocusProbe != nil)
        else { throw RemoteError.invalidMessage }
        guard streamQuality == nil || action == "heartbeat" || action == "capture" else { throw RemoteError.invalidMessage }
        if let pointerProbe {
            guard action == "heartbeat", !pointerProbe.isEmpty, pointerProbe.utf8.count <= 64 else { throw RemoteError.invalidMessage }
        }
        guard pointerLocation == nil || (action == "heartbeat" && pointerProbe != nil),
              pointerLocatorSupported == nil || action == "capture" else { throw RemoteError.invalidMessage }
        guard ["move", "moveTo", "click", "right", "middle", "double", "dragDown", "dragUp", "scroll", "text", "key", "release", "heartbeat", "viewing", "geometry", "capture", "textResult", "holdRenew"].contains(action),
              x.isFinite, y.isFinite, abs(x) <= 20000, abs(y) <= 20000,
              text.utf8.count <= 4096, text.utf16.count <= 1024, key.utf8.count <= 32, modifiers.count <= 4,
              modifiers.allSatisfy({ ["command", "shift", "option", "control"].contains($0) }) else { throw RemoteError.invalidMessage }
        // An absolute position is display-local, so it can never be negative. Phones send these
        // new actions only after the host advertises `SessionFeature.absolutePointer`/`middleButton`.
        guard action != "moveTo" || (x >= 0 && y >= 0) else { throw RemoteError.invalidMessage }
        guard action != "middle" || interaction == nil || interaction?.clickCount == 1 else { throw RemoteError.invalidMessage }
    }
}

struct ControlPacket: Codable {
    var version = 1
    var session: String
    var sequence: UInt64
    var action: RemoteAction
}
