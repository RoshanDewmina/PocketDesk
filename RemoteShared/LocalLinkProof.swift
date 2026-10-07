import Foundation
import CryptoKit
import Darwin
import Network
import os

/// A one-hop, physical-interface UDP proof. IPv4 by default; a remote-route pair proof binds the exact
/// address (IPv4 or IPv6) of the media pair it proves. IPv6-only links fail closed on a local route.
/// The peer's endpoint is exchanged inside the already authenticated pairing cipher.
struct LocalProbeEndpoint: Codable {
    let address: String
    let port: UInt16
    /// Remote-route pair proof only: the receiver's own address in the selected media pair to prove.
    var peerAddress: String? = nil
}

/// Literal unicast addresses a probe socket can bind: IPv4, or IPv6 without a scope (never link-local,
/// loopback, unspecified, multicast or IPv4-mapped).
enum LocalProbeAddress {
    static func family(_ text: String) -> Int32? {
        var bytes = [UInt8](repeating: 0, count: 16)
        if inet_pton(AF_INET, text, &bytes) == 1 { return AF_INET }
        guard inet_pton(AF_INET6, text, &bytes) == 1, !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80), bytes[0] != 0xff,
              bytes[0..<10].contains(where: { $0 != 0 }) else { return nil }
        return AF_INET6
    }

    /// One spelling per address, so addresses from WebRTC stats, `getifaddrs` and `recvmsg` compare equal.
    static func canonical(_ text: String) -> String? {
        guard let family = family(text) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_pton(family, text, &bytes) == 1, inet_ntop(family, bytes, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }

    static func ipv6Socket(_ text: String, port: UInt16) -> sockaddr_in6? {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        guard family(text) == AF_INET6, inet_pton(AF_INET6, text, &address.sin6_addr) == 1 else { return nil }
        return address
    }

    /// Canonical addresses of `family` on the named interface.
    static func addresses(on name: String, family: Int32) -> [String] {
        MacNetworkLink.interfaceAddresses().compactMap { entry in
            guard entry.name == name, let value = canonical(MacNetworkLink.normalized(entry.address)),
                  self.family(value) == family else { return nil }
            return value
        }
    }
}

struct ProvenLocalLink {
    let localAddress: String
    let peerAddress: String
}

struct ProbePacket: Codable {
    let kind: String
    let room: String
    let epoch: String
    let session: String
    let nonce: String
    let mac: String
}

enum LocalProbeRejection: String, CaseIterable {
    case size, ttl, interface, sourceAddress = "source-address", sourcePort = "source-port"
    case decode, binding, nonce, kind, hmac
}

enum LocalProbeVerifier {
    static func verify(_ data: Data, ttl: Int32?, interfaceIndex: UInt32?, sourceAddress: String?,
                       sourcePort: UInt16?, peer: LocalProbeEndpoint, expectedInterface: UInt32,
                       room: String, epoch: String, session: String, pairingKey: SymmetricKey) -> ProbePacket? {
        try? check(data, ttl: ttl, interfaceIndex: interfaceIndex, sourceAddress: sourceAddress,
                   sourcePort: sourcePort, peer: peer, expectedInterface: expectedInterface,
                   room: room, epoch: epoch, session: session, pairingKey: pairingKey).get()
    }

    static func check(_ data: Data, ttl: Int32?, interfaceIndex: UInt32?, sourceAddress: String?,
                      sourcePort: UInt16?, peer: LocalProbeEndpoint, expectedInterface: UInt32,
                      room: String, epoch: String, session: String,
                      pairingKey: SymmetricKey) -> Result<ProbePacket, LocalProbeRejectionError> {
        func reject(_ reason: LocalProbeRejection) -> Result<ProbePacket, LocalProbeRejectionError> {
            .failure(LocalProbeRejectionError(reason: reason))
        }
        guard data.count <= 512 else { return reject(.size) }
        guard ttl == 1 else { return reject(.ttl) }
        guard interfaceIndex == expectedInterface else { return reject(.interface) }
        guard sourceAddress == peer.address else { return reject(.sourceAddress) }
        guard sourcePort == peer.port else { return reject(.sourcePort) }
        guard let packet = try? JSONDecoder().decode(ProbePacket.self, from: data) else { return reject(.decode) }
        guard packet.room == room, packet.epoch == epoch, packet.session == session else { return reject(.binding) }
        guard SecureRandom.isToken(packet.nonce) else { return reject(.nonce) }
        guard packet.kind == "challenge" || packet.kind == "response" else { return reject(.kind) }
        guard let receivedMAC = Data(base64Encoded: packet.mac) else { return reject(.hmac) }
        let body = "1|\(packet.kind)|\(room)|\(epoch)|\(session)|\(packet.nonce)"
        guard HMAC<SHA256>.isValidAuthenticationCode(receivedMAC, authenticating: Data(body.utf8), using: pairingKey) else {
            return reject(.hmac)
        }
        return .success(packet)
    }
}

