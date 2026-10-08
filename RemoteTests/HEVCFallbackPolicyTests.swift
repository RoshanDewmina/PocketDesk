import XCTest

final class HEVCFallbackPolicyTests: XCTestCase {
    func testOneFailureFallsBackForThatSessionThenTheNextSessionRetriesHEVC() {
        var policy = HEVCFallbackPolicy()
        XCTAssertTrue(policy.permits(at: 100))
        policy.failed(at: 100)
        XCTAssertFalse(policy.permits(at: 101), "The reconnect after a failure negotiates H.264")
        XCTAssertFalse(policy.permits(at: 100 + HEVCFallbackPolicy.retryAfter - 1))
        XCTAssertTrue(policy.permits(at: 100 + HEVCFallbackPolicy.retryAfter), "A later session tries HEVC again")
    }

    func testHEVCIsOnByDefaultWithAnInternalSwitchOnly() throws {
        XCTAssertTrue(StreamTuning.tuned.hevc)
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.hevcKey))
        let suite = "HEVCFallbackPolicyTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).hevc)
        defaults.set(false, forKey: StreamTuning.hevcKey)
        XCTAssertFalse(StreamTuning.resolve(defaults: defaults).hevc)
        XCTAssertTrue(StreamTuning.resolve(defaults: defaults).summary.contains("no HEVC"))
    }

    func testRepeatedFailureKeepsH264ForTheLaunch() {
        var policy = HEVCFallbackPolicy()
        policy.failed(at: 100)
        policy.failed(at: 100 + HEVCFallbackPolicy.retryAfter + 5)
        XCTAssertFalse(policy.permits(at: 100 + 100 * HEVCFallbackPolicy.retryAfter),
                       "HEVC that keeps failing starts sessions on H.264 instead of tearing them down")
    }

    func testACleanHEVCSessionForgetsAnEarlierFailure() {
        var policy = HEVCFallbackPolicy()
        policy.failed(at: 100)
        let start = 100 + HEVCFallbackPolicy.retryAfter
        policy.ended(failed: false, startedAt: start, at: start + HEVCFallbackPolicy.cleanSession - 1)
        XCTAssertEqual(policy.failures, 1, "A short session proves nothing")
        policy.ended(failed: true, startedAt: start, at: start + 3600)
        XCTAssertEqual(policy.failures, 1)
        policy.ended(failed: false, startedAt: start, at: start + HEVCFallbackPolicy.cleanSession)
        XCTAssertEqual(policy, HEVCFallbackPolicy())
        policy.failed(at: start + 7200)
        XCTAssertTrue(policy.permits(at: start + 7200 + HEVCFallbackPolicy.retryAfter), "A transient failure days later is a first failure")
    }

    func testARunReportsItsFailureAndEndOnce() {
        let run = HEVCRun(at: 5)
        XCTAssertTrue(run.markFailed())
        XCTAssertFalse(run.markFailed(), "Encoder and decoder failing together count once")
        XCTAssertEqual(run.markEnded(), true)
        XCTAssertNil(run.markEnded())
        let late = HEVCRun(at: 5)
        XCTAssertEqual(late.markEnded(), false)
        XCTAssertFalse(late.markFailed(), "A codec callback after close does not count")
    }
}

/// `PocketDeskH264OnLAN`: off by default; on, a host on a proven one-hop local link offers H.264 alone.
final class H264OnLANTests: XCTestCase {
    private func defaults(_ values: [String: Bool]) throws -> UserDefaults {
        let suite = "H264OnLANTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for (key, value) in values { defaults.set(value, forKey: key) }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testOffByDefaultRecordedInTheSummaryAndAnExplicitHEVCSettingWins() throws {
        XCTAssertFalse(StreamTuning.tuned.h264OnLAN)
        XCTAssertFalse(StreamTuning.resolve(defaults: try defaults([:])).h264OnLAN)
        XCTAssertTrue(StreamTuning.experimentKeys.contains(StreamTuning.h264OnLANKey))
        let on = StreamTuning.resolve(defaults: try defaults([StreamTuning.h264OnLANKey: true]))
        XCTAssertTrue(on.h264OnLAN)
        XCTAssertTrue(on.hevc, "HEVC stays on for every other route")
        XCTAssertTrue(on.summary.contains("H.264 on LAN"), on.summary)
        XCTAssertFalse(StreamTuning.tuned.summary.contains("H.264 on LAN"))
        for explicit in [true, false] {
            let tuning = StreamTuning.resolve(defaults: try defaults([StreamTuning.h264OnLANKey: true, StreamTuning.hevcKey: explicit]))
            XCTAssertFalse(tuning.h264OnLAN, "PocketDeskHEVC \(explicit) wins")
            XCTAssertEqual(tuning.hevc, explicit)
        }
        XCTAssertEqual(StreamTuning.resolve(defaults: try defaults([StreamTuning.h264OnLANKey: true, StreamTuning.legacyDefaultsKey: true])), .legacy)
    }

