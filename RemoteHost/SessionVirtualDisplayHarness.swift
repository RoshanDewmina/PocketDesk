#if DEBUG
import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Isolated synthetic-content measurement entry point. Parent owns bootstrap/argument dispatch.
/// This type does not initialize HostModel or access any user's app window.
@MainActor
enum SessionVirtualDisplayHarness {
    static func run(arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let harnessArguments = Array(arguments.dropFirst())
        guard harnessArguments.count == 3,
              harnessArguments[0] == "--session-virtual-display",
              harnessArguments[1] == "--session-virtual-display-output",
              !harnessArguments[2].isEmpty else {
            print("SESSION-VD-HARNESS: error=invalid-or-mixed-harness-arguments")
            return 2
        }
        let quietGrant = "/Users/roshansilva/Documents/Codex/2026-10-01/testing/QUIET-GRANTED-b8-vdisplay"
        guard FileManager.default.fileExists(atPath: quietGrant) else {
            print("SESSION-VD-HARNESS: error=missing-exact-quiet-grant")
            return 2
        }
        guard CGPreflightScreenCaptureAccess() else {
            print("SESSION-VD-HARNESS: error=screen-recording-not-already-granted; no prompt requested")
            return 2
        }
        let app = NSApplication.shared
        app.delegate = nil
        app.setActivationPolicy(.accessory)
        let controller = SessionVirtualDisplayHarnessController(outputDirectory: URL(fileURLWithPath: harnessArguments[2], isDirectory: true))
        controller.start()
        app.run()
        return controller.exitCode
    }
}

@MainActor
private final class SessionVirtualDisplayHarnessController: NSObject {
    private let outputDirectory: URL
    private let quietGrantURL = URL(fileURLWithPath: "/Users/roshansilva/Documents/Codex/2026-10-01/testing/QUIET-GRANTED-b8-vdisplay")
    private let adapter = SessionVirtualDisplay()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var window: NSWindow?
    private var fixture: SessionVirtualDisplayFixtureView?
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private let lastOutputTime = HarnessLockedValue<Double?>(nil)
    private var stopping = false
    private var adapterStopped = false
    private var adapterStopInFlight = false
    private var adapterStopWaiters: [CheckedContinuation<Void, Never>] = []
    private var adapterStopError: String?
    private var activeStream: SCStream?
    private var activeStreamStarting = false
    private var activeStreamStarted = false
    private var activeStreamStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeStreamStopInFlight = false
    private var activeStreamStopWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeStreamStopError: String?
    private var captureStopError: String?
    private var report: [String: Any] = ["schema": 1, "harness": "synthetic-session-virtual-display"]
    private(set) var exitCode: Int32 = 0

    init(outputDirectory: URL) { self.outputDirectory = outputDirectory; super.init() }

