import Foundation

/// Whether the selected ICE pair is very likely one hop on a private LAN, judged without the local-link
/// proof: host candidates on both ends with private addresses of one family (RFC 1918, IPv4 link-local,
/// IPv6 ULA or link-local), and only Wi-Fi, Ethernet or "unknown" labels on the Mac's side (as
/// `LocalMediaRoute.matches`) with no `vpn` flag. Tailscale's 100.64/10 and fd7a:115c:a1e0::/48 are
/// excluded because a tunnel can cross the internet. An mDNS name or anything that does not parse is not
/// LAN. Unlike `LocalMediaRoute.matches`, a missing label passes: this grants no authority, only a short,
/// guarded start rate (`FastStartLANPolicy`). Known gap: a VPN that hands out RFC 1918 or ULA addresses
/// on an interface WebRTC labels "unknown" passes when its round trip is under 15 ms; the exposure is the
/// policy's hold, at most `FastStartLANPolicy.holdSamples` samples, and its guard.
enum LikelyLANPair {
    enum Family: Equatable { case v4, v6 }

    static func matches(localType: String?, remoteType: String?, localAddress: String?, remoteAddress: String?,
                        adapterType: String?, networkType: String?, vpn: Bool?) -> Bool {
        let allowed: Set<String> = ["wifi", "ethernet", "unknown"]
        guard localType == "host", remoteType == "host", vpn != true,
              [adapterType, networkType].compactMap({ $0 }).allSatisfy(allowed.contains),
              let local = localAddress.flatMap(privateFamily), let remote = remoteAddress.flatMap(privateFamily) else { return false }
        return local == remote
    }

    static func privateFamily(_ address: String) -> Family? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (bytes[0], bytes[1]) {
            case (10, _), (192, 168), (169, 254): return .v4
            case (172, 16...31): return .v4
            default: return nil
            }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0] == 0xfd, bytes[1] == 0x7a, bytes[2] == 0x11, bytes[3] == 0x5c, bytes[4] == 0xa1, bytes[5] == 0xe0 { return nil }
        if bytes[0] & 0xfe == 0xfc { return .v6 }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .v6 }
        return nil
    }
}

/// `StreamTuning.fastStartLAN`: on a likely-LAN pair with a LAN round trip, seed the estimate at the first
/// statistics sample instead of the second, and hold it there for a few samples with a minimum.
///
/// Why (device log, 7 Oct 2026, 37 of 37 host sessions): the first sample already shows the Direct/lan
/// pair with the estimate at libwebrtc's 300 kb/s and no encoder yet; the encoder starts 0.15-0.7 s later
/// at that tiny target. The owned VideoToolbox session's `DataRateLimits` (2x the target per second) then
/// cannot carry its first 72-200 KB key frame, so it drops almost every frame until the seed (second
/// sample) and the restart it triggers 0.75 s later, about 80 frames a second for ~2 s. Seeding at the
/// first sample makes the encoder start at the LAN rate. The minimum stops the initial 3x/6x probe results
/// of the 300 kb/s start, which still land after an early seed and set the estimate unconditionally
/// (`DelayBasedBwe`), from dragging it back to ~2 Mb/s.
///
/// Guard: the minimum is dropped at the first sample whose pair is no longer a likely-LAN pair, or with
/// loss, a round trip at the LAN exit limit, or a long pacer queue; otherwise after `holdSamples`. It
/// starts at most once, and only while the ordinary seed has not fired yet.
struct FastStartLANPolicy: Equatable {
    enum Phase: String { case idle, hold, done, guarded = "guard" }
    enum Action: Equatable { case none, start, release }

    static let holdSamples = 3
    static let lossLimitPercent = 2.0
    static let pacerLimitMs = 150.0

    private(set) var phase: Phase = .idle
    private var heldSamples = 0

    var holding: Bool { phase == .hold }

    mutating func observe(seedPending: Bool, likelyLANPair: Bool, route: SeedRoute?, lossPercent: Double?,
                          rttMs: Double?, pacerDelayMs: Double?) -> Action {
        switch phase {
        case .idle:
            guard seedPending else { phase = .done; return .none }
            guard likelyLANPair, route == .lan else { return .none }
            phase = .hold
            heldSamples = 0
            return .start
        case .hold:
            heldSamples += 1
            let tripped = !likelyLANPair || (lossPercent ?? 0) >= Self.lossLimitPercent
                || (rttMs ?? 0) >= CeilingRouteTracker.lanExitRoundTripMs || (pacerDelayMs ?? 0) >= Self.pacerLimitMs
            if tripped { phase = .guarded; return .release }
            if heldSamples >= Self.holdSamples { phase = .done; return .release }
            return .none
        case .done, .guarded:
            return .none
        }
    }
}

/// The estimate minimum every bitrate-settings call carries. libwebrtc keeps the last settings as a whole
/// and refuses a minimum above the maximum (or the start), so the floors are combined and clamped here.
/// With no fast-start floor this is exactly the `LANBitrateFloor` clamped as before.
enum BweMinimum {
    static func bps(lanFloorBps: Int?, fastStartFloorBps: Int?, lowData: Bool, maximumBps: Int?, currentBps: Int? = nil) -> Int? {
        guard let floor = [lanFloorBps, lowData ? nil : fastStartFloorBps].compactMap({ $0 }).max() else { return nil }
        return [floor, maximumBps, currentBps].compactMap { $0 }.min()
    }
}
