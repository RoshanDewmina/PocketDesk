import Foundation

struct RemoteAction: Codable {
    var action: String
    var x: Double = 0
    var y: Double = 0
    var text: String = ""
    var key: String = ""
    var modifiers: [String] = []
    var epoch: UInt64 = 1

    func validate() throws {
        guard ["move", "click", "right", "double", "dragDown", "dragUp", "scroll", "text", "key", "release", "heartbeat", "viewing", "geometry", "capture", "textResult"].contains(action),
              x.isFinite, y.isFinite, abs(x) <= 20000, abs(y) <= 20000,
              text.utf8.count <= 4096, text.utf16.count <= 1024, key.utf8.count <= 32, modifiers.count <= 4,
              modifiers.allSatisfy({ ["command", "shift", "option", "control"].contains($0) }) else { throw RemoteError.invalidMessage }
    }
}

struct ControlPacket: Codable {
    var version = 1
    var session: String
    var sequence: UInt64
    var action: RemoteAction
}