    func start() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory.appendingPathComponent("shots", isDirectory: true),
                                                    withIntermediateDirectories: true)
        } catch { finish(error: "output-directory: \(error)"); return }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.stop(reason: "signal-\(number)") } }
            source.resume(); signalSources.append(source)
        }
        Task { await measure() }
    }

    private func measure() async {
        let started = Date()
        report["startedAt"] = ISO8601DateFormatter().string(from: started)
        report["requestedSeparately"] = ["captureDelivery": "ScreenCaptureKit output only", "encode": "not measured",
                                         "networkDelivery": "not measured", "phonePresentation": "not measured"]
        do {
            let tuning = StreamTuning.current
            report["streamTuning"] = tuning.liveSummary
            report["representativeCaptureProfile"] = ["quality": StreamQuality.sharp.rawValue,
                "codecBudget": "representative H.264 level 5.2", "level": 52, "targetFPS": 60,
                "actuallyNegotiated": false, "encodedOrDelivered": false]
            let phonePortrait = VirtualDisplayViewport(width: 402, height: 874, scale: 3, maximumFPS: 120)
            let phoneLandscape = VirtualDisplayViewport(width: 874, height: 402, scale: 3, maximumFPS: 120)
            let ipadPortrait = VirtualDisplayViewport(width: 820, height: 1180, scale: 2, maximumFPS: 60)
            for viewport in [phonePortrait, phoneLandscape, ipadPortrait] { try viewport.validate() }
            report["viewports"] = ["iphone17Portrait": viewportJSON(phonePortrait),
                                   "iphone17Landscape": viewportJSON(phoneLandscape),
                                   "ipadAir5Portrait": viewportJSON(ipadPortrait)]

            guard let physical = NSScreen.screens.first(where: { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value) != 0
            }) else { throw HarnessFailure("built-in-physical-reference-screen-unavailable") }
            guard let physicalID = screenDisplayID(physical), CGDisplayIsInMirrorSet(physicalID) == 0 else {
                throw HarnessFailure("built-in-reference-is-mirrored-or-has-no-display-id")
            }
            report["physicalReference"] = ["displayID": physicalID,
                "backingScaleFactor": physical.backingScaleFactor, "wholeDisplayCapture": true,
                "fixtureWindowOnlyContent": true]
            try await showFixture(on: physical)
            startTimer()
            fixture?.freeze(at: 0x10203)
            let physicalContent = try await shareableContent()
            guard let physicalDisplay = physicalContent.displays.first(where: { $0.displayID == physicalID }) else {
                throw HarnessFailure("built-in-screen-unavailable-to-screencapturekit")
            }
            report["physicalBaseline"] = try await capturePhysicalBaseline(
                viewport: phonePortrait, screen: physical, display: physicalDisplay, tuning: tuning)

            fixture?.unfreeze()
            let portraitDisplay = try await prepare(phonePortrait)
            try await showFixture(on: screen(for: portraitDisplay))
            fixture?.freeze(at: 0x10203)
            let portraitConfiguration = try virtualConfiguration(phonePortrait, fps: 60, tuning: tuning)
            report["portraitStill"] = try await captureProvenWholeDisplayStill(label: "phone-portrait-still",
                display: portraitDisplay, fps: 60, stillName: "iphone17-portrait.png", configuration: portraitConfiguration,
                width: portraitConfiguration.width, height: portraitConfiguration.height,
                barcodeScaleX: 2, barcodeScaleY: 2,
                barcodeOriginX: Double(portraitDisplay.width) / 2 - 18, barcodeOriginY: 5)
            guard hasLiveFixture(on: portraitDisplay.displayID) else { throw HarnessFailure("still-composite-invalidated") }
            try createSideBySide(
                outputDirectory.appendingPathComponent("shots/physical-phone-fill-baseline.png"),
                outputDirectory.appendingPathComponent("shots/iphone17-portrait.png"),
                outputDirectory.appendingPathComponent("shots/side-by-side.png"))
            report["edgeGradientComparison"] = compareEdgeMetric(
                outputDirectory.appendingPathComponent("shots/physical-phone-fill-baseline.png"),
                outputDirectory.appendingPathComponent("shots/iphone17-portrait.png"))
            fixture?.unfreeze()
            report["phonePortrait60"] = try await observe("iphone17-portrait-60", viewport: phonePortrait,
                display: portraitDisplay, fps: 60)
            report["phonePortrait120"] = try await observe("iphone17-portrait-120", viewport: phonePortrait,
                display: portraitDisplay, fps: 120)

            let oldOutput = lastOutputTime.value
            let resizeStarted = MachClock.nowMs()
            let landscapeDisplay = try await prepare(phoneLandscape)
            try await showFixture(on: screen(for: landscapeDisplay))
            let landscape60 = try await observe("iphone17-landscape-60", viewport: phoneLandscape,
                display: landscapeDisplay, fps: 60)
            let firstNewOutput = landscape60["firstCompleteCallbackMs"] as? Double
            var landscape120 = try await observe("iphone17-landscape-120", viewport: phoneLandscape,
                display: landscapeDisplay, fps: 120)
            landscape120["provedStill"] = try await captureProvenWholeDisplayStill(label: "iphone17-landscape-still",
                display: landscapeDisplay, fps: 120, stillName: "iphone17-landscape.png",
                configuration: try virtualConfiguration(phoneLandscape, fps: 120, tuning: tuning),
                width: phoneLandscape.pixelWidth, height: phoneLandscape.pixelHeight,
                barcodeScaleX: 2, barcodeScaleY: 2,
                barcodeOriginX: Double(VirtualDisplaySpecification(viewport: phoneLandscape)!.logicalWidth) / 2 - 18,
                barcodeOriginY: 5)
            report["portraitToLandscape"] = ["adapterObjectReused": true,
                "lastOldToPrepareStartMs": oldOutput.map { resizeStarted - $0 } as Any? ?? NSNull(),
                "prepareStartToFirstNewOutputMs": firstNewOutput.map { $0 - resizeStarted } as Any? ?? NSNull(),
                "lastOldToFirstNewOutputMs": (oldOutput != nil && firstNewOutput != nil) ? firstNewOutput! - oldOutput! : NSNull(),
                "landscape60": landscape60, "landscape120": landscape120]

            let ipadDisplay = try await prepare(ipadPortrait)
            try await showFixture(on: screen(for: ipadDisplay))
            var ipad = try await observe("ipad-air-5-60", viewport: ipadPortrait,
                display: ipadDisplay, fps: 60)
            ipad["provedStill"] = try await captureProvenWholeDisplayStill(label: "ipad-air-5-still",
                display: ipadDisplay, fps: 60, stillName: "ipad-air-5.png",
                configuration: try virtualConfiguration(ipadPortrait, fps: 60, tuning: tuning),
                width: ipadPortrait.pixelWidth, height: ipadPortrait.pixelHeight,
                barcodeScaleX: 2, barcodeScaleY: 2,
                barcodeOriginX: ipadPortrait.width / 2 - 18, barcodeOriginY: 5)
            report["ipadAir5_60"] = ipad
            await stop(reason: "complete")
            report["elapsedSeconds"] = Date().timeIntervalSince(started)
            if let captureStopError {
                finish(error: "capture-retirement-unverified: \(captureStopError)")
            } else if let adapterStopError {
                finish(error: "owned-display-removal-unverified: \(adapterStopError)")
            } else {
                finish(error: nil)
            }
        } catch {
            await stop(reason: "failure")
            let captureCleanup = captureStopError.map { "; capture-retirement-unverified: \($0)" } ?? ""
            let displayCleanup = adapterStopError.map { "; owned-display-removal-unverified: \($0)" } ?? ""
            finish(error: "\(error)\(captureCleanup)\(displayCleanup)")
        }
    }

    private func prepare(_ viewport: VirtualDisplayViewport) async throws -> SCDisplay {
        guard !stopping, let requestedSpec = VirtualDisplaySpecification(viewport: viewport) else {
            throw HarnessFailure("stopped-or-invalid-viewport")
        }
        let isCurrent = { [weak self] in self.map { !$0.stopping } ?? false }
        let prepared: SCDisplay
        var acceptedSpec = requestedSpec
        var refreshFallbackReason: String?
        do {
            prepared = try await adapter.prepare(requestedSpec, whileCurrent: isCurrent)
        } catch {
            let reason = String(describing: error)
            guard requestedSpec.refreshHz == 120,
                  reason.contains("virtual display mode/discovery deadline"),
                  isCurrent(), let ownedID = adapter.displayID, adapter.isOwnedDisplay(ownedID),
                  adapter.physicalTopologyUnchanged else { throw error }
            acceptedSpec = requestedSpec.at60Hz
            refreshFallbackReason = reason
            prepared = try await adapter.prepare(acceptedSpec, whileCurrent: isCurrent)
        }
        let content = try await shareableContent()
        guard let mode = CGDisplayCopyDisplayMode(prepared.displayID) else {
            throw HarnessFailure("owned-display-mode-or-screen-missing")
        }
        let screen = try screen(for: prepared)
        let actualMode = ["logicalWidth": mode.width, "logicalHeight": mode.height,
                          "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight,
                          "refreshHz": mode.refreshRate, "backingScaleFactor": screen.backingScaleFactor] as [String: Any]
        var modes = report["preparedModes"] as? [String: Any] ?? [:]
        modes["\(viewport.width)x\(viewport.height)"] = actualMode
        report["preparedModes"] = modes
        var refreshModes = report["refreshAcceptance"] as? [String: Any] ?? [:]
        refreshModes["\(viewport.width)x\(viewport.height)"] = [
            "requestedModeRefreshHz": requestedSpec.refreshHz,
            "acceptedModeRefreshHz": acceptedSpec.refreshHz,
            "fallbackReason": refreshFallbackReason as Any? ?? NSNull(),
            "captureFPSRequests": viewport.maximumFPS == 120 ? [60, 120] : [60],
            "phonePresentedFPS": NSNull()
        ] as [String: Any]
        report["refreshAcceptance"] = refreshModes
        guard let display = content.displays.first(where: { $0.displayID == prepared.displayID }),
              display.width == acceptedSpec.logicalWidth, display.height == acceptedSpec.logicalHeight,
              mode.width == acceptedSpec.logicalWidth, mode.height == acceptedSpec.logicalHeight,
              mode.pixelWidth == acceptedSpec.width, mode.pixelHeight == acceptedSpec.height,
              abs(mode.refreshRate - Double(acceptedSpec.refreshHz)) < 0.5,
              abs(screen.backingScaleFactor - 2) < 0.01 else {
            throw HarnessFailure("shareable-display-points-do-not-match-request")
        }
        return display
    }

    private func capturePhysicalBaseline(viewport: VirtualDisplayViewport, screen: NSScreen,
                                         display: SCDisplay, tuning: StreamTuning) async throws -> [String: Any] {
        guard let id = screenDisplayID(screen), id == display.displayID,
              CGDisplayIsBuiltin(id) != 0, CGDisplayIsInMirrorSet(id) == 0,
              let window, let fixture, window.screen === screen, window.isVisible,
              window.level == .screenSaver, window.isOpaque, window.alphaValue == 1,
              rectClose(window.frame, screen.frame), rectClose(fixture.bounds, CGRect(origin: .zero, size: screen.frame.size)),
              display.width == Int(screen.frame.width), display.height == Int(screen.frame.height),
              let mode = CGDisplayCopyDisplayMode(id) else {
            throw HarnessFailure("physical-fixture-does-not-provenly-cover-exact-built-in-frame")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let sourceSize = CGSize(width: display.width, height: display.height)
        let pointScale = Double(filter.pointPixelScale)
        guard filter.contentRect.width == sourceSize.width, filter.contentRect.height == sourceSize.height,
              pointScale.isFinite, pointScale > 0 else { throw HarnessFailure("physical-filter-geometry-invalid") }
        let phoneLongEdge = max(viewport.pixelWidth, viewport.pixelHeight)
        guard let output = RemoteCaptureConfiguration.outputSize(contentSize: sourceSize, pointPixelScale: pointScale,
                quality: .sharp, budget: .level(52), fps: 60, clientLongEdge: phoneLongEdge, tuning: tuning) else {
            throw HarnessFailure("physical-reference-output-size-rejected-by-current-capture-policy")
        }
        let configuration = RemoteCaptureConfiguration.streamConfiguration(output: output, region: nil,
            showsCursor: false, fps: 60, displayRefreshHz: mode.refreshRate, tuning: tuning)

        let content = try await shareableContent()
        let (ownedWindow, windowDisplayID) = try ownWindow(in: content)
        guard windowDisplayID == id else { throw HarnessFailure("physical-fixture-window-not-on-built-in-display") }
        var geometry: [String: Any] = ["displayID": id, "sourceLogicalPoints": [display.width, display.height],
            "physicalModePixels": [mode.pixelWidth, mode.pixelHeight], "physicalModeRefreshHz": mode.refreshRate,
            "screenBackingScaleFactor": screen.backingScaleFactor, "sckPointPixelScale": pointScale,
            "fixtureWindowFrame": rectJSON(window.frame), "physicalFrame": rectJSON(screen.frame),
            "windowLevel": window.level.rawValue, "windowIsOpaque": window.isOpaque, "windowAlpha": window.alphaValue,
            "fixtureCoverage": "exact AppKit frame plus whole-display pixels must equal own-window capture"]
        let windowMetrics = try await capture(label: "physical-window-coverage-proof", filter: SCContentFilter(desktopIndependentWindow: ownedWindow),
            displayID: id, fps: 60, seconds: 1, stillName: "physical-window-coverage-proof.png", configuration: configuration,
            width: output.width, height: output.height, barcodeScaleX: Double(output.width) / Double(display.width),
            barcodeScaleY: Double(output.height) / Double(display.height),
            barcodeOriginX: Double(screen.frame.width / 2 - 18), barcodeOriginY: 5)
        let proofURL = outputDirectory.appendingPathComponent("shots/physical-window-coverage-proof.png")
        guard let proof = image(at: proofURL),
              hasCornerMarkers(proof, scaleX: Double(output.width) / Double(display.width),
                                      scaleY: Double(output.height) / Double(display.height)) else {
            throw HarnessFailure("physical-own-window-content-proof-invalid")
        }
        let wholeMetrics = try await capture(label: "physical-whole-display-raw-proof", filter: filter,
            displayID: id, fps: 60, seconds: 1, stillName: "physical-source-raw.png", configuration: configuration,
            width: output.width, height: output.height, barcodeScaleX: Double(output.width) / Double(display.width),
            barcodeScaleY: Double(output.height) / Double(display.height), barcodeOriginX: Double(screen.frame.width / 2 - 18),
            barcodeOriginY: 5, mustMatchImageAtURL: proofURL,
            requiresCornerMarkers: true)
        let wholeURL = outputDirectory.appendingPathComponent("shots/physical-source-raw.png")
        guard let whole = image(at: wholeURL), let proof = image(at: proofURL), samePixels(whole, proof),
              hasCornerMarkers(whole, scaleX: Double(output.width) / Double(display.width),
                                     scaleY: Double(output.height) / Double(display.height)) else {
            throw HarnessFailure("physical-whole-display-pixels-not-proven-to-be-only-the-owned-fixture")
        }

        var fill = ViewportTransform(sourceSize: sourceSize,
            canvasSize: CGSize(width: viewport.width, height: viewport.height), mode: .fill)
        let request = fill.captureRequest(displayScale: CGFloat(viewport.scale))
        guard let request else { throw HarnessFailure("physical-fill-capture-request-invalid") }
        let viewportRegion = request.region(epoch: 1)
        let displayGeometry = DisplayGeometry(size: sourceSize, pointPixelScale: pointScale)
        let appliedRegion = ViewportCapturePolicy.region(for: viewportRegion, display: displayGeometry,
            output: output, tuning: tuning, previous: nil)
        guard (try? appliedRegion.validate()) != nil else { throw HarnessFailure("physical-current-viewport-region-invalid") }
        let regionOutput = CapturePixelDimensions(width: appliedRegion.outputWidth, height: appliedRegion.outputHeight)
        let regionConfiguration = RemoteCaptureConfiguration.streamConfiguration(output: regionOutput,
            region: appliedRegion, showsCursor: false, fps: 60, displayRefreshHz: mode.refreshRate, tuning: tuning)
        let regionFilter = SCContentFilter(display: display, excludingWindows: [])
        let regionScaleX = Double(appliedRegion.outputWidth) / appliedRegion.width
        let regionScaleY = Double(appliedRegion.outputHeight) / appliedRegion.height
        let localBarcodeX = Double(screen.frame.width / 2 - 18) - appliedRegion.x
        let localBarcodeY = 5 - appliedRegion.y
        let viewportSourceRect = fill.visibleSourceRect
        guard !viewportSourceRect.isNull, viewportSourceRect.width > 0, viewportSourceRect.height > 0,
              appliedRegion.rect.contains(viewportSourceRect) else {
            throw HarnessFailure("physical-fill-crop-invalid")
        }
        let sourceRectInRegion = viewportSourceRect.offsetBy(dx: -CGFloat(appliedRegion.x), dy: -CGFloat(appliedRegion.y))
        let sourceRectPixels = CGRect(x: sourceRectInRegion.minX * CGFloat(regionScaleX),
            y: sourceRectInRegion.minY * CGFloat(regionScaleY),
            width: sourceRectInRegion.width * CGFloat(regionScaleX),
            height: sourceRectInRegion.height * CGFloat(regionScaleY))
        guard let finalWidth = VirtualDisplaySpecification(viewport: viewport)?.width,
              let finalHeight = VirtualDisplaySpecification(viewport: viewport)?.height else {
            throw HarnessFailure("physical-fill-crop-raster-failed")
        }
        let regionProofMetrics = try await capture(label: "physical-current-region-window-proof",
            filter: SCContentFilter(desktopIndependentWindow: ownedWindow), displayID: id, fps: 60, seconds: 1,
            stillName: "physical-current-region-window-proof.png", configuration: regionConfiguration,
            width: regionOutput.width, height: regionOutput.height, barcodeScaleX: regionScaleX,
            barcodeScaleY: regionScaleY, barcodeOriginX: localBarcodeX, barcodeOriginY: localBarcodeY)
        let regionProofURL = outputDirectory.appendingPathComponent("shots/physical-current-region-window-proof.png")
        guard image(at: regionProofURL) != nil else {
            throw HarnessFailure("physical-current-region-window-proof-invalid")
        }
        let regionMetrics = try await capture(label: "physical-current-viewport-region", filter: regionFilter,
            displayID: id, fps: 60, seconds: 1, stillName: "physical-current-region-raw.png",
            configuration: regionConfiguration, width: regionOutput.width, height: regionOutput.height,
            barcodeScaleX: regionScaleX, barcodeScaleY: regionScaleY,
            barcodeOriginX: localBarcodeX, barcodeOriginY: localBarcodeY,
            mustMatchImageAtURL: regionProofURL)
        guard let regionImage = image(at: outputDirectory.appendingPathComponent("shots/physical-current-region-raw.png")),
              let cropped = fillCrop(regionImage, topLeftRect: sourceRectPixels, width: finalWidth, height: finalHeight) else {
            throw HarnessFailure("physical-fill-crop-raster-failed")
        }
        guard hasLiveFixture(on: id) else { throw HarnessFailure("physical-baseline-crop-invalidated-before-write") }
        try writePNG(cropped, to: outputDirectory.appendingPathComponent("shots/physical-phone-fill-baseline.png"))
        geometry["wholeDisplayRawCaptureRecipe"] = ["quality": StreamQuality.sharp.rawValue,
            "representativeH264Level": 52, "targetFPS": 60, "streamOutputPixels": [output.width, output.height],
            "captureQueueDepth": configuration.queueDepth,
            "captureMinimumFrameInterval": [configuration.minimumFrameInterval.value, configuration.minimumFrameInterval.timescale],
            "capturePixelFormat": configuration.pixelFormat, "streamTuning": tuning.liveSummary]
        geometry["viewportCaptureRecipe"] = ["viewportCaptureEnabled": tuning.viewportCapture,
            "cropPhoneNativeEnabled": CropPhoneNativeSwitch.isOn,
            "baselineFillCropEnabled": fill.baselineFillCrop,
            "requestRequestsWholeDisplay": fill.requestsWholeDisplay,
            "request": ["rect": rectJSON(request.rect), "pixelWidth": request.pixelWidth,
                        "pixelHeight": request.pixelHeight, "zoom": request.zoom,
                        "displaySize": [request.displaySize.width, request.displaySize.height]],
            "appliedRegion": ["epoch": appliedRegion.epoch, "isWholeDisplay": appliedRegion.isWholeDisplay,
                "rect": rectJSON(appliedRegion.rect), "outputPixels": [appliedRegion.outputWidth, appliedRegion.outputHeight]],
            "wholeDisplayOutputPixels": [output.width, output.height],
            "streamOutputPixels": [regionOutput.width, regionOutput.height],
            "streamQueueDepth": regionConfiguration.queueDepth,
            "streamMinimumFrameInterval": [regionConfiguration.minimumFrameInterval.value, regionConfiguration.minimumFrameInterval.timescale],
            "streamPixelFormat": regionConfiguration.pixelFormat,
            "streamSourceRect": rectJSON(regionConfiguration.sourceRect),
            "fillVisibleRectLogicalPoints": rectJSON(viewportSourceRect),
            "fillVisibleRectRelativeToAppliedRegion": rectJSON(sourceRectInRegion),
            "fillVisibleRectInStreamPixelsTopLeft": rectJSON(sourceRectPixels),
            "finalPhonePixels": [finalWidth, finalHeight],
            "capturePixelMapping": "applied-region output pixels divided by applied-region logical points"]
        geometry["fixtureWindowCaptureMetrics"] = windowMetrics
        geometry["wholeDisplayCaptureMetrics"] = wholeMetrics
        geometry["currentRegionWindowProofMetrics"] = regionProofMetrics
        geometry["currentRegionCaptureMetrics"] = regionMetrics
        geometry["coverageProof"] = "full-display raw still is pixel-identical to the same-size own-window still; cropped current-region still is pixel-identical to its same-size own-window region proof; four corner markers match"
        geometry["phonePresentationEvidence"] = "synthetic crop only; no phone or real-app presentation measured"
        return geometry
    }

    private func virtualConfiguration(_ viewport: VirtualDisplayViewport, fps: Int, tuning: StreamTuning) throws -> SCStreamConfiguration {
        guard let spec = VirtualDisplaySpecification(viewport: viewport),
              let output = RemoteCaptureConfiguration.virtualDisplayOutput(spec, budget: .level(52), fps: fps) else {
            throw HarnessFailure("virtual-output-size-rejected-by-current-capture-policy")
        }
        return RemoteCaptureConfiguration.streamConfiguration(output: output, region: nil, showsCursor: false,
            fps: fps, displayRefreshHz: Double(spec.refreshHz), tuning: tuning)
    }

    private func observe(_ label: String, viewport: VirtualDisplayViewport, display: SCDisplay,
                         fps: Int) async throws -> [String: Any] {
        let spec = VirtualDisplaySpecification(viewport: viewport)!
        let configuration = try virtualConfiguration(viewport, fps: fps, tuning: StreamTuning.current)
        var result = try await capture(label: label,
            filter: SCContentFilter(display: display, excludingWindows: []), displayID: display.displayID,
            fps: fps, seconds: 5, stillName: nil, configuration: configuration,
            width: spec.width, height: spec.height,
            barcodeScaleX: Double(spec.width) / Double(spec.logicalWidth),
            barcodeScaleY: Double(spec.height) / Double(spec.logicalHeight),
            barcodeOriginX: Double(spec.logicalWidth) / 2 - 18, barcodeOriginY: 5)
        let start = result["measurementStartMs"] as? Double ?? 0
        let end = result["measurementEndMs"] as? Double ?? start
        let ticks = fixture?.ticks(from: start, through: end) ?? 0
        result["syntheticDispatchTimerTicks"] = ticks
        let elapsed = result["measurementSeconds"] as? Double ?? 0
        result["syntheticDispatchTimerTickFPS"] = elapsed > 0 ? Double(ticks) / elapsed : 0
        return result
    }

    private func captureProvenWholeDisplayStill(label: String, display: SCDisplay, fps: Int, stillName: String,
                                                configuration: SCStreamConfiguration, width: Int, height: Int,
                                                barcodeScaleX: Double, barcodeScaleY: Double,
                                                barcodeOriginX: Double, barcodeOriginY: Double) async throws -> [String: Any] {
        guard !stopping, FileManager.default.fileExists(atPath: quietGrantURL.path),
              let fixture, let window, window.isVisible else {
            throw HarnessFailure("still-proof-requires-live-grant-and-visible-owned-fixture")
        }
        fixture.freeze(at: fixture.frameNumber)
        window.contentView?.displayIfNeeded()
        defer { fixture.unfreeze() }
        let content = try await shareableContent()
        let (ownedWindow, windowDisplayID) = try ownWindow(in: content)
        guard windowDisplayID == display.displayID else { throw HarnessFailure("still-proof-owned-window-on-wrong-display") }
        let proofName = "\(URL(fileURLWithPath: stillName).deletingPathExtension().lastPathComponent)-window-proof.png"
        let proofMetrics = try await capture(label: "\(label)-window-proof",
            filter: SCContentFilter(desktopIndependentWindow: ownedWindow),
            displayID: display.displayID, fps: fps, seconds: 1, stillName: proofName,
            configuration: configuration, width: width, height: height,
            barcodeScaleX: barcodeScaleX, barcodeScaleY: barcodeScaleY,
            barcodeOriginX: barcodeOriginX, barcodeOriginY: barcodeOriginY,
            requiresCornerMarkers: true)
        let proofURL = outputDirectory.appendingPathComponent("shots/\(proofName)")
        guard let proof = image(at: proofURL), hasCornerMarkers(proof, scaleX: barcodeScaleX, scaleY: barcodeScaleY) else {
            throw HarnessFailure("owned-window-still-proof-missing-or-invalid")
        }
        let stillMetrics = try await capture(label: label,
            filter: SCContentFilter(display: display, excludingWindows: []), displayID: display.displayID,
            fps: fps, seconds: 1, stillName: stillName, configuration: configuration,
            width: width, height: height, barcodeScaleX: barcodeScaleX, barcodeScaleY: barcodeScaleY,
            barcodeOriginX: barcodeOriginX, barcodeOriginY: barcodeOriginY,
            mustMatchImageAtURL: proofURL, requiresCornerMarkers: true)
        return ["ownWindowProof": proofMetrics, "wholeDisplayStill": stillMetrics,
                "fixtureFrameNumber": fixture.frameNumber]
    }

    private func startOwnedCapture(_ stream: SCStream) async throws {
        guard activeStream == nil, !activeStreamStarting, !activeStreamStopInFlight else {
            throw HarnessFailure("another-screen-capture-stream-is-still-active")
        }
        activeStream = stream
        activeStreamStarting = true
        activeStreamStarted = false
        activeStreamStopError = nil
        do {
            try await stream.startCapture()
            activeStreamStarted = true
            activeStreamStarting = false
            let waiters = activeStreamStartWaiters
            activeStreamStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } catch {
            do {
                try await stream.stopCapture()
                activeStream = nil
                activeStreamStarted = false
                activeStreamStopError = nil
            } catch let stopError {
                // Start may have partially activated the stream. Retain its owner so `stop()` retries
                // retirement and keeps the fixture/display intact if the retry also fails.
                activeStream = stream
                activeStreamStarted = true
                activeStreamStopError = String(describing: stopError)
            }
            activeStreamStarting = false
            let waiters = activeStreamStartWaiters
            activeStreamStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            throw error
        }
    }

    private func retireActiveCapture() async throws {
        if activeStreamStarting {
            await withCheckedContinuation { activeStreamStartWaiters.append($0) }
        }
        if activeStreamStopInFlight {
            await withCheckedContinuation { activeStreamStopWaiters.append($0) }
            if let activeStreamStopError { throw HarnessFailure("ScreenCaptureKit stop failed: \(activeStreamStopError)") }
            return
        }
        guard let stream = activeStream else { return }
        guard activeStreamStarted else {
            throw HarnessFailure("ScreenCaptureKit stream start did not settle before retirement")
        }
        activeStreamStopInFlight = true
        do {
            try await stream.stopCapture()
            activeStream = nil
            activeStreamStarted = false
            activeStreamStopError = nil
        } catch {
            activeStreamStopError = String(describing: error)
        }
        activeStreamStopInFlight = false
        let waiters = activeStreamStopWaiters
        activeStreamStopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if let activeStreamStopError { throw HarnessFailure("ScreenCaptureKit stop failed: \(activeStreamStopError)") }
    }

    private func hasLiveFixture(on expectedDisplayID: CGDirectDisplayID) -> Bool {
        guard !stopping, FileManager.default.fileExists(atPath: quietGrantURL.path),
              let window, let fixture, let screen = window.screen,
              displayID(screen) == expectedDisplayID, fixture.window === window, window.isVisible,
              window.isOpaque, window.alphaValue == 1, window.ignoresMouseEvents,
              window.level == .screenSaver, rectClose(window.frame, screen.frame),
              rectClose(fixture.bounds, CGRect(origin: .zero, size: screen.frame.size)) else { return false }
        return true
    }

    private func capture(label: String, filter: SCContentFilter,
                         displayID: CGDirectDisplayID, fps: Int, seconds: TimeInterval, stillName: String?,
                         configuration: SCStreamConfiguration, width: Int, height: Int,
                         barcodeScaleX: Double, barcodeScaleY: Double,
                         barcodeOriginX: Double = 34, barcodeOriginY: Double = 5,
                         mustMatchImageAtURL: URL? = nil, requiresCornerMarkers: Bool = false) async throws -> [String: Any] {
        guard hasLiveFixture(on: displayID),
              configuration.width == width, configuration.height == height,
              barcodeScaleX.isFinite, barcodeScaleX > 0, barcodeScaleY.isFinite, barcodeScaleY > 0,
              barcodeOriginX.isFinite, barcodeOriginY.isFinite else {
            throw HarnessFailure("capture-preflight-or-geometry-rejected-\(label)")
        }
        let output = SessionVirtualDisplayCaptureOutput(width: width, height: height,
            barcodeScaleX: barcodeScaleX, barcodeScaleY: barcodeScaleY,
            barcodeOriginX: barcodeOriginX, barcodeOriginY: barcodeOriginY,
            onFrame: { [weak self] time in self?.lastOutputTime.value = time })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        let startupInclusive = stillName != nil
        if startupInclusive { output.begin() }
        do {
            try await startOwnedCapture(stream)
        } catch {
            if startupInclusive { _ = output.end() }
            throw error
        }
        guard hasLiveFixture(on: displayID) else {
            output.end()
            try await retireActiveCapture()
            throw HarnessFailure("capture-cancelled-before-measurement-\(label)")
        }
        if !startupInclusive { output.begin() }
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            _ = output.end()
            try await retireActiveCapture()
            throw error
        }
        let metrics = output.end()
        try await retireActiveCapture()
        guard !stopping, FileManager.default.fileExists(atPath: quietGrantURL.path) else {
            throw HarnessFailure("capture-result-invalidated-before-acceptance-\(label)")
        }
        guard metrics.complete > 0, metrics.barcodeDecodeFailures == 0,
              metrics.geometryErrors == 0, metrics.blank == 0, metrics.suspended == 0,
              output.delegateError == nil else {
            throw HarnessFailure("invalid-capture-geometry-or-frame-status-\(label)")
        }
        let elapsed = metrics.elapsedSeconds
        guard elapsed.isFinite, elapsed > 0 else { throw HarnessFailure("capture-measurement-window-invalid-\(label)") }
        var result = metrics.json(label: label, displayID: displayID, fps: fps, width: width, height: height,
                                  requestedSeconds: seconds)
        result["streamError"] = output.delegateError as Any? ?? NSNull()
        result["measurementKind"] = startupInclusive ? "startup-inclusive-still-proof" : "steady-state-after-start"
        result["streamStartupIncluded"] = startupInclusive
        if let stillName, let capturedImage = output.latestImage {
            if let mustMatchImageAtURL {
                guard let comparison = image(at: mustMatchImageAtURL), samePixels(capturedImage, comparison) else {
                    throw HarnessFailure("capture-still-did-not-match-proven-own-window-content")
                }
            }
            if requiresCornerMarkers {
                guard hasCornerMarkers(capturedImage, scaleX: barcodeScaleX, scaleY: barcodeScaleY) else {
                    throw HarnessFailure("capture-still-fixture-corner-markers-missing")
                }
            }
            guard hasLiveFixture(on: displayID) else {
                throw HarnessFailure("still-save-invalidated-before-write-\(label)")
            }
            try writePNG(capturedImage, to: outputDirectory.appendingPathComponent("shots/\(stillName)"))
        } else if stillName != nil {
            throw HarnessFailure("still-image-missing-\(label)")
        }
        return result
    }

    private func showFixture(on screen: NSScreen) async throws {
        guard !stopping else { throw HarnessFailure("stopped") }
        if window == nil {
            let view = SessionVirtualDisplayFixtureView(frame: .zero)
            let created = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            created.isReleasedWhenClosed = false; created.backgroundColor = .black
            created.hasShadow = false; created.ignoresMouseEvents = true; created.isOpaque = true
            created.alphaValue = 1; created.level = .screenSaver; created.contentView = view
            created.orderFrontRegardless(); window = created; fixture = view
        }
        guard let window, let fixture else { throw HarnessFailure("synthetic-window-missing") }
        window.setFrame(screen.frame, display: true, animate: false)
        fixture.frame = window.contentView?.bounds ?? .zero
        window.orderFrontRegardless()
        guard window.screen === screen, window.isVisible, rectClose(window.frame, screen.frame),
              rectClose(fixture.bounds, CGRect(origin: .zero, size: screen.frame.size)) else {
            throw HarnessFailure("synthetic-window-does-not-cover-exact-selected-screen-frame")
        }
        window.contentView?.displayIfNeeded()
        await Task.yield()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
        source.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            self.fixture?.advance(); self.window?.contentView?.displayIfNeeded()
        }
        source.resume(); timer = source
    }

    private func stop(reason: String) async {
        if !stopping {
            stopping = true; timer?.cancel(); timer = nil
            report["stopReason"] = reason
        }
        do {
            try await retireActiveCapture()
        } catch {
            captureStopError = String(describing: error)
            report["captureStopError"] = captureStopError
            // Keep the owned fixture visible and the display retained while SCK retirement is unknown.
            return
        }
        captureStopError = nil
        window?.orderOut(nil); window?.close(); window = nil; fixture = nil
        guard !adapterStopped else { return }
        if adapterStopInFlight {
            await withCheckedContinuation { adapterStopWaiters.append($0) }
            return
        }
        adapterStopInFlight = true
        do {
            try await adapter.stop()
            adapterStopped = true
            adapterStopError = nil
            report["ownedDisplayRemovalVerified"] = true
        } catch {
            adapterStopError = String(describing: error)
            report["adapterStopError"] = adapterStopError
            report["ownedDisplayRemovalVerified"] = false
        }
        adapterStopInFlight = false
        let waiters = adapterStopWaiters
        adapterStopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    private func ownWindow(in content: SCShareableContent) throws -> (SCWindow, CGDirectDisplayID) {
        guard let window, let match = content.windows.first(where: { $0.windowID == window.windowNumber }),
              match.owningApplication?.processID == getpid(), let screen = window.screen else {
            throw HarnessFailure("own-physical-window-not-found")
        }
        return (match, displayID(screen))
    }

    private func screen(for display: SCDisplay) throws -> NSScreen {
        guard let screen = NSScreen.screens.first(where: { displayID($0) == display.displayID }) else {
            throw HarnessFailure("owned-display-has-no-NSScreen")
        }
        return screen
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func rectClose(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 0.5 && abs(first.minY - second.minY) <= 0.5 &&
        abs(first.width - second.width) <= 0.5 && abs(first.height - second.height) <= 0.5
    }

    private func rectJSON(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    private func viewportJSON(_ viewport: VirtualDisplayViewport) -> [String: Any] {
        let spec = VirtualDisplaySpecification(viewport: viewport)!
        return ["widthPoints": viewport.width, "heightPoints": viewport.height, "viewportScale": viewport.scale,
                "maximumFPS": viewport.maximumFPS, "requestedRasterWidth": spec.width, "requestedRasterHeight": spec.height,
                "virtualModePointsWidth": spec.logicalWidth, "virtualModePointsHeight": spec.logicalHeight,
                "requestedVirtualModeBackingScale": 2, "requestedModeRefreshHz": spec.refreshHz]
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw HarnessFailure("png-destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HarnessFailure("png-finalize") }
    }

    private func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Render to an explicitly RGBA, big-endian bitmap so comparisons never assume a CI-created
    /// CGImage has the source pixel buffer's BGRA channel order.
    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height, bytesPerRow = image.width * 4
        var data = Data(count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? Array(data) : nil
    }

    private func samePixels(_ first: CGImage, _ second: CGImage) -> Bool {
        guard first.width == second.width, first.height == second.height,
              let firstRGBA = rgbaPixels(first), let secondRGBA = rgbaPixels(second) else { return false }
        return firstRGBA == secondRGBA
    }

    private func hasCornerMarkers(_ image: CGImage, scaleX: Double, scaleY: Double) -> Bool {
        guard let bytes = rgbaPixels(image), scaleX > 0, scaleY > 0 else { return false }
        let insetX = max(0, min(image.width - 1, Int(12 * scaleX)))
        let insetY = max(0, min(image.height - 1, Int(12 * scaleY)))
        let points = [(insetX, insetY), (image.width - 1 - insetX, insetY),
                      (insetX, image.height - 1 - insetY), (image.width - 1 - insetX, image.height - 1 - insetY)]
        let colors = points.map { x, y -> (Int, Int, Int) in
            let i = (y * image.width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        func red(_ c: (Int, Int, Int)) -> Bool { c.0 > 160 && c.0 > c.1 * 3 / 2 && c.0 > c.2 * 3 / 2 }
        func green(_ c: (Int, Int, Int)) -> Bool { c.1 > 120 && c.1 > c.0 * 3 / 2 && c.1 > c.2 * 3 / 2 }
        func blue(_ c: (Int, Int, Int)) -> Bool { c.2 > 150 && c.2 > c.0 * 3 / 2 && c.2 > c.1 * 3 / 2 }
        func yellow(_ c: (Int, Int, Int)) -> Bool { c.0 > 160 && c.1 > 160 && c.2 < 130 }
        return red(colors[0]) && green(colors[1]) && blue(colors[2]) && yellow(colors[3])
    }

    private func fillCrop(_ image: CGImage, topLeftRect: CGRect, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, topLeftRect.width > 0, topLeftRect.height > 0,
              topLeftRect.minX >= 0, topLeftRect.minY >= 0,
              topLeftRect.maxX <= CGFloat(image.width) + 0.5,
              topLeftRect.maxY <= CGFloat(image.height) + 0.5 else { return nil }
        let ci = CIImage(cgImage: image)
        let crop = CGRect(x: topLeftRect.minX,
                          y: CGFloat(image.height) - topLeftRect.maxY,
                          width: topLeftRect.width, height: topLeftRect.height)
        let normalized = ci.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / crop.width,
                                                                   y: CGFloat(height) / crop.height))
        return ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func createSideBySide(_ leftURL: URL, _ rightURL: URL, _ destination: URL) throws {
        guard let left = image(at: leftURL), let right = image(at: rightURL),
              left.width == right.width, left.height == right.height else {
            throw HarnessFailure("side-by-side-images-missing-or-different-size")
        }
        let width = left.width * 2, height = left.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HarnessFailure("side-by-side-context")
        }
        context.interpolationQuality = .none
        context.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: height))
        context.draw(right, in: CGRect(x: left.width, y: 0, width: right.width, height: height))
        guard let combined = context.makeImage() else { throw HarnessFailure("side-by-side-image") }
        try writePNG(combined, to: destination)
    }

    private func compareEdgeMetric(_ physicalURL: URL, _ virtualURL: URL) -> [String: Any] {
        let roi = CGRect(x: 0.10, y: 0.38, width: 0.80, height: 0.24)
        guard let physical = image(at: physicalURL), let virtual = image(at: virtualURL),
              physical.width == virtual.width, physical.height == virtual.height else {
            return ["available": false]
        }
        let p = edgeGradient(physical, normalizedROI: roi), v = edgeGradient(virtual, normalizedROI: roi)
        return ["available": p != nil && v != nil, "normalizedTextROI": [roi.minX, roi.minY, roi.width, roi.height],
                "physicalFillBaselineNormalizedMeanAbsoluteLumaGradient": p as Any? ?? NSNull(),
                "virtualNormalizedMeanAbsoluteLumaGradient": v as Any? ?? NSNull(),
                "definition": "Within the same normalized center text ROI, sample each second RGBA pixel, compute Rec.709 luma from R,G,B, then average absolute one-pixel horizontal and vertical differences divided by 255.",
                "limitations": "Synthetic fixture only. This raster descriptor is affected by source/display scale, resampling, color conversion, and font rasterization; it is not MTF, OCR, human legibility, real-app quality, or phone presentation evidence."]
    }

    private func edgeGradient(_ image: CGImage, normalizedROI: CGRect) -> Double? {
        guard let bytes = rgbaPixels(image), image.width > 2, image.height > 2 else { return nil }
        let left = max(1, min(image.width - 2, Int(normalizedROI.minX * CGFloat(image.width))))
        let right = max(left + 1, min(image.width - 1, Int(normalizedROI.maxX * CGFloat(image.width))))
        let top = max(1, min(image.height - 2, Int(normalizedROI.minY * CGFloat(image.height))))
        let bottom = max(top + 1, min(image.height - 1, Int(normalizedROI.maxY * CGFloat(image.height))))
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = (y * image.width + x) * 4
            return (0.2126 * Double(bytes[p]) + 0.7152 * Double(bytes[p + 1]) + 0.0722 * Double(bytes[p + 2])) / 255
        }
        var sum = 0.0, count = 0
        for y in stride(from: top, to: bottom, by: 2) {
            for x in stride(from: left, to: right, by: 2) {
                sum += abs(luma(x + 1, y) - luma(x, y)) + abs(luma(x, y + 1) - luma(x, y))
                count += 2
            }
        }
        return count == 0 ? nil : sum / Double(count)
    }

    private func finish(error: String?) {
        if let error { report["error"] = error; exitCode = 1 }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        let url = outputDirectory.appendingPathComponent("metrics.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("SESSION-VD-HARNESS-JSON: \(String(decoding: data, as: UTF8.self))")
            print("SESSION-VD-HARNESS: \(error == nil ? "complete" : "failed") metrics=\(url.path)")
        } catch { print("SESSION-VD-HARNESS: report-write-failed \(error)"); exitCode = 2 }
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        NSApp.stop(nil); CFRunLoopStop(CFRunLoopGetMain())
    }
}

