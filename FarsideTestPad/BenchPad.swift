import AppKit
import QuartzCore

/// The Test Pad's `--bench` stimulus (Docs/perf/INSTRUMENTS-DESIGN.md §1): one borderless window over
/// the whole display, so window points equal display points and the shared marker and chart
/// geometry lands exactly where the phone reads it in every decoded frame.
@MainActor
final class BenchPad: NSObject {
    static let defaultSnapshotDirectory = "/private/tmp/farside-e2e"

    unowned let app: TestPadApp
    let window: BenchWindow
    let view: BenchView
    private(set) var state: BenchState
    private(set) var displayIndex: Int
    private var displayID: CGDirectDisplayID
    private let requestedDisplay: Int?
    private var link: CADisplayLink?
    private var shownFlash = false
    private var observers: [NSObjectProtocol] = []

    init(app: TestPadApp, requestedDisplay: Int?) {
        self.app = app
        self.requestedDisplay = requestedDisplay
        let screens = NSScreen.screens
        let index = requestedDisplay.flatMap { screens.indices.contains($0) ? $0 : nil } ?? 0
        let screen = screens.indices.contains(index) ? screens[index] : NSScreen.main!
        displayIndex = index
        displayID = Self.displayID(of: screen)
        state = BenchState(seed: LegibilityChart.randomSeed())
        window = BenchWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        view = BenchView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.title = "Farside Test Pad Bench"
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        view.pad = self
        view.flash.pad = self
    }

