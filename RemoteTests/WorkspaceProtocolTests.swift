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
    func testBoundedPayloadLeavesRoomForOuterWireEnvelope() throws {
        let frame = try WorkspaceFrame(kind: .windows, requestID: InputCausalEnvelope.identity(), value: Value(op: String(repeating: "a", count: 8000)))
        let action = RemoteAction.workspace(frame, epoch: 1)
        XCTAssertLessThan(try JSONEncoder().encode(action).count, 12*1024)
        XCTAssertThrowsError(try WorkspaceFrame(kind: .windows, requestID: InputCausalEnvelope.identity(), value: Value(op: String(repeating: "a", count: 8192))))
    }
    func testStatusMarkerPreservesFullWireListAndFailsClosedForOldUnknownOrNarrow() throws {
        let wire = (0..<32).map { "test.\($0)" }
        let derived = WorkspaceUtilities.resolvedFeatures(wire, statusVersion: 1, current: true, fullDisplay: true)
        XCTAssertEqual(derived.subtracting([WorkspaceUtilities.feature]), Set(wire))
        XCTAssertTrue(derived.contains(WorkspaceUtilities.feature))
        for version: Int? in [nil, 2] {
            XCTAssertFalse(WorkspaceUtilities.resolvedFeatures(wire, statusVersion: version, current: true, fullDisplay: true).contains(WorkspaceUtilities.feature))
        }
        XCTAssertFalse(WorkspaceUtilities.resolvedFeatures(wire, statusVersion: 1, current: false, fullDisplay: true).contains(WorkspaceUtilities.feature))
        XCTAssertFalse(WorkspaceUtilities.resolvedFeatures(wire, statusVersion: 1, current: true, fullDisplay: false).contains(WorkspaceUtilities.feature))
        XCTAssertNil(WorkspaceUtilities.statusVersion(enabled: true, peerFeatures: [], fullDisplay: true))
        XCTAssertNoThrow(try RemoteAction(action: "capture", workspaceUtilitiesVersion: 1, features: wire).validate())
        XCTAssertThrowsError(try RemoteAction(action: "key", workspaceUtilitiesVersion: 1).validate())
        XCTAssertThrowsError(try RemoteAction(action: "capture", workspaceUtilitiesVersion: 0).validate())
    }
    func testSlotBudgetAndLegacyPeer() {
        XCTAssertEqual(WorkspaceUtilities.advertised(addingTo: [], peerFeatures: [], enabled: true), [])
        let full = (0..<32).map { "test.\($0)" }
        XCTAssertEqual(WorkspaceUtilities.advertised(addingTo: full, peerFeatures: [SessionFeature.extendedFeatureList], enabled: true), full)
        XCTAssertEqual(WorkspaceUtilities.advertised(addingTo: [], peerFeatures: [SessionFeature.extendedFeatureList], enabled: true), [WorkspaceUtilities.feature])
    }
}
