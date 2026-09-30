import XCTest
import Foundation

@MainActor
private final class ScriptedPinger {
    enum Reply { case pong, error, silence }
    var reply: Reply = .pong
    private(set) var pings = 0
    private var handlers: [@Sendable ((any Error)?) -> Void] = []

    func ping(_ handler: @escaping @Sendable ((any Error)?) -> Void) {
        pings += 1
        switch reply {
        case .pong: handler(nil)
        case .error: handler(URLError(.networkConnectionLost))
        case .silence: handlers.append(handler)
        }
    }

    func answerLate() {
        let pending = handlers
        handlers.removeAll()
        for handler in pending { handler(nil) }
    }
}

@MainActor
final class SignalingKeepaliveTests: XCTestCase {
    private let fast = SignalingKeepalive.Timing(interval: .milliseconds(20), timeout: .milliseconds(40),
                                                 minimumProbeSpacing: .milliseconds(5))

    private func make(_ pinger: ScriptedPinger, failures: @escaping (SignalingKeepalive.Failure) -> Void) -> SignalingKeepalive {
        SignalingKeepalive(timing: fast, ping: { [weak pinger] handler in pinger?.ping(handler) }, onFailure: failures)
    }

    private func wait(_ duration: Duration) async { try? await Task.sleep(for: duration) }

    func testAnsweredPingsKeepTheSocketAlive() async {
        let pinger = ScriptedPinger()
        var failures: [SignalingKeepalive.Failure] = []
        let keepalive = make(pinger) { failures.append($0) }
        keepalive.start()
        await wait(.milliseconds(150))
        keepalive.stop()
        XCTAssertGreaterThanOrEqual(pinger.pings, 3, "a ping goes out every interval")
        XCTAssertEqual(failures, [])
        XCTAssertNotNil(keepalive.lastPong)
    }

    func testAMissingPongReportsATimeoutOnce() async {
        let pinger = ScriptedPinger()
        pinger.reply = .silence
        var failures: [SignalingKeepalive.Failure] = []
        let keepalive = make(pinger) { failures.append($0) }
        keepalive.start()
        await wait(.milliseconds(200))
        XCTAssertEqual(failures, [.timeout], "a half-open socket never answers; that is the failure")
        pinger.answerLate()
        await wait(.milliseconds(20))
        XCTAssertEqual(failures, [.timeout], "a late pong cannot revive or double-report a socket already given up on")
        XCTAssertEqual(pinger.pings, 1, "nothing is sent after the failure")
    }

    func testAPingErrorIsAFailure() async {
        let pinger = ScriptedPinger()
        pinger.reply = .error
        var failures: [SignalingKeepalive.Failure] = []
        let keepalive = make(pinger) { failures.append($0) }
        keepalive.start()
        await wait(.milliseconds(100))
        XCTAssertEqual(failures, [.pingFailed])
    }

    func testStoppingCancelsAnOutstandingDeadline() async {
        let pinger = ScriptedPinger()
        pinger.reply = .silence
        var failures: [SignalingKeepalive.Failure] = []
        let keepalive = make(pinger) { failures.append($0) }
        keepalive.probeNow()
        XCTAssertEqual(pinger.pings, 1)
        keepalive.stop()
        await wait(.milliseconds(100))
        XCTAssertEqual(failures, [], "a closed socket's keepalive must not report anything")
    }

    func testAProbeGoesOutAtOnceButNotInABurst() async {
        let pinger = ScriptedPinger()
        pinger.reply = .silence
        var failures: [SignalingKeepalive.Failure] = []
        let keepalive = make(pinger) { failures.append($0) }
        keepalive.probeNow()
        keepalive.probeNow()
        keepalive.probeNow()
        XCTAssertEqual(pinger.pings, 1, "network path updates can arrive every few seconds; one ping is in flight at a time")
        await wait(.milliseconds(100))
        XCTAssertEqual(failures, [.timeout])
    }

    func testProbesAreSpacedAfterAnAnswer() {
        let pinger = ScriptedPinger()
        let keepalive = SignalingKeepalive(
            timing: .init(interval: .seconds(30), timeout: .seconds(10), minimumProbeSpacing: .seconds(5)),
            ping: { [weak pinger] handler in pinger?.ping(handler) }, onFailure: { _ in })
        keepalive.probeNow()
        keepalive.probeNow()
        XCTAssertEqual(pinger.pings, 1)
        keepalive.stop()
    }

    func testStandardTimingSuitsCloudflareIdleLimits() {
        let standard = SignalingKeepalive.Timing.standard
        XCTAssertLessThanOrEqual(standard.interval + standard.timeout, .seconds(60),
                                 "a dead socket is noticed within a minute")
        XCTAssertGreaterThanOrEqual(standard.interval, .seconds(15))
    }
}