    private static func activate() {
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        Self.activate()
        // Keys from the phone go to the frontmost app; a launch from a terminal may leave that app in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !NSApp.isActive { Self.activate() } }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reframe() }
        })
        let screens = NSScreen.screens.enumerated().map { index, screen -> [String: Any] in
            ["index": index, "displayID": Int(Self.displayID(of: screen)), "name": screen.localizedName,
             "frame": TestPadGeometry.global(screen.frame)]
        }
        var fields: [String: Any] = [
            "displayIndex": displayIndex, "displayID": Int(displayID), "screens": screens,
            "screenFrame": TestPadGeometry.global(window.frame),
            "pointSize": ["width": Double(view.bounds.width), "height": Double(view.bounds.height)],
            "backingScale": Double(window.backingScaleFactor),
            "safeAreaTop": Double(window.screen?.safeAreaInsets.top ?? 0),
            "elements": view.globalFrames()
        ]
        if let requestedDisplay { fields["requestedDisplay"] = requestedDisplay }
        app.log.write("bench.launched", fields)
        logChart(source: "launch")
        app.markDirty()
    }

    // MARK: Frames

    @objc private func step(_ link: CADisplayLink) {
        if let time = state.markerTime(now: MachClock.milliseconds(fromMediaTime: link.targetTimestamp)) {
            show(time)
        }
        link.isPaused = !state.wantsFrames
    }

    /// Everything visible changes in the same display-link frame as the marker that describes it.
    private func show(_ time: Double) {
        view.markerView.marker = state.shownMarker
        view.chartSeed = state.seed
        view.flash.lit = state.flash
        view.lane.fraction = state.boxFraction
        view.codePane.scroll(to: state.scrollOffset)
        view.clock.show(timeMs: time, status: statusLine)
        if state.flash != shownFlash {
            shownFlash = state.flash
            app.log.write("bench.flashShown", ["flash": state.flash, "markerMs": time])
        }
    }

    private func changed() {
        link?.isPaused = !state.wantsFrames
        app.markDirty()
    }

    private var statusLine: String {
        func word(_ on: Bool) -> String { on ? "on" : "off" }
        return "seed \(state.seed) · motion \(word(state.motion)) · scroll \(word(state.scroll)) · flash \(word(state.flash))"
            + (state.autoFlash ? " · auto-flash" : "")
    }

    // MARK: Actions

    func newChart(seed requested: UInt16?, source: String) {
        if state.setChart(seed: requested ?? BenchState.randomSeed(excluding: state.seed)) { changed() }
        logChart(source: source)
    }

    private func logChart(source: String) {
        let cells = LegibilityChart.cells(seed: state.seed).map { cell -> [String: Any] in
            ["id": cell.id, "text": cell.text, "pointSize": cell.pointSize, "face": cell.face.rawValue,
             "colourway": cell.colourway.rawValue]
        }
        app.log.write("bench.chart", ["seed": Int(state.seed), "cells": cells, "source": source, "machMs": MachClock.nowMs()])
    }

    func setMotion(_ on: Bool, source: String) {
        if state.setMotion(on) { changed() }
        app.log.write("bench.motion", ["on": state.motion, "source": source])
    }

    func setScroll(_ on: Bool, source: String) {
        if state.setScroll(on) { changed() }
        app.log.write("bench.scroll", ["on": state.scroll, "source": source])
    }

    func jump(source: String) {
        let height = Double(view.codePane.bounds.height)
        state.jump(by: height)
        changed()
        app.log.write("bench.jump", ["by": height, "offset": state.scrollOffset, "source": source])
    }

    func toggleFlash(machMs: Double, source: String) {
        state.toggleFlash()
        changed()
        app.log.write("bench.flash", ["machMs": machMs, "flash": state.flash, "source": source])
    }

    /// Camera kit: the flash target toggles on its own every 400-700 ms; each toggle is logged as
    /// `bench.flashShown` with its display time, like a manual flash.
    func setAutoFlash(_ on: Bool, source: String) {
        let seed = UInt64.random(in: 1...UInt64.max)
        if state.setAutoFlash(on, now: MachClock.nowMs(), seed: seed) { changed() }
        app.log.write("bench.autoflash", ["on": state.autoFlash, "seed": String(seed), "source": source])
    }

    func flashPressed(_ event: NSEvent) {
        toggleFlash(machMs: MachClock.milliseconds(fromMediaTime: event.timestamp), source: "mouse")
    }

    func quit(source: String) {
        app.log.write("bench.quit", ["source": source])
        link?.invalidate()
        link = nil
        NSApp.terminate(nil)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 {
            quit(source: "key")
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), ["c", "m", "s", "j", "a", " ", "q"].contains(key) else {
            return false
        }
        guard !event.isARepeat else { return true }
        switch key {
        case "c": newChart(seed: nil, source: "key")
        case "m": setMotion(!state.motion, source: "key")
        case "s": setScroll(!state.scroll, source: "key")
        case "j": jump(source: "key")
        case "a": setAutoFlash(!state.autoFlash, source: "key")
        case " ": toggleFlash(machMs: MachClock.milliseconds(fromMediaTime: event.timestamp), source: "key")
        default: quit(source: "key")
        }
        return true
    }

    // MARK: Commands

    func perform(_ name: String, _ command: [String: Any], result: inout [String: Any]) {
        switch name {
        case "bench.chart":
            var seed: UInt16?
            if let raw = command["seed"] {
                guard let value = raw as? Int, let parsed = BenchState.chartSeed(requested: value, current: state.seed) else {
                    return fail(&result, "seed must be an integer from 0 (random) to 4095")
                }
                seed = parsed
            }
            newChart(seed: seed, source: "command")
            result["seed"] = Int(state.seed)
        case "bench.motion", "bench.scroll":
            let motion = name == "bench.motion"
            guard let on = Self.switchValue(command["on"], current: motion ? state.motion : state.scroll) else {
                return fail(&result, "on must be true or false")
            }
            if motion { setMotion(on, source: "command") } else { setScroll(on, source: "command") }
            result["on"] = on
        case "bench.jump":
            jump(source: "command")
            result["offset"] = state.scrollOffset
        case "bench.flash":
            toggleFlash(machMs: MachClock.nowMs(), source: "command")
            result["flash"] = state.flash
        case "bench.autoflash":
            guard let on = Self.switchValue(command["on"], current: state.autoFlash) else {
                return fail(&result, "on must be true or false")
            }
            setAutoFlash(on, source: "command")
            result["on"] = on
        case "bench.snapshot":
            let path = command["path"] as? String ?? "\(Self.defaultSnapshotDirectory)/bench-chart-\(state.seed).png"
            do {
                let fields = try snapshot(path: path)
                result.merge(fields) { _, new in new }
            } catch {
                return fail(&result, (error as? BenchError)?.message ?? error.localizedDescription)
            }
        case "bench.state":
            result["seed"] = Int(state.seed)
            result["motion"] = state.motion
            result["scroll"] = state.scroll
            result["flash"] = state.flash
            result["autoFlash"] = state.autoFlash
        default:
            return fail(&result, "unknown command")
        }
        result["bench"] = summary
    }

    private func fail(_ result: inout [String: Any], _ message: String) {
        result["ok"] = false
        result["error"] = message
    }

    /// A missing value toggles; booleans and "on"/"off" set.
    static func switchValue(_ raw: Any?, current: Bool) -> Bool? {
        guard let raw else { return !current }
        switch raw {
        case let value as Bool: return value
        case let value as String: return ["on": true, "true": true, "off": false, "false": false][value.lowercased()]
        default: return nil
        }
    }

    private func snapshot(path: String) throws -> [String: Any] {
        guard path.hasPrefix("/") else { throw BenchError(message: "path must be absolute") }
        let seed = state.seed
        guard let rep = view.chartSnapshot(seed: seed), let data = rep.representation(using: .png, properties: [:]) else {
            throw BenchError(message: "could not render the chart")
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BenchError(message: "could not write \(path)")
        }
        let fields: [String: Any] = [
            "path": path, "seed": Int(seed), "pixelsWide": rep.pixelsWide, "pixelsHigh": rep.pixelsHigh,
            "backingScale": Double(window.backingScaleFactor), "chartFrame": TestPadGeometry.json(view.benchLayout.chart)
        ]
        app.log.write("bench.snapshot", fields)
        return fields
    }

    // MARK: State

    var summary: [String: Any] {
        var fields: [String: Any] = [
            "seed": Int(state.seed), "motion": state.motion, "scroll": state.scroll, "flash": state.flash,
            "scrollOffset": state.scrollOffset, "boxFraction": state.boxFraction,
            "displayIndex": displayIndex, "displayID": Int(displayID), "backingScale": Double(window.backingScaleFactor)
        ]
        if let marker = state.shownMarker, let time = state.shownTimeMs {
            fields["markerTimeMs"] = time
            fields["markerValue"] = Int(marker.timeMs)
        }
        return fields
    }

    func stateFields() -> [String: Any] {
        [
            "mode": "bench",
            "windowFrame": TestPadGeometry.global(window.frame),
            "contentFrame": TestPadGeometry.global(window.frame),
            "screenFrame": window.screen.map { TestPadGeometry.global($0.frame) } ?? [:],
            "fullscreen": false,
            "key": window.isKeyWindow,
            "active": NSApp.isActive,
            "onActiveSpace": window.isOnActiveSpace,
            "visible": window.occlusionState.contains(.visible),
            "elements": view.globalFrames(),
            "bench": summary
        ]
    }

    private func reframe() {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { Self.displayID(of: $0) == displayID }) ?? screens.first else { return }
        displayIndex = screens.firstIndex(of: screen) ?? 0
        displayID = Self.displayID(of: screen)
        guard window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
        view.layoutSubtreeIfNeeded()
        app.log.write("bench.reframed", ["displayIndex": displayIndex, "displayID": Int(displayID),
                                         "screenFrame": TestPadGeometry.global(screen.frame), "elements": view.globalFrames()])
        app.markDirty()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}

