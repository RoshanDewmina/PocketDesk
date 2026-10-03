import Foundation

struct RemoteAction: Codable {
    var action: String
    /// Negotiated audio.listen.1: explicit phone playback consent, only on heartbeats.
    var macAudioRequested: Bool? = nil
    /// Only after network.lowData.1, on regular phone heartbeats. No route/input authority.
    var lowDataMode: Bool? = nil
    /// Host-applied control/file/audio suspension while authorized video continues.
    var liveViewOnly: Bool? = nil
    var liveViewOnlyRequestID: String? = nil
    var x: Double = 0
    var y: Double = 0
    var text: String = ""
    var key: String = ""
    var modifiers: [String] = []
    var epoch: UInt64 = 1
    var interaction: NativeInteraction? = nil
    /// Available only after input.pencil.1; existing checkpoint/barrier authority still applies.
    var pencil: PencilFrame? = nil
    var pointerLocatorSupported: Bool? = nil
    var pointerProbe: String? = nil
    var pointerLocation: PointerLocation? = nil
    var pointerSync: PointerSync? = nil
    var streamQuality: StreamQuality? = nil
    /// app.shortcuts.1: only a debounced identity update on a host heartbeat.
    var frontmostApp: FrontmostApp? = nil
    var textFocusProbe: String? = nil
    var textFocusEditable: Bool? = nil
    /// With a focus reply, after `SessionFeature.secureFocus`: the focused field takes a password.
    var textFocusSecure: Bool? = nil
    /// The phone wants the focused field's rect with this probe's reply (`SessionFeature.focusGeometry`).
    var textFocusGeometry: Bool? = nil
    var textFocusRect: FocusGeometry? = nil
    // Session extensions (clipboard, background pause). Validated in SessionContinuity.swift.
    var clipboard: ClipboardFrame? = nil
    /// File transfer control (`file` action, after `SessionFeature.fileTransfer`); bytes use the `file` channel.
    var file: FileFrame? = nil
    var features: [String]? = nil
    var hostState: String? = nil
    /// Sender-side stream stages for the phone's optional statistics overlay. Older phones ignore it.
    var hostStream: HostStreamSummary? = nil
    // Privacy curtain request ("curtain" action) or state (on "capture"); host lifecycle event.
    var curtain: String? = nil
    var hostEvent: String? = nil
    /// Gated Away mode state, only on a capture status.
    var away: String? = nil
    /// Display selection (`displays`, `display`); validated in DisplaySelection.swift.
    var displays: [DisplayDescriptor]? = nil
    var display: UInt32? = nil
    /// A "needs you" alert from an agent on the Mac, sent once on a `capture` status. Older phones ignore it.
    var agentAlert: AgentAlertFrame? = nil
    /// Clock-sync probe on a heartbeat: the phone sends it, the host echoes it (see `ClockProbe`).
    var clock: ClockProbe? = nil
    var videoFeedback: VideoFeedback? = nil
    /// The client's screen in device pixels, on heartbeats, so the host caps the capture to it.
    var screenPixels: PixelSize? = nil
    /// G4: the desktop region the phone shows, on heartbeats (only after `SessionFeature.viewportCapture`).
    var viewport: ViewportRegion? = nil
    /// G12: bounded receiver load from a phone that knows the host supports the ladder.
    var phoneLoad: PhoneLoadFeedback? = nil
    /// G4: the region the stream covers, on `capture` status.
    var captureRegion: CaptureRegion? = nil
    /// G12: the active ladder rung, on `capture` status.
    var ladder: LadderState? = nil
    /// The Mac's load state for the phone's pill, on `capture` status.
    var busy: BusyState? = nil
    /// Battery, temperature, Low Power Mode and whole-Mac load, on `capture` status (`SessionFeature.macVitals`).
    var macVitals: MacVitals? = nil
    /// Couch mode: the phone's `mode` request, or the Mac's mode on `capture` status. Validated in CouchProtocol.swift.
    var mode: String? = nil
    /// One-shot reason the Mac did not switch, on `capture` status.
    var modeReason: String? = nil
    /// Owner-selected scope status; never carries a target handle. Older peers ignore it.
    var captureScope: CaptureScopeFrame? = nil
    var looksLikeWidth: Double? = nil
    var scaleError: String? = nil
    /// Correlates Big Text requests and replies; absent for older peers.
    var scaleRequestID: String? = nil

    var wakeRequest: WakeRequest? = nil
    var wakeReply: WakeReply? = nil

    var inputRequestID: String? = nil
    var inputAppliedReceipt: InputAppliedReceipt? = nil

