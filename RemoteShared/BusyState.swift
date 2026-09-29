import Foundation

/// The Mac's honest account of its own load, sent on `capture` status and shown by the phone as a
/// pill ("Mac is busy · 30 fps at 1440 px"). It is derived from the same signals the ladder uses,
/// so it cannot disagree with what the user sees: `busy` when the ladder sits at its floor, or
/// capture stays under 80 % of the target rate for 5 s, or encoder latency exceeds twice the frame
/// interval; `strained` while any rung below the top holds for more than 5 s; `ok` after 10 s of
/// headroom. Old phones ignore the field.
struct BusyState: Codable, Equatable {
    enum Level: String, Codable {
        case ok, strained, busy
    }

    var level: Level
    var fps: Int
    var longEdge: Int
    /// Short, user-facing cause: "encoding", "capture", "network", "phone", "thermal".
    var reason: String

    static let ok = BusyState(level: .ok, fps: 0, longEdge: 0, reason: "")

    var isVisible: Bool { level != .ok }

    func validate() throws {
        guard (0...240).contains(fps), (0...16_384).contains(longEdge), reason.utf8.count <= 24 else {
            throw RemoteError.invalidMessage
        }
    }
}
