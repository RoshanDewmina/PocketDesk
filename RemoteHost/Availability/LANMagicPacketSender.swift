import Foundation
import Darwin

struct WakeLANInterface: Equatable {
    let name: String
    let index: UInt32
    /// Host-order IPv4 values from a currently present broadcast-capable interface.
    let address: UInt32
    let netmask: UInt32
    let broadcast: UInt32
    func valid() -> Bool {
        func isPrivate(_ value: UInt32) -> Bool { value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 }
        let inverse = ~netmask
        return index > 0 && isPrivate(address) && isPrivate(address & netmask) && isPrivate(broadcast) && netmask != 0 && inverse >= 3 &&
            inverse & (inverse + 1) == 0 && broadcast == address | inverse &&
            address & inverse != 0 && address != broadcast
    }
    static func current(named name: String) -> WakeLANInterface? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee
            guard String(cString: entry.ifa_name) == name, let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask,
                  let broadcast = entry.ifa_dstaddr,
                  entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST) == UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            func value(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
                UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            }
            let result = WakeLANInterface(name: name, index: if_nametoindex(entry.ifa_name),
                                          address: value(address), netmask: value(mask), broadcast: value(broadcast))
            if result.valid() { return result }
        }
        return nil
    }
}

/// No discovery, arbitrary destinations, SecureOn password or network settings mutation.
/// Send completion certifies only that the kernel accepted one102byte UDP datagram.
struct LANMagicPacketSender {
    var interface: (String) -> WakeLANInterface? = { WakeLANInterface.current(named: $0) }
    var write: (WakeLANInterface, Data) -> Bool = Self.sendDatagram
    func send(_ target: HostWakeTarget) -> WakeReply.Status {
        guard (try? target.validate()) != nil, let current = interface(target.interfaceName), current.valid(),
              current.name == target.interfaceName else { return .unsupported }
        return write(current, target.hardwareAddress.magicPacket) ? .sent : .unsupported
    }
    static func sendDatagram(_ interface: WakeLANInterface, _ bytes: Data) -> Bool {
        guard interface.valid(), bytes.count == 102 else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var enabled: Int32 = 1
        var index = interface.index
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = UInt8(AF_INET)
        destination.sin_port = UInt16(9).bigEndian
        destination.sin_addr = in_addr(s_addr: interface.broadcast.bigEndian)
        return withUnsafePointer(to: &destination) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bytes.withUnsafeBytes { buffer in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == bytes.count
                }
            }
        }
    }
}
