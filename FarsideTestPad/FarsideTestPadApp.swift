import AppKit
import CoreGraphics

/// Farside Test Pad: the only window the E2E harness is allowed to click or type into.
/// Every event it receives is appended as one JSON object per line to the log (default
/// /private/tmp/farside-e2e/testpad.jsonl); its live geometry is published to testpad-state.json in
/// global CoreGraphics points (top-left origin of the primary display) so the harness can steer
/// the Mac pointer onto its targets. It never reads clipboard contents on its own: only pasteboard
/// metadata is logged, and pasted text arrives through its own text view.
@main
final class TestPadApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = TestPadApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    let options = TestPadOptions(arguments: ProcessInfo.processInfo.arguments)
    lazy var log = TestPadLog(path: options.logPath, runID: options.runID)
    private var window: TestPadWindow!
    private(set) var pad: TestPadView!
    private var timers: [Timer] = []
    private var stateDirty = true
    private var lastStateWrite: TimeInterval = 0
    private var commandOffset: UInt64 = 0
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var keyMonitor: Any?
    private var lastEventSeq: UInt64 { log.sequence }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1040, visible.width - 80), height: min(700, visible.height - 80))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window = TestPadWindow(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = "Farside Test Pad"
        window.isRestorable = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        pad = TestPadView(frame: NSRect(origin: .zero, size: size), app: self)
        window.contentView = pad
        pad.textView.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pad.textView)
        NSApp.activate()

        if let size = (try? FileManager.default.attributesOfItem(atPath: options.commandsPath))?[.size] as? UInt64 {
            commandOffset = size
        }
        observeSystem()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.logKey(event)
            return event
        }
        schedule(1.0 / 30.0) { [weak self] in self?.pad.clock.needsDisplay = true }
        schedule(0.1) { [weak self] in self?.pollCommands() }
        schedule(0.25) { [weak self] in self?.pollPasteboard() }
        schedule(0.2) { [weak self] in self?.writeStateIfNeeded() }
        schedule(5) { [weak self] in self?.heartbeat() }
        log.write("launched", ["pid": Int(getpid()), "logPath": options.logPath, "statePath": options.statePath,
                               "commandsPath": options.commandsPath, "screen": TestPadGeometry.global(screen.frame)])
        markDirty()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        log.write("terminating")
        log.flush()
    }

    // MARK: Logging helpers

    func markDirty() { stateDirty = true }

    func modifiers(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        return names
    }

    func globalPoint(_ event: NSEvent) -> CGPoint {
        TestPadGeometry.global(point: NSEvent.mouseLocation)
    }

    private func logKey(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            log.write("flagsChanged", ["keyCode": Int(event.keyCode), "modifiers": modifiers(event.modifierFlags)])
        default:
            log.write(event.type == .keyDown ? "keyDown" : "keyUp", [
                "keyCode": Int(event.keyCode),
                "characters": event.characters ?? "",
                "charactersIgnoringModifiers": event.charactersIgnoringModifiers ?? "",
                "modifiers": modifiers(event.modifierFlags),
                "isRepeat": event.isARepeat,
                "firstResponder": String(describing: type(of: window.firstResponder as Any))
            ])
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let text = pad.textView.string
        log.write("textChanged", ["text": String(text.prefix(2048)), "length": text.count,
                                  "selection": selectionInfo()])
        markDirty()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        log.write("selectionChanged", ["selection": selectionInfo(), "length": pad.textView.string.count])
        markDirty()
    }

    private func selectionInfo() -> [String: Int] {
        let range = pad.textView.selectedRange()
        return ["location": range.location, "length": range.length]
    }

    // MARK: Window, app and Space state

    private func observeSystem() {
        let center = NotificationCenter.default
        let windowEvents: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "becameKey"), (NSWindow.didResignKeyNotification, "resignedKey"),
            (NSWindow.didMoveNotification, "moved"), (NSWindow.didResizeNotification, "resized"),
            (NSWindow.didChangeOcclusionStateNotification, "occlusion"),
            (NSWindow.didMiniaturizeNotification, "miniaturized"), (NSWindow.didDeminiaturizeNotification, "deminiaturized")
        ]
        for (name, label) in windowEvents {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowEvent(label) }
            }
        }
        for (name, label) in [(NSApplication.didBecomeActiveNotification, "becameActive"),
                              (NSApplication.didResignActiveNotification, "resignedActive")] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log.write("app", ["event": label, "active": NSApp.isActive])
                    self.markDirty()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.write("space", ["event": "activeSpaceChanged", "onActiveSpace": self.window.isOnActiveSpace,
                                         "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
                self.markDirty()
            }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.write("screenParameters")
                self?.markDirty()
            }
        }
    }

    private func windowEvent(_ label: String) {
        log.write("window", ["event": label, "frame": TestPadGeometry.global(window.frame),
                             "key": window.isKeyWindow, "visible": window.occlusionState.contains(.visible),
                             "onActiveSpace": window.isOnActiveSpace])
        markDirty()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullScreen("willEnter") }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreen("didEnter") }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreen("willExit") }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreen("didExit") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreen("failedToEnter") }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreen("failedToExit") }

    private func fullScreen(_ phase: String) {
        pad.fullScreenButton.title = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
        log.write("fullscreen", ["phase": phase, "fullscreen": isFullScreen,
                                 "frame": TestPadGeometry.global(window.frame), "onActiveSpace": window.isOnActiveSpace])
        markDirty()
    }

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    @objc func toggleFullScreenFromButton(_ sender: Any?) {
        log.write("fullscreenButton", ["fullscreen": isFullScreen])
        window.toggleFullScreen(nil)
    }

    private func heartbeat() {
        log.write("heartbeat", ["active": NSApp.isActive, "key": window.isKeyWindow, "fullscreen": isFullScreen,
                                "onActiveSpace": window.isOnActiveSpace,
                                "visible": window.occlusionState.contains(.visible)])
        markDirty()
    }

    // MARK: Pasteboard metadata (never contents)

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount
        let types = pasteboard.types?.map(\.rawValue) ?? []
        pad.clipboardLabel.stringValue = "Clipboard changed · #\(pasteboardChangeCount) · \(types.first ?? "no types")"
        log.write("pasteboardChanged", ["changeCount": pasteboardChangeCount, "types": Array(types.prefix(8))])
        markDirty()
    }

    // MARK: Commands from the harness

    private func pollCommands() {
        guard let handle = FileHandle(forReadingAtPath: options.commandsPath) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: commandOffset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let newline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...newline]
        commandOffset += UInt64(complete.count)
        for line in complete.split(separator: 0x0A) {
            guard let command = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            perform(command)
        }
    }

    private func perform(_ command: [String: Any]) {
        let id = command["id"] as? String ?? ""
        let name = command["cmd"] as? String ?? ""
        var result: [String: Any] = ["id": id, "cmd": name, "ok": true]
        switch name {
        case "reset":
            pad.reset()
            window.makeFirstResponder(pad.textView)
        case "setText":
            let text = command["text"] as? String ?? ""
            pad.textView.string = text
            pad.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textDidChange(Notification(name: NSText.didChangeNotification))
        case "focusText":
            window.makeFirstResponder(pad.textView)
        case "enterFullScreen":
            if !isFullScreen { window.toggleFullScreen(nil) } else { result["note"] = "already full screen" }
        case "exitFullScreen":
            if isFullScreen { window.toggleFullScreen(nil) } else { result["note"] = "not full screen" }
        case "activate":
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        case "homePointer":
            let element = command["element"] as? String ?? "home"
            if let frame = pad.globalFrames()[element] {
                let point = CGPoint(x: frame.midX, y: frame.midY)
                let error = CGWarpMouseCursorPosition(point)
                CGAssociateMouseAndMouseCursorPosition(1)
                result["point"] = TestPadGeometry.json(point)
                if error != .success { result["ok"] = false; result["error"] = "warp failed \(error.rawValue)" }
            } else {
                result["ok"] = false; result["error"] = "unknown element \(element)"
            }
        case "mark":
            result["label"] = command["label"] as? String ?? ""
        case "selfCheck":
            result["checks"] = selfCheck()
            result["ok"] = (result["checks"] as? [String: Bool])?.values.allSatisfy { $0 } ?? false
        case "quit":
            log.write("command", result)
            NSApp.terminate(nil)
            return
        default:
            result["ok"] = false
            result["error"] = "unknown command"
        }
        log.write("command", result)
        markDirty()
    }

    // MARK: Self-check (in-window synthetic events only; no global input, no cursor movement)

    /// Proves the fixture's own handlers and log without any injection permission: events are
    /// handed straight to this window, so nothing outside the Test Pad can receive them.
    private func selfCheck() -> [String: Bool] {
        let before = log.sequence
        pad.reset()
        window.makeFirstResponder(pad.textView)
        let frames = pad.localFrames()
        func point(_ name: String, dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
            let frame = frames[name] ?? .zero
            return NSPoint(x: frame.midX + dx, y: frame.midY + dy)
        }
        func mouse(_ type: NSEvent.EventType, _ location: NSPoint, clicks: Int = 1) {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
            window.sendEvent(event)
        }
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown, modifiers.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
                window.sendEvent(event)
            }
        }
        mouse(.leftMouseDown, point("A")); mouse(.leftMouseUp, point("A"))
        mouse(.rightMouseDown, point("B")); mouse(.rightMouseUp, point("B"))
        mouse(.leftMouseDown, point("C")); mouse(.leftMouseUp, point("C"))
        mouse(.leftMouseDown, point("C"), clicks: 2); mouse(.leftMouseUp, point("C"), clicks: 2)
        let handle = point("dragHandle")
        mouse(.leftMouseDown, handle)
        mouse(.leftMouseDragged, NSPoint(x: handle.x + 40, y: handle.y + 10))
        mouse(.leftMouseDragged, NSPoint(x: handle.x + 80, y: handle.y + 20))
        mouse(.leftMouseUp, NSPoint(x: handle.x + 80, y: handle.y + 20))
        window.makeFirstResponder(pad.textView)
        key("h", code: 4); key("i", code: 34)
        key("a", code: 0, modifiers: .command)
        let events = Array(log.recent.drop { ($0["seq"] as? UInt64 ?? 0) <= before })
        func has(_ type: String, _ test: ([String: Any]) -> Bool = { _ in true }) -> Bool {
            events.contains { $0["type"] as? String == type && test($0) }
        }
        return [
            "click": has("click") { $0["element"] as? String == "A" && $0["button"] as? String == "left" },
            "rightClick": has("click") { $0["element"] as? String == "B" && $0["button"] as? String == "right" },
            "doubleClick": has("click") { $0["element"] as? String == "C" && ($0["clickCount"] as? Int) == 2 },
            "drag": has("dragEnd") { (($0["delta"] as? [String: Double])?["x"] ?? 0) > 30 },
            "typing": pad.textView.string == "hi",
            "selectAll": pad.textView.selectedRange().length == 2,
            "state": FileManager.default.fileExists(atPath: options.statePath)
        ]
    }

    // MARK: Published geometry

    private func writeStateIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard stateDirty || now - lastStateWrite >= 1 else { return }
        stateDirty = false
        lastStateWrite = now
        let content = window.contentView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? window.frame
        let screen = window.screen ?? NSScreen.screens.first
        let state: [String: Any] = [
            "pid": Int(getpid()),
            "run": options.runID,
            "t": Date().timeIntervalSince1970,
            "windowFrame": TestPadGeometry.global(window.frame),
            "contentFrame": TestPadGeometry.global(content),
            "screenFrame": screen.map { TestPadGeometry.global($0.frame) } ?? [:],
            "fullscreen": isFullScreen,
            "key": window.isKeyWindow,
            "active": NSApp.isActive,
            "onActiveSpace": window.isOnActiveSpace,
            "visible": window.occlusionState.contains(.visible),
            "elements": pad.globalFrames().mapValues { TestPadGeometry.json($0) },
            "text": String(pad.textView.string.prefix(2048)),
            "selection": selectionInfo(),
            "scrollOffset": Double(pad.scroll.contentView.bounds.origin.y),
            "counters": pad.counters,
            "pasteboardChangeCount": pasteboardChangeCount,
            "lastSeq": lastEventSeq
        ]
        TestPadLog.writeAtomically(state, to: options.statePath)
    }

    private func schedule(_ interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Farside Test Pad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

struct TestPadOptions {
    var logPath = "/private/tmp/farside-e2e/testpad.jsonl"
    var statePath = "/private/tmp/farside-e2e/testpad-state.json"
    var commandsPath = "/private/tmp/farside-e2e/testpad-commands.jsonl"
    var runID = "manual"

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        logPath = value("--log") ?? logPath
        statePath = value("--state") ?? statePath
        commandsPath = value("--commands") ?? commandsPath
        runID = value("--run-id") ?? runID
    }
}