struct BenchError: Error {
    let message: String
}

final class BenchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// AppKit would otherwise keep the window clear of the menu bar; the bench must cover the display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Views

/// Content view: the chart on a plain background, with the marker, clock, lane, code pane and flash
/// target as their own layers so a tick redraws only what changed.
final class BenchView: NSView {
    static let background = NSColor(calibratedWhite: 0.1, alpha: 1)

    weak var pad: BenchPad?
    let markerView = BenchMarkerView()
    let clock = BenchClockView()
    let lane = BenchLaneView()
    let codePane = BenchCodePane()
    let flash = BenchFlashView()
    private(set) var benchLayout = BenchPadLayout(size: .zero)
    private var snapshotSeed: UInt16?

    var chartSeed: UInt16? {
        didSet { if chartSeed != oldValue { setNeedsDisplay(benchLayout.chart) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for part in [markerView, clock, lane, codePane, flash] as [NSView] { addSubview(part) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        benchLayout = BenchPadLayout(size: bounds.size, safeTop: window?.screen?.safeAreaInsets.top ?? 0)
        markerView.frame = backingAlignedRect(benchLayout.marker, options: .alignAllEdgesOutward)
        markerView.displaySize = bounds.size
        let fontSize = BenchClockView.fittedFontSize(for: benchLayout.clock.size)
        clock.fontSize = fontSize
        var clockFrame = benchLayout.clock
        clockFrame.size.height = min(clockFrame.height, BenchClockView.height(forFontSize: fontSize))
        clock.frame = backingAlignedRect(clockFrame, options: .alignAllEdgesNearest)
        lane.frame = backingAlignedRect(benchLayout.lane, options: .alignAllEdgesNearest)
        codePane.frame = backingAlignedRect(benchLayout.codePane, options: .alignAllEdgesNearest)
        flash.frame = backingAlignedRect(benchLayout.flash, options: .alignAllEdgesNearest)
        pad?.app.markDirty()
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        dirtyRect.fill()
        guard let seed = snapshotSeed ?? chartSeed, let context = NSGraphicsContext.current?.cgContext else { return }
        let chart = LegibilityChart.layout(displayPointSize: bounds.size)
        guard dirtyRect.intersects(chart.frame) else { return }
        LegibilityChartRenderer.draw(cells: LegibilityChart.cells(seed: seed), layout: chart, in: context)
    }

    /// The chart for `seed` at backing scale, rendered through the same drawing path as the screen.
    func chartSnapshot(seed: UInt16) -> NSBitmapImageRep? {
        let rect = backingAlignedRect(benchLayout.chart, options: .alignAllEdgesOutward)
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        snapshotSeed = seed
        defer { snapshotSeed = nil }
        cacheDisplay(in: rect, to: rep)
        return rep
    }

    func globalFrames() -> [String: [String: Double]] {
        guard let window else { return [:] }
        func global(_ rect: NSRect) -> [String: Double] {
            TestPadGeometry.global(window.convertToScreen(convert(rect, to: nil)))
        }
        return ["marker": global(benchLayout.marker), "chart": global(benchLayout.chart), "clock": global(clock.frame),
                "lane": global(lane.frame), "codePane": global(codePane.frame), "flash": global(flash.frame)]
    }

    override func keyDown(with event: NSEvent) {
        if pad?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

/// The marker strip in its own small layer. It draws in whole-display coordinates so the shared
/// layout applies unchanged; its frame is only the pixel-aligned box around the strip.
final class BenchMarkerView: NSView {
    var marker: BenchMarker? {
        didSet { if marker != oldValue { needsDisplay = true } }
    }
    var displaySize: CGSize = .zero {
        didSet { if displaySize != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let marker, let context = NSGraphicsContext.current?.cgContext else { return }
        context.translateBy(x: -frame.minX, y: -frame.minY)
        BenchMarkerRenderer.draw(marker, layout: BenchMarker.layout(width: Double(displaySize.width), height: Double(displaySize.height)),
                                 in: context)
    }
}

/// Mach seconds and wall-clock time of the frame's target display time, for the 240 fps camera method.
final class BenchClockView: NSView {
    static let maximumFontSize: CGFloat = 96
    static let inset: CGFloat = 16
    static let captionFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let keys = "keys: c chart · m motion · s scroll · j jump · space flash · a auto-flash · esc or q quit"
    private static let wallFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var fontSize: CGFloat = BenchClockView.maximumFontSize {
        didSet { if fontSize != oldValue { needsDisplay = true } }
    }
    private var timeMs: Double?
    private var status = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func show(timeMs: Double, status: String) {
        guard timeMs != self.timeMs || status != self.status else { return }
        self.timeMs = timeMs
        self.status = status
        needsDisplay = true
    }

    static func font(ofSize size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .semibold) }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    static var captionBlock: CGFloat { 12 + 2 * lineHeight(captionFont) }

    static func fittedFontSize(for region: CGSize) -> CGFloat {
        let probe = font(ofSize: maximumFontSize)
        let widest = ["0000000.000", "00:00:00.000"].map { ($0 as NSString).size(withAttributes: [.font: probe]).width }.max() ?? 1
        let byWidth = maximumFontSize * (region.width - 2 * inset) / max(1, widest)
        let byHeight = maximumFontSize * (region.height - 2 * inset - captionBlock) / (2 * lineHeight(probe))
        return max(12, min(maximumFontSize, byWidth, byHeight).rounded(.down))
    }

    static func height(forFontSize size: CGFloat) -> CGFloat {
        2 * inset + 2 * lineHeight(font(ofSize: size)) + captionBlock
    }

    override func draw(_ dirtyRect: NSRect) {
        BenchView.background.setFill()
        bounds.fill()
        let font = Self.font(ofSize: fontSize)
        let line = Self.lineHeight(font)
        let mach = timeMs.map { String(format: "%.3f", $0 / 1000) } ?? "–"
        let wall = timeMs.map { Self.wallFormatter.string(from: Date(timeIntervalSinceNow: ($0 - MachClock.nowMs()) / 1000)) } ?? "–"
        (mach as NSString).draw(at: NSPoint(x: Self.inset, y: Self.inset),
                                withAttributes: [.font: font, .foregroundColor: NSColor.white])
        (wall as NSString).draw(at: NSPoint(x: Self.inset, y: Self.inset + line),
                                withAttributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1)])
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.captionFont, .paragraphStyle: paragraph,
                                                         .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)]
        let captionLine = Self.lineHeight(Self.captionFont)
        let captionTop = Self.inset + 2 * line + 12
        for (index, text) in ["mach s / wall · " + status, Self.keys].enumerated() {
            (text as NSString).draw(in: NSRect(x: Self.inset, y: captionTop + CGFloat(index) * captionLine,
                                               width: bounds.width - 2 * Self.inset, height: captionLine),
                                    withAttributes: attributes)
        }
    }
}

/// A red box bouncing across the lane; only the box's layer moves.
final class BenchLaneView: NSView {
    private let box = NSView()

