import XCTest

final class InputAppliedReceiptTests: XCTestCase {
    func testReceiptIsPostingEvidenceWithExactBoundedKindAndRequest() throws {
        let receipt = InputAppliedReceipt(requestID: String(repeating: "a", count: 32), kind: "key", accepted: false)
        let action = RemoteAction(action: "inputApplied", epoch: "epoch", inputAppliedReceipt: receipt)
        try action.validate()
        XCTAssertEqual(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(action)), action)
        for bad in [InputAppliedReceipt(requestID: "bad", kind: "key", accepted: true),
                    InputAppliedReceipt(requestID: receipt.requestID, kind: "move", accepted: true)] {
            XCTAssertThrowsError(try bad.validate())
        }
        XCTAssertThrowsError(try RemoteAction(action: "inputApplied").validate())
        XCTAssertThrowsError(try RemoteAction(action: "key", key: "return", inputAppliedReceipt: receipt).validate())
    }
    func testReceiptCannotCarryControlOrMediaAuthority() throws {
        let receipt = InputAppliedReceipt(requestID: String(repeating: "1", count: 32), kind: "text", accepted: true)
        var action = RemoteAction(action: "inputApplied", inputAppliedReceipt: receipt)
        action.text = "sensitive"; XCTAssertThrowsError(try action.validate())
        action.text = ""; action.liveViewOnly = true; XCTAssertThrowsError(try action.validate())
        action.liveViewOnly = nil; action.streamQuality = .sharp; XCTAssertThrowsError(try action.validate())
        XCTAssertThrowsError(try RemoteAction(action: "pause", inputRequestID: receipt.requestID).validate())
        XCTAssertNoThrow(try RemoteAction(action: "text", text: "hello", inputRequestID: receipt.requestID).validate())
    }
}
