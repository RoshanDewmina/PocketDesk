import Foundation

/// A mouse's side buttons, sent as the `key` of an `auxClick` action to a Mac that advertises
/// `SessionFeature.auxiliaryButtons`. GameController lists them in HID order: the first auxiliary
/// button is button 4 (Back), the second is button 5 (Forward).
enum AuxiliaryMouseButton: String, CaseIterable {
    case back, forward

    init?(auxiliaryIndex: Int) {
        switch auxiliaryIndex {
        case 0: self = .back
        case 1: self = .forward
        default: return nil
        }
    }
}
