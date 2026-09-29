import Foundation
import CryptoKit
import Darwin
import Network

/// A one-hop, physical-interface UDP proof. IPv4 is the supported path; IPv6-only links fail closed.
/// The peer's endpoint is exchanged inside the already authenticated pairing cipher.
struct LocalProbeEndpoint: Codable {
    let address: String
    let port: UInt16
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

enum LocalProbeVerifier {
    static func verify(_ data: Data, ttl: Int32?, interfaceIndex: UInt32?, sourceAddress: String?,
                       sourcePort: UInt16?, peer: LocalProbeEndpoint, expectedInterface: UInt32,
                       room: String, epoch: String, session: String, pairingKey: SymmetricKey) -> ProbePacket? {
        guard data.count <= 512, ttl == 1, interfaceIndex == expectedInterface,
              sourceAddress == peer.address, sourcePort == peer.port,
              let packet = try? JSONDecoder().decode(ProbePacket.self, from: data),
              packet.room == room, packet.epoch == epoch, packet.session == session,
              SecureRandom.isToken(packet.nonce),
              packet.kind == "challenge" || packet.kind == "response",
              let receivedMAC = Data(base64Encoded: packet.mac) else { return nil }
        let body = "1|\(packet.kind)|\(room)|\(epoch)|\(session)|\(packet.nonce)"
        guard HMAC<SHA256>.isValidAuthenticationCode(receivedMAC, authenticating: Data(body.utf8), using: pairingKey) else {
            return nil
        }
        return packet
    }
}

final class LocalLinkProof {
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
    let endpoint: LocalProbeEndpoint

    /// Must run away from the main actor: obtaining the first Network.framework path is bounded at 2 s.
    static func make(room: String, epoch: String, session: String, pairingKey: Data) -> LocalLinkProof? {
        guard let physical = firstPhysicalIPv4() else { return nil }
        return try? LocalLinkProof(room: room, epoch: epoch, session: session,
                                   pairingKey: pairingKey, physical: physical)
    }

    private init(room: String, epoch: String, session: String, pairingKey: Data,
                 physical: (name: String, index: UInt32, address: String)) throws {
        guard pairingKey.count == 32, SecureRandom.isToken(room), SecureRandom.isToken(session),
              epoch.count == 32 else { throw RemoteError.invalidMessage }
        self.room = room; self.epoch = epoch; self.session = session
        key = SymmetricKey(data: pairingKey)
        nonce = try SecureRandom.token()
        interfaceName = physical.name; interfaceIndex = physical.index; localAddress = physical.address
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw RemoteError.invalidMessage }
        fd = socketFD
        do {
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
            if !self.monitorReady && path.status != .satisfied { return }
            // Even an apparently equivalent path update may have changed routing behind the
            // selected ICE pair. Require a new session and physical proof.
            if self.monitorReady || !self.pathSafe(path) {
                self.invalidate()
            } else {
                self.monitorReady = true
                self.maybeChallenge()
            }
        }
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
    }

