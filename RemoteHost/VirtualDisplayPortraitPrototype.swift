#if DEBUG
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import ObjectiveC
import QuartzCore
import ScreenCaptureKit

/// Fully isolated Debug entry point. This returns an exit code before any ordinary host model exists.
@MainActor
enum VirtualDisplayPortraitPrototype {
    static func run(arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let options = try PortraitPrototypeOptions.parse(arguments)
            print("VIRTUAL-DISPLAY-PORTRAIT-PROCESS: \(getpid())")
            if options.action == .check {
                var report = PortraitController.environment(options)
                report["screenRecordingGranted"] = CGPreflightScreenCaptureAccess()
                do { try PortraitPrivateDisplay.audit(); report["abiSupported"] = true }
                catch { report["abiSupported"] = false; report["error"] = String(describing: error) }
                report["result"] = "check-only"; report["resourcesCreated"] = false
                PortraitController.emit(report)
                return (report["screenRecordingGranted"] as? Bool == true && report["abiSupported"] as? Bool == true) ? 0 : 2
            }
            let application = NSApplication.shared
            application.delegate = nil
            application.setActivationPolicy(.accessory)
            let controller = PortraitController(options)
            controller.present()
            application.run()
            return controller.exitCode
        } catch {
            PortraitController.emit(["result": "invalid-options", "error": String(describing: error), "resourcesCreated": false])
            return 2
        }
    }
}

