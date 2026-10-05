import XCTest
@testable import PocketDeskRemote

@MainActor
final class RichImagePreparationTests: XCTestCase {
    func testCancelAndReopenCannotPrepareUntilRetiredProviderCallbackFinishes() async throws {
        let gate = PhoneRichImagePreparationGate()
        let old = try XCTUnwrap(gate.acquire())
        let entered = expectation(description: "provider entered")
        let returned = expectation(description: "provider callback returned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); old.finishCallback() }
        DispatchQueue.global().async {
            entered.fulfill(); release.wait()
            XCTAssertFalse(old.mayPublish, "Retired provider must not publish its late image")
            Task { @MainActor in old.finishCallback(); returned.fulfill() }
        }
        await fulfillment(of: [entered], timeout: 2)
        old.retirePublication()
        XCTAssertTrue(gate.isBusy)
        XCTAssertNil(gate.acquire(), "A replacement sheet must not start another decode while the old callback is running")
        release.signal()
        await fulfillment(of: [returned], timeout: 2)
        let next = try XCTUnwrap(gate.acquire())
        defer { next.finishCallback() }
        old.finishCallback() // A duplicate late completion cannot release the next provider's slot.
        XCTAssertNil(gate.acquire())
        XCTAssertTrue(next.mayPublish)
    }
}
