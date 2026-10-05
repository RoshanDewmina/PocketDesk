import Foundation

/// One extended capability slot for owner-only workspace utilities. Each service validates its
/// own bounded payload and current authority; this envelope never grants input or file access.
enum WorkspaceUtilities {
    static let feature = "workspace.1"
    static let disabledKey = "FarsideWorkspaceDisabled"
    // Data encodes as base64 inside RemoteAction/ControlPacket; reserve headroom below 16 KiB.
    static let maximumPayloadBytes = 8 * 1024
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledKey)
    }
    static func statusVersion(enabled: Bool, peerFeatures: Set<String>, fullDisplay: Bool) -> Int? {
        enabled && fullDisplay && peerFeatures.contains(SessionFeature.extendedFeatureList) ? 1 : nil
    }
    /// The wire feature list remains bounded; this derived local set also understands the marker.
    static func resolvedFeatures(_ wire: [String], statusVersion: Int?, current: Bool, fullDisplay: Bool) -> Set<String> {
        var result = Set(wire)
        if statusVersion == 1 && current && fullDisplay { result.insert(feature) }
        return result
    }
    static func advertised(addingTo features: [String], peerFeatures: Set<String>, enabled: Bool) -> [String] {
        guard enabled, peerFeatures.contains(SessionFeature.extendedFeatureList),
              features.count < 32, !features.contains(feature) else { return features }
        return features + [feature]
    }
}

struct WorkspaceFrame: Codable, Equatable {
    enum Kind: String, Codable { case windows, files, richClipboard, scopedChord }
    var version = 1
    let kind: Kind
    let requestID: String
    let payload: Data

    init<T: Encodable>(kind: Kind, requestID: String, value: T) throws {
        self.kind = kind; self.requestID = requestID
        payload = try JSONEncoder().encode(value)
        try validate()
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try validate()
        return try JSONDecoder().decode(type, from: payload)
    }

    func validate() throws {
        guard version == 1, InputCausalEnvelope.validID(requestID), !payload.isEmpty,
              payload.count <= WorkspaceUtilities.maximumPayloadBytes,
              (try? JSONSerialization.jsonObject(with: payload)) is [String: Any]
        else { throw RemoteError.invalidMessage }
    }
}

extension RemoteAction {
    static func workspace(_ frame: WorkspaceFrame, epoch: UInt64) -> RemoteAction {
        RemoteAction(action: "workspace", workspace: frame, epoch: epoch)
    }
    func validateWorkspace() throws -> Bool {
        guard action == "workspace" else {
            guard workspace == nil else { throw RemoteError.invalidMessage }
            return false
        }
        let allowed: Set<String> = ["action", "epoch", "x", "y", "text", "key", "modifiers", "workspace"]
        guard epoch > 0, let workspace,
              let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
              Set(encoded.keys).isSubset(of: allowed), x == 0, y == 0,
              text.isEmpty, key.isEmpty, modifiers.isEmpty else { throw RemoteError.invalidMessage }
        try workspace.validate()
        return true
    }
}
