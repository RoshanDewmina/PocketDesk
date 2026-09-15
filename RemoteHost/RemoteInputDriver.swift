import AppKit
import ScreenCaptureKit

struct RemoteInputOutcome: Equatable {
    enum HoldEvent: Equatable {
        case none
        case began
        case refreshed
        case ended
    }

    var accepted = false
    var holdEvent: HoldEvent = .none
    var textRequestID: String?
}

struct RemoteInputLease {
    let duration: TimeInterval
    private(set) var deadline: TimeInterval?

    init(duration: TimeInterval = 2) {
        self.duration = duration
    }

    mutating func begin(at time: TimeInterval) {
        deadline = time + duration
    }

    mutating func refreshFromMove(at time: TimeInterval) {
        guard deadline != nil else { return }
        deadline = time + duration
    }

    mutating func record(action: String, accepted: Bool, at time: TimeInterval) {
        guard accepted else { return }
        if action == "dragDown" { begin(at: time) }
        else if action == "move" { refreshFromMove(at: time) }
    }

    mutating func cancel() {
        deadline = nil
    }

    func isExpired(at time: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return time >= deadline
    }
}

struct RemoteInputEpoch {
    private(set) var value: UInt64 = 0

    @discardableResult
    mutating func beginSession() -> UInt64 {
        value &+= 1
        if value == 0 { value = 1 }
        return value
    }

    func accepts(_ action: RemoteAction) -> Bool {
        action.action == "release" || action.action == "heartbeat" || action.epoch == value
    }
}

struct RemoteInputEventSink {
    struct MouseEvent {
        var type: CGEventType
        var point: CGPoint
        var button: CGMouseButton
        var count: Int64
    }

    var pointerLocation: () -> CGPoint
    var mouseSequence: ([MouseEvent]) -> Bool
    var scroll: (CGPoint, Double, Double) -> Bool
    var text: ([UniChar]) -> Bool
    var key: (CGKeyCode, CGEventFlags) -> Bool

    static let live = RemoteInputEventSink(
        pointerLocation: { CGEvent(source: nil)?.location ?? .zero },
        mouseSequence: { descriptions in
            var events: [CGEvent] = []
            for description in descriptions {
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: description.type,
                    mouseCursorPosition: description.point,
                    mouseButton: description.button
                ) else { return false }
                event.setIntegerValueField(.mouseEventClickState, value: description.count)
                events.append(event)
            }
            for event in events { event.post(tap: .cghidEventTap) }
            return true
        },
        scroll: { point, horizontal, vertical in
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(min(2000, max(-2000, vertical))),
                wheel2: Int32(min(2000, max(-2000, horizontal))),
                wheel3: 0
            ) else { return false }
            event.location = point
            event.post(tap: .cghidEventTap)
            return true
        },
        text: { characters in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            for event in [down, up] {
                characters.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress)
                }
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        },
        key: { key, flags in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
            for event in [down, up] {
                event.flags = flags
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
    )
}

final class RemoteInputDriver {
    var enabled = false
    var displayBounds: CGRect?
    var windowID: CGWindowID?
    var report: ((String) -> Void)?

    private(set) var held = false
    private(set) var holdID: UInt64?
    private var nextHoldID: UInt64 = 0
    private var lastClick = 0.0
    private var clicks: Int64 = 0
    private var lastPoint = CGPoint.zero
    private let eventSink: RemoteInputEventSink
    private let isTrusted: () -> Bool

    init(
        eventSink: RemoteInputEventSink = .live,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.eventSink = eventSink
        self.isTrusted = isTrusted
    }

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

    func configure(bounds: CGRect?) {
        release()
        displayBounds = bounds
        windowID = nil
    }

