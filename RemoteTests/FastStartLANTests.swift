import XCTest

/// `PocketDeskFastStartLAN`: seed at the first sample on a likely-LAN pair, hold it with a guarded minimum.
final class FastStartLANTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "FastStartLANTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheFlagDefaultsOffParsesAndReachesTheSummary() throws {
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.fastStartLANKey))
        let defaults = try defaults()
        let today = StreamTuning.resolve(defaults: defaults)
        XCTAssertEqual(today, StreamTuning.tuned)
        XCTAssertFalse(today.fastStartLAN)
        XCTAssertFalse(today.summary.contains("fast start LAN"))
        defaults.set(true, forKey: StreamTuning.fastStartLANKey)
        let on = StreamTuning.resolve(defaults: defaults)
        XCTAssertTrue(on.fastStartLAN)
        XCTAssertTrue(on.summary.contains("fast start LAN"), on.summary)
        XCTAssertEqual(on.fieldTrials, StreamTuning.tuned.fieldTrials)
    }

    private func likely(_ local: String?, _ remote: String?, localType: String = "host", remoteType: String = "host",
                        adapter: String? = "unknown", network: String? = nil, vpn: Bool? = false) -> Bool {
        LikelyLANPair.matches(localType: localType, remoteType: remoteType, localAddress: local, remoteAddress: remote,
                              adapterType: adapter, networkType: network, vpn: vpn)
    }

    func testOnlyPrivateHostPairsOfOneFamilyAreLikelyLAN() {
        XCTAssertTrue(likely("192.168.1.10", "192.168.1.20"))
        XCTAssertTrue(likely("10.0.0.5", "10.20.30.40"))
        XCTAssertTrue(likely("172.16.0.1", "172.31.255.254"))
        XCTAssertTrue(likely("169.254.3.4", "169.254.9.9"), "IPv4 link-local cannot cross a router")
        XCTAssertTrue(likely("fd12:3456::1", "fd12:3456::2"), "IPv6 ULA")
        XCTAssertTrue(likely("fe80::1", "fe80::2"), "IPv6 link-local")
        XCTAssertTrue(likely("192.168.1.10", "192.168.1.20", adapter: nil, network: nil, vpn: nil),
                      "a missing adapter label is not a veto")

        XCTAssertFalse(likely("172.15.0.1", "172.16.0.1"))
        XCTAssertFalse(likely("172.32.0.1", "172.16.0.1"))
        XCTAssertFalse(likely("192.168.1.10", "8.8.8.8"), "a public address")
        XCTAssertFalse(likely("2001:db8::1", "2001:db8::2"), "global IPv6")
        XCTAssertFalse(likely("100.101.102.103", "100.64.0.7"), "Tailscale's 100.64/10")
        XCTAssertFalse(likely("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::2"), "Tailscale's ULA prefix")
        XCTAssertFalse(likely("192.168.1.10", "fd12::2"), "mixed families")
        XCTAssertFalse(likely("192.168.1.10", "3b1c2a.local"), "an mDNS name")
        XCTAssertFalse(likely(nil, "192.168.1.20"))
        XCTAssertFalse(likely("192.168.1.10", "192.168.1.20", remoteType: "srflx"))
        XCTAssertFalse(likely("192.168.1.10", "192.168.1.20", localType: "relay"))
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", adapter: "vpn"))
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", network: "cellular"))
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", adapter: "cellular4g"), "only Wi-Fi, Ethernet or unknown labels pass")
        XCTAssertTrue(likely("10.0.0.5", "10.0.0.6", adapter: "ethernet", network: "wifi"))
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", vpn: true))
        XCTAssertFalse(likely("127.0.0.1", "127.0.0.1"))
    }

    private func sample(_ policy: inout FastStartLANPolicy, pending: Bool = true, pair: Bool = true, rtt: Double? = 6,
                        loss: Double? = 0, pacer: Double? = 0) -> FastStartLANPolicy.Action {
        policy.observe(seedPending: pending, likelyLANPair: pair, route: SeedRoute.classify(detail: "lan", rttMs: rtt),
                       lossPercent: loss, rttMs: rtt, pacerDelayMs: pacer)
    }

    func testStartsOnTheFirstLikelyLANSampleAndReleasesAfterTheHold() {
        var policy = FastStartLANPolicy()
        XCTAssertEqual(sample(&policy, loss: nil, pacer: nil), .start, "the first sample, before any media statistics")
        XCTAssertTrue(policy.holding)
        XCTAssertEqual(sample(&policy, pacer: 120), .none)
        XCTAssertEqual(sample(&policy), .none)
        XCTAssertEqual(sample(&policy), .release)
        XCTAssertEqual(policy.phase, .done)
        for _ in 0..<5 { XCTAssertEqual(sample(&policy), .none, "once per session") }
    }

    func testWaitsForALANRoundTripAndNeverStartsAfterTheOrdinarySeed() {
        var policy = FastStartLANPolicy()
        XCTAssertEqual(sample(&policy, rtt: nil), .none, "no round trip yet")
        XCTAssertEqual(sample(&policy, rtt: 19), .none, "a host pair at 19 ms is not LAN")
        XCTAssertEqual(sample(&policy, pair: false), .none)
        XCTAssertEqual(sample(&policy), .start)

        var late = FastStartLANPolicy()
        XCTAssertEqual(sample(&late, pending: false), .none)
        XCTAssertEqual(late.phase, .done)
        XCTAssertEqual(sample(&late), .none, "the ordinary seed already set the start")
    }

    func testRelayAndInternetRoutesNeverStart() {
        for detail in ["relay", "p2p"] {
            var policy = FastStartLANPolicy()
            for _ in 0..<4 {
                XCTAssertEqual(policy.observe(seedPending: true, likelyLANPair: true, route: SeedRoute.classify(detail: detail, rttMs: 5),
                                              lossPercent: 0, rttMs: 5, pacerDelayMs: 0), .none, detail)
            }
        }
    }

    func testTheGuardReleasesOnLossRoundTripPacerOrAChangedPair() {
        let trips: [(String, (inout FastStartLANPolicy) -> FastStartLANPolicy.Action)] = [
            ("loss", { self.sample(&$0, loss: 2) }),
            ("round trip", { self.sample(&$0, rtt: 25) }),
            ("pacer", { self.sample(&$0, pacer: 150) }),
            ("pair", { self.sample(&$0, pair: false) }),
        ]
        for (name, trip) in trips {
            var policy = FastStartLANPolicy()
            XCTAssertEqual(sample(&policy), .start)
            XCTAssertEqual(trip(&policy), .release, name)
            XCTAssertEqual(policy.phase, .guarded, name)
            XCTAssertEqual(sample(&policy), .none, "\(name): never restarts")
        }
        var calm = FastStartLANPolicy()
        XCTAssertEqual(sample(&calm), .start)
        XCTAssertEqual(sample(&calm, rtt: 24, loss: 1.9, pacer: 149), .none, "just under every limit holds")
    }

    func testAnEarlySeedReplacesTheOrdinarySeedAndItsRecheck() {
        var policy = BandwidthSeedPolicy()
        policy.markSeeded()
        for estimate in [300.0, 10_000, 1_000] {
            XCTAssertFalse(policy.observe(route: "Direct", estimateKbps: estimate, lossPercent: 0, seedKbps: 10_000), "\(estimate)")
        }
    }

    func testTheMinimumNeverExceedsTheMaximumOrTheStartAndIsUnchangedWithoutAFastStartFloor() {
        let seed = min(StreamQuality.sharp.startBitrateBps(for: .lan), 25_000_000)
        let start = BweMinimum.bps(lanFloorBps: nil, fastStartFloorBps: seed, lowData: false, maximumBps: 25_000_000, currentBps: seed)
        XCTAssertEqual(start, seed, "start: min == start <= max")
        XCTAssertEqual(BweMinimum.bps(lanFloorBps: nil, fastStartFloorBps: seed, lowData: false, maximumBps: 25_000_000), seed, "hold")
        XCTAssertEqual(BweMinimum.bps(lanFloorBps: nil, fastStartFloorBps: seed, lowData: false, maximumBps: 4_000_000), 4_000_000,
                       "a ceiling that fell during the hold clamps the minimum")
        XCTAssertNil(BweMinimum.bps(lanFloorBps: nil, fastStartFloorBps: seed, lowData: true, maximumBps: 1_000_000),
                     "Low Data ends the fast-start floor")
        XCTAssertNil(BweMinimum.bps(lanFloorBps: nil, fastStartFloorBps: nil, lowData: false, maximumBps: 25_000_000), "release")
        XCTAssertEqual(BweMinimum.bps(lanFloorBps: 12_000_000, fastStartFloorBps: seed, lowData: false, maximumBps: 25_000_000), 12_000_000)

        for lan in [nil, 3_000_000, 10_000_000, 30_000_000] as [Int?] {
            for maximum in [nil, 6_000_000, 25_000_000] as [Int?] {
                XCTAssertEqual(BweMinimum.bps(lanFloorBps: lan, fastStartFloorBps: nil, lowData: false, maximumBps: maximum),
                               lan.map { min($0, maximum ?? $0) }, "flag off: the LAN floor clamped as before")
                let current = maximum.map { min(10_000_000, $0) } ?? 10_000_000
                XCTAssertEqual(BweMinimum.bps(lanFloorBps: lan, fastStartFloorBps: nil, lowData: false, maximumBps: maximum, currentBps: current),
                               lan.map { min($0, current) }, "flag off: the seed's floor clamped as before")
            }
        }
    }

    func testThePhaseIsAnOptionalStatisticsField() throws {
        var report = StreamStatsReport(role: "host", previous: nil, current: StreamStatsSample(entries: []), counters: nil)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fastStartLAN"))
        report.fastStartLAN = FastStartLANPolicy.Phase.guarded.rawValue
        let decoded = try JSONDecoder().decode(StreamStatsReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.fastStartLAN, "guard")
    }
}
