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
    /// Exact position used for an accepted click, before later pointer movement can change it.
    var clickPoint: CGPoint?
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
        else if action == "move" || action == "moveTo" || action == "holdRenew" { refreshFromMove(at: time) }
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

/// Marks every event the phone injects, so Mac-side listeners (the privacy curtain's local
/// Escape shortcut) can tell them apart from the physical keyboard.
enum RemoteInputTag {
    static let value: Int64 = 0x4641_5253_4944_4531

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    static func isInjected(_ event: CGEvent?, ownPID: pid_t = getpid()) -> Bool {
        guard let event else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == value
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ownPID)
    }
}

struct RemoteInputEventSink {
    struct MouseEvent {
        var type: CGEventType
        var point: CGPoint
        var button: CGMouseButton
        var count: Int64
        /// Modifier keys held on the phone's hardware keyboard (⌘-click, ⇧-click, ⌥-drag).
        var flags: CGEventFlags = []
    }

    var pointerLocation: () -> CGPoint
    var mouseSequence: ([MouseEvent]) -> Bool
    var scroll: (CGPoint, Double, Double) -> Bool
    var scrollDetailed: ((CGPoint, Double, Double, String) -> Bool)? = nil
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
                if !description.flags.isEmpty { event.flags = description.flags }
                events.append(event)
            }
            for event in events { RemoteInputTag.mark(event); event.post(tap: .cghidEventTap) }
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
            RemoteInputTag.mark(event)
            event.post(tap: .cghidEventTap)
            return true
        },
        scrollDetailed: { point, horizontal, vertical, phase in
            let clampedX = min(2000, max(-2000, horizontal))
            let clampedY = min(2000, max(-2000, vertical))
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clampedY.rounded(.towardZero)),
                wheel2: Int32(clampedX.rounded(.towardZero)),
                wheel3: 0
            ) else { return false }
            event.location = point
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64((clampedY * 65_536).rounded()))
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64((clampedX * 65_536).rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(clampedY.rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(clampedX.rounded()))
            let phaseValue: Int64
            switch phase {
            case "began": phaseValue = 1
            case "changed": phaseValue = 2
            case "ended": phaseValue = 4
            case "cancelled": phaseValue = 8
            default: phaseValue = 0
            }
            if phaseValue != 0 { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseValue) }
            RemoteInputTag.mark(event)
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
                RemoteInputTag.mark(event)
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
                RemoteInputTag.mark(event)
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
    private(set) var externalHoldID: String?
    private var nextHoldID: UInt64 = 0
    private var retiredHolds: Set<String> = []
    private var retiredHoldOrder: [String] = []
    private var heldClickCount: Int64 = 1
    private var lastClick = 0.0
    private var clicks: Int64 = 0
    private(set) var lastPoint = CGPoint.zero
    private var lastButton: CGMouseButton?
    private var lastSemanticPoint: CGPoint?
    private var activeScroll: String?
    private var retiredScrolls: Set<String> = []
    private var retiredScrollOrder: [String] = []
    private var scrollDeadline: TimeInterval = 0
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
        resetNativeSequence()
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
        resetNativeSequence()
        displayBounds = bounds
        windowID = nil
    }

    func handle(_ input: RemoteAction, upgraded: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RemoteInputOutcome {
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
        if upgraded, input.action != "scroll", let activeScroll {
            retireScroll(activeScroll)
            self.activeScroll = nil
        }

        var outcome = RemoteInputOutcome(textRequestID: requestID)
        let flags = Self.flags(for: input.modifiers)
        switch input.action {
        case "move", "moveTo":
            if upgraded && held && (input.interaction?.hold != externalHoldID || input.interaction?.clickCount != Int(heldClickCount)) { break }
            guard let bounds = validBounds else { break }
            let target: CGPoint
            if input.action == "moveTo" {
                // Display-local logical points, exactly as `geometry` described the display.
                guard input.x >= 0, input.y >= 0 else { break }
                target = CGPoint(x: bounds.minX + input.x, y: bounds.minY + input.y)
            } else {
                let current = clamped(eventSink.pointerLocation(), to: bounds)
                target = CGPoint(x: current.x + input.x, y: current.y + input.y)
            }
            let point = clamped(target, to: bounds)
            let wasHeld = held
            let event = RemoteInputEventSink.MouseEvent(
                type: wasHeld ? .leftMouseDragged : .mouseMoved,
                point: point,
                button: .left,
                count: wasHeld ? heldClickCount : 1,
                flags: flags
            )
            guard eventSink.mouseSequence([event]) else { break }
            lastPoint = point
            if !wasHeld, let semanticPoint = lastSemanticPoint,
               hypot(point.x - semanticPoint.x, point.y - semanticPoint.y) > 5 { resetClickSequence() }
            outcome.accepted = true
            outcome.holdEvent = wasHeld ? .refreshed : .none

        case "middle":
            guard !held, let bounds = validBounds else { break }
            if upgraded { guard input.interaction?.clickCount == 1 else { break } }
            let point = clamped(eventSink.pointerLocation(), to: bounds)
            let events: [RemoteInputEventSink.MouseEvent] = [
                .init(type: .otherMouseDown, point: point, button: .center, count: 1, flags: flags),
                .init(type: .otherMouseUp, point: point, button: .center, count: 1, flags: flags)
            ]
            guard eventSink.mouseSequence(events) else { break }
            lastPoint = point
            resetClickSequence()
            outcome.accepted = true
            outcome.clickPoint = point

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
            if upgraded {
                // A multi-click continues only the click just before it: same button, same place.
                guard let count = input.interaction?.clickCount,
                      (1...3).contains(count),
                      (count == 1 || (clicks == Int64(count - 1) && lastButton == button &&
                        lastSemanticPoint.map { hypot($0.x - point.x, $0.y - point.y) <= 5 } == true)),
                      (!right || count == 1),
                      (input.action != "double" || count == 1)
                else { break }
                for index in 0..<repetitions {
                    let eventCount = Int64(count + index)
                    events.append(.init(type: down, point: point, button: button, count: eventCount, flags: flags))
                    events.append(.init(type: up, point: point, button: button, count: eventCount, flags: flags))
                }
                guard eventSink.mouseSequence(events) else { break }
                clicks = Int64(count + repetitions - 1)
                lastButton = button
                lastSemanticPoint = point
                outcome.accepted = true
                outcome.clickPoint = point
                break
            }
            for index in 0..<repetitions {
                let now = CACurrentMediaTime()
                clicks = now - lastClick < NSEvent.doubleClickInterval ? min(clicks + 1, 3) : 1
                if repetitions == 2 { clicks = Int64(index + 1) }
                lastClick = now
                events.append(.init(type: down, point: point, button: button, count: clicks, flags: flags))
                events.append(.init(type: up, point: point, button: button, count: clicks, flags: flags))
            }
            outcome.accepted = eventSink.mouseSequence(events)
            if outcome.accepted { outcome.clickPoint = point }

        case "dragDown":
            guard !held, let bounds = validBounds else { break }
            if upgraded {
                guard let identity = input.interaction?.hold,
                      !identity.isEmpty, !retiredHolds.contains(identity),
                      let count = input.interaction?.clickCount, count == 1 || count == 2
                else { break }
                let point = clamped(eventSink.pointerLocation(), to: bounds)
                guard count == 1 || (clicks == 1 && lastButton == .left &&
                    lastSemanticPoint.map { hypot($0.x - point.x, $0.y - point.y) <= 5 } == true)
                else { break }
            }
            let point = clamped(eventSink.pointerLocation(), to: bounds)
            let count = upgraded ? Int64(input.interaction!.clickCount!) : 1
            let event = RemoteInputEventSink.MouseEvent(type: .leftMouseDown, point: point, button: .left,
                                                        count: count, flags: flags)
            guard eventSink.mouseSequence([event]) else { break }
            lastPoint = point
            held = true
            heldClickCount = count
            externalHoldID = upgraded ? input.interaction?.hold : nil
            if let externalHoldID { retireHold(externalHoldID) }
            nextHoldID &+= 1
            if nextHoldID == 0 { nextHoldID = 1 }
            holdID = nextHoldID
            outcome.accepted = true
            outcome.holdEvent = .began

        case "dragUp":
            if upgraded && (input.interaction?.hold != externalHoldID || input.interaction?.clickCount != Int(heldClickCount)) { break }
            let wasHeld = held
            outcome.accepted = release()
            outcome.holdEvent = wasHeld && outcome.accepted ? .ended : .none

        case "holdRenew":
            guard upgraded, held, input.interaction?.hold == externalHoldID,
                  input.interaction?.clickCount == Int(heldClickCount) else { break }
            outcome.accepted = true
            outcome.holdEvent = .refreshed

        case "scroll":
            guard let bounds = validBounds else { break }
            if upgraded {
                guard let stream = input.interaction?.stream,
                      let phase = input.interaction?.phase else { break }
                if let activeScroll, now >= scrollDeadline {
                    retireScroll(activeScroll)
                    self.activeScroll = nil
                }
                if phase == "began" {
                    guard activeScroll != stream, !retiredScrolls.contains(stream) else { break }
                    if let activeScroll { retireScroll(activeScroll) }
                    activeScroll = stream
                } else {
                    guard activeScroll == stream, now < scrollDeadline else { break }
                }
                scrollDeadline = now + 0.5
                if phase == "ended" || phase == "cancelled" {
                    retireScroll(stream)
                    activeScroll = nil
                } else if phase == "changed" && input.x == 0 && input.y == 0 {
                    // Fingers resting mid-scroll: keep the stream alive, post nothing.
                    outcome.accepted = true
                    break
                }
            }
            let point = clamped(eventSink.pointerLocation(), to: bounds)
            lastPoint = point
            if upgraded, let detailed = eventSink.scrollDetailed {
                outcome.accepted = detailed(point, input.x, input.y, input.interaction!.phase!)
            } else {
                outcome.accepted = eventSink.scroll(point, input.x, input.y)
            }

        case "text":
            guard !input.key.isEmpty, input.key.utf8.count <= 32,
                  input.text.utf8.count <= 4096, input.text.utf16.count <= 1024 else { break }
            outcome.accepted = eventSink.text(Array(input.text.utf16))
            if outcome.accepted { resetClickSequence() }

        case "key":
            guard let key = Self.keys[input.key] else { break }
            outcome.accepted = eventSink.key(key, flags.union(Self.intrinsicFlags(for: input.key)))
            if outcome.accepted { resetClickSequence() }

        default:
            break
        }
        if outcome.accepted { report?("Input accepted for injection: \(input.action)") }
        return outcome
    }

    static func flags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    @discardableResult
    func release() -> Bool {
        guard held else { return false }
        let event = RemoteInputEventSink.MouseEvent(
            type: .leftMouseUp,
            point: lastPoint,
            button: .left,
            count: heldClickCount
        )
        guard eventSink.mouseSequence([event]) else { return false }
        held = false
        holdID = nil
        externalHoldID = nil
        heldClickCount = 1
        resetClickSequence()
        return true
    }

    func resetNativeSequence() {
        resetClickSequence()
        externalHoldID = nil
        retiredHolds.removeAll()
        retiredHoldOrder.removeAll()
        activeScroll = nil
        retiredScrolls.removeAll()
        retiredScrollOrder.removeAll()
        scrollDeadline = 0
    }

    private func retireHold(_ identity: String) {
        guard retiredHolds.insert(identity).inserted else { return }
        retiredHoldOrder.append(identity)
        if retiredHoldOrder.count > 1024 {
            retiredHolds.remove(retiredHoldOrder.removeFirst())
        }
    }

    private func retireScroll(_ identity: String) {
        guard retiredScrolls.insert(identity).inserted else { return }
        retiredScrollOrder.append(identity)
        if retiredScrollOrder.count > 1024 {
            retiredScrolls.remove(retiredScrollOrder.removeFirst())
        }
    }

    private func resetClickSequence() {
        clicks = 0
        lastButton = nil
        lastSemanticPoint = nil
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

    static let keys: [String: CGKeyCode] = legacyKeys.merging(extendedKeys) { old, _ in old }

    /// The original table; every phone may send these.
    static let legacyKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46, "return": 36, "tab": 48,
        "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124,
        "down": 125, "up": 126
    ]

    /// Hardware keyboards on the phone (`SessionFeature.extendedKeys`): positional virtual key codes.
    static let extendedKeys: [String: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "minus": 27, "equal": 24, "leftBracket": 33, "rightBracket": 30, "backslash": 42,
        "semicolon": 41, "quote": 39, "grave": 50, "comma": 43, "period": 47, "slash": 44, "section": 10,
        "forwardDelete": 117, "home": 115, "end": 119, "pageUp": 116, "pageDown": 121, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86, "keypad5": 87,
        "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92, "keypadDecimal": 65,
        "keypadMultiply": 67, "keypadPlus": 69, "keypadClear": 71, "keypadDivide": 75,
        "keypadEnter": 76, "keypadMinus": 78, "keypadEquals": 81,
        "jisYen": 93, "jisUnderscore": 94, "jisKeypadComma": 95, "jisEisu": 102, "jisKana": 104
    ]

    /// Flags a Mac keyboard itself sets on these keys: Fn and numeric pad for arrows, Fn for
    /// function and navigation keys, numeric pad for the keypad. The system hotkeys for Mission
    /// Control and Spaces (⌃ plus an arrow) only match an arrow that carries Fn.
    static func intrinsicFlags(for key: String) -> CGEventFlags {
        if ["left", "right", "up", "down"].contains(key) { return [.maskSecondaryFn, .maskNumericPad] }
        if key.hasPrefix("keypad") { return .maskNumericPad }
        if ["forwardDelete", "home", "end", "pageUp", "pageDown", "help"].contains(key) { return .maskSecondaryFn }
        if key.count > 1, key.hasPrefix("f"), Int(key.dropFirst()) != nil { return .maskSecondaryFn }
        return []
    }
}
