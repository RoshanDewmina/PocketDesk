import CoreGraphics

enum HostPairingPreflight {
    static func isEligible(
        selectedDisplayID: CGDirectDisplayID,
        availableDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        availableDisplayIDs.contains(selectedDisplayID)
    }

    static func createInvitation<Invitation>(
        selectedDisplayID: CGDirectDisplayID,
        availableDisplayIDs: [CGDirectDisplayID],
        create: () throws -> Invitation
    ) rethrows -> Invitation? {
        guard isEligible(
            selectedDisplayID: selectedDisplayID,
            availableDisplayIDs: availableDisplayIDs
        ) else {
            return nil
        }
        return try create()
    }
}
