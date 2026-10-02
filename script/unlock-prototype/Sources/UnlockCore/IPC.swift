import Foundation
import SystemConfiguration
import CoreGraphics

public enum Prototype {
    public static let service = "com.roshan.Farside.UnlockPrototype.daemon"
    public static let root = "/Library/Application Support/FarsideUnlockPrototype"
    public static let team = "39HM2X8GS6"
    public static func requirement(_ roles: [String]) -> String {
        let identifiers = roles.map { "identifier \"com.roshan.Farside.UnlockPrototype.\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(identifiers))"
    }
    public static func configuration() -> (enabled: Bool, uid: UInt32)? {
        // No symlinks, root-owned, not writable by group/others. Kill switch read on each operation.
        var info = stat()
        let path = root + "/config.plist"
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0, info.st_mode & 0o022 == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let uid = values["DisposableUID"] as? UInt32, uid >= 501,
              let enabled = values["Enabled"] as? Bool else { return nil }
        return (enabled, uid)
    }
    public static func console() -> (uid: UInt32, loginWindow: Bool)? {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else { return nil }
        return (uid, user == "loginwindow" && uid == 0)
    }
    public static func canType(deadline: Double) -> Bool {
        guard let config = configuration(), let console = console(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return Policy.canType(enabled: config.enabled, expectedUID: config.uid, actualUID: console.uid,
            onConsole: session[kCGSessionOnConsoleKey as String] as? Bool == true &&
                (session[kCGSessionUserIDKey as String] as? UInt32) == config.uid,
            locked: session["CGSSessionScreenIsLocked"] as? Bool,
            deadline: deadline, now: Date().timeIntervalSince1970)
    }
    public static func canCapture() -> Bool {
        guard let config = configuration(), config.enabled, let console = console() else { return false }
        if getuid() == 0 { return console.loginWindow }
        return getuid() == config.uid && canType(deadline: Date().timeIntervalSince1970 + 15)
    }
}

@objc public protocol DaemonAPI {
    func registerAgent(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void)
    func capture(reply: @escaping (Data?, String) -> Void)
    func typePassword(_ bytes: Data, reply: @escaping (String) -> Void)
}
@objc public protocol AgentAPI {
    func capture(_ deadline: Double, reply: @escaping (Data?, String) -> Void)
    func typePassword(_ bytes: Data, deadline: Double, reply: @escaping (String) -> Void)
}
