import Foundation
import Network
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// iOS Local Network privacy (TN3179) around the same-Wi-Fi proof and ICE host candidates.
///
/// An iOS app that performs a local network operation while in the background with the permission
/// undetermined is denied silently, and the denial is not recorded. So the phone explains first,
/// triggers the alert itself while in the foreground, and never starts the proof until the app is
/// active again, which is also after the person has answered the alert.
enum LocalNetworkAccess {
    /// The coordinator's failure status when iOS reported the permission denied.
    static let deniedStatus = "Local Network access is off for Farside."

    /// Connection Health copy for the denied state.
    static let deniedTitle = "Local Network is off for Farside"
    static let deniedDetail = "iOS is blocking Farside from reaching your Mac on this Wi-Fi, so the free same-network connection can’t start."
    static let deniedNextStep = "Open Settings → Farside, turn on Local Network, then try again."

    /// The system alert can take a moment to appear and make the app inactive; don't mistake that
    /// moment for an answer.
    static let alertSettleTime: TimeInterval = 1

    private static let lock = NSLock()
    nonisolated(unsafe) private static var triggeredAt: TimeInterval?

    static func isDenied(_ reason: NWPath.UnsatisfiedReason) -> Bool {
        reason == .localNetworkDenied
    }

    /// TN3179's approach: connect UDP sockets to link-local IPv6 addresses. Connecting a UDP socket
    /// is a local network operation, so it brings up the alert, and it sends no traffic. Best effort;
    /// there is no API that guarantees the alert.
    static func triggerAlert(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); triggeredAt = now; lock.unlock()
        for var address in linkLocalProbeAddresses() {
            let socket = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
            guard socket >= 0 else { continue }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            Darwin.close(socket)
        }
    }

    /// How long to hold off after a trigger so the alert can appear first.
    static func settleDelay(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let triggeredAt, now >= triggeredAt else { return 0 }
        return max(0, alertSettleTime - (now - triggeredAt))
    }

    /// False while the app is inactive or backgrounded, which includes while the alert is showing.
    @MainActor
    static var appIsActive: Bool {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    /// Waits until the app is in the foreground and active (no system alert over it), up to `timeout`.
    /// True when it may perform local network operations now. Always true on the Mac.
    @MainActor
    static func waitUntilForeground(timeout: TimeInterval = 30) async -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let settle = settleDelay()
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
        while UIApplication.shared.applicationState != .active {
            guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
        #else
        return true
        #endif
    }

    /// Two random hosts on each broadcast-capable interface's link-local IPv6 network, port 9 (discard).
    private static func linkLocalProbeAddresses() -> [sockaddr_in6] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return [] }
        defer { freeifaddrs(start) }
        var result: [sockaddr_in6] = []
        for entry in sequence(first: start, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET6),
                  Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { continue }
            var v6 = UnsafeRawPointer(address).load(as: sockaddr_in6.self)
            let linkLocal = withUnsafeBytes(of: &v6.sin6_addr) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
            guard linkLocal else { continue }
            v6.sin6_port = UInt16(9).bigEndian
            for _ in 0..<2 {
                var probe = v6
                withUnsafeMutableBytes(of: &probe.sin6_addr) { bytes in
                    for index in 8..<16 { bytes[index] = UInt8.random(in: 0...255) }
                }
                result.append(probe)
            }
        }
        return result
    }
}
