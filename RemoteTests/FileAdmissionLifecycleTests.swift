import XCTest

@MainActor
final class FileAdmissionLifecycleTests: XCTestCase {
    /// With the receive budget (PocketDeskReceiveBudget, default ON) a stale sink is discarded on the
    /// engine's disk queue rather than inline, so the fixture waits for it and reads the flag under a lock.
    private final class Sink: FileByteSink, @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var discarded: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func write(_ data: Data) throws { XCTFail("Retired admission must never receive bytes") }
        func commit() throws -> URL { XCTFail("Retired admission must never commit"); return URL(fileURLWithPath: "/unused") }
        func discard() { lock.lock(); flag = true; lock.unlock() }
        func waitDiscarded(_ seconds: TimeInterval = 2) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !discarded, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
            return discarded
        }
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
        XCTAssertEqual(engine.incoming?.phase, .waiting, "Old callback must not admit the new transfer")
        XCTAssertTrue(stale.waitDiscarded(), "The stale sink is discarded (on the disk queue under the receive budget)")
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
        XCTAssertTrue(stale.waitDiscarded(), "A released engine's disk queue still discards the late sink")
    }
}