struct LocalProbeRejectionError: Error, Equatable {
    let reason: LocalProbeRejection
}

/// Darwin ancillary data for IP_RECVTTL / IP_RECVIF, and for IPv6 hop limit / packet info. Darwin aligns
/// control messages to 4 bytes (`__DARWIN_ALIGN32`) and delivers IP_RECVTTL as a single `u_char`, so a
/// CMSG_LEN(1) payload is normal.
enum LocalProbeControl {
    /// RFC 3542 values. Darwin names them only under `__APPLE_USE_RFC_3542`, which Swift does not see;
    /// without it the names mean the RFC 2292 options. Verified against the macOS 27 kernel.
    static let ipv6ReceivePacketInfo: Int32 = 61
    static let ipv6ReceiveHopLimit: Int32 = 37
    static let ipv6PacketInfo: Int32 = 46
    static let ipv6HopLimit: Int32 = 47

    private static func align(_ value: Int) -> Int { (value + 3) & ~3 }

    static func parse(_ control: UnsafeRawBufferPointer, length: Int) -> (ttl: Int32?, index: UInt32?) {
        var ttl: Int32?
        var index: UInt32?
        let length = min(length, control.count)
        let headerSize = MemoryLayout<cmsghdr>.size
        let dataStart = align(headerSize)
        var offset = 0
        while offset + headerSize <= length {
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let size = Int(header.cmsg_len)
            guard size >= dataStart, offset + size <= length else { break }
            let dataOffset = offset + dataStart
            let dataLength = size - dataStart
            if header.cmsg_level == IPPROTO_IP && header.cmsg_type == IP_RECVTTL {
                if dataLength >= MemoryLayout<Int32>.size {
                    ttl = control.loadUnaligned(fromByteOffset: dataOffset, as: Int32.self)
                } else if dataLength >= 1 {
                    ttl = Int32(control.load(fromByteOffset: dataOffset, as: UInt8.self))
                }
            }
            if header.cmsg_level == IPPROTO_IP && header.cmsg_type == IP_RECVIF, dataLength >= 4 {
                let family = control.load(fromByteOffset: dataOffset + 1, as: UInt8.self)
                let rawIndex = control.loadUnaligned(fromByteOffset: dataOffset + 2, as: UInt16.self)
                if family == UInt8(AF_LINK) { index = UInt32(rawIndex) }
            }
            if header.cmsg_level == IPPROTO_IPV6 && header.cmsg_type == ipv6HopLimit, dataLength >= 4 {
                ttl = control.loadUnaligned(fromByteOffset: dataOffset, as: Int32.self)
            }
            if header.cmsg_level == IPPROTO_IPV6 && header.cmsg_type == ipv6PacketInfo, dataLength >= 20 {
                index = control.loadUnaligned(fromByteOffset: dataOffset + 16, as: UInt32.self)
            }
            offset += align(size)
        }
        return (ttl, index)
    }
}

struct LocalPathInterface: Equatable {
    let name: String
    let index: Int
    let type: NWInterface.InterfaceType
}

enum LocalPathVerdict: Equatable {
    case safe
    case unsatisfied, usesOther, usesCellular, noPhysical, multiplePhysical
    case interfaceMismatch, notUsingPhysical, addressChanged

    var reason: String {
        switch self {
        case .safe: return "safe"
        case .unsatisfied: return "unsatisfied"
        case .usesOther: return "uses-other(vpn/utun)"
        case .usesCellular: return "uses-cellular"
        case .noPhysical: return "no-physical"
        case .multiplePhysical: return "multiple-physical"
        case .interfaceMismatch: return "interface-mismatch"
        case .notUsingPhysical: return "not-using-physical"
        case .addressChanged: return "ipv4-changed"
        }
    }
}

/// Pure classification of a Network.framework path. A VPN interface that is merely present in
/// `availableInterfaces` does not fail the path; a path that actually routes over it does.
enum LocalPathClassifier {
    static func physical(_ available: [LocalPathInterface]) -> [LocalPathInterface] {
        var result: [LocalPathInterface] = []
        for iface in available where iface.type == .wifi || iface.type == .wiredEthernet {
            if !result.contains(where: { $0.name == iface.name && $0.index == iface.index }) { result.append(iface) }
        }
        return result
    }