@MainActor
private final class PortraitController: NSObject, NSWindowDelegate {
    let options: PortraitPrototypeOptions
    private var admission = PortraitRunAdmission()
    private var resources: PortraitResources?
    private var control: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "Ready. Start creates one experimental portrait display.")
    private let preview = NSImageView()
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var signals: [DispatchSourceSignal] = []
    private var exitRequested = false
    private var report: [String: Any] = [:]
    private var reportToken: UInt64 = 0
    private var lastResult = "not-started"
    private(set) var exitCode: Int32 = 0
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(_ options: PortraitPrototypeOptions) { self.options = options; super.init() }

    static func environment(_ options: PortraitPrototypeOptions) -> [String: Any] {
        ["schema": 1, "mode": options.mode.rawValue, "action": options.action.rawValue,
         "requested": ["logicalWidth": 430, "logicalHeight": 932, "pixelWidth": options.pixelWidth,
                       "pixelHeight": options.pixelHeight, "refreshHz": 60],
         "os": ProcessInfo.processInfo.operatingSystemVersionString, "timestampUTC": ISO8601DateFormatter().string(from: Date()),
         "architecture": "arm64-required", "revision": ProcessInfo.processInfo.environment["FARSIDE_PORTRAIT_REVISION"] ?? "unknown",
         "captureScope": "own desktop-independent synthetic window", "beforeDisplays": inventory()]
    }
    static func emit(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("VIRTUAL-DISPLAY-PORTRAIT-JSON: \(text)") }
        print("VIRTUAL-DISPLAY-PORTRAIT: \(report["result"] ?? "unknown") cleanup=\(report["cleanupVerified"] ?? "not-run")")
    }
    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
    private static func inventory() -> [[String: Any]] {
        onlineIDs().map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return ["id": id, "main": CGDisplayIsMain(id) != 0, "mirrored": CGDisplayIsInMirrorSet(id) != 0,
                    "vendor": CGDisplayVendorNumber(id), "product": CGDisplayModelNumber(id), "serial": CGDisplaySerialNumber(id),
                    "width": mode?.width ?? 0, "height": mode?.height ?? 0,
                    "pixelWidth": mode?.pixelWidth ?? 0, "pixelHeight": mode?.pixelHeight ?? 0,
                    "refreshHz": mode?.refreshRate ?? 0]
        }
    }
    func present() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Farside portrait experiment (Debug)"; window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSView(); window.contentView = content
        let heading = NSTextField(labelWithString: "430 × 932 · \(options.mode.rawValue) · requested 60 Hz")
        startButton = NSButton(title: "Start", target: self, action: #selector(startClicked))
        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopClicked)); stopButton.isEnabled = false
        let buttons = NSStackView(views: [startButton, stopButton]); buttons.orientation = .horizontal
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.black.cgColor
        let stack = NSStackView(views: [heading, buttons, status, preview]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor), preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 510)])
        window.center(); window.makeKeyAndOrderFront(nil); control = window
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.requestExit(reason: "signal-\(number)") } }
            source.resume(); signals.append(source)
        }
        if options.action == .smoke { Task { await start() } }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await requestExit(reason: "control-window-close") }; return false
    }
    @objc private func startClicked() { Task { await start() } }
    @objc private func stopClicked() { Task { await stop(reason: "user-stop") } }

    private func start() async {
        guard !exitRequested, let token = admission.start() else { return }
        startButton.isEnabled = false; stopButton.isEnabled = true
        exitCode = 0
        report = Self.environment(options); report["resourcesCreated"] = false
        reportToken = token
        lastResult = "starting"; status.stringValue = "Checking permission and ABI…"
        let owned = PortraitResources(token: token); resources = owned
        do {
            let (lease, _) = try PortraitCreationPreflight.acquire(permission: { CGPreflightScreenCaptureAccess() },
                audit: { try PortraitPrivateDisplay.audit() }, lease: { try PortraitRuntimeLease.acquire() },
                existingIdentity: { Self.onlineIDs().contains(where: { PortraitPrivateDisplay.isExperiment($0) }) },
                create: { () })
            guard admission.accepts(token) else { throw PortraitPrototypeFailure.rejected("cancelled before creation") }
            owned.createdAt = MachClock.nowMs()
            try owned.creation.create(lease: lease, construct: { try PortraitPrivateDisplay.construct(options) },
                                      identify: { try PortraitPrivateDisplay.displayID($0) },
                                      configure: { try PortraitPrivateDisplay.configure($0, options) })
            report["resourcesCreated"] = true; report["displayID"] = owned.displayID
            guard owned.displayID != 0, await wait(5, { Self.onlineIDs().contains(owned.displayID) && Self.screen(owned.displayID) != nil }, token: token),
                  PortraitPrivateDisplay.isExperiment(owned.displayID),
                  CGDisplaySerialNumber(owned.displayID) == (options.mode == .one ? 0x4361 : 0x4362) else {
                throw PortraitPrototypeFailure.rejected("display/screen discovery timed out or was cancelled")
            }
            if options.mode == .two { try await prepareOwnedHiDPIMode(owned) }
            guard admission.accepts(token), let screen = Self.screen(owned.displayID), let mode = CGDisplayCopyDisplayMode(owned.displayID) else {
                throw PortraitPrototypeFailure.rejected("owned display disappeared before mode inspection")
            }
            // Preserve rejected observations too: removal inventory cannot explain a wrong selected mode.
            report["actual"] = ["logicalWidth": mode.width, "logicalHeight": mode.height, "pixelWidth": mode.pixelWidth,
                                "pixelHeight": mode.pixelHeight, "screenWidth": screen.frame.width, "screenHeight": screen.frame.height,
                                "backingScale": screen.backingScaleFactor, "refreshHz": mode.refreshRate]
            guard options.accepts(logicalWidth: screen.frame.width, logicalHeight: screen.frame.height,
                                  pixelsWide: mode.pixelWidth, pixelsHigh: mode.pixelHeight,
                                  backingScale: screen.backingScaleFactor, refresh: mode.refreshRate),
                  mode.width == 430, mode.height == 932, CGDisplayIsMain(owned.displayID) == 0,
                  CGDisplayIsInMirrorSet(owned.displayID) == 0 else {
                throw PortraitPrototypeFailure.rejected("unsupported actual portrait geometry/mode; physical displays untouched")
            }
            let view = PortraitSyntheticView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: options.mode.scale)
            let relativeContentRect = PortraitWindowPlacement.screenRelativeContentRect(for: screen.frame)
            let window = NSWindow(contentRect: relativeContentRect, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false; window.title = "Farside synthetic portrait fixture"
            window.animationBehavior = .none
            window.contentView = view; window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.orderFrontRegardless(); owned.window = window; owned.view = view
            view.start()
            let ownWindow = try await verifiedCaptureWindow(owned, window: window, screen: screen, initializerRect: relativeContentRect)
            let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
            guard abs(filter.contentRect.width - 430) < 1, abs(filter.contentRect.height - 932) < 1,
                  abs(Double(filter.pointPixelScale) - Double(options.mode.scale)) < 0.01 else {
                throw PortraitPrototypeFailure.rejected("capture filter geometry differs from requested geometry")
            }
            report["capture"] = ["windowID": ownWindow.windowID, "ownerPID": getpid(), "displayID": owned.displayID,
                                 "filterWidth": filter.contentRect.width, "filterHeight": filter.contentRect.height,
                                 "pointPixelScale": filter.pointPixelScale, "queueDepth": 3, "minimumIntervalSeconds": 1.0 / 60]
            let configuration = SCStreamConfiguration()
            configuration.width = options.pixelWidth; configuration.height = options.pixelHeight
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60); configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA; configuration.showsCursor = false
            configuration.capturesAudio = false; configuration.captureMicrophone = false
            let output = PortraitCaptureOutput(width: options.pixelWidth, height: options.pixelHeight)
            output.onPreview = { [weak self, weak owned] buffer in
                guard let self, let owned, self.admission.accepts(owned.token), self.resources === owned else { return }
                let image = CIImage(cvPixelBuffer: buffer)
                if let cg = self.imageContext.createCGImage(image, from: image.extent) { self.preview.image = NSImage(cgImage: cg, size: NSSize(width: 430, height: 932)) }
            }
            output.onFailure = { [weak self, weak owned] in
                guard let self, let owned, self.resources === owned, self.admission.accepts(owned.token) else { return }
                self.recordFailure(owned, "capture-error")
                Task { await self.stop(reason: "capture-error") }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            owned.stream = stream; owned.output = output
            let owner = PortraitCaptureOwner(start: { completion in
                stream.startCapture { error in Task { @MainActor in completion(error.map { "capture-start-failed(\(($0 as NSError).code))" }) } }
            }, stop: { completion in
                stream.stopCapture { error in Task { @MainActor in completion(error.map { "capture-stop-failed(\(($0 as NSError).code))" }) } }
            }, release: { [weak self, weak owned] in
                guard let self, let owned else { return }
                Task { await self.releaseAfterCapture(owned) }
            })
            owned.captureOwner = owner; owner.start()
            guard await wait(5, { owner.state != .starting }, token: token), owner.state == .running else {
                owner.deadline("capture-start deadline/cancellation")
                throw PortraitPrototypeFailure.rejected(owner.failure ?? "capture start failed")
            }
            guard await wait(5, { output.hasFirstFrame }, token: token), output.hasFirstFrame, output.geometryValid else {
                throw PortraitPrototypeFailure.rejected("first-frame timeout/cancellation or invalid frame geometry")
            }
            report["firstFrameMs"] = output.firstFrameMs.map { $0 - owned.createdAt } ?? -1
            lastResult = "running"; status.stringValue = "Running. Only the synthetic window is captured."
            if options.action == .smoke {
                output.beginPhase(); let movingStart = MachClock.nowMs(); let movingTicks = view.observedTickCount
                guard await wait(options.movingSeconds, { false }, token: token, timeoutIsSuccess: true) else { throw PortraitPrototypeFailure.rejected("motion cancelled") }
                let moving = output.endPhase(); report["moving"] = moving.report(seconds: (MachClock.nowMs() - movingStart) / 1000)
                report["movingDisplayLinkTicks"] = view.observedTickCount - movingTicks
                view.stop(); output.beginPhase(); let idleStart = MachClock.nowMs()
                guard await wait(options.idleSeconds, { false }, token: token, timeoutIsSuccess: true) else { throw PortraitPrototypeFailure.rejected("idle cancelled") }
                report["idle"] = output.endPhase().report(seconds: (MachClock.nowMs() - idleStart) / 1000)
                guard moving.distinct >= 2, output.geometryValid, output.stopError == nil else {
                    throw PortraitPrototypeFailure.rejected("smoke needs two distinct complete motion timestamps and correct frames")
                }
                lastResult = "passed"; await stop(reason: "smoke-complete"); finishApplication(owned)
            } else {
                owned.inventoryTask = Task { [weak self, weak owned] in
                    while let self, let owned, self.admission.accepts(token) {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if !Self.onlineIDs().contains(owned.displayID) {
                            self.recordFailure(owned, "owned-display-disappeared")
                            await self.stop(reason: "owned-display-disappeared"); break
                        }
                    }
                }
            }
        } catch {
            if reportToken == owned.token {
                report["resourcesCreated"] = owned.creation.hadDisplay
                report["displayID"] = owned.displayID
            }
            recordFailure(owned, String(describing: error))
            if resources === owned { await stop(reason: "start-failed") }
            if options.action == .smoke { finishApplication(owned) }
        }
    }

    private func verifiedCaptureWindow(_ owned: PortraitResources, window: NSWindow, screen: NSScreen,
                                       initializerRect: CGRect) async throws -> SCWindow {
        let beganMs = MachClock.nowMs()
        let deadline = PortraitStageDeadline(startMs: beganMs)
        let requestedWindowID = CGWindowID(window.windowNumber)
        var attempts = 0
        while admission.accepts(owned.token), deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) != nil {
            let shareable = try await discover(owned, within: deadline)
            guard admission.accepts(owned.token) else { throw PortraitPrototypeFailure.rejected("cancelled before capture identity inspection") }
            attempts += 1
            let matchingWindow = shareable.windows.first { $0.windowID == requestedWindowID }
            let displayFound = shareable.displays.contains { $0.displayID == owned.displayID }
            let windowScreenID = window.screen.map { Self.screenID($0) }
            let withinDeadline = deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) != nil
            let verified = withinDeadline && PortraitWindowPlacement.matches(windowID: matchingWindow?.windowID,
                ownerPID: matchingWindow?.owningApplication?.processID, screenID: windowScreenID, displayFound: displayFound,
                captureFrame: matchingWindow?.frame, expectedWindowID: requestedWindowID, expectedOwnerPID: getpid(),
                expectedDisplayID: owned.displayID, displayBounds: CGDisplayBounds(owned.displayID))
            // Replace a single bounded record; never accumulate snapshots, titles or unrelated window data.
            report["placement"] = ["requestedWindowID": requestedWindowID, "requestedDisplayID": owned.displayID,
                                   "expectedOwnerPID": getpid(), "matchedWindowID": matchingWindow.map { $0.windowID } as Any? ?? NSNull(),
                                   "matchedOwnerPID": matchingWindow?.owningApplication?.processID as Any? ?? NSNull(),
                                   "ownWindowFound": matchingWindow?.owningApplication?.processID == getpid(), "displayFound": displayFound,
                                   "windowScreenID": windowScreenID as Any? ?? NSNull(), "attempts": attempts,
                                   "elapsedMs": MachClock.nowMs() - beganMs, "verified": verified, "deadlineExpired": !withinDeadline,
                                   "automaticAnimation": "none",
                                   "windowFrame": Self.rectReport(window.frame), "targetScreenFrame": Self.rectReport(screen.frame),
                                   "windowScreenFrame": window.screen.map { Self.rectReport($0.frame) } as Any? ?? NSNull(),
                                   "initializerContentRect": Self.rectReport(initializerRect),
                                   "cgDisplayBounds": Self.rectReport(CGDisplayBounds(owned.displayID)),
                                   "scWindowFrame": matchingWindow.map { Self.rectReport($0.frame) } as Any? ?? NSNull()]
            if verified, let matchingWindow { return matchingWindow }
            guard let remaining = deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) else { break }
            try? await Task.sleep(nanoseconds: min(25_000_000, remaining))
        }
        throw PortraitPrototypeFailure.rejected("capture identity/placement deadline or cancellation")
    }
    private func discover(_ owned: PortraitResources, within deadline: PortraitStageDeadline) async throws -> SCShareableContent {
        guard let remaining = deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) else {
            throw PortraitPrototypeFailure.rejected("shareable-content deadline")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = PortraitDiscoveryGate(continuation)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                Task { @MainActor in
                    // Discovery itself acquires no stream; a stale response is discarded, never adopted.
                    if let content { gate.resolve(.success(content)) }
                    else { gate.resolve(.failure(PortraitPrototypeFailure.rejected("shareable-content-failed(\((error as NSError?)?.code ?? -1))"))) }
                }
            }
            Task { try? await Task.sleep(nanoseconds: remaining); gate.resolve(.failure(PortraitPrototypeFailure.rejected("shareable-content deadline"))) }
        }
    }
    private func prepareOwnedHiDPIMode(_ owned: PortraitResources) async throws {
        let id = owned.displayID
        let beganMs = MachClock.nowMs()
        let deadline = PortraitStageDeadline(startMs: beganMs)
        guard admission.accepts(owned.token), let current = CGDisplayCopyDisplayMode(id) else {
            throw PortraitPrototypeFailure.rejected("cancelled or missing owned mode before HiDPI inspection")
        }
        var selection: [String: Any] = ["targetDisplayID": id, "before": Self.modeReport(current)]
        report["modeSelection"] = selection
        if Self.modeCandidate(current).matches(options) {
            selection["action"] = "already-exact"; report["modeSelection"] = selection
        } else {
            let offered = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
            selection["offeredCount"] = offered.count
            selection["offeredModes"] = offered.prefix(64).map(Self.modeReport)
            selection["offeredReportTruncated"] = offered.count > 64
            report["modeSelection"] = selection
            let target = try ownedModeTarget(owned)
            let index = try PortraitDisplayModeSelection.select(options, candidates: offered.map(Self.modeCandidate), target: target) { index in
                // Revalidate immediately before the only public mode mutation; never follow a changed ID.
                guard admission.accepts(owned.token), deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) != nil,
                      try ownedModeTarget(owned).permitsSelection else {
                    throw PortraitPrototypeFailure.rejected("owned mode target changed or selection deadline expired")
                }
                selection["selected"] = Self.modeReport(offered[index])
                selection["action"] = "set-owned-display-mode"
                report["modeSelection"] = selection
                // Public and synchronous. Its process-lifetime scope is documented; mirrored targets were rejected.
                let result = CGDisplaySetDisplayMode(id, offered[index], nil)
                selection["setResultCode"] = result.rawValue
                selection["synchronousCallElapsedMs"] = MachClock.nowMs() - beganMs
                report["modeSelection"] = selection
                guard result == .success else { throw PortraitPrototypeFailure.rejected("owned CGDisplaySetDisplayMode failed(\(result.rawValue))") }
            }
            selection["selectedIndex"] = index; report["modeSelection"] = selection
        }
        // CG switching is synchronous, but NSScreen's cached topology can settle later. Share the original budget.
        while admission.accepts(owned.token), deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) != nil {
            guard try ownedModeTarget(owned).permitsSelection else { throw PortraitPrototypeFailure.rejected("owned mode target changed while settling") }
            if let mode = CGDisplayCopyDisplayMode(id), let screen = Self.screen(id),
               Self.modeCandidate(mode).matches(options),
               options.accepts(logicalWidth: screen.frame.width, logicalHeight: screen.frame.height,
                               pixelsWide: mode.pixelWidth, pixelsHigh: mode.pixelHeight,
                               backingScale: screen.backingScaleFactor, refresh: mode.refreshRate) {
                selection["after"] = Self.modeReport(mode); selection["backingScale"] = screen.backingScaleFactor
                selection["elapsedMs"] = MachClock.nowMs() - beganMs; selection["verified"] = true
                report["modeSelection"] = selection; return
            }
            guard let remaining = deadline.remainingNanoseconds(nowMs: MachClock.nowMs()) else { break }
            try? await Task.sleep(nanoseconds: min(25_000_000, remaining))
        }
        if let mode = CGDisplayCopyDisplayMode(id) { selection["after"] = Self.modeReport(mode) }
        if let screen = Self.screen(id) { selection["backingScale"] = screen.backingScaleFactor }
        selection["elapsedMs"] = MachClock.nowMs() - beganMs; selection["verified"] = false
        if reportToken == owned.token { report["modeSelection"] = selection }
        throw PortraitPrototypeFailure.rejected("owned HiDPI mode/NSScreen did not settle within five seconds or was cancelled")
    }
    private func ownedModeTarget(_ owned: PortraitResources) throws -> PortraitOwnedModeTarget {
        let id = owned.displayID
        let actualID = try owned.creation.display.map { try PortraitPrivateDisplay.displayID($0) } ?? 0
        let expectedIdentity: UInt32 = options.mode == .one ? 0x4361 : 0x4362
        return PortraitOwnedModeTarget(requestedID: id, retainedObjectID: actualID, objectRetained: owned.creation.display != nil,
            online: Self.onlineIDs().contains(id),
            identityMatches: CGDisplayVendorNumber(id) == 0xFA51 && CGDisplayModelNumber(id) == expectedIdentity && CGDisplaySerialNumber(id) == expectedIdentity,
            isMain: CGDisplayIsMain(id) != 0, isMirrored: CGDisplayIsInMirrorSet(id) != 0)
    }
    private static func modeCandidate(_ mode: CGDisplayMode) -> PortraitDisplayModeCandidate {
        PortraitDisplayModeCandidate(logicalWidth: mode.width, logicalHeight: mode.height, pixelWidth: mode.pixelWidth,
                                     pixelHeight: mode.pixelHeight, refreshHz: mode.refreshRate)
    }
    private static func modeReport(_ mode: CGDisplayMode) -> [String: Any] {
        ["logicalWidth": mode.width, "logicalHeight": mode.height, "pixelWidth": mode.pixelWidth,
         "pixelHeight": mode.pixelHeight, "refreshHz": mode.refreshRate, "desktopGUIUsable": mode.isUsableForDesktopGUI()]
    }
    private func stop(reason: String) async {
        guard let owned = resources else { return }
        if options.action == .smoke && reason != "smoke-complete" { recordFailure(owned, "smoke interrupted: \(reason)") }
        admission.cancel(); stopButton.isEnabled = false; status.stringValue = "Stopping…"
        owned.inventoryTask?.cancel(); owned.inventoryTask = nil; owned.view?.stop(); owned.output?.close()
        report["stopReason"] = reason
        if let owner = owned.captureOwner { owner.stop() }
        else { await releaseAfterCapture(owned) }
        let clean = await wait(5, { owned.cleaned }, token: nil)
        if !clean {
            owned.captureOwner?.deadline("capture-stop/removal unresolved after 5 seconds")
            lastResult = "cleanup-unresolved"; report["cleanupVerified"] = false
            status.stringValue = "Cleanup unresolved. Start is blocked; pending operations retain their resources."
            exitCode = 3
        }
        if let owner = owned.captureOwner, let failure = owner.failure { report["captureOwnerFailure"] = failure }
        report["result"] = lastResult; report["afterDisplays"] = Self.inventory(); Self.emit(report)
    }
    private func releaseAfterCapture(_ owned: PortraitResources) async {
        guard !owned.releaseStarted else { return }; owned.releaseStarted = true
        owned.output?.close(); owned.output = nil; owned.stream = nil
        owned.view?.stop(); owned.view = nil; owned.window?.orderOut(nil); owned.window?.close(); owned.window = nil
        let id = owned.displayID; owned.creation.releaseDisplay()
        if owned.creation.hadDisplay && id == 0 { report["cleanupVerified"] = false; return }
        let removed: Bool
        if id == 0 { removed = true } else { removed = await wait(5, { !Self.onlineIDs().contains(id) }, token: nil) }
        guard removed else {
            report["cleanupVerified"] = false
            // Removal itself has no callback. Continue observing without admitting a replacement run.
            owned.inventoryTask = Task { [weak self, weak owned] in
                while let self, let owned, self.resources === owned {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Self.onlineIDs().contains(id) { self.finishRemoval(owned); break }
                }
            }
            return
        }
        finishRemoval(owned)
    }
    private func finishRemoval(_ owned: PortraitResources) {
        owned.cleaned = true
        guard resources === owned else { return } // old callbacks cannot clear a newer run
        owned.creation.acknowledgeRemoval()
        resources = nil; admission.cleaned(); report["cleanupVerified"] = true
        preview.image = nil; startButton.isEnabled = !exitRequested; stopButton.isEnabled = false
        status.stringValue = "Stopped. Owned display removal verified."
        if lastResult == "running" || lastResult == "starting" { lastResult = "stopped" }
    }
    private func requestExit(reason: String) async {
        guard !exitRequested else { return }; exitRequested = true
        await stop(reason: reason); finishApplication()
    }
    private func recordFailure(_ owned: PortraitResources, _ reason: String) {
        owned.failed = true
        guard reportToken == owned.token else { return }
        report["error"] = report["error"] ?? reason; lastResult = "failed"; exitCode = 2
    }
    private func finishApplication(_ completed: PortraitResources? = nil) {
        if let completed, completed.failed { exitCode = 2 }
        if let completed, !completed.cleaned { exitCode = 3 }
        if report["cleanupVerified"] as? Bool != true && resources != nil { exitCode = 3 }
        else if lastResult == "failed" { exitCode = 2 }
        // If callbacks remain unresolved, exit releases the process connection. This is NOT verified teardown.
        control?.delegate = nil; control?.orderOut(nil)
        NSApplication.shared.stop(nil)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApplication.shared.postEvent(wake, atStart: false) }
    }
    private func wait(_ seconds: Double, _ condition: () -> Bool, token: UInt64?, timeoutIsSuccess: Bool = false) async -> Bool {
        let deadline = MachClock.nowMs() + seconds * 1000
        while !condition() {
            if let token, !admission.accepts(token) { return false }
            guard MachClock.nowMs() < deadline else { return timeoutIsSuccess }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return token.map { admission.accepts($0) } ?? true
    }
    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { screenID($0) == id } }
    private static func rectReport(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.origin.x), "y": Double(rect.origin.y), "width": Double(rect.width), "height": Double(rect.height)]
    }
}

