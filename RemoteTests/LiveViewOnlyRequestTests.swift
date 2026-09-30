import XCTest
final class LiveViewOnlyRequestTests: XCTestCase {
    func testDelayedRoutineStatusCannotConsumeStartOrExitReply() throws {
        var request = LiveViewOnlyRequest()
        let enter = request.begin(epoch: 7, at: 10)
        XCTAssertNil(request.receive(false, id: nil, epoch: 7, at: 10.1))
        XCTAssertNil(request.receive(true, id: enter, epoch: 8, at: 10.2))
        XCTAssertEqual(request.receive(true, id: enter, epoch: 7, at: 10.3), true)
        let exit = request.begin(epoch: 7, at: 11)
        XCTAssertNil(request.receive(false, id: enter, epoch: 7, at: 11.1))
        XCTAssertNil(request.receive(true, id: nil, epoch: 7, at: 11.2))
        XCTAssertEqual(request.receive(false, id: exit, epoch: 7, at: 11.3), false)
        XCTAssertNil(request.receive(true, id: enter, epoch: 7, at: 11.4))
    }
    func testExpiredOrResetRequestCannotAuthorizeLateReceipt() {
        var request = LiveViewOnlyRequest()
        let id = request.begin(epoch: 1, at: 10)
        XCTAssertNil(request.receive(true, id: id, epoch: 1, at: 12))
        request.reset()
        XCTAssertNil(request.receive(true, id: id, epoch: 1, at: 12.1))
    }
    func testRequestProtocolRequiresBoundedNonceOnRequestAndCorrectStatusAction() {
        let id = String(repeating: "a", count: 32)
        XCTAssertNoThrow(try RemoteAction(action: "viewOnly", liveViewOnly: true, liveViewOnlyRequestID: id).validate())
        XCTAssertThrowsError(try RemoteAction(action: "viewOnly", liveViewOnly: true).validate())
        XCTAssertThrowsError(try RemoteAction(action: "viewOnly", liveViewOnly: true, liveViewOnlyRequestID: "bad").validate())
        XCTAssertThrowsError(try RemoteAction(action: "key", liveViewOnlyRequestID: id, key: "a").validate())
        XCTAssertNoThrow(try RemoteAction(action: "capture", liveViewOnly: true, liveViewOnlyRequestID: id).validate())
    }
}