    static func classify(satisfied: Bool, available: [LocalPathInterface],
                         uses: (NWInterface.InterfaceType) -> Bool,
                         expected: (name: String, index: UInt32)?,
                         currentIPv4: String?, expectedIPv4: String?) -> LocalPathVerdict {
        guard satisfied else { return .unsatisfied }
        guard !uses(.other) else { return .usesOther }
        guard !uses(.cellular) else { return .usesCellular }
        let physical = physical(available)
        guard let first = physical.first else { return .noPhysical }
        guard physical.count == 1 else { return .multiplePhysical }
        if let expected, first.name != expected.name || first.index != Int(expected.index) { return .interfaceMismatch }
        guard uses(first.type) else { return .notUsingPhysical }
        if let expectedIPv4, currentIPv4 != expectedIPv4 { return .addressChanged }
        return .safe
    }

    static func describe(_ available: [LocalPathInterface]) -> String {
        available.map { "\($0.name)#\($0.index):\(typeName($0.type))" }.joined(separator: ",")
    }

    static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "wired"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

extension NWPath {
    var localInterfaces: [LocalPathInterface] {
        availableInterfaces.map { LocalPathInterface(name: $0.name, index: $0.index, type: $0.type) }
    }
}

/// Stage counters for diagnostics exports. Contains no keys, nonces or addresses.
struct LocalProofStage {
    var monitorReady = false
    var monitorVerdict = "pending"
    var peerSet = false
    var routeState = "not started"
    var routeReady = false
    var routePathSeen = false
    var routeVerdict = "pending"
    var challengesSent = 0
    var sendErrors = 0
    var lastSendErrno: Int32 = 0
    var packetsReceived = 0
    var packetsBeforeGates = 0
    var rejections: [LocalProbeRejection: Int] = [:]
    var lastTTL: Int32?
    var responsesSent = 0
    var proven = false
    var invalidatedBy: String?
    var localNetworkDenied = false

    var summary: String {
        let rejected = LocalProbeRejection.allCases.compactMap { reason in
            rejections[reason].map { "\(reason.rawValue)=\($0)" }
        }.joined(separator: " ")
        var parts = [
            "monitor=\(monitorReady ? "ready" : "no")(\(monitorVerdict))",
            "peer=\(peerSet ? "set" : "no")",
            "route=\(routeState) ready=\(routeReady ? "yes" : "no") path=\(routePathSeen ? "yes" : "no")(\(routeVerdict))",
            "challenges=\(challengesSent) sendErrors=\(sendErrors)" + (sendErrors > 0 ? "(errno \(lastSendErrno))" : ""),
            "received=\(packetsReceived) early=\(packetsBeforeGates) rejected=[\(rejected)]"
                + (lastTTL.map { " lastTTL=\($0)" } ?? " lastTTL=none"),
            "responses=\(responsesSent) proven=\(proven ? "yes" : "no")",
        ]
        if let invalidatedBy { parts.append("invalidated=\(invalidatedBy)") }
        if localNetworkDenied { parts.append("localNetwork=denied") }
        return parts.joined(separator: "; ")
    }
}

final class LocalLinkProof {
    static let log = Logger(subsystem: "com.roshan.PocketDesk", category: "localproof")
    private var log: Logger { Self.log }
    private var stage = LocalProofStage()
    private let fd: Int32
    private let queue = DispatchQueue(label: "farside.local-link-proof")
    private var reader: DispatchSourceRead?
    private var monitor: NWPathMonitor?
    private var routeProbe: NWConnection?
    private var challengeTimer: DispatchSourceTimer?
    private var monitorReady = false
    private var routeReady = false
    private var routePathSeen = false
    private var challengeStarted = false
    private let family: Int32
    private let interfaceName: String
    private let interfaceIndex: UInt32
    private let localAddress: String
    private let room: String
    private let epoch: String
    private let session: String
    private let key: SymmetricKey
    private let nonce: String
    private var peer: LocalProbeEndpoint?
    private var completed = false
    private var closed = false
    var onProven: ((ProvenLocalLink) -> Void)?
    var onInvalidated: (() -> Void)?
    /// iOS reported that Local Network access is denied for this app; the proof can never pass.
    var onLocalNetworkDenied: (() -> Void)?
    let endpoint: LocalProbeEndpoint

