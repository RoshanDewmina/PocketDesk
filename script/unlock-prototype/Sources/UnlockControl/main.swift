import Foundation
import Darwin
import UnlockCore

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
// Restore terminal echo on an interrupt instead of relying on Swift defer at process termination.
var secretTTY: Int32 = -1
var savedTTY = termios()
func restoreTTYOnSignal(_ number: Int32) {
    if secretTTY >= 0 { tcsetattr(secretTTY, TCSAFLUSH, &savedTTY) }
    _exit(128 + number)
}
func readSecret() -> Data {
    guard isatty(STDIN_FILENO) == 1, let tty = fopen("/dev/tty", "r+") else { fail("TTY_REQUIRED") }
    defer { fclose(tty) }
    fputs("Type DISPOSABLE to confirm this is the disposable account: ", tty); fflush(tty)
    var confirmation = [CChar](repeating: 0, count: 32)
    guard fgets(&confirmation, Int32(confirmation.count), tty) != nil, String(cString: confirmation) == "DISPOSABLE\n" else { fail("CANCELLED") }
    var original = termios()
    guard tcgetattr(fileno(tty), &original) == 0 else { fail("TTY_FAILED") }
    savedTTY = original; secretTTY = fileno(tty)
    let oldInterrupt = signal(SIGINT, restoreTTYOnSignal)
    let oldTerminate = signal(SIGTERM, restoreTTYOnSignal)
    var hidden = original; hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(fileno(tty), TCSAFLUSH, &hidden) == 0 else { fail("TTY_FAILED") }
    defer {
        tcsetattr(fileno(tty), TCSAFLUSH, &original); secretTTY = -1
        signal(SIGINT, oldInterrupt); signal(SIGTERM, oldTerminate); fputs("\n", tty)
    }
    fputs("Disposable password (hidden, lowercase ASCII/digits, ABC/U.S. layout): ", tty); fflush(tty)
    var result = Data()
    while true {
        let byte = fgetc(tty)
        if byte == 10 { break }
        guard byte >= 0, result.count < 64 else {
            result.resetBytes(in: result.startIndex..<result.endIndex)
            // fail() exits without unwinding defer; explicitly restore before exit.
            tcsetattr(fileno(tty), TCSAFLUSH, &original); fail("INVALID_PASSWORD")
        }
        result.append(UInt8(byte))
    }
    return result
}
func saveFrame(_ data: Data, path: String) {
    guard data.count <= 16_000_000 else { fail("FRAME_TOO_LARGE") }
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { fail("OUTPUT_MUST_BE_A_NEW_FILE") }
    var completed = false
    defer { close(fd); if !completed { unlink(path) } }
    let ok = data.withUnsafeBytes { bytes -> Bool in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count <= 0 { return false }; offset += count
        }
        return fsync(fd) == 0
    }
    guard ok else { close(fd); unlink(path); fail("WRITE_FAILED") }
    completed = true
}
guard geteuid() == 0 else { fail("ROOT_REQUIRED") }
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : ""
guard (mode == "capture" && args.count == 3) || (mode == "type" && args.count == 2) else {
    fail("Usage: sudo UnlockControl capture /absolute/new-frame.png | sudo UnlockControl type")
}
guard Prototype.configuration()?.enabled == true else { fail("DISABLED") }
let connection = NSXPCConnection(machServiceName: Prototype.service, options: .privileged)
connection.setCodeSigningRequirement(Prototype.requirement(["daemon"]))
connection.remoteObjectInterface = NSXPCInterface(with: DaemonAPI.self)
connection.resume()
defer { connection.invalidate() }
let semaphore = DispatchSemaphore(value: 0)
let proxy = connection.remoteObjectProxyWithErrorHandler { _ in fail("XPC_FAILED") } as! DaemonAPI
if mode == "capture" {
    guard args[2].hasPrefix("/") else { fail("ABSOLUTE_OUTPUT_PATH_REQUIRED") }
    proxy.capture { data, status in
        guard status == "FRAME", let data else { fail(status) }
        saveFrame(data, path: args[2]); print("FRAME_SAVED_ROOT_ONLY"); semaphore.signal()
    }
} else {
    var password = readSecret()
    guard Policy.validPassword(password) else { password.resetBytes(in: password.startIndex..<password.endIndex); fail("INVALID_PASSWORD") }
    proxy.typePassword(password) { status in
        guard status == "POSTED_NOT_VERIFIED" else { fail(status) }
        print(status); semaphore.signal()
    }
    password.resetBytes(in: password.startIndex..<password.endIndex)
}
guard semaphore.wait(timeout: .now() + 25) == .success else { fail("TIMEOUT_RESULT_UNKNOWN_DO_NOT_RETRY") }