    func testOnlyAHostOnAProvenLocalLinkWithoutForcedRelayPrefersH264() {
        XCTAssertTrue(LANCodecPolicy.prefersH264(isHost: true, nativeDesktopCodecs: true, provenLocalLink: true, forceRelay: false, enabled: true))
        XCTAssertFalse(LANCodecPolicy.prefersH264(isHost: true, nativeDesktopCodecs: true, provenLocalLink: true, forceRelay: false, enabled: false),
                       "off keeps today's choice")
        XCTAssertFalse(LANCodecPolicy.prefersH264(isHost: true, nativeDesktopCodecs: true, provenLocalLink: false, forceRelay: false, enabled: true),
                       "a remote route, even one later LAN-trusted, keeps today's choice")
        XCTAssertFalse(LANCodecPolicy.prefersH264(isHost: true, nativeDesktopCodecs: true, provenLocalLink: true, forceRelay: true, enabled: true))
        XCTAssertFalse(LANCodecPolicy.prefersH264(isHost: false, nativeDesktopCodecs: true, provenLocalLink: true, forceRelay: false, enabled: true),
                       "the phone keeps advertising what it decodes")
        XCTAssertFalse(LANCodecPolicy.prefersH264(isHost: true, nativeDesktopCodecs: false, provenLocalLink: true, forceRelay: false, enabled: true))
    }

    @MainActor
    func testTheHostOfferDropsHEVCOnlyOnTheProvenLocalLinkWithTheFlagOn() async throws {
        defer { LANCodecPolicy.enabledForTesting = nil }
        let link = ProvenLocalLink(localAddress: "192.168.1.10", peerAddress: "192.168.1.20")
        // A fixed snapshot, so the result never depends on whether the launch's hardware probe has finished.
        let capable = NativeVideoCapabilitySnapshot(supportsLevel52: true, supportsHEVCDecode: true, supportsHEVCEncode: true)
        let hevcAvailable = NativeHEVCCapability.permits(isHost: true, snapshot: capable)
        func offer(enabled: Bool, localLink: ProvenLocalLink?) async throws -> (sdp: String, h264OnLAN: Bool) {
            LANCodecPolicy.enabledForTesting = enabled
            let host = PeerMedia(isHost: true, servers: [], localLink: localLink, capabilitySnapshot: capable)
            defer { host.close() }
            var sdp: String?
            host.onSignal = { if $0.kind == "offer" { sdp = $0.sdp } }
            host.offer()
            let deadline = Date().addingTimeInterval(5)
            while sdp == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            return (try XCTUnwrap(sdp), host.h264OnLAN)
        }
        let lan = try await offer(enabled: true, localLink: link)
        XCTAssertTrue(lan.h264OnLAN)
        XCTAssertFalse(lan.sdp.contains("H265/90000"), "neither 4:2:0 nor 4:4:4 HEVC is offered")
        XCTAssertTrue(lan.sdp.contains("H264/90000"))
        let remote = try await offer(enabled: true, localLink: nil)
        XCTAssertFalse(remote.h264OnLAN)
        XCTAssertEqual(remote.sdp.contains("H265/90000"), hevcAvailable, "a remote route keeps today's codec choice")
        let off = try await offer(enabled: false, localLink: link)
        XCTAssertFalse(off.h264OnLAN)
        XCTAssertEqual(off.sdp.contains("H265/90000"), hevcAvailable, "off keeps today's codec choice on the LAN")
    }
}