private struct HarnessFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct HarnessMeasurement {
    var complete = 0, idle = 0, blank = 0, suspended = 0, other = 0
    var geometryErrors = 0, missingDisplayTime = 0
    var barcodeDecodeFailures = 0
    var displayTimesMs: [Double] = []
    var barcodes = Set<UInt32>()
    var firstCallbackTime: Double?
    var lastCallbackTime: Double?
    var measurementStartMs: Double?
    var measurementEndMs: Double?

    var elapsedSeconds: Double {
        guard let measurementStartMs, let measurementEndMs, measurementEndMs > measurementStartMs else { return 0 }
        return (measurementEndMs - measurementStartMs) / 1_000
    }

    mutating func record(status: SCFrameStatus, displayTime: UInt64?, barcode: UInt32?, callbackTime: Double, geometryOK: Bool) {
        switch status {
        case .complete:
            if !geometryOK { geometryErrors += 1 }
            complete += 1
            if let barcode { barcodes.insert(barcode) } else { barcodeDecodeFailures += 1 }
            firstCallbackTime = firstCallbackTime ?? callbackTime; lastCallbackTime = callbackTime
            if let displayTime, displayTime != 0 { displayTimesMs.append(MachClock.milliseconds(fromMachTicks: displayTime)) }
            else { missingDisplayTime += 1 }
        case .idle: idle += 1
        case .blank: blank += 1
        case .suspended: suspended += 1
        default: other += 1
        }
    }

