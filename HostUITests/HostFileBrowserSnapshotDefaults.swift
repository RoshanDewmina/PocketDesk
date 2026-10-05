import Foundation

/// Dedicated snapshot-target storage. Real grants/owner behavior remain in HostFileBrowserFolders.
@MainActor
enum HostFileBrowserSnapshotDefaults {
    static let suiteName = "farside.host-ui-snapshot.shared-folders." + UUID().uuidString
    static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated shared-folder snapshot defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("[]".utf8), forKey: "FarsideSharedFolderGrants")
        return defaults
    }()

    static func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