    /// Must run away from the main actor: obtaining the first Network.framework path is bounded at 2 s.
    /// `boundTo` (a remote-route pair proof) must be an address of the single physical interface;
    /// otherwise the proof binds that interface's IPv4 address.
    static func make(room: String, epoch: String, session: String, pairingKey: Data,
                     boundTo: String? = nil) -> LocalLinkProof? {
        guard let physical = firstPhysicalIPv4(owning: boundTo) else { return nil }
        do {
            let proof = try LocalLinkProof(room: room, epoch: epoch, session: session,
                                           pairingKey: pairingKey, physical: physical)
            log.info("created on \(physical.name, privacy: .public)#\(physical.index, privacy: .public)")
            return proof
        } catch {
            log.error("socket setup failed on \(physical.name, privacy: .public) errno=\(errno, privacy: .public)")
            return nil
        }
    }

    /// Stage counters for diagnostics; safe to call from the main actor.
    func stageSummary() -> String {
        queue.sync { stage.summary }
    }

    private init(room: String, epoch: String, session: String, pairingKey: Data,
                 physical: (name: String, index: UInt32, address: String)) throws {
        guard pairingKey.count == 32, SecureRandom.isToken(room), SecureRandom.isToken(session),
              epoch.count == 32 else { throw RemoteError.invalidMessage }
        self.room = room; self.epoch = epoch; self.session = session
        key = SymmetricKey(data: pairingKey)
        nonce = try SecureRandom.token()
        interfaceName = physical.name; interfaceIndex = physical.index; localAddress = physical.address
        guard let family = LocalProbeAddress.family(physical.address) else { throw RemoteError.invalidMessage }
        self.family = family
        let socketFD = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw RemoteError.invalidMessage }
        fd = socketFD
        do {
            if family == AF_INET6 {
                endpoint = try Self.bindIPv6(socketFD, address: physical.address, index: physical.index)
            } else {
                var boundIndex = Int32(physical.index)
                var one: Int32 = 1
                guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIndex, socklen_t(MemoryLayout.size(ofValue: boundIndex))) == 0,
                      setsockopt(fd, IPPROTO_IP, IP_TTL, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
                      setsockopt(fd, IPPROTO_IP, IP_RECVIF, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
                      setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
                    throw RemoteError.invalidMessage
                }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = 0
                guard inet_pton(AF_INET, physical.address, &address.sin_addr) == 1 else { throw RemoteError.invalidMessage }
                let didBind = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard didBind == 0 else { throw RemoteError.invalidMessage }
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let didName = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socketFD, $0, &size) }
                }
                guard didName == 0 else { throw RemoteError.invalidMessage }
                endpoint = LocalProbeEndpoint(address: physical.address, port: UInt16(bigEndian: address.sin_port))
            }
        } catch {
            Darwin.close(socketFD)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(socketFD) }
        source.setEventHandler { [weak self] in self?.receive() }
        reader = source
        source.resume()
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard !self.closed else { return }
            let verdict = self.classify(path)
            self.log.info("monitor path \(String(describing: path.status), privacy: .public) verdict=\(verdict.reason, privacy: .public) interfaces=\(LocalPathClassifier.describe(path.localInterfaces), privacy: .public)")
            if !self.monitorReady && path.status != .satisfied { return }
            // Some networks republish IPv6 every few seconds. The safe verdict already pins the one
            // physical interface, its index and IPv4 address, and rules out VPN and cellular use; the
            // media pair is pinned to the proven IPv4 addresses, so only an unsafe update ends the session.
            if verdict != .safe {
                self.stage.monitorVerdict = verdict.reason
                self.invalidate(self.monitorReady ? "monitor-path-changed-\(verdict.reason)" : "monitor-\(verdict.reason)")
            } else if self.monitorReady {
                self.log.info("equivalent monitor path update ignored")
            } else {
                self.monitorReady = true
                self.stage.monitorReady = true; self.stage.monitorVerdict = verdict.reason
                self.log.info("gate monitorReady")
                self.maybeChallenge()
            }
        }
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
    }

    func setPeer(_ endpoint: LocalProbeEndpoint) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            let address = self.family == AF_INET6 ? LocalProbeAddress.canonical(endpoint.address) ?? endpoint.address : endpoint.address
            let valid = LocalProbeAddress.family(address) == self.family
            guard self.peer == nil, endpoint.port > 0, address != self.localAddress, valid else {
                self.log.error("peer endpoint ignored: duplicate=\(self.peer != nil, privacy: .public) self=\(address == self.localAddress, privacy: .public) family=\(valid, privacy: .public)")
                return
            }
            let endpoint = LocalProbeEndpoint(address: address, port: endpoint.port)
            self.peer = endpoint
            self.stage.peerSet = true
            self.log.info("gate peer set")
            #if DEBUG
            if self.bypassRouteProbeForTesting { self.routeReady = true; self.routePathSeen = true; self.maybeChallenge(); return }
            #endif
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { self.invalidate("peer-port"); return }
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.address), port: port, using: .udp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, !self.closed, let connection else { return }
                self.stage.routeState = Self.stateName(state)
                self.log.info("route probe state \(Self.stateName(state), privacy: .public)")
                switch state {
                case .ready:
                    guard !self.routeReady, let path = connection.currentPath else {
                        self.invalidate("route-ready-repeat-or-no-path"); return
                    }
                    let verdict = self.classify(path)
                    self.log.info("route probe ready verdict=\(verdict.reason, privacy: .public) interfaces=\(LocalPathClassifier.describe(path.localInterfaces), privacy: .public)")
                    guard verdict == .safe else { self.invalidate("route-ready-\(verdict.reason)"); return }
                    self.routeReady = true
                    self.stage.routeReady = true
                    self.stage.localNetworkDenied = false
                    self.log.info("gate routeReady")
                    self.maybeChallenge()
                case .waiting:
                    if let reason = connection.currentPath?.unsatisfiedReason, LocalNetworkAccess.isDenied(reason) {
                        self.localNetworkDenied()
                    }
                case .failed, .cancelled:
                    self.invalidate("route-\(Self.stateName(state))")
                default: break
                }
            }
            connection.pathUpdateHandler = { [weak self] path in
                guard let self, !self.closed else { return }
                let verdict = self.classify(path)
                self.log.info("route probe path \(String(describing: path.status), privacy: .public) verdict=\(verdict.reason, privacy: .public) interfaces=\(LocalPathClassifier.describe(path.localInterfaces), privacy: .public)")
                if path.status == .unsatisfied, LocalNetworkAccess.isDenied(path.unsatisfiedReason) {
                    self.localNetworkDenied(); return
                }
                if !self.routePathSeen && path.status != .satisfied { return }
                if verdict != .safe {
                    self.stage.routeVerdict = verdict.reason
                    self.invalidate(self.routePathSeen ? "route-path-changed-\(verdict.reason)" : "route-path-\(verdict.reason)")
                } else if self.routePathSeen {
                    self.log.info("equivalent route probe path update ignored")
                } else {
                    self.routePathSeen = true
                    self.stage.routePathSeen = true; self.stage.routeVerdict = verdict.reason
                    self.log.info("gate routePathSeen")
                    self.maybeChallenge()
                }
            }
            self.routeProbe = connection
            connection.start(queue: self.queue)
        }
    }

    func close() {
        queue.async { [weak self] in self?.finish() }
    }

    #if DEBUG
    /// Same-machine tests only: the route to this machine's own address is loopback, never physical.
    /// Set before `setPeer`.
    var bypassRouteProbeForTesting = false

    /// Drives the same invalidation a path change causes.
    func invalidateForTesting(_ reason: String) {
        queue.async { [weak self] in self?.invalidate(reason) }
    }
    #endif

    private func finish() {
        guard !closed else { return }
        closed = true
        challengeTimer?.cancel(); challengeTimer = nil
        routeProbe?.cancel(); routeProbe = nil
        monitor?.cancel(); monitor = nil
        reader?.cancel(); reader = nil
    }

    deinit {
        if !closed {
            challengeTimer?.cancel()
            routeProbe?.cancel()
            monitor?.cancel()
            reader?.cancel()
        }
    }

    private func maybeChallenge() {
        guard !closed, monitorReady, routeReady, routePathSeen, !challengeStarted, let peer else { return }
        challengeStarted = true
        log.info("all gates open; challenging every 250 ms")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed, !self.completed else { return }
            if self.send(kind: "challenge", nonce: self.nonce, to: peer) { self.stage.challengesSent += 1 }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        challengeTimer = timer
        timer.resume()
    }

    private func classify(_ path: NWPath) -> LocalPathVerdict {
        // An IPv6 interface carries several addresses; the bound one must still be among them.
        let current = family == AF_INET6
            ? LocalProbeAddress.addresses(on: interfaceName, family: AF_INET6).first { $0 == localAddress }
            : Self.ipv4Address(on: interfaceName)
        return LocalPathClassifier.classify(satisfied: path.status == .satisfied, available: path.localInterfaces,
                                            uses: { path.usesInterfaceType($0) },
                                            expected: (interfaceName, interfaceIndex),
                                            currentIPv4: current, expectedIPv4: localAddress)
    }

    private static func stateName(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .waiting: return "waiting"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    private func invalidate(_ reason: String) {
        guard !closed else { return }
        stage.invalidatedBy = reason
        log.error("invalidated: \(reason, privacy: .public) stage: \(self.stage.summary, privacy: .public)")
        finish()
        DispatchQueue.main.async { [weak self] in self?.onInvalidated?() }
    }

    /// Reported, not final: while the system alert is still up the route waits, and Network.framework
    /// retries it by itself once the person chooses Allow. The coordinator decides.
    private func localNetworkDenied() {
        guard !closed, !stage.localNetworkDenied else { return }
        stage.localNetworkDenied = true
        log.error("Local Network access denied: \(self.stage.summary, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onLocalNetworkDenied?() }
    }

    /// True while iOS is refusing this proof's route for Local Network privacy.
    var isLocalNetworkDenied: Bool {
        queue.sync { stage.localNetworkDenied }
    }

    private func signed(_ kind: String, _ nonce: String) -> ProbePacket {
        let body = "1|\(kind)|\(room)|\(epoch)|\(session)|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return ProbePacket(kind: kind, room: room, epoch: epoch, session: session,
                           nonce: nonce, mac: Data(mac).base64EncodedString())
    }

    @discardableResult
    private func send(kind: String, nonce: String, to endpoint: LocalProbeEndpoint) -> Bool {
        guard !closed, let data = try? JSONEncoder().encode(signed(kind, nonce)), data.count <= 512 else { return false }
        let sent: Int
        if family == AF_INET6 {
            guard var address = LocalProbeAddress.ipv6Socket(endpoint.address, port: endpoint.port) else { return false }
            sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = endpoint.port.bigEndian
            guard inet_pton(AF_INET, endpoint.address, &address.sin_addr) == 1 else { return false }
            sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0,
                                      socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        if sent < 0 {
            let code = errno
            stage.sendErrors += 1; stage.lastSendErrno = code
            if stage.sendErrors <= 3 || stage.sendErrors % 20 == 0 {
                log.error("send \(kind, privacy: .public) failed errno=\(code, privacy: .public) count=\(self.stage.sendErrors, privacy: .public)")
            }
            return false
        }
        if kind == "response" || stage.challengesSent < 3 || stage.challengesSent % 20 == 0 {
            log.debug("sent \(kind, privacy: .public) (challenges so far \(self.stage.challengesSent, privacy: .public), responses so far \(self.stage.responsesSent, privacy: .public))")
        }
        return true
    }

    private func receive() {
        guard !closed else { return }
        if family == AF_INET6 { let (result, payload) = readIPv6(); accept(result, payload: payload); return }
        var payload = [UInt8](repeating: 0, count: 513)
        var ancillary = [UInt8](repeating: 0, count: 256)
        var source = sockaddr_in()
        let result: (Int, Int32?, UInt32?, String?, UInt16?) = payload.withUnsafeMutableBytes { body in
            ancillary.withUnsafeMutableBytes { control in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    var vector = iovec(iov_base: body.baseAddress, iov_len: body.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var header = msghdr(msg_name: UnsafeMutableRawPointer(sourcePointer),
                                            msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
                                            msg_iov: vectorPointer, msg_iovlen: 1,
                                            msg_control: control.baseAddress,
                                            msg_controllen: socklen_t(control.count), msg_flags: 0)
                        let count = Darwin.recvmsg(fd, &header, 0)
                        guard count > 0, count <= 512, header.msg_flags & MSG_CTRUNC == 0,
                              sourcePointer.pointee.sin_family == sa_family_t(AF_INET) else { return (count, nil, nil, nil, nil) }
                        let metadata = LocalProbeControl.parse(UnsafeRawBufferPointer(control), length: Int(header.msg_controllen))
                        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var address = sourcePointer.pointee.sin_addr
                        guard inet_ntop(AF_INET, &address, &ip, socklen_t(ip.count)) != nil else {
                            return (count, nil, nil, nil, nil)
                        }
                        return (count, metadata.ttl, metadata.index, String(cString: ip), UInt16(bigEndian: sourcePointer.pointee.sin_port))
                    }
                }
            }
        }
        accept(result, payload: payload)
    }

    private func readIPv6() -> ((Int, Int32?, UInt32?, String?, UInt16?), [UInt8]) {
        var payload = [UInt8](repeating: 0, count: 513)
        var ancillary = [UInt8](repeating: 0, count: 256)
        var source = sockaddr_in6()
        let result: (Int, Int32?, UInt32?, String?, UInt16?) = payload.withUnsafeMutableBytes { body in
            ancillary.withUnsafeMutableBytes { control in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    var vector = iovec(iov_base: body.baseAddress, iov_len: body.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var header = msghdr(msg_name: UnsafeMutableRawPointer(sourcePointer),
                                            msg_namelen: socklen_t(MemoryLayout<sockaddr_in6>.size),
                                            msg_iov: vectorPointer, msg_iovlen: 1,
                                            msg_control: control.baseAddress,
                                            msg_controllen: socklen_t(control.count), msg_flags: 0)
                        let count = Darwin.recvmsg(fd, &header, 0)
                        guard count > 0, count <= 512, header.msg_flags & MSG_CTRUNC == 0,
                              sourcePointer.pointee.sin6_family == sa_family_t(AF_INET6) else { return (count, nil, nil, nil, nil) }
                        let metadata = LocalProbeControl.parse(UnsafeRawBufferPointer(control), length: Int(header.msg_controllen))
                        var ip = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        var address = sourcePointer.pointee.sin6_addr
                        guard inet_ntop(AF_INET6, &address, &ip, socklen_t(ip.count)) != nil else {
                            return (count, nil, nil, nil, nil)
                        }
                        return (count, metadata.ttl, metadata.index, String(cString: ip), UInt16(bigEndian: sourcePointer.pointee.sin6_port))
                    }
                }
            }
        }
        return (result, payload)
    }

    private func accept(_ result: (Int, Int32?, UInt32?, String?, UInt16?), payload: [UInt8]) {
        guard result.0 > 0 else {
            log.error("recvmsg returned \(result.0, privacy: .public)")
            return
        }
        stage.packetsReceived += 1
        stage.lastTTL = result.1
        guard monitorReady, routeReady, routePathSeen, let peer else {
            stage.packetsBeforeGates += 1
            log.info("packet before gates open: monitor=\(self.monitorReady, privacy: .public) route=\(self.routeReady, privacy: .public) path=\(self.routePathSeen, privacy: .public) peer=\(self.peer != nil, privacy: .public)")
            return
        }
        let packet: ProbePacket
        switch LocalProbeVerifier.check(Data(payload.prefix(result.0)), ttl: result.1,
                                        interfaceIndex: result.2, sourceAddress: result.3, sourcePort: result.4,
                                        peer: peer, expectedInterface: interfaceIndex, room: room, epoch: epoch,
                                        session: session, pairingKey: key) {
        case .success(let accepted):
            packet = accepted
        case .failure(let rejection):
            stage.rejections[rejection.reason, default: 0] += 1
            let count = stage.rejections[rejection.reason] ?? 0
            if count <= 3 || count % 20 == 0 {
                let ttl = result.1.map(String.init) ?? "nil", index = result.2.map(String.init) ?? "nil"
                log.error("packet rejected: \(rejection.reason.rawValue, privacy: .public) count=\(count, privacy: .public) ttl=\(ttl, privacy: .public) if=\(index, privacy: .public)/\(self.interfaceIndex, privacy: .public)")
            }
            return
        }
        log.info("packet accepted: \(packet.kind, privacy: .public)")
        if packet.kind == "challenge" {
            if send(kind: "response", nonce: packet.nonce, to: peer) { stage.responsesSent += 1 }
        } else if packet.nonce == nonce, !completed {
            completed = true
            stage.proven = true
            log.info("proven: one-hop link verified")
            let proof = ProvenLocalLink(localAddress: localAddress, peerAddress: peer.address)
            DispatchQueue.main.async { [weak self] in self?.onProven?(proof) }
        }
    }

    /// Hop limit 1 out, hop limit and arrival interface reported in, bound to one physical interface.
    private static func bindIPv6(_ fd: Int32, address text: String, index: UInt32) throws -> LocalProbeEndpoint {
        var boundIndex = Int32(index), one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, size) == 0,
              setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &boundIndex, size) == 0,
              setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &one, size) == 0,
              setsockopt(fd, IPPROTO_IPV6, LocalProbeControl.ipv6ReceiveHopLimit, &one, size) == 0,
              setsockopt(fd, IPPROTO_IPV6, LocalProbeControl.ipv6ReceivePacketInfo, &one, size) == 0,
              var address = LocalProbeAddress.ipv6Socket(text, port: 0) else { throw RemoteError.invalidMessage }
        let length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard didBind == 0 else { throw RemoteError.invalidMessage }
        var named = length
        let didName = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &named) }
        }
        guard didName == 0 else { throw RemoteError.invalidMessage }
        return LocalProbeEndpoint(address: text, port: UInt16(bigEndian: address.sin6_port))
    }

    private static func ipv4Address(on name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var current = head
        while let node = current {
            defer { current = node.pointee.ifa_next }
            guard String(cString: node.pointee.ifa_name) == name,
                  let address = node.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let v4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
            var value = v4.pointee.sin_addr
            if inet_ntop(AF_INET, &value, &ip, socklen_t(ip.count)) != nil { return String(cString: ip) }
        }
        return nil
    }

    private static func firstPhysicalIPv4(owning wanted: String?) -> (name: String, index: UInt32, address: String)? {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "farside.local-link-path")
        var result: (name: String, index: UInt32, address: String)?
        monitor.pathUpdateHandler = { path in
            if path.status != .satisfied { return }
            let available = path.localInterfaces
            let verdict = LocalPathClassifier.classify(satisfied: true, available: available,
                                                       uses: { path.usesInterfaceType($0) },
                                                       expected: nil, currentIPv4: nil, expectedIPv4: nil)
            log.info("initial path verdict=\(verdict.reason, privacy: .public) interfaces=\(LocalPathClassifier.describe(available), privacy: .public)")
            guard verdict == .safe, let iface = LocalPathClassifier.physical(available).first else {
                semaphore.signal(); return
            }
            if let wanted {
                if let address = LocalProbeAddress.canonical(wanted), let family = LocalProbeAddress.family(address),
                   LocalProbeAddress.addresses(on: iface.name, family: family).contains(address) {
                    result = (iface.name, UInt32(iface.index), address)
                } else {
                    log.error("pair address is not on \(iface.name, privacy: .public)")
                }
            } else if let address = ipv4Address(on: iface.name) {
                result = (iface.name, UInt32(iface.index), address)
            } else {
                log.error("no IPv4 address on \(iface.name, privacy: .public)")
            }
            semaphore.signal()
        }
        monitor.start(queue: queue)
        if semaphore.wait(timeout: .now() + 2) == .timedOut { log.error("initial path timed out") }
        monitor.cancel()
        return result
    }
}

