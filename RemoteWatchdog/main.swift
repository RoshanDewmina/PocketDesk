import AppKit
import Darwin
import Foundation

// launchd sends SIGTERM at logout or when the host unregisters this agent.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { exit(0) }
termination.resume()

let executable = HostProcessInfo.executablePath(of: getpid()) ?? CommandLine.arguments[0]
MainActor.assumeIsolated {
    if let supervisor = WatchdogSupervisor(executablePath: executable) {
        supervisor.run()
        withExtendedLifetime(supervisor) { RunLoop.main.run() }
    } else {
        // Not inside a Farside app bundle. Idle rather than exit, so KeepAlive does not respawn a
        // misplaced helper every few seconds.
        FileHandle.standardError.write(Data("FarsideWatchdog: not inside a Farside app bundle; idling.\n".utf8))
    }
}
dispatchMain()
