import XCTest
@testable import PocketDeskRemote

@MainActor
final class AwayPhoneTests: XCTestCase {
    private func deliver(_ action: RemoteAction, to model: PhoneRemoteModel) throws {
        model.connection.onControl?(try JSONEncoder().encode(action))
    }

    private func encoded(_ action: RemoteAction) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(action)
    }

    /// A connected model whose sends are recorded instead of leaving the phone.
    private func liveModel(features: [String], control: Bool) throws -> (PhoneRemoteModel, () -> [RemoteAction]) {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())
        var sent: [RemoteAction] = []
        model.controlSendOverride = { sent.append($0); return true }
        model.connection.connected = true
        try deliver(RemoteAction(action: "geometry", x: 1440, y: 900, epoch: 7), to: model)
        try deliver(RemoteAction(action: "capture", x: 1, epoch: 7, features: features), to: model)
        try deliver(RemoteAction(action: "viewing", x: control ? 1 : 0, epoch: 7), to: model)
        return (model, { sent })
    }

    func testAwayStateIsReadOnlyFromAMacThatAdvertisesIt() throws {
        let model = PhoneRemoteModel(background: FakeBackgroundExecution())

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: SessionFeature.host,
                                 away: AwayModeState.covered.rawValue), to: model)
        XCTAssertFalse(model.awaySupported)
        XCTAssertNil(model.awayState, "A Mac that does not advertise Away mode reports nothing")

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: [SessionFeature.away],
                                 away: AwayModeState.covered.rawValue), to: model)
        XCTAssertTrue(model.awaySupported)
        XCTAssertEqual(model.awayState, .covered)

        try deliver(RemoteAction(action: "capture", x: 1, epoch: 1, features: [SessionFeature.away],
                                 away: "somethingNew"), to: model)
        XCTAssertEqual(model.awayState, .off, "Unknown future states read as off")
    }

    func testEndAndLockSendsLockMacOnlyWithControl() throws {
        let (model, sent) = try liveModel(features: [SessionFeature.away], control: true)
        XCTAssertTrue(model.canLockMac)
        XCTAssertTrue(model.endAndLockMac())
        let locks = sent().filter { $0.action == "lockMac" }
        XCTAssertEqual(locks.count, 1)
        let action = try XCTUnwrap(locks.first)
        XCTAssertEqual(action.action, "lockMac")
        XCTAssertEqual(action.epoch, 7)
        XCTAssertEqual(try encoded(action), try encoded(RemoteAction(action: "lockMac", epoch: 7)),
                       "Nothing but the action and the epoch")
        XCTAssertNoThrow(try action.validate())

        let (viewOnly, viewOnlySent) = try liveModel(features: [SessionFeature.away], control: false)
        XCTAssertFalse(viewOnly.canLockMac)
        XCTAssertFalse(viewOnly.endAndLockMac())
        XCTAssertFalse(viewOnlySent().contains { $0.action == "lockMac" }, "A view-only session cannot lock the Mac")

        let (older, olderSent) = try liveModel(features: SessionFeature.host, control: true)
        XCTAssertFalse(older.canLockMac)
        XCTAssertFalse(older.endAndLockMac())
        XCTAssertFalse(olderSent().contains { $0.action == "lockMac" }, "A Mac without Away mode never receives lockMac")
    }

    func testSessionEndsLocallyIfTheMacDoesNotWithinFiveSeconds() async throws {
        XCTAssertEqual(PhoneRemoteModel.lockEndGrace, 5)
        PhoneRemoteModel.lockEndGrace = 0.1
        addTeardownBlock { @MainActor in PhoneRemoteModel.lockEndGrace = 5 }

        let (model, _) = try liveModel(features: [SessionFeature.away], control: true)
        XCTAssertTrue(model.endAndLockMac())
        XCTAssertTrue(model.connection.connected, "The Mac gets its chance to end the session first")

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.connection.connected)
        XCTAssertEqual(model.sessionSnapshot.endReason, .user)
    }

    func testLockedNoticeMentionsAwayOnlyWhenItWasOn() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let today = PhoneRemoteModel.notice(for: .locked, at: date)
        XCTAssertEqual(PhoneRemoteModel.notice(for: .locked, at: date, awayWasOn: false), today)
        let away = PhoneRemoteModel.notice(for: .locked, at: date, awayWasOn: true)
        XCTAssertTrue(away.hasSuffix("Away mode can’t unlock it."))
        XCTAssertEqual(away, today + " Away mode can’t unlock it.")
        XCTAssertEqual(PhoneRemoteModel.notice(for: .sleeping, at: date, awayWasOn: true),
                       PhoneRemoteModel.notice(for: .sleeping, at: date), "Only a lock mentions Away mode")
    }

    func testLockedDepartureCarriesAwayIntoTheErrorPeopleSee() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let suffix = PhoneSessionNotice.awayCantUnlock

        let away = try XCTUnwrap(MacDeparture(notice: PhoneRemoteModel.notice(for: .locked, at: date, awayWasOn: true)))
        XCTAssertEqual(away.kind, .locked)
        XCTAssertTrue(away.awayWasOn)
        let awayError = try XCTUnwrap(FriendlyError.from(presence: away.kind, at: away.time, awayWasOn: away.awayWasOn))
        XCTAssertTrue(awayError.message.hasSuffix(suffix))

        let plain = try XCTUnwrap(MacDeparture(notice: PhoneRemoteModel.notice(for: .locked, at: date)))
        XCTAssertFalse(plain.awayWasOn)
        let plainError = try XCTUnwrap(FriendlyError.from(presence: plain.kind, at: plain.time, awayWasOn: plain.awayWasOn))
        XCTAssertEqual(plainError.message, FriendlyError.locked(since: plain.time).message, "Unchanged without Away mode")
        XCTAssertFalse(plainError.message.contains(suffix))
    }

    func testAwayMemoryIsPerMacAndForgettable() {
        let defaults = makeTestDefaults()
        let memory = AwayMemory(defaults: defaults)
        let roomA = "r_studio_mac_room_aaaaaaaaaaaa"
        let roomB = "r_laptop_room_bbbbbbbbbbbbbbbb"

        XCTAssertFalse(memory.wasOn(forRoom: roomA))
        memory.remember(.covered, forRoom: roomA)
        XCTAssertTrue(memory.wasOn(forRoom: roomA))
        XCTAssertFalse(memory.wasOn(forRoom: roomB))
        XCTAssertTrue(AwayMemory(defaults: defaults).wasOn(forRoom: roomA), "It survives a relaunch")

        memory.remember(.armed, forRoom: roomB)
        for (key, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse(key.contains(roomA) || key.contains(roomB), "Stored keys never name the Mac's room")
            XCTAssertFalse("\(value)".contains(roomA) || "\(value)".contains(roomB))
        }

        memory.remember(.off, forRoom: roomA)
        XCTAssertFalse(memory.wasOn(forRoom: roomA))
        XCTAssertTrue(memory.wasOn(forRoom: roomB))

        memory.remember(.covered, forRoom: roomA)
        memory.forget(room: roomA)
        XCTAssertFalse(memory.wasOn(forRoom: roomA))
        XCTAssertTrue(memory.wasOn(forRoom: roomB), "Forgetting one Mac keeps the others")
    }
}
