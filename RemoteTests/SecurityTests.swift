import XCTest
import CryptoKit

final class SecurityTests: XCTestCase {
    func testTamperWrongKeyAndReflectionRejected() throws {
        let pair = try HostPair.create(server: "wss://example.com/signal", name: "Mac")
        let cipher = try SignalCipher(key: pair.invitation.key, room: pair.invitation.room)
        let msg = ProtectedMessage(kind: "request", request: try SecureRandom.token(), session: "", sequence: 0)
        let sealed = try cipher.seal(msg, sender: "client")
        XCTAssertEqual(try cipher.open(sealed, sender: "client").request, msg.request)
        XCTAssertThrowsError(try cipher.open(sealed, sender: "host"))
        let other = try SignalCipher(key: SecureRandom.bytes(), room: pair.invitation.room)
        XCTAssertThrowsError(try other.open(sealed, sender: "client"))
        var tampered = Data(base64Encoded: sealed)!; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try cipher.open(tampered.base64EncodedString(), sender: "client"))
    }
    func testReplayedAndCrossSessionMessagesRejected() throws {
        let request = try SecureRandom.token(), session = try SecureRandom.token()
        var guardState = SessionReplayGuard(request: request, session: session)
        let msg = ProtectedMessage(kind: "media", request: request, session: session, sequence: 1)
        try guardState.accept(msg)
        XCTAssertThrowsError(try guardState.accept(msg))
        XCTAssertThrowsError(try guardState.accept(ProtectedMessage(kind: "media", request: request, session: SecureRandom.token(), sequence: 2)))
    }
    func testEnrollmentExpiryAndNonTLSURLRejected() throws {
        let pair = try HostPair.create(server: "wss://example.com/signal", name: "Mac")
        XCTAssertEqual(try PairInvitation.parse(pair.invitation.code()).room, pair.invitation.room)
        XCTAssertThrowsError(try PairInvitation.parse(pair.invitation.code(), now: Date().addingTimeInterval(200)))
        XCTAssertFalse(PairInvitation.validServer("ws://192.168.1.2/signal"))
        XCTAssertFalse(PairInvitation.validServer("wss://user:pass@example.com/signal"))
        XCTAssertTrue(PairInvitation.validServer("ws://127.0.0.1:8787/signal"))
    }
    func testEnrollmentRotationInvalidatesOriginalKey() throws {
        let pair = try HostPair.create(server: "wss://example.com/signal", name: "Mac"), rotated = try pair.rotated()
        XCTAssertEqual(pair.invitation.room, rotated.invitation.room)
        XCTAssertNotEqual(pair.invitation.token, rotated.invitation.token)
        XCTAssertNotEqual(pair.invitation.key, rotated.invitation.key)
    }
    func testInputValidation() throws {
        XCTAssertThrowsError(try RemoteAction(action: "move", x: .nan).validate())
        XCTAssertThrowsError(try RemoteAction(action: "run-script").validate())
        XCTAssertThrowsError(try RemoteAction(action: "text", text: String(repeating: "a", count: 4097)).validate())
        XCTAssertNoThrow(try RemoteAction(action: "text", text: "Bonjour 👋 中文").validate())
    }
}
