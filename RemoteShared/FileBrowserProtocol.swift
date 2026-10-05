import Foundation

/// Paths never cross this protocol. Entry IDs are short-lived host authority references.
struct FileBrowserRequest: Codable, Equatable {
    enum Operation: String, Codable { case roots, list, download, cancel }
    let operation: Operation
    var entry: String? = nil
    var offset: Int = 0
    var filter: String = ""
    var transfer: String? = nil
    static func decode(_ frame: WorkspaceFrame) throws -> FileBrowserRequest {
        try frame.validate()
        guard frame.kind == .files,
              let object = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
              Set(object.keys).isSubset(of: ["operation", "entry", "offset", "filter", "transfer"]) else { throw RemoteError.invalidMessage }
        let request = try frame.decode(Self.self); try request.validate(); return request
    }
    func validate() throws {
        guard (0...100_000).contains(offset), filter.utf8.count <= 128,
              entry.map(InputCausalEnvelope.validID) ?? true,
              transfer.map(FileTransferID.isValid) ?? true else { throw RemoteError.invalidMessage }
        switch operation {
        case .roots: guard entry == nil, transfer == nil, offset == 0, filter.isEmpty else { throw RemoteError.invalidMessage }
        case .list: guard entry != nil, transfer == nil else { throw RemoteError.invalidMessage }
        case .download: guard entry != nil, transfer != nil, offset == 0, filter.isEmpty else { throw RemoteError.invalidMessage }
        case .cancel: guard entry == nil, transfer != nil, offset == 0, filter.isEmpty else { throw RemoteError.invalidMessage }
        }
    }
}
struct FileBrowserEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case folder, file, unsupported }
    let id: String
    let name: String
    let kind: Kind
    let bytes: Int64?
    var modified: TimeInterval? = nil
}
struct FileBrowserReply: Codable, Equatable {
    enum Status: String, Codable { case ok, stale, notAllowed, unavailable, busy }
    let status: Status
    var entries: [FileBrowserEntry] = []
    var nextOffset: Int? = nil
}
