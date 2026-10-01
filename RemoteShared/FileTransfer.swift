import Foundation
import CryptoKit

/// One file per transfer between the paired phone and Mac. Control frames travel on the ordered
/// `control` channel as `RemoteAction(action: "file")`; file bytes travel on a separate ordered,
/// reliable `file` data channel. SCTP congestion is shared; bulk admission bounds its contention.
enum FileTransferLimits {
    static let maximumBytes: Int64 = 1 << 30
    static let chunkHeaderBytes = 28
    /// Every file.1 receiver accepts 64 KiB. The link's budget picks each message's size: 64 KiB only on the
    /// calm-LAN fast lane with a peer whose SDP max-message-size allows it, otherwise 16 KiB.
    static let maximumMessageBytes = 64 * 1024
    static let maximumOutgoingMessageBytes = maximumMessageBytes
    static let directChunkPayload = maximumOutgoingMessageBytes - chunkHeaderBytes
    /// Smaller relay chunks bound how long one message holds the shared association ahead of input.
    static let relayChunkPayload = 16 * 1024 - chunkHeaderBytes
    /// An upper bound only: the budget's own queue bound (2 MiB fast lane, else 32 KiB) governs admission.
    static let directHighWater: UInt64 = BulkAdmissionPolicy.fastLaneBufferedBytes
    static let relayHighWater: UInt64 = 32 * 1024
    /// Backstop only, kept above the media governor's relay ceiling; the governor adapts/pauses actual sends.
    static let relayBytesPerSecond: Double = 250_000
    static let progressInterval: TimeInterval = 0.25
    /// Long enough for someone at the Mac to answer a first-use Downloads consent prompt.
    static let acceptTimeout: TimeInterval = 60
    static let stallTimeout: TimeInterval = 30
    static let pickTimeout: TimeInterval = 180
    static let maximumNameBytes = 255
    static let maximumTypeBytes = 128
    static let maximumURLBytes = 2048
    /// Space kept free on the receiving volume beyond the file itself.
    static let freeSpaceMargin: Int64 = 50 * 1024 * 1024

    static func chunkPayload(relayed: Bool) -> Int { relayed ? relayChunkPayload : directChunkPayload }
    static func highWater(relayed: Bool) -> UInt64 { relayed ? relayHighWater : directHighWater }

    static func hasRoom(for bytes: Int64, available: Int64?) -> Bool {
        guard let available else { return true }
        return available >= bytes + freeSpaceMargin
    }
}

/// Codes travel as strings so a newer peer's unknown code degrades to a generic failure.
enum FileTransferStatus: String {
    case stored, cancelled, tooLarge, notAllowed, disabled, busy, diskFull, denied, invalid, timedOut
    case empty, unsupported, unreadable
    /// Links: the Mac is offering to open it, or could only copy it.
    case offered, copied
    /// Local only: the session or the file channel went away mid-transfer.
    case connectionLost
    /// Local only: the phone left the foreground.
    case backgrounded
}

enum FileTransferID {
    static func make() -> String { ClipboardTransferID.make() }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func bytes(_ value: String) -> [UInt8]? {
        guard isValid(value) else { return nil }
        let digits = Array(value.utf8)
        return stride(from: 0, to: 32, by: 2).map { index in
            (nibble(digits[index]) << 4) | nibble(digits[index + 1])
        }
    }

    static func string(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func nibble(_ digit: UInt8) -> UInt8 { digit <= 57 ? digit - 48 : digit - 87 }
}

struct FileFrame: Codable, Equatable {
    var version = 1
    var op: String
    var transfer: String
    var name: String? = nil
    var bytes: Int64? = nil
    var type: String? = nil
    var digest: String? = nil
    var status: String? = nil
    var url: String? = nil
    /// Why a Mac refused (`result` only, newer hosts): lets the phone say why instead of a generic refusal.
    var reason: String? = nil

    static let operations: Set<String> = ["offer", "accept", "progress", "complete", "result", "cancel", "request", "link"]

