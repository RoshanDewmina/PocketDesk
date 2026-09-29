import Foundation

/// The Mac's honest account of its own load, sent on `capture` status and shown by the phone as a
/// pill ("Mac is busy · 30 fps at 1440 px"). It is derived from the same signals the ladder uses,
/// so it cannot disagree with current pressure: `busy` while a trigger keeps firing at the ladder
/// floor, capture stays under 80 % of the rung's rate and late for 5 s, or encoder latency exceeds
/// twice the frame interval for 5 s. It clears after 10 continuous seconds without a current
/// trigger, avoiding repeated announcements during intermittent pressure. `strained` lasts 8 s
/// after a downward step, then becomes `ok` even below the top (the `ladder` field still carries the
/// rung). Old phones ignore the field.
struct BusyState: Codable, Equatable {
    enum Level: String, Codable {
        case ok, strained, busy
    }

    var level: Level
    var fps: Int
    var longEdge: Int
    /// Short, user-facing cause (`LadderReason`): "encoding", "capture", "network", "phone", "thermal", "power", "phonePower".
    var reason: String

    static let ok = BusyState(level: .ok, fps: 0, longEdge: 0, reason: "")

    var isVisible: Bool { level != .ok }

    func validate() throws {
        guard (0...240).contains(fps), (0...16_384).contains(longEdge), reason.utf8.count <= 24 else {
            throw RemoteError.invalidMessage
        }
    }
}