    func setPeer(_ endpoint: LocalProbeEndpoint) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.peer == nil, endpoint.port > 0,
                  endpoint.address != self.localAddress, Self.validIPv4(endpoint.address) else { return }
            self.peer = endpoint
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { self.invalidate(); return }
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.address), port: port, using: .udp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, !self.closed, let connection else { return }
                switch state {
                case .ready:
                    guard !self.routeReady, let path = connection.currentPath, self.pathSafe(path) else {
                        self.invalidate(); return
                    }
                    self.routeReady = true
                    self.maybeChallenge()
                case .failed, .cancelled:
                    self.invalidate()
                default: break
                }
            }
            connection.pathUpdateHandler = { [weak self] path in
                guard let self, !self.closed else { return }
                if !self.routePathSeen && path.status != .satisfied { return }
                if self.routePathSeen || !self.pathSafe(path) {
                    self.invalidate()
                } else {
                    self.routePathSeen = true
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed, !self.completed else { return }
            self.send(kind: "challenge", nonce: self.nonce, to: peer)
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        challengeTimer = timer
        timer.resume()
    }

    private func pathSafe(_ path: NWPath) -> Bool {
        let physicalInterfaces = Self.physicalInterfaces(path)
        guard path.status == .satisfied, !path.usesInterfaceType(.other),
              !path.usesInterfaceType(.cellular),
              physicalInterfaces.count == 1,
              let physical = physicalInterfaces.first,
              physical.name == interfaceName && physical.index == Int(interfaceIndex),
              path.usesInterfaceType(physical.type),
              Self.ipv4Address(on: interfaceName) == localAddress else { return false }
        return true
    }

    private func invalidate() {
        finish()
        DispatchQueue.main.async { [weak self] in self?.onInvalidated?() }
    }

    private func signed(_ kind: String, _ nonce: String) -> ProbePacket {
        let body = "1|\(kind)|\(room)|\(epoch)|\(session)|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return ProbePacket(kind: kind, room: room, epoch: epoch, session: session,
                           nonce: nonce, mac: Data(mac).base64EncodedString())
    }

    private func send(kind: String, nonce: String, to endpoint: LocalProbeEndpoint) {
        guard !closed, let data = try? JSONEncoder().encode(signed(kind, nonce)), data.count <= 512 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.address, &address.sin_addr) == 1 else { return }
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0,
                                      socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receive() {
        guard !closed else { return }
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
                        let metadata = Self.metadata(control: control, length: Int(header.msg_controllen))
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
        guard result.0 > 0, monitorReady, routeReady, routePathSeen, let peer,
              let packet = LocalProbeVerifier.verify(Data(payload.prefix(result.0)), ttl: result.1,
                   interfaceIndex: result.2, sourceAddress: result.3, sourcePort: result.4,
                   peer: peer, expectedInterface: interfaceIndex, room: room, epoch: epoch,
                   session: session, pairingKey: key) else { return }
        if packet.kind == "challenge" {
            send(kind: "response", nonce: packet.nonce, to: peer)
        } else if packet.nonce == nonce, !completed {
            completed = true
            let proof = ProvenLocalLink(localAddress: localAddress, peerAddress: peer.address)
            DispatchQueue.main.async { [weak self] in self?.onProven?(proof) }
        }
    }

    private static func metadata(control: UnsafeMutableRawBufferPointer, length: Int) -> (ttl: Int32?, index: UInt32?) {
        var ttl: Int32?
        var index: UInt32?
        var offset = 0
        let alignment = MemoryLayout<Int>.size
        while offset + MemoryLayout<cmsghdr>.size <= length {
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let size = Int(header.cmsg_len)
            let dataOffset = offset + (MemoryLayout<cmsghdr>.size + alignment - 1) & ~(alignment - 1)
            guard size >= dataOffset - offset, offset + size <= length else { break }
            if header.cmsg_level == IPPROTO_IP && header.cmsg_type == IP_RECVTTL,
               dataOffset + MemoryLayout<Int32>.size <= offset + size {
                ttl = control.loadUnaligned(fromByteOffset: dataOffset, as: Int32.self)
            }
            if header.cmsg_level == IPPROTO_IP && header.cmsg_type == IP_RECVIF,
               dataOffset + MemoryLayout<sockaddr_dl>.size <= offset + size {
                let link = control.loadUnaligned(fromByteOffset: dataOffset, as: sockaddr_dl.self)
                index = UInt32(link.sdl_index)
            }
            offset += (size + alignment - 1) & ~(alignment - 1)
        }
        return (ttl, index)
    }

    private static func validIPv4(_ text: String) -> Bool {
        var value = in_addr()
        return inet_pton(AF_INET, text, &value) == 1
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

    private static func firstPhysicalIPv4() -> (name: String, index: UInt32, address: String)? {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "farside.local-link-path")
        var result: (name: String, index: UInt32, address: String)?
        monitor.pathUpdateHandler = { path in
            if path.status != .satisfied { return }
            let physical = physicalInterfaces(path)
            guard path.status == .satisfied, !path.usesInterfaceType(.other),
                  !path.usesInterfaceType(.cellular),
                  physical.count == 1 else {
                semaphore.signal(); return
            }
            for iface in physical {
                if path.usesInterfaceType(iface.type), let address = ipv4Address(on: iface.name) {
                    result = (iface.name, UInt32(iface.index), address)
                    break
                }
            }
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 2)
        monitor.cancel()
        return result
    }

    private static func physicalInterfaces(_ path: NWPath) -> [NWInterface] {
        var result: [NWInterface] = []
        for iface in path.availableInterfaces where iface.type == .wifi || iface.type == .wiredEthernet {
            if !result.contains(where: { $0.name == iface.name && $0.index == iface.index }) {
                result.append(iface)
            }
        }
        return result
    }

}
