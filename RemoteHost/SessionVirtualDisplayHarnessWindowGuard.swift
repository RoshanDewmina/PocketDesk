#if DEBUG
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// A lane-owned, bounded cleanup tool. It never starts HostModel, requests permissions,
/// reads window titles, creates displays, changes Spaces, or changes physical display modes.
@MainActor
enum SessionVirtualDisplayHarnessWindowGuard {
    private static let lane = "b8-vdisplay"
    private static let laneRoot = "/Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b8-vdisplay"
    private static let quietGrant = "/Users/roshansilva/Documents/Codex/2026-10-01/testing/QUIET-GRANTED-b8-vdisplay"
    private static let maximumWindows = 64
    private static let tolerance: CGFloat = 2

    static func run(arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(arguments.dropFirst())
        guard args.count == 3, args[0] == "--session-virtual-display-window-guard",
              ["snapshot", "restore", "verify"].contains(args[1]), args[2].hasPrefix("/") else {
            print("SESSION-VD-WINDOW-GUARD: error=invalid-arguments")
            return 2
        }
        let deadline = WindowGuardDeadline(seconds: 6)
        defer { deadline.finish() }
        let budget = HostAXBudget(total: 5.5)
        do {
            let url = try validatedURL(args[2])
            if args[1] == "snapshot" {
                guard FileManager.default.fileExists(atPath: quietGrant) else { throw GuardFailure("missing-exact-quiet-grant") }
                guard !FileManager.default.fileExists(atPath: url.path) else { throw GuardFailure("snapshot-already-exists") }
            }
            // Read-only permission checks. Neither check requests a TCC prompt.
            guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw GuardFailure("permissions-not-already-granted") }
            if args[1] == "snapshot" {
                let journal = try snapshot(url: url, budget: budget)
                try check(budget)
                guard FileManager.default.fileExists(atPath: quietGrant) else { throw GuardFailure("quiet-grant-withdrawn-before-persist") }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(journal).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try check(budget)
                print("SESSION-VD-WINDOW-GUARD: command=snapshot result=pass windows=\(journal.windows.count) protectedDisplays=\(journal.displays.count)")
                return 0
            }
            // Mandatory cleanup stays available after the grant is withdrawn. Only a journal
            // with this lane's granted-snapshot provenance and canonical path is admitted.
            let journal = try load(url)
            guard try displays(budget: budget) == journal.displays else { throw GuardFailure("protected-display-topology-changed") }
            if args[1] == "restore" {
                for (record, resolution) in try resolve(journal.windows, budget: budget) {
                    try check(budget)
                    if case let .matched(window) = resolution, !close(window.frame, record.original) {
                        // This command's native AX binding was established by a unique public
                        // CG/AX frame match (or the recorded exact identifier plus that frame).
                        // Recheck process, visible CG ID, AX eligibility and frame before writing.
                        do { try restore(record, window: window, budget: budget) }
                        catch { if budget.isExhausted { throw error } }
                    }
                }
            }
            let resolved = try resolve(journal.windows, budget: budget)
            var surviving = 0, retired = 0, unresolved = 0
            for (record, result) in resolved {
                switch result {
                case .retired: retired += 1
                case .unresolved: unresolved += 1
                case let .matched(window):
                    surviving += 1
                    if !close(window.frame, record.original) { unresolved += 1 }
                }
            }
            guard try displays(budget: budget) == journal.displays else { throw GuardFailure("protected-display-topology-changed") }
            try check(budget)
            print("SESSION-VD-WINDOW-GUARD: command=\(args[1]) result=\(unresolved == 0 ? "pass" : "unresolved") surviving=\(surviving) retired=\(retired) unresolved=\(unresolved)")
            // The immutable journal remains as the baseline/cleanup receipt, including on failure.
            return unresolved == 0 ? 0 : 1
        } catch let error as GuardFailure {
            print("SESSION-VD-WINDOW-GUARD: command=\(args[1]) error=\(error.reason); journal-retained-if-present")
            return 1
        } catch {
            print("SESSION-VD-WINDOW-GUARD: command=\(args[1]) error=journal-or-system-failure; journal-retained-if-present")
            return 1
        }
    }

    private struct GuardFailure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    private struct Record: Codable {
        let pid: Int32
        let launchTime: TimeInterval
        let windowID: UInt32
        let axIdentifier: String?
        let original: CGRect
    }
    private struct Display: Codable, Equatable {
        let id: UInt32, vendor: UInt32, product: UInt32, serial: UInt32
        let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
        let modeID: UInt32, modeFlags: UInt32
        let refresh: Double
        let main: Bool, mirrored: Bool
        let mirrorTarget: UInt32
        let bounds: CGRect
    }
    private struct Journal: Codable {
        let version: Int
        let tool: String
        let lane: String
        let snapshotID: UUID
        let createdAt: Date
        let uid: UInt32
        let canonicalJournalPath: String
        let canonicalLaneRoot: String
        let grantedSnapshot: Bool
        let grantPath: String
        let windows: [Record]
        // All preexisting online displays are protected, including physical displays. No assumption
        // that a third-party virtual display is physically attached is needed for the safety check.
        let displays: [Display]
    }
    private struct Window {
        let element: AXUIElement
        let frame: CGRect
        let identifier: String?
        let standardNormal: Bool
    }
    private enum Resolution { case retired, unresolved, matched(Window) }

    private static func snapshot(url: URL, budget: HostAXBudget) throws -> Journal {
        let baseline = try displays(budget: budget)
        let visible = try windowInfo(.optionOnScreenOnly, budget: budget).filter(visibleAppWindow)
        guard visible.count <= maximumWindows else { throw GuardFailure("too-many-visible-windows") }
        var records: [Record] = []
        let pids = Set(visible.compactMap { number($0, kCGWindowOwnerPID)?.int32Value }).sorted()
        for pid in pids {
            try check(budget)
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  let launch = app.launchDate?.timeIntervalSince1970, launch.isFinite else { throw GuardFailure("process-launch-unavailable") }
            let candidates = try axWindows(pid, budget: budget)
            let rows = visible.filter { number($0, kCGWindowOwnerPID)?.int32Value == pid }
            for row in rows {
                guard let id = number(row, kCGWindowNumber)?.uint32Value, id != 0, let cgFrame = cgFrame(row) else { throw GuardFailure("incomplete-window-inventory") }
                let matches = candidates.filter { close($0.frame, cgFrame) }
                let cgMatches = rows.filter { self.cgFrame($0).map { close($0, cgFrame) } ?? false }
                guard matches.count == 1, cgMatches.count == 1 else { throw GuardFailure("ambiguous-initial-window-match") }
                guard matches[0].standardNormal else { continue }
                records.append(Record(pid: pid, launchTime: launch, windowID: id,
                                      axIdentifier: matches[0].identifier, original: matches[0].frame))
            }
        }
        guard records.count <= maximumWindows, Set(records.map(\.windowID)).count == records.count else { throw GuardFailure("duplicate-or-too-many-windows") }
        let current = try windowInfo(.optionOnScreenOnly, budget: budget).filter(visibleAppWindow)
        guard Set(current.compactMap { number($0, kCGWindowNumber)?.uint32Value })
            == Set(visible.compactMap { number($0, kCGWindowNumber)?.uint32Value }) else { throw GuardFailure("visible-window-set-changed-during-snapshot") }
        for row in visible {
            guard let id = number(row, kCGWindowNumber)?.uint32Value,
                  let before = cgFrame(row),
                  let after = current.first(where: { number($0, kCGWindowNumber)?.uint32Value == id
                    && number($0, kCGWindowOwnerPID)?.int32Value == number(row, kCGWindowOwnerPID)?.int32Value }).flatMap({ cgFrame($0) }),
                  close(before, after) else { throw GuardFailure("visible-window-frame-changed-during-snapshot") }
        }
        for record in records {
            guard NSRunningApplication(processIdentifier: record.pid)?.launchDate?.timeIntervalSince1970 == record.launchTime,
                  let row = current.first(where: { number($0, kCGWindowNumber)?.uint32Value == record.windowID && number($0, kCGWindowOwnerPID)?.int32Value == record.pid }),
                  let frame = cgFrame(row), close(frame, record.original) else { throw GuardFailure("snapshot-changed-before-persist") }
        }
        guard try displays(budget: budget) == baseline else { throw GuardFailure("display-topology-changed-during-snapshot") }
        return Journal(version: 1, tool: "SessionVirtualDisplayHarnessWindowGuard", lane: lane, snapshotID: UUID(), createdAt: Date(),
            uid: UInt32(geteuid()), canonicalJournalPath: url.path, canonicalLaneRoot: canonicalRoot.path,
            grantedSnapshot: true, grantPath: quietGrant, windows: records.sorted { $0.windowID < $1.windowID }, displays: baseline)
    }

    private static func resolve(_ records: [Record], budget: HostAXBudget) throws -> [(Record, Resolution)] {
        let all = try windowInfo(.optionAll, budget: budget)
        if all.isEmpty && records.contains(where: {
            NSRunningApplication(processIdentifier: $0.pid)?.launchDate?.timeIntervalSince1970 == $0.launchTime
        }) { throw GuardFailure("empty-public-inventory-with-surviving-process") }
        let visible = try windowInfo(.optionOnScreenOnly, budget: budget).filter(visibleAppWindow)
        var cache: [Int32: [Window]] = [:]
        var failedPIDs: Set<Int32> = []
        var result: [(Record, Resolution)] = []
        for record in records {
            try check(budget)
            guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else { result.append((record, .retired)); continue }
            guard let launch = app.launchDate?.timeIntervalSince1970 else { result.append((record, .unresolved)); continue }
            guard launch == record.launchTime else { result.append((record, .retired)); continue }
            let existing = all.filter { number($0, kCGWindowNumber)?.uint32Value == record.windowID && number($0, kCGWindowOwnerPID)?.int32Value == record.pid }
            guard !existing.isEmpty else { result.append((record, .retired)); continue }
            let rows = visible.filter { number($0, kCGWindowNumber)?.uint32Value == record.windowID && number($0, kCGWindowOwnerPID)?.int32Value == record.pid }
            guard existing.count == 1, rows.count == 1, let frame = cgFrame(rows[0]) else { result.append((record, .unresolved)); continue }
            if cache[record.pid] == nil, !failedPIDs.contains(record.pid) {
                do { cache[record.pid] = try axWindows(record.pid, budget: budget) }
                catch { if budget.isExhausted { throw error }; failedPIDs.insert(record.pid) }
            }
            guard let candidates = cache[record.pid] else { result.append((record, .unresolved)); continue }
            let matches = candidates.filter { $0.standardNormal && close($0.frame, frame) }
            let sameCGFrame = visible.filter { number($0, kCGWindowOwnerPID)?.int32Value == record.pid && cgFrame($0).map { close($0, frame) } == true }
            if let identifier = record.axIdentifier {
                let identified = matches.filter { $0.identifier == identifier }
                result.append((record, identified.count == 1 ? .matched(identified[0]) : .unresolved))
            } else {
                result.append((record, matches.count == 1 && sameCGFrame.count == 1 ? .matched(matches[0]) : .unresolved))
            }
        }
        return result
    }

    private static func restore(_ record: Record, window: Window, budget: HostAXBudget) throws {
        guard NSRunningApplication(processIdentifier: record.pid)?.launchDate?.timeIntervalSince1970 == record.launchTime else { throw GuardFailure("process-changed-before-restore") }
        let current = try readWindow(window.element, budget: budget)
        let visible = try windowInfo(.optionOnScreenOnly, budget: budget).filter(visibleAppWindow)
        guard current.standardNormal, record.axIdentifier == nil || current.identifier == record.axIdentifier,
              let row = visible.first(where: { number($0, kCGWindowNumber)?.uint32Value == record.windowID && number($0, kCGWindowOwnerPID)?.int32Value == record.pid }),
              let frame = cgFrame(row), close(frame, current.frame) else { throw GuardFailure("window-changed-before-restore") }
        var size = record.original.size, origin = record.original.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { throw GuardFailure("invalid-original-frame") }
        let sizeChanged = abs(current.frame.width - size.width) > tolerance || abs(current.frame.height - size.height) > tolerance
        let positionChanged = abs(current.frame.minX - origin.x) > tolerance || abs(current.frame.minY - origin.y) > tolerance
        if sizeChanged { try requireSettable(window.element, kAXSizeAttribute, budget: budget) }
        if positionChanged { try requireSettable(window.element, kAXPositionAttribute, budget: budget) }
        if sizeChanged {
            try arm(window.element, budget: budget)
            guard AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue) == .success else { throw GuardFailure("restore-size-refused") }
        }
        if positionChanged {
            try arm(window.element, budget: budget)
            guard AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, originValue) == .success else { throw GuardFailure("restore-position-refused") }
        }
    }

    private static func axWindows(_ pid: Int32, budget: HostAXBudget) throws -> [Window] {
        let app = AXUIElementCreateApplication(pid)
        guard let list = try attribute(app, kAXWindowsAttribute, budget: budget) as? [AXUIElement], list.count <= 128 else { throw GuardFailure("incomplete-or-large-ax-inventory") }
        return try list.map { try readWindow($0, budget: budget) }
    }

    private static func readWindow(_ element: AXUIElement, budget: HostAXBudget) throws -> Window {
        guard let subrole = try attribute(element, kAXSubroleAttribute, budget: budget) as? String,
              let position = try attribute(element, kAXPositionAttribute, budget: budget),
              let extent = try attribute(element, kAXSizeAttribute, budget: budget),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID() else { throw GuardFailure("incomplete-ax-window") }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size) else { throw GuardFailure("invalid-ax-frame") }
        let frame = CGRect(origin: origin, size: size)
        guard valid(frame) else { throw GuardFailure("invalid-ax-frame") }
        var normal = false
        if subrole == kAXStandardWindowSubrole as String {
            guard let minimized = try attribute(element, kAXMinimizedAttribute, budget: budget) as? NSNumber else { throw GuardFailure("unknown-minimized-state") }
            if !minimized.boolValue {
                guard let full = try attribute(element, "AXFullScreen", budget: budget) as? NSNumber else { throw GuardFailure("unknown-fullscreen-state") }
                normal = !full.boolValue
            }
        }
        let identifier = try attribute(element, kAXIdentifierAttribute, optional: true, budget: budget) as? String
        guard (identifier?.utf8.count ?? 0) <= 1024 else { throw GuardFailure("invalid-ax-identifier") }
        return Window(element: element, frame: frame, identifier: identifier.flatMap { $0.isEmpty ? nil : $0 }, standardNormal: normal)
    }

    private static func attribute(_ element: AXUIElement, _ key: String, optional: Bool = false, budget: HostAXBudget) throws -> CFTypeRef? {
        try arm(element, budget: budget)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        if optional && (error == .attributeUnsupported || error == .noValue || error == .notImplemented) { return nil }
        guard error == .success else { throw GuardFailure("ax-read-incomplete") }
        try check(budget)
        return value
    }
    private static func requireSettable(_ element: AXUIElement, _ key: String, budget: HostAXBudget) throws {
        try arm(element, budget: budget)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, key as CFString, &settable) == .success, settable.boolValue else { throw GuardFailure("original-frame-not-settable") }
        try check(budget)
    }
    private static func arm(_ element: AXUIElement, budget: HostAXBudget) throws {
        guard budget.arm(element) else { throw GuardFailure("ax-deadline-or-element-unavailable") }
    }
    private static func check(_ budget: HostAXBudget) throws { if budget.isExhausted { throw GuardFailure("deadline") } }

    private static func windowInfo(_ options: CGWindowListOption, budget: HostAXBudget) throws -> [[String: Any]] {
        try check(budget)
        guard let rows = CGWindowListCopyWindowInfo([options, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]], rows.count <= 16384 else { throw GuardFailure("public-window-inventory-unavailable") }
        try check(budget)
        return rows
    }
    private static func number(_ row: [String: Any], _ key: CFString) -> NSNumber? { row[key as String] as? NSNumber }
    private static func visibleAppWindow(_ row: [String: Any]) -> Bool {
        number(row, kCGWindowLayer)?.intValue == 0 && (number(row, kCGWindowAlpha)?.doubleValue ?? 0) > 0
            && (number(row, kCGWindowOwnerPID)?.int32Value ?? 0) > 0
    }
    private static func cgFrame(_ row: [String: Any]) -> CGRect? {
        guard let dictionary = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary), valid(frame) else { return nil }
        return frame
    }
    private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && frame.width <= 32768 && frame.height <= 32768
    }
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func displays(budget: HostAXBudget) throws -> [Display] {
        try check(budget)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { throw GuardFailure("display-inventory-unavailable") }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success, count > 0, Int(count) <= ids.count else { throw GuardFailure("display-inventory-changed") }
        let result = try ids.prefix(Int(count)).sorted().map { id -> Display in
            try check(budget)
            guard let mode = CGDisplayCopyDisplayMode(id) else { throw GuardFailure("display-mode-unavailable") }
            return Display(id: id, vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                modeID: CGDisplayModeGetIODisplayModeID(mode), modeFlags: CGDisplayModeGetIOFlags(mode), refresh: mode.refreshRate,
                main: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0, mirrorTarget: CGDisplayMirrorsDisplay(id), bounds: CGDisplayBounds(id))
        }
        try check(budget)
        return result
    }

    private static var canonicalRoot: URL { URL(fileURLWithPath: laneRoot, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL }
    private static func validatedURL(_ path: String) throws -> URL {
        guard path.utf8.count <= 4096 else { throw GuardFailure("invalid-journal-path") }
        let raw = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: raw.path), try raw.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw GuardFailure("journal-symlink-rejected") }
        let url = raw.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonicalRoot.path + "/"), url.path != canonicalRoot.path else { throw GuardFailure("journal-outside-lane") }
        return url
    }
    private static func load(_ url: URL) throws -> Journal {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576 else { throw GuardFailure("invalid-journal-file") }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        guard journal.version == 1, journal.tool == "SessionVirtualDisplayHarnessWindowGuard", journal.lane == lane,
              journal.uid == UInt32(geteuid()), journal.grantedSnapshot, journal.grantPath == quietGrant,
              journal.canonicalJournalPath == url.path, journal.canonicalLaneRoot == canonicalRoot.path,
              journal.createdAt.timeIntervalSince1970.isFinite, journal.createdAt <= Date().addingTimeInterval(5),
              journal.windows.count <= maximumWindows, !journal.displays.isEmpty, journal.displays.count <= 32,
              Set(journal.windows.map(\.windowID)).count == journal.windows.count,
              Set(journal.displays.map(\.id)).count == journal.displays.count,
              journal.windows.allSatisfy({ $0.pid > 0 && $0.launchTime.isFinite && $0.windowID != 0 && valid($0.original) && ($0.axIdentifier?.utf8.count ?? 0) <= 1024 }) else { throw GuardFailure("invalid-journal-provenance") }
        return journal
    }
}

/// Wall-clock fail-safe covers AX, CoreGraphics, filesystem or AppKit calls that fail to return.
/// The snapshot is immutable, so a partial restore remains retryable after this process exits.
private final class WindowGuardDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let timer: DispatchSourceTimer
    init(seconds: Double) {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let timedOut = self.lock.withLock { () -> Bool in
                guard !self.finished else { return false }
                self.finished = true
                return true
            }
            if timedOut {
                fputs("SESSION-VD-WINDOW-GUARD: error=hard-deadline; journal-retained-if-present\n", stderr)
                _exit(124)
            }
        }
        timer.resume()
    }
    func finish() { lock.withLock { finished = true }; timer.cancel() }
}
#endif