@MainActor
private final class PortraitResources {
    let token: UInt64
    let creation = PortraitDisplayCreationOwner<PortraitRuntimeLease, NSObject>()
    var displayID: CGDirectDisplayID { creation.displayID }
    var window: NSWindow?
    var view: PortraitSyntheticView?
    var stream: SCStream?
    var output: PortraitCaptureOutput?
    var captureOwner: PortraitCaptureOwner?
    var inventoryTask: Task<Void, Never>?
    var createdAt = 0.0
    var releaseStarted = false
    var cleaned = false
    var failed = false
    init(token: UInt64) { self.token = token }
}

@MainActor
private final class PortraitDiscoveryGate {
    private var continuation: CheckedContinuation<SCShareableContent, Error>?
    init(_ continuation: CheckedContinuation<SCShareableContent, Error>) { self.continuation = continuation }
    func resolve(_ result: Result<SCShareableContent, Error>) {
        guard let continuation else { return }; self.continuation = nil; continuation.resume(with: result)
    }
}

/// The file is retained and never unlinked: unlinking a locked inode would permit a second lock owner.
/// Dedicated adapter: only exact arm64 scalar/struct signatures are allowed. No KVC, block callback,
/// copied private header, or guessed UInt/BOOL widths. ALL methods are checked before any allocation.
private enum PortraitPrivateDisplay {
    private typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector) -> Unmanaged<AnyObject>?
    private typealias ObjectInit = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias ModeInit = @convention(c) (Unmanaged<AnyObject>, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
    private typealias ObjectSetter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias UIntSetter = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias SizeSetter = @convention(c) (AnyObject, Selector, CGSize) -> Void
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private typealias IDGetter = @convention(c) (AnyObject, Selector) -> UInt32
    private static let classes = ["CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode", "CGVirtualDisplay"]
    private static let descriptorSetters = ["setQueue:", "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:", "setVendorID:", "setProductID:", "setSerialNum:"]
    static func isExperiment(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == 0xFA51 && [UInt32(0x4361), 0x4362].contains(CGDisplayModelNumber(id)) }
    static func audit() throws {
        #if !arch(arm64)
        throw PortraitPrototypeFailure.rejected("private ABI allowlist supports arm64 only")
        #else
        for name in classes {
            guard NSClassFromString(name) is NSObject.Type else { throw PortraitPrototypeFailure.rejected("private class is not an NSObject") }
            _ = try checked(name, "alloc", returns: "@", args: ["@", ":"], isClass: true)
        }
        for name in classes.prefix(2) { _ = try checked(name, "init", returns: "@", args: ["@", ":"]) }
        _ = try checked(classes[2], "initWithWidth:height:refreshRate:", returns: "@", args: ["@", ":", "I", "I", "d"])
        _ = try checked(classes[3], "initWithDescriptor:", returns: "@", args: ["@", ":", "@"])
        _ = try checked(classes[3], "applySettings:", returns: "B", args: ["@", ":", "@"])
        _ = try checked(classes[3], "displayID", returns: "I", args: ["@", ":"])
        for setter in descriptorSetters {
            let value = ["setQueue:", "setName:"].contains(setter) ? "@" : setter == "setSizeInMillimeters:" ? "{CGSize=dd}" : "I"
            _ = try checked(classes[0], setter, returns: "v", args: ["@", ":", value])
        }
        _ = try checked(classes[1], "setHiDPI:", returns: "v", args: ["@", ":", "I"])
        _ = try checked(classes[1], "setModes:", returns: "v", args: ["@", ":", "@"])
        #endif
    }
    private static func checked(_ className: String, _ name: String, returns: String, args: [String], isClass: Bool = false) throws -> (Method, Selector) {
        guard let cls = NSClassFromString(className) else { throw PortraitPrototypeFailure.rejected("missing private class \(className)") }
        let selector = NSSelectorFromString(name)
        guard let method = isClass ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == args.count else { throw PortraitPrototypeFailure.rejected("missing private method/arity \(className).\(name)") }
        func type(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
            guard let pointer else { return "missing" }; defer { free(pointer) }
            let raw = String(cString: pointer)
            return raw.hasPrefix("@\"") ? "@" : raw
        }
        guard PortraitABIEncoding.accepts(actualReturn: type(method_copyReturnType(method)),
                                         actualArguments: args.indices.map { type(method_copyArgumentType(method, UInt32($0))) },
                                         expectedReturn: returns, expectedArguments: args) else {
            throw PortraitPrototypeFailure.rejected("unsupported private ABI \(className).\(name)")
        }
        return (method, selector)
    }
    private static func function<T>(_ cls: String, _ name: String, returns: String, args: [String], as: T.Type) throws -> (T, Selector) {
        let (method, selector) = try checked(cls, name, returns: returns, args: args)
        return (unsafeBitCast(method_getImplementation(method), to: T.self), selector)
    }
    private static func allocated(_ name: String) throws -> Unmanaged<AnyObject> {
        let (method, selector) = try checked(name, "alloc", returns: "@", args: ["@", ":"], isClass: true)
        let call = unsafeBitCast(method_getImplementation(method), to: Alloc.self)
        guard let cls = NSClassFromString(name), let allocated = call(cls, selector) else { throw PortraitPrototypeFailure.rejected("private allocation failed") }
        return allocated
    }
    private static func initialized(_ name: String) throws -> NSObject {
        let (call, selector) = try function(name, "init", returns: "@", args: ["@", ":"], as: Init.self)
        return try retained(call(try allocated(name), selector))
    }
    private static func retained(_ value: Unmanaged<AnyObject>?) throws -> NSObject {
        guard let object = value?.takeRetainedValue() as? NSObject else { throw PortraitPrototypeFailure.rejected("private initializer returned nil/non-NSObject") }
        return object
    }
    static func construct(_ options: PortraitPrototypeOptions) throws -> NSObject {
        try audit()
        let descriptor = try initialized(classes[0])
        func object(_ key: String, _ value: AnyObject) throws {
            let (call, selector) = try function(classes[0], key, returns: "v", args: ["@", ":", "@"], as: ObjectSetter.self); call(descriptor, selector, value)
        }
        func uint(_ key: String, _ value: UInt32) throws {
            let (call, selector) = try function(classes[0], key, returns: "v", args: ["@", ":", "I"], as: UIntSetter.self); call(descriptor, selector, value)
        }
        try object("setQueue:", DispatchQueue.main as AnyObject)
        try object("setName:", "Farside Portrait \(options.mode.rawValue)" as NSString)
        try uint("setMaxPixelsWide:", UInt32(options.pixelWidth)); try uint("setMaxPixelsHigh:", UInt32(options.pixelHeight))
        try uint("setVendorID:", 0xFA51); try uint("setProductID:", options.mode == .one ? 0x4361 : 0x4362)
        try uint("setSerialNum:", options.mode == .one ? 0x4361 : 0x4362)
        let (size, sizeSelector) = try function(classes[0], "setSizeInMillimeters:", returns: "v", args: ["@", ":", "{CGSize=dd}"], as: SizeSetter.self)
        size(descriptor, sizeSelector, CGSize(width: 110, height: 238))
        let (displayInit, displaySelector) = try function(classes[3], "initWithDescriptor:", returns: "@", args: ["@", ":", "@"], as: ObjectInit.self)
        return try retained(displayInit(try allocated(classes[3]), displaySelector, descriptor))
    }
    static func configure(_ display: NSObject, _ options: PortraitPrototypeOptions) throws {
        let (modeInit, modeSelector) = try function(classes[2], "initWithWidth:height:refreshRate:", returns: "@", args: ["@", ":", "I", "I", "d"], as: ModeInit.self)
        let mode = try retained(modeInit(try allocated(classes[2]), modeSelector, 430, 932, 60))
        let settings = try initialized(classes[1])
        let (hidpi, hidpiSelector) = try function(classes[1], "setHiDPI:", returns: "v", args: ["@", ":", "I"], as: UIntSetter.self)
        hidpi(settings, hidpiSelector, options.mode == .two ? 1 : 0)
        let (modes, modesSelector) = try function(classes[1], "setModes:", returns: "v", args: ["@", ":", "@"], as: ObjectSetter.self)
        modes(settings, modesSelector, [mode] as NSArray)
        let (apply, applySelector) = try function(classes[3], "applySettings:", returns: "B", args: ["@", ":", "@"], as: Apply.self)
        guard apply(display, applySelector, settings) else { throw PortraitPrototypeFailure.rejected("private applySettings rejected requested mode") }
    }
    static func displayID(_ object: NSObject) throws -> CGDirectDisplayID {
        let (call, selector) = try function(classes[3], "displayID", returns: "I", args: ["@", ":"], as: IDGetter.self); return call(object, selector)
    }
}

