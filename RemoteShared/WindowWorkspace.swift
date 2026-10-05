import Foundation
import CoreGraphics

struct WindowWorkspaceRequest: Codable, Equatable {
    enum Operation: String, Codable { case list, activate, focusCurrent, close }
    let operation: Operation
    var revision: String? = nil
    var handle: String? = nil
    func validate() throws {
        switch operation {
        case .activate:
            guard let revision, let handle, InputCausalEnvelope.validID(revision), InputCausalEnvelope.validID(handle) else { throw RemoteError.invalidMessage }
        default:
            guard revision == nil, handle == nil else { throw RemoteError.invalidMessage }
        }
    }
}
struct WindowWorkspaceEntry: Codable, Equatable, Identifiable {
    let id: String
    let app: String
    let title: String?
    let exactWindow: Bool
}
struct WindowWorkspaceReply: Codable, Equatable {
    enum Outcome: String, Codable { case confirmed, requested, stale, unsupported, notAllowed, timedOut }
    let operation: WindowWorkspaceRequest.Operation
    let outcome: Outcome
    var revision: String? = nil
    var entries: [WindowWorkspaceEntry] = []
    var geometry: FocusGeometry? = nil
    var display: UInt32? = nil
    func validate() throws {
        guard entries.count <= 24, revision.map(InputCausalEnvelope.validID) ?? true,
              operation != .list || outcome != .confirmed || revision != nil,
              operation != .focusCurrent || outcome != .confirmed || geometry != nil,
              entries.allSatisfy({ InputCausalEnvelope.validID($0.id) && !$0.app.isEmpty && $0.app.utf8.count <= 128 && ($0.title?.utf8.count ?? 0) <= 128 }),
              Set(entries.map(\.id)).count == entries.count else { throw RemoteError.invalidMessage }
        if let geometry { try geometry.validate() }
        guard geometry == nil || (operation == .focusCurrent && outcome == .confirmed && display != nil),
              entries.isEmpty || (operation == .list && outcome == .confirmed && revision != nil) else { throw RemoteError.invalidMessage }
    }
    static func boundedCatalog(revision: String, entries: [WindowWorkspaceEntry], maximumBytes: Int = min(8192, WorkspaceUtilities.maximumPayloadBytes)) -> WindowWorkspaceReply? {
        var reply = WindowWorkspaceReply(operation: .list, outcome: .confirmed, revision: revision, entries: Array(entries.prefix(24)))
        while let data = try? JSONEncoder().encode(reply), data.count > maximumBytes, !reply.entries.isEmpty {
            reply.entries.removeLast()
        }
        guard let data = try? JSONEncoder().encode(reply), data.count <= maximumBytes, (try? reply.validate()) != nil else { return nil }
        return reply
    }
    static func label(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let next = String(scalar)
            if result.utf8.count + next.utf8.count > 128 { break }
            result += next
        }
        return result
    }
}

/// Shared policy for retained targets, independently testable without Accessibility grants.
struct WindowWorkspaceLifetime: Equatable {
    let session: UUID
    let epoch: UInt64
    let display: UInt32
    let generation: UInt64
    let issuedAt: TimeInterval
    func permits(session: UUID, epoch: UInt64, display: UInt32, generation: UInt64, now: TimeInterval, allowed: Bool) -> Bool {
        allowed && self.session == session && self.epoch == epoch && self.display == display && self.generation == generation &&
        now >= issuedAt && now - issuedAt <= 30
    }
    static func currentWindow(retainedMember: Bool, minimized: Bool, frame: CGRect?, displayFrame: CGRect) -> Bool {
        guard retainedMember, !minimized, let frame, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return false }
        let visible = frame.intersection(displayFrame)
        return !visible.isNull && visible.width >= 1 && visible.height >= 1
    }
    static func sameProcess(pid: Int32, launch: Date?, currentPID: Int32, currentLaunch: Date?, terminated: Bool) -> Bool {
        !terminated && launch != nil && launch == currentLaunch && pid == currentPID
    }
}

enum WindowWorkspaceViewport {
    static func fit(_ geometry: FocusGeometry, viewport: ViewportTransform) -> ViewportTransform? {
        guard let target = FocusTarget(geometry, sourceSize: viewport.sourceSize, epoch: 1, refresh: false, revision: 1),
              viewport.canvasSize.width > 1, viewport.canvasSize.height > 1 else { return nil }
        var fitted = viewport
        fitted.setMode(.fit)
        let usable = fitted.safeRect.insetBy(dx: 12, dy: 12)
        guard usable.width > 1, usable.height > 1, fitted.fitScale > 0 else { return nil }
        let scale = min(usable.width / target.rect.width, usable.height / target.rect.height)
        fitted.setZoom(scale / fitted.fitScale, anchoredAt: CGPoint(x: fitted.safeRect.midX, y: fitted.safeRect.midY))
        fitted.center(onSourcePoint: CGPoint(x: target.rect.midX, y: target.rect.midY))
        return fitted
    }
}