    func handle(_ input: RemoteAction) -> RemoteInputOutcome {
        let requestID = input.action == "text" ? input.key : nil
        if input.action == "release" {
            let hadHold = held
            let released = release()
            return RemoteInputOutcome(
                accepted: !hadHold || released,
                holdEvent: !hadHold || released ? .ended : .none,
                textRequestID: requestID
            )
        }
        guard enabled, isTrusted(), input.x.isFinite, input.y.isFinite else {
            return RemoteInputOutcome(textRequestID: requestID)
        }

        var outcome = RemoteInputOutcome(textRequestID: requestID)
        switch input.action {
        case "move":
            guard let bounds = validBounds else { break }
            let current = clamped(eventSink.pointerLocation(), to: bounds)
            let point = clamped(
                CGPoint(x: current.x + input.x, y: current.y + input.y),
                to: bounds
            )
            let wasHeld = held
            let event = RemoteInputEventSink.MouseEvent(
                type: wasHeld ? .leftMouseDragged : .mouseMoved,
                point: point,
                button: .left,
                count: 1
            )
            guard eventSink.mouseSequence([event]) else { break }
            lastPoint = point
            outcome.accepted = true
            outcome.holdEvent = wasHeld ? .refreshed : .none

        case "click", "right", "double":
            guard !held, let bounds = validBounds else { break }
            let point = clamped(eventSink.pointerLocation(), to: bounds)
            let right = input.action == "right"
            let button: CGMouseButton = right ? .right : .left
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            let repetitions = input.action == "double" ? 2 : 1
            var events: [RemoteInputEventSink.MouseEvent] = []
            lastPoint = point
            for index in 0..<repetitions {
                let now = CACurrentMediaTime()
                clicks = now - lastClick < NSEvent.doubleClickInterval ? min(clicks + 1, 3) : 1
                if repetitions == 2 { clicks = Int64(index + 1) }
                lastClick = now
                events.append(.init(type: down, point: point, button: button, count: clicks))
                events.append(.init(type: up, point: point, button: button, count: clicks))
            }
            outcome.accepted = eventSink.mouseSequence(events)

        case "dragDown":
            guard !held, let bounds = validBounds else { break }
            let point = clamped(eventSink.pointerLocation(), to: bounds)
            let event = RemoteInputEventSink.MouseEvent(type: .leftMouseDown, point: point, button: .left, count: 1)
            guard eventSink.mouseSequence([event]) else { break }
            lastPoint = point
            held = true
            nextHoldID &+= 1
            if nextHoldID == 0 { nextHoldID = 1 }
            holdID = nextHoldID
            outcome.accepted = true
            outcome.holdEvent = .began

        case "dragUp":
            let wasHeld = held
            outcome.accepted = release()
            outcome.holdEvent = wasHeld && outcome.accepted ? .ended : .none

        case "scroll":
            guard let bounds = validBounds else { break }
            let point = clamped(eventSink.pointerLocation(), to: bounds)
            lastPoint = point
            outcome.accepted = eventSink.scroll(point, input.x, input.y)

        case "text":
            guard !input.key.isEmpty, input.key.utf8.count <= 32,
                  input.text.utf8.count <= 4096, input.text.utf16.count <= 1024 else { break }
            outcome.accepted = eventSink.text(Array(input.text.utf16))

        case "key":
            guard let key = Self.keys[input.key] else { break }
            var flags: CGEventFlags = []
            for modifier in input.modifiers {
                switch modifier {
                case "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "option": flags.insert(.maskAlternate)
                case "control": flags.insert(.maskControl)
                default: break
                }
            }
            outcome.accepted = eventSink.key(key, flags)

        default:
            break
        }
        if outcome.accepted { report?("Input accepted for injection: \(input.action)") }
        return outcome
    }

    @discardableResult
    func release() -> Bool {
        guard held else { return false }
        let event = RemoteInputEventSink.MouseEvent(
            type: .leftMouseUp,
            point: lastPoint,
            button: .left,
            count: 1
        )
        guard eventSink.mouseSequence([event]) else { return false }
        held = false
        holdID = nil
        return true
    }

    private var validBounds: CGRect? {
        if let displayBounds, displayBounds.width > 0, displayBounds.height > 0,
           displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite,
           displayBounds.width.isFinite, displayBounds.height.isFinite {
            return displayBounds
        }
        guard let windowID,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = windows.first,
              let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    private func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        let fallback = CGPoint(x: bounds.midX, y: bounds.midY)
        let source = point.x.isFinite && point.y.isFinite ? point : fallback
        return CGPoint(
            x: min(bounds.maxX.nextDown, max(bounds.minX, source.x)),
            y: min(bounds.maxY.nextDown, max(bounds.minY, source.y))
        )
    }

    static let keys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46, "return": 36, "tab": 48,
        "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124,
        "down": 125, "up": 126
    ]
}