    func validate() throws {
        guard lowDataMode == nil || isRegularPhoneHeartbeat else { throw RemoteError.invalidMessage }
        guard macAudioRequested == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
try pencil?.validate(action: action, interaction: interaction)
        try frontmostApp?.validate()
        guard frontmostApp == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        if try validateWakeExtension() { return }
        // Before the extension early returns, so no other action can carry an unchecked summary.
      guard liveViewOnly == nil || action == "viewOnly" || action == "capture" else { throw RemoteError.invalidMessage }
        if let liveViewOnlyRequestID {
            guard ["viewOnly", "capture"].contains(action), liveViewOnly != nil, InputCausalEnvelope.validID(liveViewOnlyRequestID) else { throw RemoteError.invalidMessage }
        }
        guard action != "viewOnly" || liveViewOnlyRequestID != nil else { throw RemoteError.invalidMessage }
        try captureScope?.validate()
        guard captureScope == nil || action == "capture" else { throw RemoteError.invalidMessage }
        if let inputRequestID {
            guard InputCausalEnvelope.validID(inputRequestID), InputAppliedReceipt.actions.contains(action) else { throw RemoteError.invalidMessage }
        }
        if let inputAppliedReceipt {
            guard action == "inputApplied", inputRequestID == nil, interaction == nil, x == 0, y == 0, text.isEmpty, key.isEmpty,
                  modifiers.isEmpty, features == nil, liveViewOnly == nil, captureScope == nil else { throw RemoteError.invalidMessage }
            try inputAppliedReceipt.validate()
        }
        guard action != "inputApplied" || inputAppliedReceipt != nil else { throw RemoteError.invalidMessage }
        try hostStream?.validate()
        guard hostStream == nil || action == "capture" else { throw RemoteError.invalidMessage }
        try videoFeedback?.validate()
        guard videoFeedback == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        try clock?.validate()
        guard clock == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        try screenPixels?.validate()
        guard screenPixels == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        try viewport?.validate()
        guard viewport == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        try phoneLoad?.validate()
        guard phoneLoad == nil || action == "heartbeat" else { throw RemoteError.invalidMessage }
        try captureRegion?.validate()
        try ladder?.validate()
        try busy?.validate()
        try macVitals?.validate()
        guard (captureRegion == nil && ladder == nil && busy == nil && macVitals == nil) || action == "capture" else {
            throw RemoteError.invalidMessage
        }
        guard textFocusSecure == nil || (action == "heartbeat" && textFocusProbe != nil && textFocusEditable != nil)
        else { throw RemoteError.invalidMessage }
        guard file == nil || action == "file" else { throw RemoteError.invalidMessage }
        try validateFocusGeometry()
        if looksLikeWidth != nil, action != "displayScale" { throw RemoteError.invalidMessage }
        if let scaleError, action != "displays" || scaleError.isEmpty || scaleError.utf8.count > 64 { throw RemoteError.invalidMessage }
        if let scaleRequestID {
            guard ["displayScale", "displays"].contains(action),
                  scaleRequestID.utf8.count == 32,
                  scaleRequestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw RemoteError.invalidMessage }
        }
        // Also before the early returns, so no other action can carry a display list.
        if try validateSessionMode() { return }
        if try validateDisplaySelection() { return }
        if try validateSessionExtension() { return }
        if try validatePointerSync() { return }
        try interaction?.validate()
        try pointerLocation?.validate()
        if let textFocusProbe {
            guard ["click", "double", "heartbeat", "text", "key"].contains(action),
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
        guard ["move", "moveTo", "click", "right", "middle", "double", "dragDown", "dragUp", "scroll", "text", "key", "release", "heartbeat", "viewing", "geometry", "capture", "textResult", "holdRenew", "auxClick", "inputApplied"].contains(action),
              x.isFinite, y.isFinite, abs(x) <= 20000, abs(y) <= 20000,
              text.utf8.count <= 4096, text.utf16.count <= 1024, key.utf8.count <= 32, modifiers.count <= 4,
              modifiers.allSatisfy({ ["command", "shift", "option", "control"].contains($0) }) else { throw RemoteError.invalidMessage }
        // An absolute position is display-local, so it can never be negative. Phones send these
        // new actions only after the host advertises `SessionFeature.absolutePointer`/`middleButton`.
        guard action != "moveTo" || (x >= 0 && y >= 0) else { throw RemoteError.invalidMessage }
        guard action != "middle" || interaction == nil || interaction?.clickCount == 1 else { throw RemoteError.invalidMessage }
        guard action != "auxClick" || (AuxiliaryMouseButton(rawValue: key) != nil &&
            (interaction == nil || interaction?.clickCount == 1)) else { throw RemoteError.invalidMessage }
    }
}

extension RemoteAction {
    /// A heartbeat that states the phone's current capabilities (pointer envelope, viewport, screen
    /// pixels). The phone also sends heartbeats that carry only a video-feedback packet, a pointer
    /// probe or a focus probe; those say nothing about capability, and reading their missing fields
    /// as withdrawals switched the captured cursor back on about every 2.25 s (1 Oct).
    var isRegularPhoneHeartbeat: Bool {
        action == "heartbeat" && videoFeedback == nil && pointerProbe == nil && textFocusProbe == nil
    }
}

struct ControlPacket: Codable {
    var version = 1
    var session: String
    var sequence: UInt64
    var action: RemoteAction
    var input: InputCausalEnvelope? = nil
    /// Optional performance metadata; older peers ignore it and invalid values are not evidence.
    var inputTiming: InputSendTiming? = nil
}

