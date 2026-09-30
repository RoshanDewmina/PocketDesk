#!/usr/bin/env swift
// S2 in Docs/plans/AWAY-MODE-FEASIBILITY-TESTS.md: does posting the Lock Screen shortcut lock this Mac?
// Roshan runs this himself; agents only type-check it. It LOCKS THE MAC.
//
//   swift script/away-feasibility/away-lock-probe.swift
//
// HostLockShortcut below must stay identical to HostLockShortcut in RemoteHost/AwayLock.swift
// (key code, flags, event source, tag, order, tap). A reviewer must diff the two; if they drift,
// this test no longer says anything about the app.

import ApplicationServices
import CoreGraphics
import Foundation

enum HostLockShortcut {
    static let keyCode: CGKeyCode = 12
    static let flags: CGEventFlags = [.maskControl, .maskCommand]
    static let tag: Int64 = 0x4641_5253_4944_4531

    static func events(source: CGEventSource?) -> [CGEvent] {
        [true, false].compactMap { keyDown in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return nil }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            return event
        }
    }

    static func post(_ events: [CGEvent]) {
        events.forEach { $0.post(tap: .cghidEventTap) }
    }
}

func stderrLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func isLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
}

func timestamp(_ format: String, _ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
}

guard CommandLine.arguments.count == 1 else {
    stderrLine("usage: swift script/away-feasibility/away-lock-probe.swift (no arguments)")
    exit(64)
}

guard isatty(0) != 0 else {
    stderrLine("Refusing to run: stdin is not a terminal. Run this yourself in Terminal and type LOCK.")
    exit(1)
}

let hostApp: String = {
    switch ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
    case "Apple_Terminal": "Terminal"
    case "iTerm.app": "iTerm"
    case let other?: "the app running this shell (TERM_PROGRAM=\(other))"
    case nil: "the app running this shell (Terminal or iTerm)"
    }
}()

print("""
Farside Away mode — S2 lock-shortcut test

This will post Control-Command-Q (the system Lock Screen shortcut) once, exactly as Farside
does when Away mode locks, then check for 2 s whether macOS reports the screen locked.
YOUR MAC WILL LOCK. Save your work first. It changes no setting and asks for no password.

Type LOCK and press Return to continue (anything else cancels):
""", terminator: "")

guard readLine() == "LOCK" else {
    print("Cancelled. Nothing was posted.")
    exit(1)
}

guard AXIsProcessTrusted() else {
    print("""
    \(hostApp) does not have Accessibility, so macOS would drop the shortcut. Nothing was posted.
    Add it in System Settings → Privacy & Security → Accessibility, then run this again.
    Remove it afterwards if you added it only for this test.
    """)
    exit(2)
}

guard !isLocked() else {
    print("macOS already reports the screen locked. Nothing was posted.")
    exit(1)
}

let events = HostLockShortcut.events(source: CGEventSource(stateID: .hidSystemState))
guard events.count == 2 else {
    print("Could not create the key events. Nothing was posted.")
    exit(1)
}

print("Hands off the keyboard and trackpad.")
for second in stride(from: 5, through: 1, by: -1) {
    print("Locking in \(second)…")
    sleep(1)
}

let posted = Date()
HostLockShortcut.post(events)

var lockedAfterMs: Int?
while Date().timeIntervalSince(posted) < 2 {
    if isLocked() {
        lockedAfterMs = Int((Date().timeIntervalSince(posted) * 1000).rounded())
        break
    }
    usleep(100_000)
}

let result = lockedAfterMs.map { "S2 RESULT: LOCKED in \($0) ms" } ?? "S2 RESULT: NOT LOCKED within 2 s"

let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Farside")
let logURL = logDirectory.appendingPathComponent("away-s2-\(timestamp("yyyyMMdd-HHmmss", posted)).log")
let record = """
# S2 \(timestamp("yyyy-MM-dd'T'HH:mm:ssXXXXX", posted)) macOS \(ProcessInfo.processInfo.operatingSystemVersionString) host=\(hostApp)
\(result)

"""
do {
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: logURL)
    handle.seekToEndOfFile()
    handle.write(Data(record.utf8))
    try handle.close()
    print(result)
    print("log: \(logURL.path)")
} catch {
    print(result)
    stderrLine("Could not write \(logURL.path): \(error)")
}
exit(lockedAfterMs == nil ? 1 : 0)