/// Remote-route pre-filter: a peer address outside every `en*` subnet (IPv4) or prefix (IPv6) of this
/// device is on another network, so no probe is sent to whoever holds that address here. The proof's
/// own gates still decide; this only avoids probing (and a Local Network prompt) off the LAN.
enum LocalProbeSubnet {
    static func contains(_ address: String, network: String, mask: String) -> Bool {
        var peer = in_addr(), base = in_addr(), netmask = in_addr()
        guard inet_pton(AF_INET, address, &peer) == 1, inet_pton(AF_INET, network, &base) == 1,
              inet_pton(AF_INET, mask, &netmask) == 1, netmask.s_addr != 0 else { return false }
        return peer.s_addr & netmask.s_addr == base.s_addr & netmask.s_addr
    }

    static func contains(_ address: String, network: String, prefixLength: Int) -> Bool {
        var peer = [UInt8](repeating: 0, count: 16), base = [UInt8](repeating: 0, count: 16)
        guard (1...128).contains(prefixLength), LocalProbeAddress.family(address) == AF_INET6,
              LocalProbeAddress.family(network) == AF_INET6,
              inet_pton(AF_INET6, address, &peer) == 1, inet_pton(AF_INET6, network, &base) == 1 else { return false }
        return (0..<prefixLength).allSatisfy { (peer[$0 / 8] ^ base[$0 / 8]) & (0x80 >> ($0 % 8)) == 0 }
    }

