import Foundation

/// Evidence of a host posting attempt, not proof an app completed a task.
struct InputAppliedReceipt: Codable, Equatable {
    static let actions: Set<String> = ["click", "right", "double", "middle", "auxClick", "dragUp", "key", "text"]
    let requestID: String
    let kind: String
    let accepted: Bool
    func validate() throws {
        guard InputCausalEnvelope.validID(requestID), Self.actions.contains(kind) else { throw RemoteError.invalidMessage }
    }
}
