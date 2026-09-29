#if DEBUG
import Foundation
import WebRTC

/// E2E harness only: keeps every harness media path on 127.0.0.1. The simulator phone and the
/// Mac host share this Mac, so loopback is enough, and no E2E process ever sends to a local-network
/// address — which on macOS would raise a Local Network privacy prompt nobody can answer overnight.
/// Set by HostE2E, PhoneE2E and the stub host before any peer connection exists.
enum E2EMedia {
    static var loopbackOnly = false

    static func restrictToLoopbackIfNeeded(_ factory: RTCPeerConnectionFactory) {
        guard loopbackOnly else { return }
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        options.ignoreWiFiNetworkAdapter = true
        options.ignoreEthernetNetworkAdapter = true
        options.ignoreVPNNetworkAdapter = true
        options.ignoreCellularNetworkAdapter = true
        factory.setOptions(options)
    }

    /// `candidate:<foundation> <component> <transport> <priority> <address> <port> typ …`
    static func allows(candidate sdp: String) -> Bool {
        guard loopbackOnly else { return true }
        let fields = sdp.split(separator: " ")
        guard fields.count > 5 else { return false }
        return fields[4] == "127.0.0.1" || fields[4] == "::1"
    }
}
#endif