/// JSON-lines event log with a monotonic sequence number.
final class TestPadLog {
    let path: String
    let runID: String
    private(set) var sequence: UInt64 = 0
    /// Last few hundred events, for the self-check.
    private(set) var recent: [[String: Any]] = []
    private var handle: FileHandle?
    private let start = ProcessInfo.processInfo.systemUptime

    init(path: String, runID: String) {
        self.path = path
        self.runID = runID
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
    }

    func write(_ type: String, _ fields: [String: Any] = [:]) {
        sequence += 1
        var line = fields
        line["type"] = type
        line["seq"] = sequence
        line["t"] = Date().timeIntervalSince1970
        line["mono"] = ProcessInfo.processInfo.systemUptime
        line["run"] = runID
        recent.append(line)
        if recent.count > 400 { recent.removeFirst(recent.count - 400) }
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        try? handle?.write(contentsOf: data)
    }

    func flush() { try? handle?.synchronize() }

    static func writeAtomically(_ object: [String: Any], to path: String) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        let temporary = path + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        _ = rename(temporary, path)
    }
}

/// Converts AppKit screen coordinates (bottom-left origin) to global CoreGraphics points.
enum TestPadGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func global(point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func globalRect(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func global(_ rect: NSRect) -> [String: Double] { json(globalRect(rect)) }

    static func json(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }

    static func json(_ point: CGPoint) -> [String: Double] { ["x": Double(point.x), "y": Double(point.y)] }
}

final class TestPadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Content

final class TestPadView: NSView {
    unowned let app: TestPadApp
    let header = NSTextField(labelWithString: "")
    let clock = ClockView()
    var targets: [TargetView] = []
    let dragField = DragFieldView()
    let scroll = LoggingScrollView()
    let textView = NSTextView()
    let textScroll = NSScrollView()
    let clipboardLabel = NSTextField(labelWithString: "Clipboard: no change yet")
    let fullScreenButton = NSButton(title: "Enter Full Screen", target: nil, action: nil)
    let home = NSView()
    var counters: [String: Int] = [:]
    private var lastMove: TimeInterval = 0

    override var isFlipped: Bool { true }

    init(frame: NSRect, app: TestPadApp) {
        self.app = app
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        header.stringValue = "Farside Test Pad · E2E fixture · run \(app.options.runID). The harness only clicks and types in this window."
        header.textColor = .white
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(header)
        addSubview(clock)
        for (index, name) in ["A", "B", "C", "D"].enumerated() {
            let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemOrange]
            let target = TargetView(id: name, color: colors[index], pad: self)
            targets.append(target)
            addSubview(target)
        }
        dragField.pad = self
        addSubview(dragField)
        scroll.pad = self
        scroll.hasVerticalScroller = true
        scroll.documentView = ScrollContentView(frame: NSRect(x: 0, y: 0, width: 280, height: 3000))
        addSubview(scroll)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("testpad.text")
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        addSubview(textScroll)
        clipboardLabel.textColor = .lightGray
        addSubview(clipboardLabel)
        fullScreenButton.target = app
        fullScreenButton.action = #selector(TestPadApp.toggleFullScreenFromButton(_:))
        fullScreenButton.bezelStyle = .rounded
        addSubview(fullScreenButton)
        home.wantsLayer = true
        home.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        home.layer?.borderWidth = 1
        addSubview(home)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Proportional layout so every element keeps a generous size in a window or full screen.
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let margin: CGFloat = 20
        header.frame = NSRect(x: margin, y: 12, width: width - 2 * margin - 240, height: 20)
        clock.frame = NSRect(x: width - margin - 220, y: 8, width: 220, height: 28)
        let targetTop: CGFloat = 48
        let targetHeight = max(80, height * 0.16)
        let targetWidth = (width - 2 * margin - 3 * 16) / 4
        for (index, target) in targets.enumerated() {
            target.frame = NSRect(x: margin + CGFloat(index) * (targetWidth + 16), y: targetTop,
                                  width: targetWidth, height: targetHeight)
        }
        let rowTop = targetTop + targetHeight + 20
        let rowHeight = max(180, height * 0.36)
        let columnWidth = (width - 2 * margin - 2 * 16) / 3
        dragField.frame = NSRect(x: margin, y: rowTop, width: columnWidth, height: rowHeight)
        scroll.frame = NSRect(x: margin + columnWidth + 16, y: rowTop, width: columnWidth, height: rowHeight)
        textScroll.frame = NSRect(x: margin + 2 * (columnWidth + 16), y: rowTop, width: columnWidth, height: rowHeight)
        textView.frame = NSRect(origin: .zero, size: textScroll.contentSize)
        textView.minSize = NSSize(width: 0, height: textScroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: textScroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let bottomTop = rowTop + rowHeight + 20
        fullScreenButton.frame = NSRect(x: margin, y: bottomTop, width: 180, height: 32)
        clipboardLabel.frame = NSRect(x: margin + 200, y: bottomTop + 6, width: width - 2 * margin - 200, height: 20)
        let homeTop = bottomTop + 48
        home.frame = NSRect(x: margin, y: homeTop, width: width - 2 * margin, height: max(40, height - homeTop - margin))
        dragField.clampHandle()
        app.markDirty()
    }

    func globalFrames() -> [String: CGRect] {
        guard let window else { return [:] }
        func frame(_ view: NSView, _ rect: NSRect? = nil) -> CGRect {
            TestPadGeometry.globalRect(window.convertToScreen(view.convert(rect ?? view.bounds, to: nil)))
        }
        var frames: [String: CGRect] = [:]
        for target in targets { frames[target.id] = frame(target) }
        frames["dragField"] = frame(dragField)
        frames["dragHandle"] = frame(dragField, dragField.handleRect)
        frames["scroll"] = frame(scroll)
        frames["text"] = frame(textScroll)
        frames["fullscreenButton"] = frame(fullScreenButton)
        frames["home"] = frame(home)
        frames["clock"] = frame(clock)
        return frames
    }

    /// Element frames in window coordinates, for in-window synthetic events.
    func localFrames() -> [String: NSRect] {
        var frames: [String: NSRect] = [:]
        for target in targets { frames[target.id] = target.convert(target.bounds, to: nil) }
        frames["dragHandle"] = dragField.convert(dragField.handleRect, to: nil)
        frames["text"] = textScroll.convert(textScroll.bounds, to: nil)
        frames["scroll"] = scroll.convert(scroll.bounds, to: nil)
        return frames
    }

    func reset() {
        textView.string = ""
        dragField.resetHandle()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        counters = [:]
        for target in targets { target.hits = 0; target.needsDisplay = true }
        app.markDirty()
    }

    func count(_ key: String) { counters[key, default: 0] += 1 }

    func logMouse(_ type: String, _ event: NSEvent, element: String, view: NSView) {
        let local = view.convert(event.locationInWindow, from: nil)
        let button: String
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: button = "right"
        case .otherMouseDown, .otherMouseUp: button = "other"
        default: button = "left"
        }
        app.log.write(type, ["element": element, "button": button, "clickCount": event.clickCount,
                             "local": TestPadGeometry.json(CGPoint(x: local.x, y: local.y)),
                             "screen": TestPadGeometry.json(app.globalPoint(event)),
                             "modifiers": app.modifiers(event.modifierFlags)])
    }

    override func mouseMoved(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove >= 0.1 else { return }
        lastMove = now
        let point = convert(event.locationInWindow, from: nil)
        let element = subviews.first { $0.frame.contains(point) }.flatMap(elementName) ?? "background"
        app.log.write("mouseMoved", ["element": element, "screen": TestPadGeometry.json(app.globalPoint(event))])
    }

    override func mouseDown(with event: NSEvent) { logMouse("mouseDown", event, element: "background", view: self) }
    override func mouseUp(with event: NSEvent) { logMouse("mouseUp", event, element: "background", view: self) }
    override func rightMouseDown(with event: NSEvent) { logMouse("mouseDown", event, element: "background", view: self) }
    override func rightMouseUp(with event: NSEvent) { logMouse("mouseUp", event, element: "background", view: self) }

    private func elementName(_ view: NSView) -> String? {
        if let target = view as? TargetView { return target.id }
        if view === dragField { return "dragField" }
        if view === scroll { return "scroll" }
        if view === textScroll { return "text" }
        if view === fullScreenButton { return "fullscreenButton" }
        if view === home { return "home" }
        return nil
    }
}

