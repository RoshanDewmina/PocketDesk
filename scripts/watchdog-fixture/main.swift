import Foundation
import Darwin

// A stand-in for the Farside host, used only to exercise the real FarsideWatchdog binary end to end.
// It publishes the same run record as the host and obeys one-word commands: crash, quit, hang.

let bundle = Bundle.main
guard let identifier = bundle.bundleIdentifier, let executable = bundle.executablePath,
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
else { exit(2) }
let files = WatchdogFiles.forHost(bundleIdentifier: identifier, bundlePath: bundle.bundlePath, applicationSupport: support)
let commandURL = files.directory.appendingPathComponent("command")
let launchLog = files.directory.appendingPathComponent("launches.log")

var record = HostRunRecord(pid: getpid(), launchID: UUID().uuidString, bootSession: HostProcessInfo.bootSession(),
                           executablePath: executable, startedAt: Date(),
                           heartbeatUptime: ProcessInfo.processInfo.systemUptime, heartbeatAt: Date(),
                           curtainUp: true)
WatchdogStore.write(record, to: files.hostRecord)
let line = "pid=\(getpid()) launch=\(record.launchID) args=\(CommandLine.arguments.dropFirst().joined(separator: " "))\n"
if let handle = try? FileHandle(forWritingTo: launchLog) {
    handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile()
} else {
    try? Data(line.utf8).write(to: launchLog)
}

var hanging = false
let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
    if let command = try? String(contentsOf: commandURL, encoding: .utf8) {
        try? FileManager.default.removeItem(at: commandURL)
        switch command.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "crash": _exit(9)
        case "quit":
            record.cleanExit = true
            WatchdogStore.write(record, to: files.hostRecord)
            exit(0)
        case "hang": hanging = true
        default: break
        }
    }
    guard !hanging else { return }
    record.heartbeatUptime = ProcessInfo.processInfo.systemUptime
    record.heartbeatAt = Date()
    WatchdogStore.write(record, to: files.hostRecord)
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
