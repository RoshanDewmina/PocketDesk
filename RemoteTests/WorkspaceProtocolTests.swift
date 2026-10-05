import XCTest

final class WorkspaceProtocolTests: XCTestCase {
    private struct Value: Codable, Equatable { var op: String }
    func testRoundTripAndMalformedPayloads() throws {
        let id = InputCausalEnvelope.identity()
        let frame = try WorkspaceFrame(kind: .windows, requestID: id, value: Value(op: "list"))
        XCTAssertEqual(try frame.decode(Value.self), Value(op: "list"))
        var action = RemoteAction(action: "workspace", workspace: frame, epoch: 4)
        XCTAssertNoThrow(try action.validate())
        action.action = "key"
        XCTAssertThrowsError(try action.validate())
        action.action = "workspace"; action.clipboard = .pull("0123456789abcdef0123456789abcdef")
        XCTAssertThrowsError(try action.validate())
    }
    func testSlotBudgetAndLegacyPeer() {
        XCTAssertEqual(WorkspaceUtilities.advertised(addingTo: [], peerFeatures: [], enabled: true), [])
        let full = (0..<32).map { "test.\($0)" }
        XCTAssertEqual(WorkspaceUtilities.advertised(addingTo: full, peerFeatures: [SessionFeature.extendedFeatureList], enabled: true), full)
        XCTAssertEqual(WorkspaceUtilities.advertised(addingTo: [], peerFeatures: [SessionFeature.extendedFeatureList], enabled: true), [WorkspaceUtilities.feature])
    }
}
