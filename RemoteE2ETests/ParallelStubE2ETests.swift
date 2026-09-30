import XCTest

/// Only the stub-lane runner accepts these actions. No Test Pad or Mac input is involved.
final class ParallelStubE2ETests: E2ETestCase {
    func test_parallel_IsolatedStubSmoke() throws {
        guard let lane = config.lane, config.isStub else {
            throw E2EFailure("parallel smoke requires a validated stub simulator lane")
        }
        recorder.metrics["laneID"] = lane.laneID
        recorder.metrics["udid"] = lane.udid
        recorder.metrics["runID"] = lane.runID
        try waitFor("owned stub registered", timeout: 90) {
            host.state.bool("hostRegistered") && host.state.bool("invitationAvailable")
                && host.state.string("run") == lane.runID && host.state.string("mode") == "stub"
        }
        let before = marks()
        launchPhone(reset: true)
        try pairViaPaste()
        try waitFor("one-time native pairing and controllable generated video", timeout: 90) {
            phone.ready && (phone.state.int("frames") ?? 0) > 5
                && !host.events.since(before.hostEvents, type: "pairing.autoApproved").isEmpty
        }
        recorder.check("native pairing token consumed", !FileManager.default.fileExists(atPath: E2EPaths.token))
        recorder.check("no manual pairing approval", host.events.since(before.hostEvents, type: "pairing.awaitingManualApproval").isEmpty)
        recorder.check("generated frames decoded", (phone.state.int("frames") ?? 0) > 5)
        recorder.check("fixed synthetic display", host.display == CGRect(x: 0, y: 0, width: 1280, height: 720))
        // The runner holds A/B at this request until both are ready, then grants each a turn.
        try harness.request("parallel.ready", ["laneID": lane.laneID], timeout: 150)
        let inputMark = host.input.mark()
        tapCanvas()
        let key = lane.laneID == "phone" ? "p" : "t"
        try phone.sendKey(key, modifiers: [])
        try waitFor("this lane's accepted virtual click and key", timeout: 15) {
            let inputs = host.input.since(inputMark)
            return inputs.contains { $0.bool("accepted") && $0.string("action") == "click" }
                && inputs.contains { $0.bool("accepted") && $0.string("action") == "key" && $0.string("key") == key }
        }
        recorder.check("own virtual click/key delivered", true)
        let controls = try harness.request("parallel.actionDone", ["laneID": lane.laneID], timeout: 150)
        recorder.check("both cross-lane negative controls passed", controls.bool("negativeControlsPassed"))
        attachScreenshot("isolated-generated-video")
    }
}
