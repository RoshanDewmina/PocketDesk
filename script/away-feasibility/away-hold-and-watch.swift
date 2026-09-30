#!/usr/bin/env swift
// S1 in Docs/plans/AWAY-MODE-FEASIBILITY-TESTS.md: do the two assertions Away mode holds while
// armed stop the idle lock? Roshan runs this himself; agents only type-check it.
//
//   swift script/away-feasibility/away-hold-and-watch.swift [--minutes N] [--declare-activity-every S]
//
// It changes no setting and posts no events. The assertions exist only while it runs.

import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

let assertionName = "Farside Away S1 test"
let sampleSeconds = 10

func stderrLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func usageAndExit(_ problem: String) -> Never {
    stderrLine(problem)
    stderrLine("usage: swift script/away-feasibility/away-hold-and-watch.swift [--minutes N] [--declare-activity-every S]")
    exit(64)
}

var minutes = 30
var activityEvery: Int?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--minutes":
        guard let value = arguments.popFirst().flatMap(Int.init), value > 0 else {
            usageAndExit("--minutes needs a whole number above 0")
        }
        minutes = value
    case "--declare-activity-every":
        guard let value = arguments.popFirst().flatMap(Int.init), value > 0 else {
            usageAndExit("--declare-activity-every needs a whole number of seconds above 0")
        }
        activityEvery = value
    default:
        usageAndExit("unknown argument: \(argument)")
    }
}

guard isatty(0) != 0 else {
    stderrLine("Refusing to run: stdin is not a terminal. Run this yourself in Terminal and type HOLD.")
    exit(1)
}

print("""
Farside Away mode — S1 idle-lock test

For \(minutes) min this will:
  • hold "PreventUserIdleSystemSleep" and "PreventUserIdleDisplaySleep" assertions named "\(assertionName)"
    (the same two Farside holds while Away mode is armed)
""")
if let activityEvery {
    print("  • declare local user activity every \(activityEvery) s (S1c)")
}
print("""
  • every \(sampleSeconds) s, record whether the Mac is locked, the screen saver is running and the display is asleep
  • release the assertions when it finishes, on Control-C, or when it is terminated

It changes no setting and posts no keyboard or mouse events.
After typing HOLD, walk away and do not touch the Mac until it finishes.

Type HOLD and press Return to start (anything else cancels):
""", terminator: "")

guard readLine() == "HOLD" else {
    print("Cancelled. Nothing was held.")
    exit(1)
}

func timestamp(_ format: String, _ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
}

let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Farside")
let logURL = logDirectory.appendingPathComponent("away-s1-\(timestamp("yyyyMMdd-HHmmss")).log")
do {
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
} catch {
    stderrLine("Could not create \(logURL.path): \(error). Nothing was held.")
    exit(1)
}
guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
    stderrLine("Could not open \(logURL.path). Nothing was held.")
    exit(1)
}

func log(_ line: String) {
    print(line)
    logHandle.seekToEndOfFile()
    logHandle.write(Data((line + "\n").utf8))
}

final class Holder {
    private(set) var systemID: IOPMAssertionID = 0
    private(set) var displayID: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var holdingSystem = false
    private var holdingDisplay = false
    private var holdingActivity = false

    func hold() -> Bool {
        holdingSystem = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), assertionName as CFString, &systemID
        ) == kIOReturnSuccess
        holdingDisplay = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), assertionName as CFString, &displayID
        ) == kIOReturnSuccess
        return holdingSystem && holdingDisplay
    }

    func declareActivity() -> IOReturn {
        let result = IOPMAssertionDeclareUserActivity(assertionName as CFString, kIOPMUserActiveLocal, &activityID)
        if result == kIOReturnSuccess { holdingActivity = true }
        return result
    }

    func releaseAll() {
        if holdingSystem { IOPMAssertionRelease(systemID); holdingSystem = false }
        if holdingDisplay { IOPMAssertionRelease(displayID); holdingDisplay = false }
        if holdingActivity { IOPMAssertionRelease(activityID); holdingActivity = false }
    }
}