/// A click target that logs button, click count and position.
final class TargetView: NSView {
    let id: String
    let color: NSColor
    unowned let pad: TestPadView
    var hits = 0
    private var pressedButton: String?

    init(id: String, color: NSColor, pad: TestPadView) {
        self.id = id
        self.color = color
        self.pad = pad
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(hits % 2 == 0 ? 0.55 : 0.9).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let text = "\(id)  ·  \(hits)" as NSString
        text.draw(at: NSPoint(x: 14, y: 12), withAttributes: [.foregroundColor: NSColor.white,
                                                              .font: NSFont.systemFont(ofSize: 26, weight: .bold)])
    }

    override func mouseDown(with event: NSEvent) { down(event, "left") }
    override func rightMouseDown(with event: NSEvent) { down(event, "right") }
    override func otherMouseDown(with event: NSEvent) { down(event, "other") }
    override func mouseUp(with event: NSEvent) { up(event) }
    override func rightMouseUp(with event: NSEvent) { up(event) }
    override func otherMouseUp(with event: NSEvent) { up(event) }

    private func down(_ event: NSEvent, _ button: String) {
        pressedButton = button
        pad.logMouse("mouseDown", event, element: id, view: self)
    }

    private func up(_ event: NSEvent) {
        pad.logMouse("mouseUp", event, element: id, view: self)
        guard let button = pressedButton else { return }
        pressedButton = nil
        hits += 1
        pad.count("click.\(id).\(button)")
        needsDisplay = true
        pad.app.log.write("click", ["element": id, "button": button, "clickCount": event.clickCount,
                                    "screen": TestPadGeometry.json(pad.app.globalPoint(event))])
        pad.app.markDirty()
    }
}

