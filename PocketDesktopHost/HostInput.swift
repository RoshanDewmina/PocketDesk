import AppKit
import ScreenCaptureKit

/// Runs on the main thread. Input is accepted only while the host's explicit control switch is on.
final class HostInput {
    var enabled = false
    var displayBounds: CGRect?
    var windowID: CGWindowID?
    private var held = false
    private var lastClick = 0.0
    private var clicks: Int64 = 0
    private var lastPoint = CGPoint.zero
    var report: ((String) -> Void)?
    func configure(_ filter: SCContentFilter) {
        release()
        if filter.style == .display {
            displayBounds = filter.includedDisplays.first?.frame
            windowID = nil
        } else {
            displayBounds = nil
            windowID = filter.includedWindows.first?.windowID
        }
    }
    private var bounds: CGRect? {
        if let displayBounds { return displayBounds }
        guard let windowID,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = windows.first, let rect = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: rect as CFDictionary)
    }
    func handle(_ input: RemoteInput) {
        if input.action == "release" { release(); return }
        guard enabled, AXIsProcessTrusted(), let bounds, bounds.width > 0, bounds.height > 0,
              input.x.isFinite, input.y.isFinite else { return }
        let point = CGPoint(x: bounds.minX + min(1, max(0, input.x)) * max(0, bounds.width - 1),
                            y: bounds.minY + min(1, max(0, input.y)) * max(0, bounds.height - 1))
        switch input.action {
        case "move":
            lastPoint = point
            mouse(held ? .leftMouseDragged : .mouseMoved, point)
        case "click", "right", "double":
            guard !held else { return }
            lastPoint = point
            let right = input.action == "right"
            let repetitions = input.action == "double" ? 2 : 1
            for index in 0..<repetitions {
                let now = CACurrentMediaTime()
                clicks = now - lastClick < NSEvent.doubleClickInterval ? min(clicks + 1, 3) : 1
                if repetitions == 2 { clicks = Int64(index + 1) }
                lastClick = now
                mouse(right ? .rightMouseDown : .leftMouseDown, point, button: right ? .right : .left, count: clicks)
                mouse(right ? .rightMouseUp : .leftMouseUp, point, button: right ? .right : .left, count: clicks)
            }
        case "drag":
            lastPoint = point; held.toggle(); mouse(held ? .leftMouseDown : .leftMouseUp, point)
        case "scroll":
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(min(2000, max(-2000, input.y))), wheel2: Int32(min(2000, max(-2000, input.x))), wheel3: 0)
            event?.location = lastPoint; event?.post(tap: .cghidEventTap)
        case "text":
            guard input.text.utf16.count <= 1024 else { return }
            let characters = Array(input.text.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                characters.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress) }
                event?.post(tap: .cghidEventTap)
            }
        case "key":
            guard let key = Self.keys[input.key] else { return }
            var flags: CGEventFlags = []
            for modifier in input.modifiers {
                switch modifier { case "command": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
                case "option": flags.insert(.maskAlternate); case "control": flags.insert(.maskControl); default: break }
            }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                event?.flags = flags; event?.post(tap: .cghidEventTap)
            }
        default: return
        }
        report?("Input: \(input.action)")
    }
    func release() {
        if held { mouse(.leftMouseUp, lastPoint); held = false }
    }
    private func mouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: count)
        event?.post(tap: .cghidEventTap)
    }
    // Virtual key codes for the initial ANSI shortcut strip; Unicode text has a separate path.
    static let keys: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,"return":36,"tab":48,"space":49,"delete":51,"escape":53,"left":123,"right":124,"down":125,"up":126]
}
