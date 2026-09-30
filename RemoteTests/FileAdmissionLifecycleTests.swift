import XCTest

@MainActor
final class FileAdmissionLifecycleTests: XCTestCase {
    private final class Sink: FileByteSink {
        var discarded = false
        func write(_ data: Data) throws { XCTFail("Retired admission must never receive bytes") }
        func commit() throws -> URL { XCTFail("Retired admission must never commit"); return URL(fileURLWithPath: "/unused") }
        func discard() { discarded = true }
    }
    func testStaleAdmissionCannotAdoptAReusedTransferAfterReset() throws {
        let engine = FileTransferEngine(acceptsUnsolicitedOffers: true)
        defer { engine.reset() }
        var answers: [@MainActor (Result<FileByteSink, FileTransferStatus>) -> Void] = []
        engine.admit = { _, answer in answers.append(answer) }
        let transfer = String(repeating: "a", count: 32)
        let offer = FileFrame.offer(transfer, name: "one.txt", bytes: 1, type: nil)
        engine.receive(offer); XCTAssertEqual(answers.count, 1)
        engine.reset()
        engine.receive(offer); XCTAssertEqual(answers.count, 2)
        let stale = Sink()
        answers[0](.success(stale))
        XCTAssertTrue(stale.discarded)
        XCTAssertEqual(engine.incoming?.phase, .waiting, "Old callback must not admit the new transfer")
        answers[1](.failure(.denied))
        XCTAssertNil(engine.incoming)
    }
    func testAdmissionCompletingAfterEngineReleaseDiscardsItsSink() {
        var answer: (@MainActor (Result<FileByteSink, FileTransferStatus>) -> Void)?
        var engine: FileTransferEngine? = FileTransferEngine(acceptsUnsolicitedOffers: true)
        engine?.admit = { _, callback in answer = callback }
        engine?.receive(.offer(String(repeating: "b", count: 32), name: "two.txt", bytes: 1, type: nil))
        engine?.reset(); engine = nil
        let stale = Sink(); answer?(.success(stale))
        XCTAssertTrue(stale.discarded)
    }
}