/// A field with a draggable handle; logs start, sampled moves and end.
final class DragFieldView: NSView {
    weak var pad: TestPadView?
    private(set) var handleRect = NSRect(x: 20, y: 20, width: 72, height: 72)
    private var dragStart: (mouse: NSPoint, handle: NSPoint)?
    private var lastLogged: TimeInterval = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resetHandle() {
        handleRect.origin = NSPoint(x: 20, y: 20)
        clampHandle()
    }

    func clampHandle() {
        handleRect.origin.x = min(max(0, handleRect.origin.x), max(0, bounds.width - handleRect.width))
        handleRect.origin.y = min(max(0, handleRect.origin.y), max(0, bounds.height - handleRect.height))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        ("Drag field" as NSString).draw(at: NSPoint(x: 10, y: bounds.height - 24),
                                         withAttributes: [.foregroundColor: NSColor.lightGray, .font: NSFont.systemFont(ofSize: 12)])
        (dragStart == nil ? NSColor.systemPurple : NSColor.systemPink).setFill()
        NSBezierPath(roundedRect: handleRect, xRadius: 10, yRadius: 10).fill()
        ("DRAG" as NSString).draw(at: NSPoint(x: handleRect.minX + 14, y: handleRect.minY + 26),
                                  withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .bold)])
    }

    override func mouseDown(with event: NSEvent) {
        guard let pad else { return }
        let point = convert(event.locationInWindow, from: nil)
        pad.logMouse("mouseDown", event, element: handleRect.contains(point) ? "dragHandle" : "dragField", view: self)
        guard handleRect.contains(point) else { return }
        dragStart = (point, handleRect.origin)
        pad.app.log.write("dragStart", ["handle": handleCenter(), "clickCount": event.clickCount,
                                        "screen": TestPadGeometry.json(pad.app.globalPoint(event))])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pad, let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        handleRect.origin = NSPoint(x: dragStart.handle.x + point.x - dragStart.mouse.x,
                                    y: dragStart.handle.y + point.y - dragStart.mouse.y)
        clampHandle()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLogged >= 0.05 {
            lastLogged = now
            pad.app.log.write("dragMove", ["handle": handleCenter(), "screen": TestPadGeometry.json(pad.app.globalPoint(event))])
        }
        pad.app.markDirty()
    }

    override func mouseUp(with event: NSEvent) {
        guard let pad else { return }
        pad.logMouse("mouseUp", event, element: "dragField", view: self)
        guard let dragStart else { return }
        self.dragStart = nil
        pad.count("drag")
        pad.app.log.write("dragEnd", ["handle": handleCenter(),
                                      "delta": ["x": Double(handleRect.origin.x - dragStart.handle.x),
                                                "y": Double(handleRect.origin.y - dragStart.handle.y)],
                                      "screen": TestPadGeometry.json(pad.app.globalPoint(event))])
        needsDisplay = true
        pad.app.markDirty()
    }

    private func handleCenter() -> [String: Double] {
        guard let window else { return [:] }
        let rect = TestPadGeometry.globalRect(window.convertToScreen(convert(handleRect, to: nil)))
        return ["x": Double(rect.midX), "y": Double(rect.midY)]
    }
}

