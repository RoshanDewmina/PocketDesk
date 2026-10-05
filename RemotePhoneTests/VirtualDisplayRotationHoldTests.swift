import CoreVideo
import UIKit
import WebRTC
import XCTest
@testable import PocketDeskRemote

final class VirtualDisplayRotationHoldTests: XCTestCase {
    private func source(identity: VideoPresentationIdentity, lifetime: VideoPresentationLifetime, geometry: UInt64, width: Int, height: Int, time: Double) throws -> VideoPresentedSource {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return .init(lifetime: lifetime, envelope: .init(receiptID: UUID(), identity: identity,
            frame: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1),
            arrivalMs: 1, marker: nil, originalSource: true,
            videoTag: .init(generation: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32),
                geometryEpoch: geometry, scopeEpoch: 3, ltrToken: nil)), presentedAt: time, refinementPixels: nil)
    }
    @MainActor
    func testSeparateFrozenOwnerClearsSynchronouslyWithoutReopeningRetiredLiveLifetime() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "pair", sessionID: UUID(), trackID: UUID(), contentEpoch: 2, geometryEpoch: 7)
        let proof = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
        let holder = VirtualDisplayRotationHold(), mounted = UIImageView()
        holder.mount(mounted)
        holder.record(try source(identity: identity, lifetime: proof.lifetime, geometry: 7, width: 128, height: 256, time: now), admission: proof, scope: 3, display: 9, now: now)
        let begin = VirtualDisplayResizeBegin(token: String(repeating: "c", count: 32), display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: 256, pixelHeight: 128)
        XCTAssertTrue(holder.begin(begin, admission: proof, scope: 3, display: 9, routeDeadline: now + 20, now: now))
        XCTAssertNotNil(mounted.image); XCTAssertFalse(mounted.isHidden)
        proof.lifetime.retire()
        XCTAssertFalse(proof.permits(at: now)); XCTAssertTrue(holder.isHolding)
        holder.clear()
        XCTAssertNil(mounted.image); XCTAssertTrue(mounted.isHidden); XCTAssertFalse(holder.isHolding)
        holder.record(try source(identity: identity, lifetime: proof.lifetime, geometry: 7, width: 128, height: 256, time: now), admission: proof, scope: 3, display: 9, now: now)
        XCTAssertFalse(holder.begin(begin, admission: proof, scope: 3, display: 9, routeDeadline: now + 20, now: now))
    }
    @MainActor
    func testExpiryDropsMountedPixelsAndExactSuccessorPhysicalSourceRemovesOverlay() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let old = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "pair", sessionID: UUID(), trackID: UUID(), contentEpoch: 2, geometryEpoch: 7)
        let oldProof = VideoPresentationAdmission(identity: old, validUntil: now + 20)
        let holder = VirtualDisplayRotationHold(), mounted = UIImageView()
        holder.mount(mounted)
        holder.record(try source(identity: old, lifetime: oldProof.lifetime, geometry: 7, width: 128, height: 256, time: now), admission: oldProof, scope: 3, display: 9, now: now)
        let begin = VirtualDisplayResizeBegin(token: String(repeating: "c", count: 32), display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: 256, pixelHeight: 128)
        XCTAssertTrue(holder.begin(begin, admission: oldProof, scope: 3, display: 9, routeDeadline: now + 20, now: now))
        XCTAssertTrue(holder.bind(token: begin.token, epoch: 9, scope: 3, display: 9, current: old, now: now))
        oldProof.lifetime.retire()
        let next = VideoPresentationIdentity(hostRecordID: old.hostRecordID, ownerPairID: old.ownerPairID,
            sessionID: old.sessionID, trackID: old.trackID, contentEpoch: 3, geometryEpoch: 9)
        let nextProof = VideoPresentationAdmission(identity: next, validUntil: now + 20)
        holder.record(try source(identity: next, lifetime: nextProof.lifetime, geometry: 7, width: 256, height: 128, time: now), admission: nextProof, scope: 3, display: 9, now: now)
        XCTAssertNotNil(mounted.image)
        holder.record(try source(identity: next, lifetime: nextProof.lifetime, geometry: 9, width: 256, height: 128, time: now), admission: nextProof, scope: 3, display: 9, now: now)
        XCTAssertNil(mounted.image); XCTAssertTrue(mounted.isHidden); XCTAssertFalse(holder.isHolding)
        let expired = VirtualDisplayRotationHold(), expiredView = UIImageView()
        expired.mount(expiredView)
        expired.record(try source(identity: next, lifetime: nextProof.lifetime, geometry: 9, width: 256, height: 128, time: now), admission: nextProof, scope: 3, display: 9, now: now)
        let another = VirtualDisplayResizeBegin(token: String(repeating: "d", count: 32), display: 9, fromEpoch: 9, scopeEpoch: 3, pixelWidth: 128, pixelHeight: 256)
        XCTAssertTrue(expired.begin(another, admission: nextProof, scope: 3, display: 9, routeDeadline: now + 20, now: now))
        expired.expire(at: now + 2)
        XCTAssertNil(expiredView.image); XCTAssertTrue(expiredView.isHidden); XCTAssertFalse(expired.isHolding)
    }
    @MainActor
    func testQueuedOldSourceCannotEnterNewAdmissionWithIdenticalIdentity() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "pair", sessionID: UUID(), trackID: UUID(), contentEpoch: 2, geometryEpoch: 7)
        let old = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
        let queued = try source(identity: identity, lifetime: old.lifetime, geometry: 7, width: 128, height: 256, time: now)
        old.lifetime.retire()
        let replacement = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
        XCTAssertEqual(old.identity, replacement.identity)
        XCTAssertFalse(old.lifetime === replacement.lifetime)
        let holder = VirtualDisplayRotationHold(), mounted = UIImageView()
        holder.mount(mounted)
        holder.record(queued, admission: replacement, scope: 3, display: 9, now: now)
        let begin = VirtualDisplayResizeBegin(token: String(repeating: "c", count: 32), display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: 256, pixelHeight: 128)
        XCTAssertFalse(holder.begin(begin, admission: replacement, scope: 3, display: 9, routeDeadline: now + 20, now: now))
        XCTAssertNil(mounted.image); XCTAssertTrue(mounted.isHidden); XCTAssertFalse(holder.isHolding)
    }
    @MainActor
    func testCachedOldSourceCannotBeginAgainstReplacementLifetimeEvenWithIdenticalIdentity() throws {
        for retire in [false, true] {
            let now = ProcessInfo.processInfo.systemUptime
            let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "pair", sessionID: UUID(), trackID: UUID(), contentEpoch: 2, geometryEpoch: 7)
            let old = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
            let holder = VirtualDisplayRotationHold(), mounted = UIImageView()
            holder.mount(mounted)
            holder.record(try source(identity: identity, lifetime: old.lifetime, geometry: 7, width: 128, height: 256, time: now), admission: old, scope: 3, display: 9, now: now)
            if retire { old.lifetime.retire() }
            let replacement = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
            let begin = VirtualDisplayResizeBegin(token: String(repeating: "c", count: 32), display: 9, fromEpoch: 7, scopeEpoch: 3, pixelWidth: 256, pixelHeight: 128)
            XCTAssertFalse(holder.begin(begin, admission: replacement, scope: 3, display: 9, routeDeadline: now + 20, now: now))
            XCTAssertNil(mounted.image); XCTAssertTrue(mounted.isHidden); XCTAssertFalse(holder.isHolding)
        }
    }
    @MainActor
    func testPresentedReceiptPayloadCarriesItsExactOriginatingLifetime() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "pair", sessionID: UUID(), trackID: UUID(), contentEpoch: 2, geometryEpoch: 7)
        let proof = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
        let view = OwnedMetalVideoView(admission: proof, fence: VideoPresentationFence(proof))
        let fixture = try source(identity: identity, lifetime: proof.lifetime, geometry: 7, width: 128, height: 256, time: now)
        let delivered = expectation(description: "originating lifetime carried through presented receipt")
        let callback = view.presentedReceipt(fixture.envelope, callback: nil, sourceCallback: { payload in
            XCTAssertTrue(payload.lifetime === proof.lifetime)
            XCTAssertTrue(payload.lifetime.isActive)
            delivered.fulfill()
        })
        callback(now)
        wait(for: [delivered], timeout: 1)
        view.invalidate()
    }
    @MainActor
    func testActualSourceCallbackStillRejectsLatePixelsAfterItsFenceRetires() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "pair", sessionID: UUID(), trackID: UUID(), contentEpoch: 2, geometryEpoch: 7)
        let proof = VideoPresentationAdmission(identity: identity, validUntil: now + 20)
        let view = OwnedMetalVideoView(admission: proof, fence: VideoPresentationFence(proof))
        let payload = try source(identity: identity, lifetime: proof.lifetime, geometry: 7, width: 128, height: 256, time: now)
        let rejected = expectation(description: "late physical callback rejected"); rejected.isInverted = true
        let callback = view.presentedReceipt(payload.envelope, callback: nil, sourceCallback: { _ in rejected.fulfill() })
        proof.lifetime.retire(); view.invalidate(); callback(now)
        wait(for: [rejected], timeout: 0.1)
    }
}