    func json(label: String, displayID: CGDirectDisplayID, fps: Int, width: Int, height: Int,
              requestedSeconds: TimeInterval) -> [String: Any] {
        let elapsed = elapsedSeconds
        let unique = Array(Set(displayTimesMs)).sorted()
        let intervals = zip(unique, unique.dropFirst()).map { $1 - $0 }.sorted()
        return ["label": label, "displayID": displayID, "requestedCaptureFPS": fps,
                "requestedPixels": [width, height], "requestedMeasurementSeconds": requestedSeconds,
                "measurementSeconds": elapsed,
                "measurementStartMs": measurementStartMs as Any? ?? NSNull(),
                "measurementEndMs": measurementEndMs as Any? ?? NSNull(),
                "status": ["complete": complete, "idle": idle, "blank": blank, "suspended": suspended, "other": other],
                "callbackCompleteFPS": elapsed > 0 ? Double(complete) / elapsed : 0,
                "distinctDecodedBarcodeContentFrames": barcodes.count,
                "distinctDecodedBarcodeContentFPS": elapsed > 0 ? Double(barcodes.count) / elapsed : 0,
                "uniqueDisplayTimeFPS": elapsed > 0 ? Double(unique.count) / elapsed : 0,
                "displayTimeDeltaMsP50": percentile(intervals, 0.50), "displayTimeDeltaMsP95": percentile(intervals, 0.95),
                "missingDisplayTime": missingDisplayTime, "geometryErrors": geometryErrors,
                "firstCompleteCallbackMs": firstCallbackTime as Any? ?? NSNull(),
                "lastCompleteCallbackMs": lastCallbackTime as Any? ?? NSNull(),
                "encodeFPS": NSNull(), "networkDeliveredFPS": NSNull(), "phonePresentedFPS": NSNull()]
    }