/// Scroll area that logs wheel/trackpad deltas and the resulting offset.
final class LoggingScrollView: NSScrollView {
    weak var pad: TestPadView?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let pad else { return }
        pad.count("scroll")
        pad.app.log.write("scroll", [
            "deltaX": Double(event.deltaX), "deltaY": Double(event.deltaY),
            "scrollingDeltaX": Double(event.scrollingDeltaX), "scrollingDeltaY": Double(event.scrollingDeltaY),
            "precise": event.hasPreciseScrollingDeltas, "phase": Int(event.phase.rawValue),
            "momentumPhase": Int(event.momentumPhase.rawValue),
            "offsetY": Double(contentView.bounds.origin.y),
            "screen": TestPadGeometry.json(pad.app.globalPoint(event))
        ])
        pad.app.markDirty()
    }
}

final class ScrollContentView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()
        let first = max(0, Int(dirtyRect.minY / 30)), last = min(99, Int(dirtyRect.maxY / 30) + 1)
        guard first <= last else { return }
        for row in first...last {
            let rect = NSRect(x: 0, y: CGFloat(row) * 30, width: bounds.width, height: 30)
            (row % 2 == 0 ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.18, alpha: 1)).setFill()
            rect.fill()
            ("Row \(row)" as NSString).draw(at: NSPoint(x: 12, y: rect.minY + 7),
                                            withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        }
    }
}

/// Always-changing strip so the video stream never goes idle and stalls are measurable.
final class ClockView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let now = Date().timeIntervalSince1970
        let phase = CGFloat(now.truncatingRemainder(dividingBy: 2) / 2)
        NSColor.systemTeal.setFill()
        NSRect(x: phase * (bounds.width - 24), y: 0, width: 24, height: bounds.height).fill()
        (String(format: "%.3f", now) as NSString).draw(at: NSPoint(x: 8, y: 5),
            withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)])
    }
}