    var fraction = 0.0 {
        didSet { if fraction != oldValue { placeBox() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0.753, green: 0.224, blue: 0.169, alpha: 1).cgColor
        box.layer?.cornerRadius = 10
        addSubview(box)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeBox()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func placeBox() {
        let side = BenchPadLayout.boxSide
        let scale = window?.backingScaleFactor ?? 2
        let x = (CGFloat(fraction) * max(0, bounds.width - side) * scale).rounded() / scale
        let y = ((bounds.height - side) / 2 * scale).rounded() / scale
        box.frame = NSRect(x: x, y: y, width: side, height: side)
    }
}

/// Invented code in two recycled tiles: scrolling moves the tiles, and a tile redraws only when it
/// wraps to the next block of lines, so a 1000 pt/s scroll costs almost nothing on the Mac.
final class BenchCodePane: NSView {
    static let lineHeight: CGFloat = 18
    private let tiles = [BenchCodeTile(), BenchCodeTile()]
    private var offset = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        for tile in tiles { addSubview(tile) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var tileHeight: CGFloat { max(1, (bounds.height / Self.lineHeight).rounded(.up)) * Self.lineHeight }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let lines = Int(tileHeight / Self.lineHeight)
        for tile in tiles {
            tile.lineCount = lines
            tile.block = nil
        }
        scroll(to: offset)
    }

    override func draw(_ dirtyRect: NSRect) {
        BenchCodeTile.background.setFill()
        dirtyRect.fill()
    }

    func scroll(to newOffset: Double) {
        offset = newOffset
        let scale = Double(window?.backingScaleFactor ?? 2)
        let shown = (newOffset * scale).rounded() / scale
        let height = Double(tileHeight)
        let first = Int((shown / height).rounded(.down))
        for block in first...(first + 1) {
            let tile = tiles[block & 1]
            tile.block = block
            tile.frame = NSRect(x: 0, y: CGFloat(Double(block) * height - shown), width: bounds.width, height: tileHeight)
        }
    }
}

final class BenchCodeTile: NSView {
    static let background = NSColor(calibratedWhite: 0.13, alpha: 1)
    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let gutter: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)]
    private static let code: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1)]
    private static let comment: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(srgbRed: 0.45, green: 0.75, blue: 0.45, alpha: 1)
    ]

    var block: Int? {
        didSet { if block != oldValue { needsDisplay = true } }
    }
    var lineCount = 0 {
        didSet { if lineCount != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        guard let block, block >= 0 else { return }
        for row in 0..<lineCount {
            let number = block * lineCount + row
            let y = CGFloat(row) * BenchCodePane.lineHeight + 1
            (String(format: "%5ld", number + 1) as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: Self.gutter)
            let text = BenchCode.line(number)
            (text as NSString).draw(at: NSPoint(x: 60, y: y),
                                    withAttributes: text.hasPrefix("//") ? Self.comment : Self.code)
        }
    }
}

