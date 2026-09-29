import Foundation

/// Removes anything identifying from free text before it can reach a diagnostics bundle:
/// addresses, URLs and host names, long tokens, e-mail addresses and home-folder names.
enum DiagnosticsSanitizer {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, "[url]"),
        (#"[^\s@]+@[^\s@]+\.[^\s@]+"#, "[email]"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "[id]"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, "[ip]"),
        (#"(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}|[0-9A-Fa-f:]*::[0-9A-Fa-f:]*[0-9A-Fa-f]"#, "[ip]"),
        (#"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b"#, "[host]"),
        // Keys, pairing codes and digests mix letters and digits; plain error codes do not.
        (#"(?=[A-Za-z0-9+/_=-]*[0-9])(?=[A-Za-z0-9+/_=-]*[A-Za-z])[A-Za-z0-9+/_=-]{20,}"#, "[redacted]"),
        (#"/Users/[^/\s]+"#, "/Users/[user]")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func clean(_ text: String, limit: Int = 240) -> String {
        var value = text
        for (expression, replacement) in rules {
            let range = NSRange(value.startIndex..., in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
        }
        value = value.replacingOccurrences(of: "\n", with: " ")
        if value.count > limit { value = String(value.prefix(limit)) + "…" }
        return value
    }
}

/// A short in-memory history of what the host did, for support. Messages are sanitized on entry
/// and never include screen content, typed text, clipboard contents, tokens or addresses.
@MainActor
final class HostEventLog {
    enum Kind: String {
        case launch, sharing, session, capture, availability, curtain, recovery, settings, error
    }

    struct Entry: Equatable {
        let at: Date
        let kind: Kind
        let message: String
    }

    static let capacity = 60
    private(set) var entries: [Entry] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func record(_ kind: Kind, _ message: String) {
        let clean = DiagnosticsSanitizer.clean(message)
        if let last = entries.last, last.kind == kind, last.message == clean,
           now().timeIntervalSince(last.at) < 5 { return }
        entries.append(Entry(at: now(), kind: kind, message: clean))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}

struct HostDiagnosticsSnapshot {
    var generatedAt = Date()
    var appVersion = "?"
    var appBuild = "?"
    var osVersion = "?"
    var hardwareModel = "?"
    var installedInApplications = false
    var appUptime: TimeInterval = 0

    var screenRecording = "?"
    var accessibility = "?"
    var loginItem = "?"
    var automaticRecovery = "?"

    var status = "?"
    var sharingWanted = false
    var sharingActive = false
    var phonePaired = false
    var phoneConnected = false
    var controlEffective = false
    var keepAwake = false
    var displayCount = 0
    var detail: String?
    var localPairRemovalFailure: String?
    var serviceEnvironment = "not configured"

    var curtainPreference = false
    var curtainState = "off"

    var recoveredThisLaunch = false
    var previousExit: String?
    var safeMode = false
    var watchdogRelaunchesThisBoot = 0
    var watchdogLastExit: String?
    var watchdogLastExitAt: Date?
    var watchdogStoppedAt: Date?

    var sessionsThisLaunch = 0
    var lastSessionDuration: TimeInterval?
    var route: String?
    var streamQuality: String?
    /// Sent size, negotiated codec level, encoder and decoder-probe outcome of the last session.
    var stream: String?
    /// The active stream tuning, including any experiment switch left in defaults.
    var tuning: String?

    var events: [HostEventLog.Entry] = []
}

enum HostDiagnosticsReport {
    static func render(_ snapshot: HostDiagnosticsSnapshot) -> String {
        let s = snapshot
        var lines: [String] = []
        func section(_ title: String) { lines.append(""); lines.append("## \(title)") }
        func row(_ key: String, _ value: String) { lines.append("\(key): \(DiagnosticsSanitizer.clean(value))") }
        func yes(_ flag: Bool) -> String { flag ? "yes" : "no" }
        func ago(_ date: Date?) -> String {
            guard let date else { return "never" }
            return duration(s.generatedAt.timeIntervalSince(date)) + " ago"
        }

        lines.append("Farside Mac diagnostics")
        lines.append("Contains no screen content, typed text, clipboard contents, pairing codes, tokens or network addresses.")
        section("App")
        row("Version", "\(s.appVersion) (\(s.appBuild))")
        row("macOS", s.osVersion)
        row("Mac model", s.hardwareModel)
        row("In Applications folder", yes(s.installedInApplications))
        row("Running for", duration(s.appUptime))
        section("Permissions and background items")
        row("Screen Recording", s.screenRecording)
        row("Accessibility", s.accessibility)
        row("Open at login", s.loginItem)
        row("Automatic recovery", s.automaticRecovery)
        section("Sharing")
        row("Status", s.status)
        row("Sharing on", yes(s.sharingWanted))
        row("Sharing active", yes(s.sharingActive))
        row("Phone paired", yes(s.phonePaired))
        row("Service environment", s.serviceEnvironment)
        if let failure = s.localPairRemovalFailure { row("Local pairing removal", failure) }
        row("Phone connected", yes(s.phoneConnected))
        row("Mouse and keyboard control", yes(s.controlEffective))
        row("Keep awake while sharing", yes(s.keepAwake))
        row("Displays", "\(s.displayCount)")
        if let detail = s.detail { row("Last message", detail) }
        section("Privacy curtain")
        row("Hide screen while sharing", yes(s.curtainPreference))
        row("Curtain", s.curtainState)
        section("Recovery")
        row("Restarted after a problem", s.recoveredThisLaunch ? "yes (\(s.previousExit ?? "unknown"))" : "no")
        row("Stopped after repeated crashes", yes(s.safeMode))
        row("Watchdog relaunches this boot", "\(s.watchdogRelaunchesThisBoot)")
        row("Last unexpected exit", s.watchdogLastExit.map { "\($0), \(ago(s.watchdogLastExitAt))" } ?? "none")
        if s.watchdogStoppedAt != nil { row("Crash-loop stop", ago(s.watchdogStoppedAt)) }
        section("Sessions")
        row("Sessions since launch", "\(s.sessionsThisLaunch)")
        row("Last session length", s.lastSessionDuration.map(duration) ?? "none")
        row("Route", s.route ?? "not measured")
        row("Picture quality", s.streamQuality ?? "not applied")
        row("Stream", s.stream ?? "not measured")
        row("Stream tuning", s.tuning ?? "?")
        section("Recent events")
        if s.events.isEmpty { lines.append("none") }
        for entry in s.events.suffix(40) {
            lines.append("-\(duration(s.generatedAt.timeIntervalSince(entry.at))) \(entry.kind.rawValue): \(DiagnosticsSanitizer.clean(entry.message))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }
}

enum HostHardware {
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
}