    private func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        return values[min(values.count - 1, Int(Double(values.count - 1) * q))]
    }
}

private final class SessionVirtualDisplayCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Farside.SessionVirtualDisplayHarness.capture", qos: .userInteractive)
    private let width: Int, height: Int
    private let barcodeScaleX: Double, barcodeScaleY: Double
    private let barcodeOriginX: Double, barcodeOriginY: Double
    private let onFrame: (Double) -> Void
    private let errorLock = NSLock()
    private var measuring = false
    private var stats = HarnessMeasurement()
    private var latestBuffer: CVPixelBuffer?
    private var storedError: String?
    var delegateError: String? { errorLock.lock(); defer { errorLock.unlock() }; return storedError }
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(width: Int, height: Int, barcodeScaleX: Double, barcodeScaleY: Double,
         barcodeOriginX: Double, barcodeOriginY: Double, onFrame: @escaping (Double) -> Void) {
        self.width = width; self.height = height; self.barcodeScaleX = barcodeScaleX
        self.barcodeScaleY = barcodeScaleY; self.barcodeOriginX = barcodeOriginX
        self.barcodeOriginY = barcodeOriginY; self.onFrame = onFrame
    }
    func begin() {
        queue.sync {
            stats = HarnessMeasurement()
            latestBuffer = nil
            stats.measurementStartMs = MachClock.nowMs()
            measuring = true
        }
    }
    func end() -> HarnessMeasurement {
        queue.sync {
            measuring = false
            stats.measurementEndMs = MachClock.nowMs()
            return stats
        }
    }
    var latestImage: CGImage? {
        let buffer = queue.sync { latestBuffer }
        guard let buffer else { return nil }
        return ciContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, measuring, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        let buffer = sampleBuffer.imageBuffer
        let correct = buffer.map { CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height } ?? false
        let barcode = correct && status == .complete ? buffer.flatMap(decodeBarcode) : nil
        let callback = MachClock.nowMs()
        let rawTime = (info[.displayTime] as? NSNumber)?.uint64Value
        stats.record(status: status, displayTime: rawTime, barcode: barcode,
                     callbackTime: callback, geometryOK: correct)
        if correct && status == .complete { latestBuffer = buffer }
        if status == .complete { onFrame(callback) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorLock.lock(); storedError = String(describing: error); errorLock.unlock()
    }

    private func decodeBarcode(_ buffer: CVPixelBuffer) -> UInt32? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let y = max(0, min(height - 1, Int((barcodeOriginY + 3) * barcodeScaleY)))
        return SessionVirtualDisplayBarcode.decode { slot in
            let x = Int((barcodeOriginX + (Double(slot) + 0.5) * 1.5) * barcodeScaleX)
            guard x >= 0, x < width else { return nil }
            let isWhite: Bool
            switch CVPixelBufferGetPixelFormatType(buffer) {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                guard CVPixelBufferGetPlaneCount(buffer) >= 2,
                      let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
                let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
                let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
                guard x < planeWidth, y < planeHeight else { return nil }
                let luma = Int(plane[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x])
                isWhite = luma > 125
            case kCVPixelFormatType_32BGRA:
                guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
                let p = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                isWhite = Int(base[p]) + Int(base[p + 1]) + Int(base[p + 2]) > 380
            default:
                return nil
            }
            return isWhite
        }
    }
}

