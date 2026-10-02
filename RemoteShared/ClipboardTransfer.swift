import Foundation
import CryptoKit

/// Bounded text clipboard transfer over the ordered control channel.
/// Every transfer is bounded, chunked below the 16 KiB control-message limit, paced by
/// the channel's queued bytes so input stays responsive, and integrity-checked on arrival.
enum ClipboardLimits {
    static let maximumBytes = 256 * 1024
    /// Base64 plus worst-case JSON slash escaping stays under the 16 KiB packet limit.
    static let chunkBytes = 4 * 1024
    static let maximumChunks = maximumBytes / chunkBytes
    static let bufferedHighWater: UInt64 = 16 * 1024
    static let framesPerTick = 2
    static let pacingInterval: TimeInterval = 0.01
    static let reassemblyTimeout: TimeInterval = 5

    static func chunkCount(forBytes bytes: Int) -> Int {
        (bytes + chunkBytes - 1) / chunkBytes
    }

    static func chunkLength(index: Int, totalBytes: Int) -> Int {
        let start = index * chunkBytes
        return max(0, min(chunkBytes, totalBytes - start))
    }
}

enum ClipboardKind: String {
    case text, url
}

/// Result codes travel as strings so a newer peer's unknown code degrades to a generic failure
/// instead of failing JSON decoding for the whole control message.
enum ClipboardStatus: String {
    case stored, concealed, empty, unsupported, tooLarge, denied, notAllowed, busy, unchanged, invalid
}

struct ClipboardFrame: Codable, Equatable {
    var version = 1
    var op: String
    var transfer: String
    var kind: String? = nil
    var index: Int? = nil
    var count: Int? = nil
    var bytes: Int? = nil
    var digest: String? = nil
    var data: Data? = nil
    var status: String? = nil
    var afterCopy: Bool? = nil
    /// Capability-negotiated Mac→phone sync. Every chunk carries the same marker.
    var automatic: Bool? = nil

    static let operations: Set<String> = ["push", "pull", "data", "result"]

    var carriesPayload: Bool { op == "push" || op == "data" }

    func validate() throws {
        guard version == 1, Self.operations.contains(op), ClipboardTransferID.isValid(transfer),
              automatic == nil || (op == "data" && automatic == true) else {
            throw RemoteError.invalidMessage
        }
        switch op {
        case "push", "data":
            guard let kind, ClipboardKind(rawValue: kind) != nil,
                  let index, let count, let bytes, let digest, let data,
                  (1...ClipboardLimits.maximumBytes).contains(bytes),
                  count == ClipboardLimits.chunkCount(forBytes: bytes),
                  (0..<count).contains(index),
                  data.count == ClipboardLimits.chunkLength(index: index, totalBytes: bytes),
                  ClipboardDigest.isWellFormed(digest),
                  status == nil, afterCopy == nil
            else { throw RemoteError.invalidMessage }
        case "pull":
            guard kind == nil, index == nil, count == nil, bytes == nil, digest == nil, data == nil, status == nil
            else { throw RemoteError.invalidMessage }
        default:
            guard let status, Self.isWellFormedStatus(status),
                  kind == nil, index == nil, count == nil, bytes == nil, digest == nil, data == nil, afterCopy == nil
            else { throw RemoteError.invalidMessage }
        }
    }

    static func isWellFormedStatus(_ status: String) -> Bool {
        (1...24).contains(status.utf8.count) && status.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
    }

    static func pull(_ transfer: String, afterCopy: Bool = false) -> ClipboardFrame {
        ClipboardFrame(op: "pull", transfer: transfer, afterCopy: afterCopy ? true : nil)
    }

    static func result(_ transfer: String, _ status: ClipboardStatus) -> ClipboardFrame {
        ClipboardFrame(op: "result", transfer: transfer, status: status.rawValue)
    }
}

enum ClipboardTransferID {
    static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isValid(_ value: String) -> Bool {
        (8...32).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }
    }
}

enum ClipboardDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isWellFormed(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
    }
}

struct ClipboardPayload: Equatable {
    let kind: ClipboardKind
    let text: String

    init(text: String, kind: ClipboardKind? = nil) {
        self.text = text
        self.kind = kind ?? Self.classify(text)
    }

    var byteCount: Int { text.utf8.count }

    /// A lone web address also gets a URL representation so Safari and Messages paste it as a link.
    static func classify(_ text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return .text }
        return .url
    }
}

enum ClipboardRefusal: Error, Equatable {
    case empty, tooLarge
}

enum ClipboardChunker {
    static func frames(for payload: ClipboardPayload, operation: String, transfer: String) throws -> [ClipboardFrame] {
        precondition(operation == "push" || operation == "data")
        let bytes = Data(payload.text.utf8)
        guard !bytes.isEmpty else { throw ClipboardRefusal.empty }
        guard bytes.count <= ClipboardLimits.maximumBytes else { throw ClipboardRefusal.tooLarge }
        let digest = ClipboardDigest.hex(bytes)
        let count = ClipboardLimits.chunkCount(forBytes: bytes.count)
        return (0..<count).map { index in
            let start = index * ClipboardLimits.chunkBytes
            let end = min(bytes.count, start + ClipboardLimits.chunkBytes)
            return ClipboardFrame(op: operation, transfer: transfer, kind: payload.kind.rawValue,
                                  index: index, count: count, bytes: bytes.count, digest: digest,
                                  data: bytes.subdata(in: start..<end))
        }
    }
}