    static func isOnLink(_ address: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        let ipv6 = LocalProbeAddress.family(address) == AF_INET6
        var current = head
        while let node = current {
            defer { current = node.pointee.ifa_next }
            guard String(cString: node.pointee.ifa_name).hasPrefix("en"),
                  let addr = node.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(ipv6 ? AF_INET6 : AF_INET),
                  let mask = node.pointee.ifa_netmask else { continue }
            if ipv6 {
                if let local = text6(addr), contains(address, network: local, prefixLength: prefixLength(mask)) { return true }
            } else if let local = text(addr), let netmask = text(mask), contains(address, network: local, mask: netmask) { return true }
        }
        return false
    }

    private static func text6(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var ip = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
        return inet_ntop(AF_INET6, &value, &ip, socklen_t(ip.count)) != nil ? String(cString: ip) : nil
    }

    /// A netmask sockaddr may be shorter than `sockaddr_in6`; bytes past its length are zero.
    private static func prefixLength(_ mask: UnsafeMutablePointer<sockaddr>) -> Int {
        let start = MemoryLayout.offset(of: \sockaddr_in6.sin6_addr) ?? 8
        let end = min(Int(mask.pointee.sa_len), start + 16)
        guard end > start else { return 0 }
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(mask) + start, count: end - start)
        return bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        return inet_ntop(AF_INET, &value, &ip, socklen_t(ip.count)) != nil ? String(cString: ip) : nil
    }
}