@MainActor
private final class PortraitSyntheticView: NSView {
    private var link: CADisplayLink?
    private var tick = 0
    var observedTickCount: Int { tick }
    private let scale: Int
    override var isFlipped: Bool { true }
    init(frame: NSRect, scale: Int) { self.scale = scale; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func step() { tick += 1; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1).setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor.white]
        let lines = ["FARSIDE · OWN SYNTHETIC WINDOW", "430 × 932 pt · \(430 * scale) × \(932 * scale) px", "requested 60 Hz · frame \(tick)", "", "01  struct PortraitWorkspace {", "02    let width = 430", "03    let height = 932", "04    let capture = ownWindow", "05    // No user apps captured", "06    func stop() {", "07      stream.stopCapture()", "08      releaseOwnedDisplay()", "09    }", "10  }", "", "The moving bar tests cadence.", "Static phase stops display-link ticks."]
        for (index, line) in lines.enumerated() { (line as NSString).draw(at: NSPoint(x: 16, y: 24 + index * 27), withAttributes: attributes) }
        NSColor.systemOrange.setFill(); NSRect(x: CGFloat(tick % 320) + 16, y: 650, width: 65, height: 80).fill()
    }
}

/// Queue-owned counters and a single-slot pixel mailbox. A pending main callback carries no pixel;
/// newer frames replace the slot. Close drops the slot and disables all old callbacks before teardown.
private final class PortraitCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Farside.Portrait.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var previewScheduled = false
    private var closed = false
    private var metrics = PortraitFrameMetrics()
    private var measuring = false
    private var first: Double?
    private var correctGeometry = true
    private var errorCode: Int?
    private var failureReported = false
    private let width: Int
    private let height: Int
    var onPreview: (@MainActor (CVPixelBuffer) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    init(width: Int, height: Int) { self.width = width; self.height = height; super.init() }
    var hasFirstFrame: Bool { queue.sync { first != nil } }
    var firstFrameMs: Double? { queue.sync { first } }
    var geometryValid: Bool { queue.sync { correctGeometry } }
    var stopError: Int? { queue.sync { errorCode } }
    func beginPhase() { queue.sync { metrics = PortraitFrameMetrics(); measuring = true } }
    func endPhase() -> PortraitFrameMetrics { queue.sync { measuring = false; return metrics } }
    func close() { lock.lock(); closed = true; latest = nil; lock.unlock(); queue.sync { measuring = false } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let name: String
        switch status { case .complete: name = "complete"; case .idle: name = "idle"; case .blank: name = "blank";
        case .suspended: name = "suspended"; case .started: name = "started"; case .stopped: name = "stopped"; @unknown default: name = "unknown" }
        let ticks = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        if measuring { metrics.record(status: name, timeMs: ticks == 0 ? nil : MachClock.milliseconds(fromMachTicks: ticks)) }
        guard status == .complete, let buffer = sampleBuffer.imageBuffer else { return }
        first = first ?? MachClock.nowMs()
        if CVPixelBufferGetWidth(buffer) != width || CVPixelBufferGetHeight(buffer) != height {
            correctGeometry = false; reportFailure(); return
        }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        latest = buffer
        let schedule = !previewScheduled; previewScheduled = true; lock.unlock()
        if schedule { Task { @MainActor [weak self] in
            guard let self else { return }
            let buffer = self.takePreview()
            if let buffer { self.onPreview?(buffer) }
        } }
    }
    private func takePreview() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        let buffer = closed ? nil : latest; latest = nil; previewScheduled = false; return buffer
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.errorCode = (error as NSError).code; self?.reportFailure() }
    }
    private func reportFailure() {
        guard !failureReported else { return }; failureReported = true
        Task { @MainActor [weak self] in self?.onFailure?() }
    }
}
#endif