@MainActor
private final class SessionVirtualDisplayFixtureView: NSView {
    private(set) var frameNumber: UInt32 = 0
    private var frozen = false
    private(set) var tickCount = 0
    private var tickTimesMs: [Double] = []
    init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    func advance() {
        guard !frozen else { return }
        tickCount += 1; frameNumber &+= 1; tickTimesMs.append(MachClock.nowMs()); needsDisplay = true
    }
    func freeze(at value: UInt32) { frozen = true; frameNumber = value; needsDisplay = true }
    func unfreeze() { frozen = false }
    func ticks(from start: Double, through end: Double) -> Int {
        tickTimesMs.reduce(into: 0) { if $1 >= start && $1 <= end { $0 += 1 } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let canvas = bounds
        NSColor(calibratedWhite: 0.965, alpha: 1).setFill(); canvas.fill()
        NSColor.red.setFill(); CGRect(x: 0, y: 0, width: 24, height: 24).fill()
        NSColor.green.setFill(); CGRect(x: bounds.maxX - 24, y: 0, width: 24, height: 24).fill()
        NSColor.blue.setFill(); CGRect(x: 0, y: bounds.maxY - 24, width: 24, height: 24).fill()
        NSColor.yellow.setFill(); CGRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 24, height: 24).fill()
        let centerY = bounds.midY
        centeredText("FARSIDE · VIRTUAL DESKTOP", y: centerY - 62, size: 14, .black)
        centeredText("Readable text / 0123456789 / ÀÉ日", y: centerY - 38, size: 15, .black)
        centeredText("The quick brown fox jumps over the lazy dog.", y: centerY - 14, size: 13, .black)
        centeredText("Monospaced: 0O 1Il | UUID 7c3a-90ef", y: centerY + 9, size: 12, .black, mono: true)
        for row in 0..<4 {
            centeredText(String(format: "Item %02d     value %04d     state active", row + 1, 271 + row * 17),
                         y: centerY + CGFloat(34 + row * 22), size: 12, .black, mono: true)
        }
        for bit in -4..<SessionVirtualDisplayBarcode.bits {
            (SessionVirtualDisplayBarcode.white(slot: bit, frame: frameNumber) ? NSColor.white : NSColor.black).setFill()
            CGRect(x: bounds.midX - 18 + CGFloat(bit) * 1.5, y: 5, width: 1.5, height: 6).fill()
        }
        text(String(format: "CONTENT FRAME %08X", frameNumber), CGPoint(x: bounds.midX + 22, y: 3), 10, .black, mono: true)
        context.restoreGState()
    }

    private func centeredText(_ value: String, y: CGFloat, size: CGFloat, _ color: NSColor, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let width = (value as NSString).size(withAttributes: [.font: font]).width
        text(value, CGPoint(x: bounds.midX - width / 2, y: y), size, color, mono: mono)
    }

    private func text(_ value: String, _ point: CGPoint, _ size: CGFloat, _ color: NSColor, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        (value as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

private final class HarnessLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}
#endif
