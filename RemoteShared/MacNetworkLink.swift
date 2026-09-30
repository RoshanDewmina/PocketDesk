import Foundation
import Darwin
import Network

/// How the Mac reaches the phone on a same-network route, reported on `capture` status so the
/// phone can say "Your Mac is on Wi-Fi" as a fact. WebRTC labels every macOS adapter "unknown", and
/// interface names prove nothing (en0 is Wi-Fi on a MacBook but Ethernet on a Mac mini), so the
/// selected pair's host-candidate address is matched to an interface and then to its Network type.
enum MacNetworkLink: String, Equatable {
    case wifi, wired, other

    static let maximumBytes = 8

    /// Nil unless the local candidate is a host candidate whose address belongs to a known interface.
    static func resolve(localAddress: String?, candidateType: String?,
                        addresses: [(name: String, address: String)],
                        interfaces: [LocalPathInterface]) -> MacNetworkLink? {
        guard candidateType == "host", let localAddress else { return nil }
        let wanted = normalized(localAddress)
        guard !wanted.isEmpty,
              let name = addresses.first(where: { normalized($0.address) == wanted })?.name,
              let interface = interfaces.first(where: { $0.name == name }) else { return nil }
        switch interface.type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wired
        default: return .other
        }
    }

    /// Lowercased, without IPv6 brackets or a `%scope` suffix.
    static func normalized(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if let percent = value.firstIndex(of: "%") { value = String(value[..<percent]) }
        return value
    }

    /// Every IPv4 and IPv6 address on this machine with its interface name.
    static func interfaceAddresses() -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [(name: String, address: String)] = []
        var current = head
        while let node = current {
            defer { current = node.pointee.ifa_next }
            guard let address = node.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: node.pointee.ifa_name), String(cString: host)))
        }
        return result
    }
}
