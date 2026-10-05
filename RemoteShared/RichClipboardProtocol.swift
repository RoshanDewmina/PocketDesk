import Foundation
import CryptoKit

extension ClipboardStatus: Error {}

enum RichClipboardLimits {
    static let encodedBytes = 8 * 1024 * 1024
    static let pixels = 16_000_000
    static let decodedBytes = 64 * 1024 * 1024
    static let dimension = 16_384
    static let timeout: UInt64 = 20_000_000_000
}
struct RichImageMetadata: Codable, Equatable {
    let bytes: Int
    let width: Int
    let height: Int
    let digest: String
    func validate() throws {
        guard (1...RichClipboardLimits.encodedBytes).contains(bytes), (1...RichClipboardLimits.dimension).contains(width),
              (1...RichClipboardLimits.dimension).contains(height), width <= RichClipboardLimits.pixels / height,
              ClipboardDigest.isWellFormed(digest) else { throw RemoteError.invalidMessage }
    }
}
struct RichClipboardMessage: Codable, Equatable {
    enum Operation: String, Codable { case pull, push, ready, control, committed, cancel, failed }
    let operation: Operation
    let transfer: String
    var revision: UInt64? = nil
    var image: RichImageMetadata? = nil
    var control: FileFrame? = nil
    var status: String? = nil
    func validate() throws {
        guard FileTransferID.isValid(transfer), revision.map({ $0 > 0 }) ?? true else { throw RemoteError.invalidMessage }
        if let image { try image.validate() }
        switch operation {
        case .pull, .cancel: guard revision == nil, image == nil, control == nil, status == nil else { throw RemoteError.invalidMessage }
        case .push: guard revision == nil, image != nil, control == nil, status == nil else { throw RemoteError.invalidMessage }
        case .ready: guard revision != nil, image != nil, control == nil, status == nil else { throw RemoteError.invalidMessage }
        case .control:
            guard revision != nil, image == nil, status == nil, let control, control.transfer == transfer,
                  ["offer", "accept", "complete", "result", "cancel"].contains(control.op) else { throw RemoteError.invalidMessage }
            try control.validate()
        case .committed: guard revision != nil, image == nil, control == nil, status == nil else { throw RemoteError.invalidMessage }
        case .failed: guard revision == nil, image == nil, control == nil, status.flatMap(ClipboardStatus.init(rawValue:)) != nil else { throw RemoteError.invalidMessage }
        }
    }
    static func decode(_ frame: WorkspaceFrame) throws -> Self {
        try frame.validate()
        guard frame.kind == .richClipboard,
              let object = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
              Set(object.keys).isSubset(of: ["operation", "transfer", "revision", "image", "control", "status"]) else { throw RemoteError.invalidMessage }
        let result = try frame.decode(Self.self); try result.validate(); return result
    }
}

/// One sender clock for automatic text and explicit rich transactions. Session retirement never
/// rewinds it; the receiving session's admission separately rejects old envelopes.
final class ClipboardSourceClock {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
struct ClipboardRevisionBarrier {
    private(set) var committed: UInt64 = 0
    private var assembling: UInt64?
    mutating func commit(_ revision: UInt64) { committed = max(committed, revision); assembling = nil }
    mutating func admit(_ revision: UInt64) -> Bool {
        guard revision > committed, assembling.map({ revision >= $0 }) ?? true else { return false }
        assembling = revision; return true
    }
    mutating func retireAssembly() { assembling = nil }
}

/// Separate magic prevents clipboard chunks from ever reaching user-visible file admission.
enum RichClipboardBulk {
    static let magic = Data([0x46, 0x52, 0x43, 0x31]) // FRC1
    static func unwrap(_ data: Data) -> Data? {
        guard data.count > magic.count, data.starts(with: magic) else { return nil }
        return data.dropFirst(magic.count)
    }
    static func isRich(_ data: Data) -> Bool { data.starts(with: magic) }
}
final class RichClipboardLink: FileChannelLink {
    private let underlying: FileChannelLink
    init(_ underlying: FileChannelLink) { self.underlying = underlying }
    func sendFile(_ data: Data) -> Bool { underlying.sendFile(RichClipboardBulk.magic + data) }
    var fileBufferedAmount: UInt64? { underlying.fileBufferedAmount }
    func permitsFileSend(bytes: Int, at now: TimeInterval) -> Bool { underlying.permitsFileSend(bytes: bytes + RichClipboardBulk.magic.count, at: now) }
    func fileMessageBytes(at now: TimeInterval) -> Int { max(FileTransferLimits.chunkHeaderBytes + 1, underlying.fileMessageBytes(at: now) - RichClipboardBulk.magic.count) }
    func fileQueueBytes(at now: TimeInterval) -> UInt64 { underlying.fileQueueBytes(at: now) }
}
