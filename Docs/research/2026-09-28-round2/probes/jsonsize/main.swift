import Foundation
let session = UUID().uuidString
var move = RemoteAction(action: "move", x: 3.25, y: -1.5)
move.epoch = 7
let ni = NativeInteraction(version: 1, token: nil, hold: nil, clickCount: nil, phase: "changed", stream: nil, doubleClickInterval: nil)
var moveNative = move; moveNative.interaction = ni
var click = RemoteAction(action: "click", x: 0, y: 0); click.epoch = 7; click.interaction = NativeInteraction(version: 1, token: UUID().uuidString, hold: nil, clickCount: 1, phase: nil, stream: nil, doubleClickInterval: 0.5)
for (name, a) in [("move (legacy)", move), ("move (native interaction)", moveNative), ("click w/ token", click)] {
    let data = try JSONEncoder().encode(ControlPacket(session: session, sequence: 123456, action: a))
    print("\(name): \(data.count) bytes JSON")
    if name == "move (native interaction)" { print(String(data: data, encoding: .utf8)!) }
}
print("Binary equivalent (seq u32 + dx i16 + dy i16 + flags u8): 9 bytes")