    func validate() throws {
        guard version == 1, Self.operations.contains(op), FileTransferID.isValid(transfer) else {
            throw RemoteError.invalidMessage
        }
        let valid: Bool
        switch op {
        case "offer":
            valid = name.map(Self.isWellFormedName) == true
                && bytes.map { (1...FileTransferLimits.maximumBytes).contains($0) } == true
                && (type == nil || type.map(Self.isWellFormedType) == true)
                && digest == nil && status == nil && url == nil
        case "progress":
            valid = bytes.map { (0...FileTransferLimits.maximumBytes).contains($0) } == true
                && name == nil && type == nil && digest == nil && status == nil && url == nil
        case "complete":
            valid = digest.map(ClipboardDigest.isWellFormed) == true
                && name == nil && bytes == nil && type == nil && status == nil && url == nil
        case "result":
            valid = status.map(ClipboardFrame.isWellFormedStatus) == true
                && name == nil && bytes == nil && type == nil && digest == nil && url == nil
                && (reason == nil || reason.map(Self.isWellFormedReason) == true)
        case "link":
            valid = url.map(Self.isWellFormedLink) == true
                && name == nil && bytes == nil && type == nil && digest == nil && status == nil
        default:
            valid = name == nil && bytes == nil && type == nil && digest == nil && status == nil && url == nil
        }
        guard op == "result" || reason == nil else { throw RemoteError.invalidMessage }
        guard valid else { throw RemoteError.invalidMessage }
    }

    static func isWellFormedReason(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
    }

    static func isWellFormedName(_ value: String) -> Bool {
        (1...FileTransferLimits.maximumNameBytes).contains(value.utf8.count) && !value.utf8.contains(0)
    }

    static func isWellFormedType(_ value: String) -> Bool {
        (1...FileTransferLimits.maximumTypeBytes).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
        }
    }

    static func isWellFormedLink(_ value: String) -> Bool {
        guard (1...FileTransferLimits.maximumURLBytes).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return false }
        return true
    }

    static func offer(_ transfer: String, name: String, bytes: Int64, type: String?) -> FileFrame {
        FileFrame(op: "offer", transfer: transfer, name: name, bytes: bytes, type: type)
    }
    static func accept(_ transfer: String) -> FileFrame { FileFrame(op: "accept", transfer: transfer) }
    static func progress(_ transfer: String, bytes: Int64) -> FileFrame { FileFrame(op: "progress", transfer: transfer, bytes: bytes) }
    static func complete(_ transfer: String, digest: String) -> FileFrame { FileFrame(op: "complete", transfer: transfer, digest: digest) }
    static func result(_ transfer: String, _ status: FileTransferStatus, reason: String? = nil) -> FileFrame {
        FileFrame(op: "result", transfer: transfer, status: status.rawValue, reason: reason)
    }
    static func cancel(_ transfer: String) -> FileFrame { FileFrame(op: "cancel", transfer: transfer) }
    static func request(_ transfer: String) -> FileFrame { FileFrame(op: "request", transfer: transfer) }
    static func link(_ transfer: String, url: String) -> FileFrame { FileFrame(op: "link", transfer: transfer, url: url) }
}

/// Binary message on the `file` channel: `FSF1 | transfer id (16 bytes) | offset (UInt64 BE) | payload`.
/// No JSON or base64, so bulk bytes pay no encoding overhead.
enum FileChunk {
    static let magic: [UInt8] = Array("FSF1".utf8)

    struct Decoded: Equatable {
        let transfer: String
        let offset: Int64
        let payload: Data
    }

    static func encode(transfer: String, offset: Int64, payload: Data) -> Data? {
        guard let id = FileTransferID.bytes(transfer), offset >= 0, !payload.isEmpty,
              payload.count <= FileTransferLimits.maximumOutgoingMessageBytes - FileTransferLimits.chunkHeaderBytes
        else { return nil }
        var data = Data(capacity: FileTransferLimits.chunkHeaderBytes + payload.count)
        data.append(contentsOf: magic)
        data.append(contentsOf: id)
        withUnsafeBytes(of: UInt64(offset).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> Decoded? {
        let header = FileTransferLimits.chunkHeaderBytes
        guard data.count > header, data.count <= FileTransferLimits.maximumMessageBytes else { return nil }
        let bytes = [UInt8](data.prefix(header))
        guard Array(bytes[0..<4]) == magic else { return nil }
        let offset = bytes[20..<28].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard offset <= UInt64(FileTransferLimits.maximumBytes) else { return nil }
        return Decoded(transfer: FileTransferID.string(bytes[4..<20]), offset: Int64(offset),
                       payload: data.subdata(in: data.startIndex + header..<data.endIndex))
    }
}

/// Makes a received name safe to create in a folder: no path, no control, format or bidi-override
/// characters (so "photo\u{202E}gpj.exe" cannot pose as a picture), no leading dots, bounded length.
enum FileNameSanitizer {
    static let fallback = "File"
    /// Room for " 999" before the extension when de-duplicating.
    private static let suffixReserve = 4
    private static let maximumExtensionBytes = 16

    static func sanitize(_ raw: String) -> String {
        let lastComponent = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in lastComponent.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                continue
            default:
                scalars.append(scalar == ":" ? "-" : scalar)
            }
        }
        var name = String(scalars)
        while let first = name.first, first == "." || first.isWhitespace { name.removeFirst() }
        while let last = name.last, last.isWhitespace { name.removeLast() }
        guard !name.isEmpty else { return fallback }
        let (stem, ext) = split(name)
        let budget = FileTransferLimits.maximumNameBytes - suffixReserve - (ext.map { $0.utf8.count + 1 } ?? 0)
        let trimmedStem = truncate(stem.isEmpty ? fallback : stem, toUTF8Bytes: budget)
        return ext.map { trimmedStem + "." + $0 } ?? trimmedStem
    }

