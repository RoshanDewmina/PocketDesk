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
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", adapter: "unknown", network: "cellular5g"))
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", adapter: "wildcard"))
        XCTAssertFalse(likely("192.168.1.10", "192.168.1.20", adapter: nil, network: nil, vpn: nil),
                       "no label at all fails, as LocalMediaRoute")
        for (adapter, network) in [("unknown", nil), ("wifi", "wifi"), ("ethernet", nil), ("cellular", nil), (nil, nil)] as [(String?, String?)] {
            XCTAssertEqual(likely("192.168.1.10", "192.168.1.20", adapter: adapter, network: network),
                           LocalMediaRoute.isPhysicalHostPair(localType: "host", remoteType: "host", adapterType: adapter,
                                                              networkType: network, vpn: false), "\(adapter ?? "nil")/\(network ?? "nil")")
        }
        XCTAssertTrue(likely("10.0.0.5", "10.0.0.6", adapter: "ethernet", network: "wifi"))
        XCTAssertFalse(likely("10.0.0.5", "10.0.0.6", vpn: true))
        XCTAssertFalse(likely("127.0.0.1", "127.0.0.1"))
    }

    private func report(localType: String = "host", local: String = "192.168.1.10", remote: String = "192.168.1.20",
                        adapter: String = "unknown", network: String = "wifi", vpn: Bool = false, rtt: Double = 0.006) -> [StreamStatsEntry] {
        [StreamStatsEntry(id: "T", type: "transport", values: ["selectedCandidatePairId": "P"]),
         StreamStatsEntry(id: "P", type: "candidate-pair", values: ["localCandidateId": "L", "remoteCandidateId": "R",
                                                                     "currentRoundTripTime": NSNumber(value: rtt)]),
         StreamStatsEntry(id: "L", type: "local-candidate", values: ["candidateType": localType, "address": local,
                                                                      "networkAdapterType": adapter, "networkType": network,
                                                                      "vpn": NSNumber(value: vpn)]),
         StreamStatsEntry(id: "R", type: "remote-candidate", values: ["candidateType": "host", "address": remote])]
    }

    func testTheEarlyReadJudgesTheSelectedPairFromAStatisticsReport() {
        XCTAssertTrue(LikelyLANPair.matches(selectedIn: report()))
        XCTAssertFalse(LikelyLANPair.matches(selectedIn: report(localType: "relay")))
        XCTAssertFalse(LikelyLANPair.matches(selectedIn: report(local: "100.101.102.103", remote: "100.64.0.7")))
        XCTAssertFalse(LikelyLANPair.matches(selectedIn: report(adapter: "cellular4g", network: "cellular")))
        XCTAssertFalse(LikelyLANPair.matches(selectedIn: report(vpn: true)))
        XCTAssertFalse(LikelyLANPair.matches(selectedIn: Array(report().dropFirst())), "no selected pair")
        let sample = StreamStatsSample(entries: report())
        let stats = StreamStatsReport(role: "host", previous: nil, current: sample, counters: nil)
        XCTAssertEqual(SeedRoute.classify(detail: sample.routeDetail, rttMs: stats.rttMs), .lan,
                       "the early read classifies the route from the same report")
    }

    /// `PeerMedia.seedBandwidthEstimate`'s order: the fast start first, the ordinary seed only when it did not start.
    private func seedSample(_ fast: inout FastStartLANPolicy, _ seed: inout BandwidthSeedPolicy, lowDataKnown: Bool) -> (FastStartLANPolicy.Action, Bool) {
        let action = sample(&fast, pending: seed.attempts == 0, lowDataKnown: lowDataKnown)
        if action == .start { seed.markSeeded(); return (action, false) }
        return (action, seed.observe(route: "Direct", estimateKbps: 300, lossPercent: 0, seedKbps: 10_000))
    }

    func testTheTwoSeedsNeverBothFire() {
        var fast = FastStartLANPolicy(), seed = BandwidthSeedPolicy()
        XCTAssertTrue(seedSample(&fast, &seed, lowDataKnown: false) == (.none, false), "Low Data unknown: the first sample waits")
        XCTAssertTrue(seedSample(&fast, &seed, lowDataKnown: false) == (.none, true), "the ordinary seed fires on the second")
        XCTAssertEqual(seedSample(&fast, &seed, lowDataKnown: true).0, .none)
        XCTAssertEqual(fast.phase, .done, "the fast start never follows the ordinary seed")

        var early = FastStartLANPolicy(), ordinary = BandwidthSeedPolicy()
        XCTAssertTrue(seedSample(&early, &ordinary, lowDataKnown: false) == (.none, false))
        XCTAssertTrue(seedSample(&early, &ordinary, lowDataKnown: true) == (.start, false), "the early read after the heartbeat")
        for _ in 0..<6 { XCTAssertFalse(seedSample(&early, &ordinary, lowDataKnown: true).1, "the ordinary seed stays quiet") }
        XCTAssertEqual(early.phase, .done)
    }

    func testAnICERestartEndsTheHold() {
        var policy = FastStartLANPolicy()
        XCTAssertFalse(policy.cancel(), "nothing to end while idle")
        XCTAssertEqual(policy.phase, .idle)
        XCTAssertEqual(sample(&policy), .start)
        XCTAssertTrue(policy.cancel())
        XCTAssertEqual(policy.phase, .guarded)
        XCTAssertFalse(policy.cancel())
        XCTAssertEqual(sample(&policy), .none, "never restarts")
    }

    private func sample(_ policy: inout FastStartLANPolicy, pending: Bool = true, lowDataKnown: Bool = true, pair: Bool = true,
                        rtt: Double? = 6, loss: Double? = 0, pacer: Double? = 0) -> FastStartLANPolicy.Action {
        policy.observe(seedPending: pending, lowDataKnown: lowDataKnown, likelyLANPair: pair,
                       route: SeedRoute.classify(detail: "lan", rttMs: rtt), lossPercent: loss, rttMs: rtt, pacerDelayMs: pacer)
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
        XCTAssertEqual(sample(&policy, lowDataKnown: false), .none, "no phone heartbeat has said whether Low Data applies")
        XCTAssertEqual(policy.phase, .idle, "waiting for the heartbeat does not end the fast start")
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
                XCTAssertEqual(policy.observe(seedPending: true, lowDataKnown: true, likelyLANPair: true,
                                              route: SeedRoute.classify(detail: detail, rttMs: 5),
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

    private func compose(lan: Int? = nil, fast: Int? = nil, lowData: Bool = false, maximum: Int?, current: Int? = nil) -> BweSettings {
        BweSettings.compose(lanFloorBps: lan, fastStartFloorBps: fast, lowData: lowData, maximumBps: maximum, currentBps: current)
    }

    func testBweSettingsComposeKeepsMinimumAtMostCurrentAtMostMaximum() {
        let seed = StreamQuality.sharp.startBitrateBps(for: .lan)
        XCTAssertEqual(compose(fast: seed, maximum: 25_000_000, current: seed),
                       BweSettings(minimumBps: seed, currentBps: seed, maximumBps: 25_000_000), "start")
        XCTAssertEqual(compose(fast: seed, maximum: 25_000_000), BweSettings(minimumBps: seed, currentBps: nil, maximumBps: 25_000_000), "hold")
        XCTAssertEqual(compose(fast: seed, maximum: 4_000_000), BweSettings(minimumBps: 4_000_000, currentBps: nil, maximumBps: 4_000_000),
                       "a ceiling that fell during the hold clamps the minimum")
        XCTAssertEqual(compose(fast: seed, maximum: 4_000_000, current: seed),
                       BweSettings(minimumBps: 4_000_000, currentBps: 4_000_000, maximumBps: 4_000_000), "a start above the ceiling")
        XCTAssertEqual(compose(fast: seed, lowData: true, maximum: 1_000_000), BweSettings(minimumBps: nil, currentBps: nil, maximumBps: 1_000_000),
                       "Low Data ends the fast-start floor")
        XCTAssertEqual(compose(maximum: 25_000_000), BweSettings(minimumBps: nil, currentBps: nil, maximumBps: 25_000_000), "release")
        XCTAssertEqual(compose(lan: 12_000_000, fast: seed, maximum: 25_000_000).minimumBps, max(12_000_000, seed), "the higher floor")
        XCTAssertEqual(compose(fast: seed, maximum: nil), BweSettings(minimumBps: seed, currentBps: nil, maximumBps: nil),
                       "no ceiling applied yet: nothing to clamp to")

        let floors: [Int?] = [nil, 3_000_000, seed, 30_000_000]
        let maxima: [Int?] = [nil, 1_000_000, 6_000_000, 25_000_000]
        for lan in floors {
            for fast in floors {
                for maximum in maxima {
                    for current in [nil, 2_000_000, seed, 40_000_000] as [Int?] {
                        for lowData in [false, true] {
                            let settings = compose(lan: lan, fast: fast, lowData: lowData, maximum: maximum, current: current)
                            let label = "\(String(describing: lan)) \(String(describing: fast)) \(String(describing: maximum)) \(String(describing: current)) \(lowData)"
                            XCTAssertEqual(settings.maximumBps, maximum, label)
                            if let minimum = settings.minimumBps {
                                XCTAssertLessThanOrEqual(minimum, settings.currentBps ?? minimum, label)
                                XCTAssertLessThanOrEqual(minimum, maximum ?? minimum, label)
                            }
                            if let current = settings.currentBps { XCTAssertLessThanOrEqual(current, maximum ?? current, label) }
                            if fast == nil || lowData {
                                XCTAssertEqual(settings, compose(lan: lan, maximum: maximum, current: current), "\(label): no fast-start floor")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Flag off, every bitrate-settings call sends what it sent before `BweSettings`.
    func testBweSettingsComposeMatchesTheOldCallsWithoutAFastStartFloor() {
        for lan in [nil, 3_000_000, 10_000_000, 30_000_000] as [Int?] {
            for maximum in [6_000_000, 25_000_000] {
                XCTAssertEqual(compose(lan: lan, maximum: maximum), BweSettings(minimumBps: lan.map { min($0, maximum) }, currentBps: nil,
                                                                               maximumBps: maximum), "ceiling calls")
                for seedBps in [4_000_000, 10_000_000, 40_000_000] {
                    let seed = min(seedBps, maximum)
                    XCTAssertEqual(compose(lan: lan, maximum: maximum, current: seedBps),
                                   BweSettings(minimumBps: lan.map { min($0, seed) }, currentBps: seed, maximumBps: maximum), "seed")
                }
            }
            for applied in [nil, 6_000_000] as [Int?] {
                let clamped = lan.map { min($0, applied ?? $0) }
                XCTAssertEqual(compose(lan: clamped, maximum: applied), BweSettings(minimumBps: clamped, currentBps: nil, maximumBps: applied),
                               "LAN floor call")
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
