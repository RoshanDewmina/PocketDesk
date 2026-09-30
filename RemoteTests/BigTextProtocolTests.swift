import XCTest

final class BigTextProtocolTests: XCTestCase {
    func testDisplayScaleRequestsValidate() {
        XCTAssertNoThrow(try RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 1280).validate())
        XCTAssertNoThrow(try RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 0).validate(),
                         "0 asks for the Mac's own size")
    }

    func testMalformedScaleActionsAreRejected() {
        let invalid: [RemoteAction] = [
            RemoteAction(action: "displayScale", epoch: 3, display: 1),
            RemoteAction(action: "displayScale", epoch: 3, looksLikeWidth: 1280),
            RemoteAction(action: "displayScale", epoch: 3, display: 0, looksLikeWidth: 1280),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: .nan),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: 25_000),
            RemoteAction(action: "displayScale", epoch: 3, display: 1, looksLikeWidth: -5),
            RemoteAction(action: "displayScale", text: "x", epoch: 3, display: 1, looksLikeWidth: 1280),
            RemoteAction(action: "click", epoch: 3, looksLikeWidth: 1280),
            RemoteAction(action: "displays", epoch: 3, scaleError: "nonsense"),
            RemoteAction(action: "capture", epoch: 3, scaleError: "failed"),
        ]
        for action in invalid { XCTAssertThrowsError(try action.validate(), "\(action.action) must be rejected") }
    }

    func testDescriptorScaleFields() {
        var display = DisplayDescriptor(id: 1, name: "Built-in Retina Display", width: 1470, height: 956)
        display.scaleSteps = [ScaleStep(width: 1280, height: 832), ScaleStep(width: 1024, height: 665)]
        display.scaleBaselineWidth = 1470
        display.scaleCurrentWidth = 1280
        XCTAssertNoThrow(try display.validate())

        display.scaleCurrentWidth = 1111
        XCTAssertThrowsError(try display.validate(), "current must be the baseline or an offered step")
        display.scaleCurrentWidth = nil
        display.scaleSteps = [ScaleStep(width: 1600, height: 1040)]
        XCTAssertThrowsError(try display.validate(), "steps are bigger text, so narrower than the baseline")
        display.scaleSteps = Array(repeating: ScaleStep(width: 1000, height: 650), count: 5)
        XCTAssertThrowsError(try display.validate(), "at most four steps")
        display.scaleSteps = [ScaleStep(width: 1280, height: 832)]
        display.scaleBaselineWidth = nil
        XCTAssertThrowsError(try display.validate(), "steps need a baseline")
        display.scaleSteps = []
        display.scaleBaselineWidth = 1470
        XCTAssertNoThrow(try display.validate(), "already at the largest size offers no steps")
    }

    func testOlderDecodersIgnoreTheNewDescriptorFields() {
        struct OldDescriptor: Decodable { var id: UInt32; var name: String; var width: Double; var height: Double }
        let json = #"{"id":1,"name":"Built-in","width":1470,"height":956,"main":true,"scaleSteps":[{"width":1280,"height":832}],"scaleBaselineWidth":1470}"#
        XCTAssertNoThrow(try JSONDecoder().decode(OldDescriptor.self, from: Data(json.utf8)))
    }

    func testErrorReplyRoundTrips() throws {
        let reply = RemoteAction(action: "displays", epoch: 4, displays: [], display: 1, scaleError: BigTextError.failed.rawValue)
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(reply))
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertEqual(decoded.scaleError, "failed")
    }

    func testCapabilityIsOptIn() {
        XCTAssertEqual(SessionFeature.displayScale, "display.scale.1")
        XCTAssertFalse(SessionFeature.host.contains(SessionFeature.displayScale), "advertised only when the Mac allows it")
    }
}