/// Accepts one in-order transfer at a time. Any gap, mismatch, digest failure or invalid UTF-8
/// discards the whole transfer; nothing partial is ever written to a pasteboard.
struct ClipboardAssembler {
    enum Outcome: Equatable {
        case progress
        case complete(transfer: String, payload: ClipboardPayload)
        case failed(transfer: String)
    }

    private var transfer: String?
    private var kind = ""
    private var automatic: Bool?
    private var count = 0
    private var bytes = 0
    private var digest = ""
    private var nextIndex = 0
    private var buffer = Data()
    private var lastActivity: TimeInterval = 0

    var activeTransfer: String? { transfer }

    mutating func accept(_ frame: ClipboardFrame, at now: TimeInterval) -> Outcome {
        guard frame.carriesPayload, (try? frame.validate()) != nil,
              let index = frame.index, let data = frame.data else {
            return fail(frame.transfer)
        }
        if index == 0 {
            reset()
            transfer = frame.transfer
            kind = frame.kind ?? ""
            automatic = frame.automatic
            count = frame.count ?? 0
            bytes = frame.bytes ?? 0
            digest = frame.digest ?? ""
            buffer.reserveCapacity(bytes)
        } else {
            guard frame.transfer == transfer, index == nextIndex, frame.kind == kind,
                  frame.count == count, frame.bytes == bytes, frame.digest == digest, frame.automatic == automatic
            else { return fail(frame.transfer) }
        }
        buffer.append(data)
        nextIndex += 1
        lastActivity = now
        guard nextIndex == count, let finished = transfer else { return .progress }
        defer { reset() }
        guard buffer.count == bytes, ClipboardDigest.hex(buffer) == digest,
              let text = String(data: buffer, encoding: .utf8),
              let payloadKind = ClipboardKind(rawValue: kind)
        else { return .failed(transfer: finished) }
        return .complete(transfer: finished, payload: ClipboardPayload(text: text, kind: payloadKind))
    }

    mutating func expire(at now: TimeInterval) -> String? {
        guard let transfer, now - lastActivity > ClipboardLimits.reassemblyTimeout else { return nil }
        reset()
        return transfer
    }

    mutating func reset() {
        transfer = nil
        kind = ""
        automatic = nil
        count = 0
        bytes = 0
        digest = ""
        nextIndex = 0
        buffer = Data()
        lastActivity = 0
    }

    private mutating func fail(_ frameTransfer: String) -> Outcome {
        let reported = transfer ?? frameTransfer
        reset()
        return .failed(transfer: reported)
    }
}

/// Releases queued frames only while the control channel has little data buffered, so a
/// clipboard transfer never starves pointer input or trips the channel's hard buffer limit.
struct ClipboardOutbox {
    private var frames: [ClipboardFrame] = []
    private var position = 0

    var isEmpty: Bool { position >= frames.count }
    var transfer: String? { isEmpty ? nil : frames[position].transfer }

    mutating func load(_ next: [ClipboardFrame]) {
        frames = next
        position = 0
    }

    mutating func cancel() {
        frames = []
        position = 0
    }

    mutating func release(bufferedAmount: UInt64?, limit: Int = ClipboardLimits.framesPerTick) -> [ClipboardFrame] {
        guard !isEmpty, limit > 0, let bufferedAmount, bufferedAmount < ClipboardLimits.bufferedHighWater else { return [] }
        let end = min(frames.count, position + limit)
        defer { position = end }
        return Array(frames[position..<end])
    }
}

/// nspasteboard.org markers that password managers and text expanders use to say
/// "do not record or sync this". PocketDesk never transfers such an item.
enum ClipboardPrivacy {
    enum Verdict: Equatable {
        case shareable, concealed, transient, autoGenerated
    }

    static let concealedMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "com.agilebits.onepassword"
    ]
    static let transientMarkers: Set<String> = [
        "org.nspasteboard.TransientType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type"
    ]
    static let autoGeneratedMarkers: Set<String> = ["org.nspasteboard.AutoGeneratedType"]
    static let sourceType = "org.nspasteboard.source"
    static let pocketDeskMarker = "com.roshan.pocketdesk.remote-clipboard"

    static func verdict<S: Sequence>(forTypes types: S) -> Verdict where S.Element == String {
        let present = Set(types)
        if !present.isDisjoint(with: concealedMarkers) { return .concealed }
        if !present.isDisjoint(with: transientMarkers) { return .transient }
        if !present.isDisjoint(with: autoGeneratedMarkers) { return .autoGenerated }
        return .shareable
    }
}
