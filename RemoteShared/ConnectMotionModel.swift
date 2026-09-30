import Foundation

// Pure rules behind the connect motion (PRODUCT D38) and the phone name the Mac shows (D39).
// Every visible stage follows a real coordinator state; nothing here advances on a timer.

/// The stage the Home art shows while connecting, from `MacStatus.progress`.
enum ConnectStage: Int, Comparable, CaseIterable {
    case idle, reaching, found, opening

    init(progress: Int) { self = Self(rawValue: min(max(progress, 0), 3)) ?? .idle }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The placeholder before the first frame: coarse once the connection is up, finer once the video
/// track is attached, crisp on the first decoded frame. It never steps on its own.
enum ResolutionLockStage: Int, Comparable {
    case waiting, connected, videoTrack, picture

    init(connected: Bool, videoTrack: Bool, pictureReady: Bool) {
        if pictureReady { self = .picture }
        else if videoTrack { self = .videoTrack }
        else if connected { self = .connected }
        else { self = .waiting }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Faint rings that leave the fingertip while a stage waits: "still trying", never "further along".
/// The first one is due 0.4 s after connecting starts, so a quick connect never shows any.
enum SearchRings {
    static let delay: TimeInterval = 0.4
    static let period: TimeInterval = 1.6
    /// Enough rings for about a minute; the list is dropped as soon as the wait ends.
    static let count = 40

    static func dates(from start: Date) -> [Date] {
        (0..<count).map { start.addingTimeInterval(delay + period * TimeInterval($0)) }
    }

    /// How many rings have started by `now`.
    static func started(from start: Date, now: Date) -> Int {
        let elapsed = now.timeIntervalSince(start) - delay + 1e-6
        return elapsed < 0 ? 0 : min(count, Int(elapsed / period) + 1)
    }
}

/// The measured parts of a live route, from the coordinator's diagnostics line, e.g.
/// "Direct · video/H264 · 60 fps · 14 ms network RTT · VideoToolbox". Unmeasured parts are nil.
struct SessionRouteCaption: Equatable {
    var relayed: Bool?
    var roundTripMs: Int?

    static func parse(_ diagnostics: String) -> Self {
        var caption = Self()
        for part in diagnostics.components(separatedBy: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part == "Direct" { caption.relayed = false }
            else if part == "Relay" { caption.relayed = true }
            else if part.hasSuffix(" ms network RTT"), let value = Double(part.dropLast(15)), value.isFinite, value >= 0 {
                caption.roundTripMs = Int(value.rounded())
            }
        }
        return caption
    }

    var isMeasured: Bool { relayed != nil && roundTripMs != nil }

    /// "Direct · 14 ms" once both are measured; nil until then, so nothing is guessed.
    var text: String? {
        guard let relayed, let roundTripMs else { return nil }
        return "\(relayed ? "Relayed" : "Direct") · \(roundTripMs < 1 ? "<1" : String(roundTripMs)) ms"
    }
}

/// What a phone tells its Mac about itself, inside the authenticated pairing exchange
/// (the sealed `acceptedAck`). Only a display name; it is never used to decide trust.
struct PhoneIdentity: Codable, Equatable {
    var name: String

    static let maximumLength = 40

    /// Printable text only: no control, format or bidi-override characters, one line, at most 40 characters.
    static func sanitized(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: " "
            default: Character(scalar)
            }
        }
        let collapsed = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = String(collapsed.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func body(for name: String?) -> Data? {
        guard let name, let clean = sanitized(name) else { return nil }
        return try? JSONEncoder().encode(PhoneIdentity(name: clean))
    }

    /// A small, well-formed body or nothing. A bad name never fails the session.
    static func decode(_ body: Data?) -> String? {
        guard let body, body.count <= 1_024, let identity = try? JSONDecoder().decode(Self.self, from: body) else { return nil }
        return sanitized(identity.name)
    }
}

/// The phone's name as the Mac shows it. Without Apple's user-assigned-device-name entitlement a
/// phone reports only its model ("iPhone"), which reads better as "Your iPhone"; older pairs and
/// phones that never sent a name get the same fallback.
enum PhoneDisplayName {
    static let fallback = "Your iPhone"

    static func display(_ stored: String?) -> String {
        guard let stored, let clean = PhoneIdentity.sanitized(stored) else { return fallback }
        switch clean.lowercased() {
        case "iphone": return "Your iPhone"
        case "ipad": return "Your iPad"
        case "ipod touch": return "Your iPod touch"
        default: return clean
        }
    }

    /// The display name mid-sentence: "Stop sharing with your iPhone?".
    static func inSentence(_ display: String) -> String {
        display.hasPrefix("Your ") ? "your " + display.dropFirst(5) : display
    }
}
