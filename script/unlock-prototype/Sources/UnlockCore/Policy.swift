import Foundation

public enum Policy {
    public static func canType(enabled: Bool, expectedUID: UInt32, actualUID: UInt32?, onConsole: Bool, locked: Bool?, deadline: Double, now: Double) -> Bool {
        enabled && expectedUID >= 501 && actualUID == expectedUID && onConsole && locked == true && deadline > now && deadline - now <= 30
    }
    // Prototype uses a disposable lowercase ASCII/digit password on an ABC/U.S. keyboard only.
    public static func validPassword(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= 64 && data.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }
}
public struct AttemptBudget {
    private var count = 0
    private var last: Double?
    public init() {}
    public mutating func take(now: Double) -> Bool {
        guard now.isFinite, count < 3, last.map({ now - $0 >= 30 }) ?? true else { return false }
        count += 1; last = now; return true
    }
}
