import Foundation
import CoreGraphics

/// A location aid only. The captured cursor remains the source of shape and visibility.
struct PointerLocation: Codable, Equatable {
    var x: Double
    var y: Double

    func validate() throws {
        guard x.isFinite, y.isFinite, (0...20000).contains(x), (0...20000).contains(y) else {
            throw RemoteError.invalidMessage
        }
    }
}

/// One outstanding challenge bounds both telemetry traffic and delayed response age.
struct PointerProbeState {
    private(set) var pending: String?
    private var sentAt: TimeInterval = 0
    private(set) var point: CGPoint?
    private(set) var acceptedAt: TimeInterval = 0
    static let lifetime: TimeInterval = 0.25

    mutating func begin(at now: TimeInterval) -> String? {
        if pending != nil && now - sentAt <= Self.lifetime { return nil }
        let id = UUID().uuidString
        pending = id
        sentAt = now
        return id
    }

    mutating func receive(probe: String, location: PointerLocation?, at now: TimeInterval, sourceSize: CGSize) -> Bool {
        guard probe == pending else { return false }
        pending = nil
        guard now >= sentAt, now - sentAt <= Self.lifetime,
              let location, (try? location.validate()) != nil,
              location.x < sourceSize.width, location.y < sourceSize.height else {
            point = nil
            return false
        }
        point = CGPoint(x: location.x, y: location.y)
        acceptedAt = now
        return true
    }

    mutating func expire(at now: TimeInterval) {
        if now < acceptedAt || now - acceptedAt > Self.lifetime { point = nil }
    }
}

/// Limits authenticated location queries and maps the global event point into
/// the selected capture display's logical coordinate space.
struct HostPointerLocator {
    static let minimumInterval: TimeInterval = 1.0 / 30.0
    private var lastResponseAt: TimeInterval?

    mutating func reset() { lastResponseAt = nil }

    mutating func admit(at now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0 else { return false }
        if let lastResponseAt {
            guard now >= lastResponseAt + Self.minimumInterval else { return false }
        }
        lastResponseAt = now
        return true
    }

    static func location(for point: CGPoint, in frame: CGRect) -> PointerLocation? {
        guard point.x.isFinite, point.y.isFinite,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              point.x >= frame.minX, point.x < frame.maxX,
              point.y >= frame.minY, point.y < frame.maxY
        else { return nil }
        let location = PointerLocation(x: Double(point.x - frame.minX),
                                       y: Double(point.y - frame.minY))
        return (try? location.validate()) == nil ? nil : location
    }
}