enum BenchCode {
    private static let names = ["frame", "packet", "tile", "glyph", "cursor", "sample", "route", "probe", "layer",
                                "stage", "window", "budget"]
    private static let templates = [
        "// MARK: {A} pipeline, pass {N}",
        "struct {A}Stage: Equatable {",
        "    var budget = {N}",
        "    var threshold = 0.{N}",
        "    private var history: [{A}Sample] = []",
        "",
        "    mutating func submit(_ {a}: {A}Sample, at time: Double) -> Bool {",
        "        guard {a}.bytes > 0, time >= lastTime else { return false }",
        "        history.append({a})",
        "        if history.count > {N} { history.removeFirst(history.count - {N}) }",
        "        let mean = history.map(\\.bytes).reduce(0, +) / history.count",
        "        lastTime = time",
        "        return mean < budget * {N}",
        "    }",
        "",
        "    func describe() -> String {",
        "        \"{a} budget \\(budget) threshold \\(threshold)\"",
        "    }",
        "}",
        "",
        "// {A} flush: every third index of {N}",
        "let {a}Queue = DispatchQueue(label: \"bench.{a}.{N}\", qos: .userInitiated)",
        "for index in 0..<{N} where index % 3 == 0 {",
        "    {a}Queue.async { encoder.flush(index, reason: .{a}) }",
        "}",
        ""
    ]

    static func line(_ number: Int) -> String {
        let index = max(0, number)
        let cycle = index / templates.count
        let name = names[cycle % names.count]
        let value = (index * 37 + cycle * 11) % 900 + 100
        return templates[index % templates.count]
            .replacingOccurrences(of: "{A}", with: name.prefix(1).uppercased() + name.dropFirst())
            .replacingOccurrences(of: "{a}", with: name)
            .replacingOccurrences(of: "{N}", with: String(value))
    }
}

/// The click-to-photon target; the pad applies its colour in the same frame as the marker's flash bit.
final class BenchFlashView: NSView {
    weak var pad: BenchPad?

    var lit = false {
        didSet { if lit != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 24, yRadius: 24)
        (lit ? NSColor(srgbRed: 0.153, green: 0.682, blue: 0.376, alpha: 1) : NSColor(calibratedWhite: 0.133, alpha: 1)).setFill()
        shape.fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
        shape.stroke()
        let text = "tap / click me" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        pad?.flashPressed(event)
    }
}