    /// The name to try on the n-th attempt: "report.pdf", then "report 2.pdf", "report 3.pdf"…
    static func candidate(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let (stem, ext) = split(name)
        let numbered = (stem.isEmpty ? fallback : stem) + " \(attempt)"
        return ext.map { numbered + "." + $0 } ?? numbered
    }

    private static func split(_ name: String) -> (stem: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty, ext.utf8.count <= maximumExtensionBytes,
              ext.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return (name, nil) }
        return (String(name[..<dot]), ext)
    }

    private static func truncate(_ value: String, toUTF8Bytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = ""
        for character in value {
            guard result.utf8.count + String(character).utf8.count <= limit else { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
    }
}

/// Receiver-side bookkeeping for one transfer's bytes. Chunks must arrive contiguously (the channel
/// is ordered and reliable), never past the offered size, and the whole-file digest gates success.
struct FileAssembler {
    enum Outcome: Equatable {
        case progress(Int64)
        case awaitingDigest
        case verified
        case failed
    }

    let transfer: String
    let expectedBytes: Int64
    private(set) var receivedBytes: Int64 = 0
    private(set) var digest: String?
    private var hasher = SHA256()
    private var finished = false

    init(transfer: String, expectedBytes: Int64) {
        self.transfer = transfer
        self.expectedBytes = expectedBytes
    }

    var isComplete: Bool { receivedBytes == expectedBytes }

    mutating func accept(_ chunk: FileChunk.Decoded) -> Outcome {
        guard !finished, chunk.transfer == transfer, chunk.offset == receivedBytes,
              Int64(chunk.payload.count) <= expectedBytes - receivedBytes else {
            finished = true
            return .failed
        }
        hasher.update(data: chunk.payload)
        receivedBytes += Int64(chunk.payload.count)
        return isComplete ? settle() : .progress(receivedBytes)
    }

    mutating func receiveDigest(_ value: String) -> Outcome {
        guard !finished, digest == nil, ClipboardDigest.isWellFormed(value) else {
            finished = true
            return .failed
        }
        digest = value
        return isComplete ? settle() : .progress(receivedBytes)
    }

    private mutating func settle() -> Outcome {
        guard let digest else { return .awaitingDigest }
        finished = true
        return FileDigest.hex(hasher.finalize()) == digest ? .verified : .failed
    }
}

enum FileDigest {
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Token bucket for relayed transfers. Direct routes are unpaced; SCTP's own congestion control applies.
struct FilePacer {
    let bytesPerSecond: Double?
    let burst: Double
    private var tokens: Double
    private var last: TimeInterval?

    init(bytesPerSecond: Double?, burst: Double = 256 * 1024) {
        self.bytesPerSecond = bytesPerSecond
        self.burst = burst
        tokens = burst
    }

    mutating func allows(_ bytes: Int, at now: TimeInterval) -> Bool {
        guard let bytesPerSecond else { return true }
        if let last { tokens = min(burst, tokens + max(0, now - last) * bytesPerSecond) }
        last = now
        guard tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        return true
    }

    mutating func refund(_ bytes: Int) {
        guard bytesPerSecond != nil else { return }
        tokens = min(burst, tokens + Double(bytes))
    }
}

/// Throttles progress reports to about four a second, always letting the final count through.
struct FileProgressThrottle {
    private var lastSent: TimeInterval?

    mutating func shouldReport(at now: TimeInterval, final: Bool) -> Bool {
        if final || lastSent == nil || now - (lastSent ?? 0) >= FileTransferLimits.progressInterval {
            lastSent = now
            return true
        }
        return false
    }
}