struct Sample {
    var locked: Bool
    var screensaver: Bool
    var displayAsleep: Bool

    static func now() -> Sample {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let screensaver = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
                || $0.localizedName == "ScreenSaverEngine"
                || $0.executableURL?.lastPathComponent == "ScreenSaverEngine"
        }
        return Sample(
            locked: (session?["CGSSessionScreenIsLocked"] as? Bool) == true,
            screensaver: screensaver,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0
        )
    }
}

let holder = Holder()
guard holder.hold() else {
    holder.releaseAll()
    stderrLine("Could not create both assertions. Nothing is held; no test ran.")
    exit(1)
}

let start = Date()
let durationSeconds = minutes * 60
var firstLockedAfter: Int?
var screensaverSeenByLock = false
var screensaverEverSeen = false
var finished = false
var sources: [DispatchSourceProtocol] = []

log("# S1 start \(timestamp("yyyy-MM-dd'T'HH:mm:ssXXXXX", start)) macOS \(ProcessInfo.processInfo.operatingSystemVersionString) minutes=\(minutes) declareActivityEvery=\(activityEvery.map(String.init) ?? "off")")

@MainActor
func finish(stoppedBy signalName: String?) {
    guard !finished else { return }
    finished = true
    sources.forEach { $0.cancel() }
    holder.releaseAll()
    let elapsed = Int(Date().timeIntervalSince(start).rounded())
    let result: String
    if let firstLockedAfter {
        result = "S1 RESULT: LOCKED after \(firstLockedAfter) s (screensaver=\(screensaverSeenByLock))"
    } else if let signalName {
        result = "S1 RESULT: INCOMPLETE, stopped by \(signalName) after \(elapsed) s without locking"
    } else {
        result = "S1 RESULT: NOT LOCKED during \(minutes) min"
    }
    log("# assertions released; screensaverEverSeen=\(screensaverEverSeen)")
    log(result)
    log("# log: \(logURL.path)")
    try? logHandle.close()
    exit(firstLockedAfter == nil && signalName == nil ? 0 : 1)
}

for (number, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { finish(stoppedBy: name) } }
    source.resume()
    sources.append(source)
}

let sampler = DispatchSource.makeTimerSource(queue: .main)
sampler.schedule(deadline: .now(), repeating: .seconds(sampleSeconds))
sampler.setEventHandler {
    MainActor.assumeIsolated {
        let elapsed = Int(Date().timeIntervalSince(start).rounded())
        let sample = Sample.now()
        if sample.screensaver {
            screensaverEverSeen = true
            if firstLockedAfter == nil { screensaverSeenByLock = true }
        }
        if sample.locked, firstLockedAfter == nil { firstLockedAfter = elapsed }
        log("\(timestamp("yyyy-MM-dd'T'HH:mm:ssXXXXX")) elapsed=\(elapsed) locked=\(sample.locked) screensaver=\(sample.screensaver) displayAsleep=\(sample.displayAsleep)")
        if elapsed >= durationSeconds { finish(stoppedBy: nil) }
    }
}
sampler.resume()
sources.append(sampler)

if let activityEvery {
    let declarer = DispatchSource.makeTimerSource(queue: .main)
    declarer.schedule(deadline: .now(), repeating: .seconds(activityEvery))
    declarer.setEventHandler {
        MainActor.assumeIsolated {
            let result = holder.declareActivity()
            if result != kIOReturnSuccess {
                log("# IOPMAssertionDeclareUserActivity failed: 0x\(String(UInt32(bitPattern: result), radix: 16))")
            }
        }
    }
    declarer.resume()
    sources.append(declarer)
}

// NSWorkspace.runningApplications only refreshes while the main run loop runs, so dispatchMain() would not do.
RunLoop.main.run()
