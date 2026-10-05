import XCTest

final class SessionVirtualDisplayPolicyTests: XCTestCase {
    func testSuccessfulExitReportsIdleOnlyAfterConfirmedOrdinaryCapture() {
        func phase(healthy: Bool = true, captured: UInt32? = 7, epoch: UInt64 = 18,
                   owned: Bool = false, restoring: Bool = false, recovery: Bool = false) -> WorkspaceBetaPhase {
            SessionVirtualDisplayPolicy.phase(recoveryPending: recovery, retirementPending: restoring,
                preparing: false, virtualSourceActive: false, workspaceOwned: owned, entryBlocked: true,
                ordinaryCaptureHealthy: healthy, capturedDisplayID: captured, selectedPhysicalDisplayID: 7, routeEpoch: epoch)
        }
        // Deliberate cancellation and automatic fallback keep the request fence closed,
        // but their confirmed fresh ordinary route must release the phone's exit gate.
        XCTAssertEqual(phase(), .idle)
        XCTAssertEqual(phase(healthy: false), .blocked, "Cleanup alone is not an ordinary picture")
        XCTAssertEqual(phase(captured: 900), .blocked, "The old virtual source cannot complete exit")
        XCTAssertEqual(phase(captured: nil), .blocked)
        XCTAssertEqual(phase(epoch: 0), .blocked)
        XCTAssertEqual(phase(owned: true), .blocked, "Owned windows must be confirmed retired")
        XCTAssertEqual(phase(restoring: true), .restoring, "Producer quarantine retains retirement")
        XCTAssertEqual(phase(recovery: true), .restoring, "An unresolved recovery journal cannot finish exit")
        XCTAssertEqual(SessionVirtualDisplayPolicy.phase(recoveryPending: false, retirementPending: false,
            preparing: false, virtualSourceActive: false, workspaceOwned: true, entryBlocked: false,
            ordinaryCaptureHealthy: true, capturedDisplayID: 7, selectedPhysicalDisplayID: 7, routeEpoch: 18), .blocked)
    }

