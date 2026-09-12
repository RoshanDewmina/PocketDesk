import Foundation
import Network
import Security

/// Version 1: TLS 1.2 PSK over TCP. Session keys are random 256-bit secrets, never passwords.
enum StreamWire {
    static let version = 1
    static let maximumPacket = 8 * 1024 * 1024
    static func parameters(key: Data) -> NWParameters {
        precondition(key.count == 32)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let identity = Data("PocketDesktop-v1".utf8)
        key.withUnsafeBytes { secret in
            identity.withUnsafeBytes { name in
                sec_protocol_options_add_pre_shared_key(options,
                    DispatchData(bytes: secret) as __DispatchData,
                    DispatchData(bytes: name) as __DispatchData)
            }
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_add_tls_ciphersuite(options, TLS_PSK_WITH_AES_128_GCM_SHA256)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
    static func packet(_ kind: UInt8, _ payload: Data = Data()) -> Data {
        var result = Data()
        result.appendInteger(UInt32(payload.count + 1))
        result.append(kind)
        result.append(payload)
        return result
    }
    static func json<T: Encodable>(_ kind: UInt8, _ value: T) -> Data {
        packet(kind, (try? JSONEncoder().encode(value)) ?? Data())
    }
    static func parseKey(_ string: String) -> Data? {
        guard string.count == 64, string.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        var bytes = [UInt8](); var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        return Data(bytes)
    }
    static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WireError.invalid }
        return Data(bytes)
    }
}

enum WireError: Error { case invalid, oversized, closed }

struct StreamInfo: Codable {
    var version = StreamWire.version
    var width: Int
    var height: Int
    var logicalWidth: Double
    var logicalHeight: Double
    var name: String
    var controlAllowed: Bool
}

struct RemoteInput: Codable {
    var action: String
    var x: Double = 0
    var y: Double = 0
    var text: String = ""
    var key: String = ""
    var modifiers: [String] = []
}

struct VideoFrame {
    var id: UInt64
    var captureTime: Double
    var encodeMS: Double
    var sps: Data
    var pps: Data
    var bytes: Data
    var payload: Data {
        var data = Data()
        data.appendInteger(id)
        data.appendInteger(captureTime.bitPattern)
        data.appendInteger(encodeMS.bitPattern)
        data.appendInteger(UInt16(sps.count)); data.append(sps)
        data.appendInteger(UInt16(pps.count)); data.append(pps)
        data.append(bytes)
        return data
    }
    init(id: UInt64, captureTime: Double, encodeMS: Double, sps: Data, pps: Data, bytes: Data) {
        self.id = id; self.captureTime = captureTime; self.encodeMS = encodeMS
        self.sps = sps; self.pps = pps; self.bytes = bytes
    }
    init(payload: Data) throws {
        var reader = WireReader(data: payload)
        id = try reader.integer(UInt64.self)
        captureTime = Double(bitPattern: try reader.integer(UInt64.self))
        encodeMS = Double(bitPattern: try reader.integer(UInt64.self))
        sps = try reader.take(Int(reader.integer(UInt16.self)))
        pps = try reader.take(Int(reader.integer(UInt16.self)))
        bytes = try reader.take(reader.remaining)
        guard !sps.isEmpty, !pps.isEmpty, !bytes.isEmpty, captureTime.isFinite, encodeMS.isFinite else { throw WireError.invalid }
    }
}

struct WireReader {
    var data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }
    mutating func take(_ size: Int) throws -> Data {
        guard size >= 0, size <= remaining else { throw WireError.invalid }
        defer { offset += size }
        return data.subdata(in: offset..<(offset + size))
    }
}
extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ number: T) {
        var value = number.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

/// One serial queue owns the connection and framing. Reads allocate only after validating length.
final class WireConnection {
    let connection: NWConnection
    let queue: DispatchQueue
    var onPacket: ((UInt8, Data) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    private var heartbeat: DispatchSourceTimer?
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.startHeartbeat(); self.onReady?(); self.readHeader()
            case .failed: self.close("Connection failed. Check the pairing key and address.")
            case .cancelled: self.close("Disconnected")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.connection.state != .ready else { return }
            self.close("Connection timed out")
        }
    }
    func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close("Connection interrupted") }
        })
    }
    func close(_ reason: String = "Disconnected") {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel(); heartbeat = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }
    private func startHeartbeat() {
        lastReceived = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastReceived > 4 { self.close("Connection stopped responding") }
            else { self.send(StreamWire.packet(250)) }
        }
        heartbeat = timer; timer.resume()
    }
    private func readHeader() {
        readExactly(4) { [weak self] bytes in
            guard let self else { return }
            var reader = WireReader(data: bytes)
            guard let size = try? reader.integer(UInt32.self), size > 0, size <= StreamWire.maximumPacket else {
                self.close("Invalid packet size"); return
            }
            self.readExactly(Int(size)) { [weak self] body in
                guard let self, let kind = body.first else { return }
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                if kind != 250 { self.onPacket?(kind, Data(body.dropFirst())) }
                if !self.closed { self.readHeader() }
            }
        }
    }
    private func readExactly(_ length: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == length else { self.close("Connection ended"); return }
            completion(data)
            if complete { self.close("Connection ended") }
        }
    }
}