extension ControlPacket {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        session = try values.decode(String.self, forKey: .session)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        action = try values.decode(RemoteAction.self, forKey: .action)
        input = try values.decodeIfPresent(InputCausalEnvelope.self, forKey: .input)
        // Malformed diagnostic metadata must not change otherwise valid input admission.
        inputTiming = try? values.decodeIfPresent(InputSendTiming.self, forKey: .inputTiming)
    }
}

/// Perf pack item 1a (Moonlight's move accumulator): while the control channel is backed up, pointer
/// moves merge into one pending message instead of queueing behind the stall, where every later click
/// waits and 64 KB of backlog ends the session. A healthy channel passes every message straight through.
///
/// Relative deltas sum and absolute placements keep the newest point; the merged message carries the
/// newest `pointerSync` ordinal, which the host acknowledges cumulatively. Only moves whose other fields
/// are identical merge, and any other message sends the pending move ahead of itself.
struct PointerMoveCoalescer {
    static let backlogBytes: UInt64 = 4 * 1024
    static let flushInterval: TimeInterval = 1.0 / 30
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private(set) var pending: RemoteAction?
    private var pendingSince: TimeInterval = 0
    private var pendingEnvelope: Data?
    private var merged = 0

    /// The messages to send now, in order; empty when the move is held.
    mutating func offer(_ action: RemoteAction, backlogged: Bool, now: TimeInterval) -> [RemoteAction] {
        guard Self.isMove(action) else {
            defer { pending = nil; pendingEnvelope = nil }
            return (pending.map { [$0] } ?? []) + [action]
        }
        var out: [RemoteAction] = []
        if var held = pending {
            if let combined = combine(held, action) {
                held = combined
                merged += 1
                pending = held
                guard !backlogged else { return [] }
                pending = nil; pendingEnvelope = nil
                return [held]
            }
            out.append(held)
            pending = nil; pendingEnvelope = nil
        }
        guard backlogged else { return out + [action] }
        pending = action
        pendingSince = now
        pendingEnvelope = Self.envelope(action)
        return out
    }

    /// The held move once the backlog clears or it has waited `flushInterval`.
    mutating func flush(backlogged: Bool, now: TimeInterval) -> RemoteAction? {
        guard let held = pending, !backlogged || now - pendingSince >= Self.flushInterval else { return nil }
        pending = nil; pendingEnvelope = nil
        return held
    }

    mutating func discard() {
        pending = nil; pendingEnvelope = nil
    }

    /// Moves merged into a pending one since the last call.
    mutating func takeMerged() -> Int {
        defer { merged = 0 }
        return merged
    }

    private static func isMove(_ action: RemoteAction) -> Bool { action.action == "move" || action.action == "moveTo" }

    private func combine(_ held: RemoteAction, _ next: RemoteAction) -> RemoteAction? {
        guard held.action == next.action, (held.pointerSync == nil) == (next.pointerSync == nil),
              let envelope = pendingEnvelope, envelope == Self.envelope(next) else { return nil }
        var result = next
        if next.action == "move" {
            result.x = held.x + next.x
            result.y = held.y + next.y
            guard abs(result.x) <= 20_000, abs(result.y) <= 20_000 else { return nil }
        }
        return result
    }

    /// Only unsent compatible motion may merge. Do not erase reversals (clamping matters)
    /// or Pencil samples (pressure/path matters), and never cross an authority boundary.
    static func coalescedUnsentMove(_ held: RemoteAction, _ next: RemoteAction) -> RemoteAction? {
        guard isMove(held), held.action == next.action, held.pencil == nil, next.pencil == nil,
              (held.pointerSync == nil) == (next.pointerSync == nil),
              let authority = envelope(held), authority == envelope(next) else { return nil }
        var result = next
        if next.action == "move" {
            guard held.x * next.x >= 0, held.y * next.y >= 0 else { return nil }
            result.x += held.x; result.y += held.y
            guard abs(result.x) <= 20_000, abs(result.y) <= 20_000 else { return nil }
        }
        return result
    }

    /// Everything but the position and the ordinal, which merging is allowed to change.
    private static func envelope(_ action: RemoteAction) -> Data? {
        var copy = action
        copy.x = 0
        copy.y = 0
        copy.pointerSync = nil
        return try? encoder.encode(copy)
    }
}

extension RemoteAction {
    func validateWakeExtension() throws -> Bool {
        guard wakeRequest != nil || wakeReply != nil || action == "wakeRequest" || action == "wakeReply" else { return false }
        guard (action == "wakeRequest" && wakeRequest != nil && wakeReply == nil) ||
              (action == "wakeReply" && wakeReply != nil && wakeRequest == nil),
              x == 0, y == 0, text.isEmpty, key.isEmpty, modifiers.isEmpty, epoch > 0 else { throw RemoteError.invalidMessage }
        // Refuse every other optional extension, including future fields, before extension returns.
        let allowed: Set<String> = ["action", "epoch", "x", "y", "text", "key", "modifiers", "wakeRequest", "wakeReply"]
        guard let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
              Set(encoded.keys).isSubset(of: allowed) else { throw RemoteError.invalidMessage }
        try wakeRequest?.validate(); try wakeReply?.validate()
        return true
    }
}