    func testSuccessfulExitWireClearsVirtualRouteEvenAfterCapabilityWithdrawal() throws {
        let phase = SessionVirtualDisplayPolicy.phase(recoveryPending: false, retirementPending: false,
            preparing: false, virtualSourceActive: false, workspaceOwned: false, entryBlocked: true,
            ordinaryCaptureHealthy: true, capturedDisplayID: 7, selectedPhysicalDisplayID: 7, routeEpoch: 18)
        let status = SessionVirtualDisplayPolicy.activeStatus(sourceActive: false,
            experimentalPhonePeer: true, virtualDisplayAdvertised: false)
        let packet = RemoteAction(action: "capture", x: 1, epoch: 18, display: 7,
            virtualDisplayActive: status, virtualDisplayPhase: phase)
        try packet.validate()
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(packet))
        XCTAssertEqual(decoded.virtualDisplayPhase, .idle)
        XCTAssertEqual(decoded.virtualDisplayActive, false)
        XCTAssertEqual(decoded.epoch, 18)
        XCTAssertEqual(decoded.display, 7)
        XCTAssertNil(SessionVirtualDisplayPolicy.activeStatus(sourceActive: false,
            experimentalPhonePeer: false, virtualDisplayAdvertised: false), "Legacy bytes still omit unsupported status")
        XCTAssertEqual(SessionVirtualDisplayPolicy.activeStatus(sourceActive: true,
            experimentalPhonePeer: true, virtualDisplayAdvertised: false), true)
    }

    func testPhoneWorkspaceRequiresExplicitMarkerAndExperimentalAdmission() {
        var phone = VirtualDisplayViewport(width: 402, height: 874, scale: 3, maximumFPS: 60)
        XCTAssertFalse(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: phone))
        XCTAssertFalse(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: phone, experimentalPhoneEnabled: true))
        phone.experimentalPhoneWorkspace = false
        XCTAssertFalse(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: phone, experimentalPhoneEnabled: true))
        phone.experimentalPhoneWorkspace = true
        XCTAssertFalse(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: phone))
        XCTAssertTrue(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: phone, experimentalPhoneEnabled: true))
    }

    func testExperimentalAdmissionPreservesIPadAndRejectsInvalidPhoneGeometry() throws {
        var pad = VirtualDisplayViewport(width: 1024, height: 768, scale: 2, maximumFPS: 60)
        pad.iPadWorkspace = true
        XCTAssertTrue(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: pad))
        var invalid = VirtualDisplayViewport(width: 403, height: 874, scale: 3, maximumFPS: 60)
        invalid.experimentalPhoneWorkspace = true
        XCTAssertFalse(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: invalid, experimentalPhoneEnabled: true))
        let decoded = try JSONDecoder().decode(VirtualDisplayViewport.self, from: JSONEncoder().encode(invalid))
        XCTAssertEqual(decoded.experimentalPhoneWorkspace, true)
        XCTAssertFalse(SessionVirtualDisplayPolicy.permitsWorkspace(viewport: decoded, experimentalPhoneEnabled: true))
    }

    func testIPadHandshakeRetainsLegacyBoundsAndDoesNotChangePhoneOrRefinement() throws {
        let phone = MacShareBlocker.Handshake.phoneRequest([])
        XCTAssertEqual(phone.features, MacShareBlocker.Handshake.phone.features)
        XCTAssertFalse(phone.requested.contains(SessionFeature.ipadWorkspace))
        let pad = MacShareBlocker.Handshake.phoneRequest([], requestsIPadWorkspace: true)
        XCTAssertEqual(pad.features.count, 8)
        XCTAssertEqual(pad.options, phone.options)
        XCTAssertEqual(MacShareBlocker.Handshake.features(in: try JSONEncoder().encode(pad)), pad.requested)
        XCTAssertTrue(pad.requested.contains(SessionFeature.ipadWorkspace))
        let refinement = MacShareBlocker.Handshake.phoneRequest([SessionFeature.videoRefinement], requestsIPadWorkspace: true)
        XCTAssertEqual(refinement.features.count, 8)
        XCTAssertTrue(refinement.requested.contains(SessionFeature.videoRefinement))
        XCTAssertFalse(refinement.requested.contains(SessionFeature.ipadWorkspace))
    }

    func testWorkspaceViewportProvenanceSurvivesWireAndLegacyViewportDoesNotOptIn() throws {
        let legacy = VirtualDisplayViewport(width: 1024, height: 768, scale: 2, maximumFPS: 60)
        XCTAssertNil(try JSONDecoder().decode(VirtualDisplayViewport.self, from: JSONEncoder().encode(legacy)).iPadWorkspace)
        XCTAssertNil(try JSONDecoder().decode(VirtualDisplayViewport.self, from: JSONEncoder().encode(legacy)).experimentalPhoneWorkspace)
        var pad = legacy; pad.iPadWorkspace = true
        XCTAssertEqual(try JSONDecoder().decode(VirtualDisplayViewport.self, from: JSONEncoder().encode(pad)).iPadWorkspace, true)
    }

    func testContentBarcodeRoundTripsKnownFramesAndRejectsPlainBackgroundAndMissingPixels() {
        for frame in [UInt32(0), 0x010203, 0xFFFFFF, 0x12345678] {
            XCTAssertEqual(SessionVirtualDisplayBarcode.decode {
                SessionVirtualDisplayBarcode.white(slot: $0, frame: frame)
            }, frame & 0xFFFFFF)
        }
        XCTAssertNil(SessionVirtualDisplayBarcode.decode { _ in true })
        XCTAssertNil(SessionVirtualDisplayBarcode.decode { _ in false })
        XCTAssertNil(SessionVirtualDisplayBarcode.decode { slot in
            slot == 10 ? nil : SessionVirtualDisplayBarcode.white(slot: slot, frame: 0x010203)
        })
    }

    func testThreeTimesPhoneUsesExactBackingPixelsAndTwoTimesMacPoints() throws {
        let viewport = VirtualDisplayViewport(width: 402, height: 874, scale: 3, maximumFPS: 120)
        try viewport.validate()
        let spec = try XCTUnwrap(VirtualDisplaySpecification(viewport: viewport))
        XCTAssertEqual(viewport.pixelWidth, 1206)
        XCTAssertEqual(viewport.pixelHeight, 2622)
        XCTAssertEqual(spec.width, 1206)
        XCTAssertEqual(spec.height, 2622)
        XCTAssertEqual(spec.logicalWidth, 603)
        XCTAssertEqual(spec.logicalHeight, 1311)
        XCTAssertEqual(spec.refreshHz, 120)
    }

    func testRotationPreservesPixelBudgetAndTwoTimesTabletUsesPhonePoints() throws {
        let portrait = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 1024, height: 1366, scale: 2, maximumFPS: 60)))
        let landscape = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 1366, height: 1024, scale: 2, maximumFPS: 60)))
        XCTAssertEqual(portrait.width, landscape.height)
        XCTAssertEqual(portrait.height, landscape.width)
        XCTAssertEqual(portrait.logicalWidth, 1024)
        XCTAssertEqual(portrait.logicalHeight, 1366)
        XCTAssertEqual(portrait.refreshHz, 60)
    }

    func testSixtyHzFallbackPreservesExactPixelAndLogicalGeometry() throws {
        let spec = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 640, height: 360, scale: 2, maximumFPS: 120)))
        let fallback = spec.at60Hz
        XCTAssertEqual(fallback.width, 1280)
        XCTAssertEqual(fallback.height, 720)
        XCTAssertEqual(fallback.logicalWidth, spec.logicalWidth)
        XCTAssertEqual(fallback.logicalHeight, spec.logicalHeight)
        XCTAssertEqual(fallback.refreshHz, 60)
        XCTAssertEqual(fallback.at60Hz, fallback)
    }

    func testMalformedAndExcessiveRequestsFailClosedWithoutRounding() {
        let invalid: [VirtualDisplayViewport] = [
            .init(width: .nan, height: 874, scale: 3, maximumFPS: 120),
            .init(width: 402, height: .infinity, scale: 3, maximumFPS: 120),
            .init(width: 402, height: 874, scale: .nan, maximumFPS: 120),
            .init(width: 0, height: 874, scale: 3, maximumFPS: 120),
            .init(width: 402, height: 874, scale: 0, maximumFPS: 120),
            .init(width: 402, height: 874, scale: 4, maximumFPS: 120),
            .init(width: 403, height: 874, scale: 3, maximumFPS: 120),
            .init(width: 402.1, height: 874, scale: 3, maximumFPS: 120),
            .init(width: 4096, height: 4096, scale: 3, maximumFPS: 120),
            .init(width: 3000, height: 3000, scale: 2, maximumFPS: 120),
            .init(width: Double.greatestFiniteMagnitude, height: 874, scale: 3, maximumFPS: 120),
            .init(width: 402, height: 874, scale: 3, maximumFPS: 30),
            .init(width: 402, height: 874, scale: 3, maximumFPS: 121)
        ]
        for viewport in invalid {
            XCTAssertThrowsError(try viewport.validate())
            XCTAssertNil(VirtualDisplaySpecification(viewport: viewport))
        }
    }

    func testFractionalPhonePointsAreAllowedOnlyForExactEvenPixelsAndRateStaysBelowMaximum() throws {
        let spec = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 402 + 2.0 / 3, height: 874, scale: 3, maximumFPS: 90)))
        XCTAssertEqual(spec.width, 1208)
        XCTAssertEqual(spec.refreshHz, 60)
    }

    func testWireRoundTripStillRequiresValidation() throws {
        let value = VirtualDisplayViewport(width: 402, height: 874, scale: 3, maximumFPS: 120)
        XCTAssertEqual(try JSONDecoder().decode(VirtualDisplayViewport.self, from: JSONEncoder().encode(value)), value)
        let invalid = Data(#"{"width":403,"height":874,"scale":3,"maximumFPS":120}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(VirtualDisplayViewport.self, from: invalid).validate())
    }

    func testModeAdmissionRejectsOneTimesWrongBackingWrongRateAndNonfiniteRate() throws {
        let spec = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 402, height: 874, scale: 3, maximumFPS: 120)))
        XCTAssertTrue(spec.matches(logicalWidth: 603, logicalHeight: 1311, pixelWidth: 1206, pixelHeight: 2622, refreshHz: 120))
        XCTAssertFalse(spec.matches(logicalWidth: 1206, logicalHeight: 2622, pixelWidth: 1206, pixelHeight: 2622, refreshHz: 120))
        XCTAssertFalse(spec.matches(logicalWidth: 603, logicalHeight: 1311, pixelWidth: 1208, pixelHeight: 2622, refreshHz: 120))
        XCTAssertFalse(spec.matches(logicalWidth: 603, logicalHeight: 1311, pixelWidth: 1206, pixelHeight: 2622, refreshHz: 60))
        XCTAssertFalse(spec.matches(logicalWidth: 603, logicalHeight: 1311, pixelWidth: 1206, pixelHeight: 2622, refreshHz: .nan))
    }

    func testAdvertisementStartsWithRequestedRasterAndLogicalModesAndFitsReservedCaps() throws {
        let spec = try XCTUnwrap(VirtualDisplaySpecification(viewport: .init(width: 402, height: 874, scale: 3, maximumFPS: 120)))
        let modes = spec.advertisedModes
        XCTAssertEqual(modes.prefix(2).map { [$0.width, $0.height] }, [[1206, 2622], [603, 1311]])
        XCTAssertTrue(modes.allSatisfy { $0.width <= VirtualDisplaySpecification.maximumAxisPixels && $0.height <= VirtualDisplaySpecification.maximumAxisPixels })
        XCTAssertEqual(Set(modes), Set(modes.filter { $0.refreshHz == 120 }))
        XCTAssertEqual(Set(modes).count, modes.count)
    }

    func testModeSelectionRequiresRetainedOnlineIdentityAndCannotTargetMainOrMirror() {
        XCTAssertTrue(SessionVirtualDisplayOwnership.permitsModeChange(requestedID: 9, retainedID: 9, online: true, identityMatches: true, isMain: false, isMirrored: false))
        for values in [(UInt32(0), UInt32(0), true, true, false, false), (9, 10, true, true, false, false),
                       (9, 9, false, true, false, false), (9, 9, true, false, false, false),
                       (9, 9, true, true, true, false), (9, 9, true, true, false, true)] {
            XCTAssertFalse(SessionVirtualDisplayOwnership.permitsModeChange(requestedID: values.0, retainedID: values.1, online: values.2,
                identityMatches: values.3, isMain: values.4, isMirrored: values.5))
        }
    }
}
