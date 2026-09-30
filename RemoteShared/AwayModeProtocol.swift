import Foundation

/// Away mode as the Mac reports it on `capture` status (`SessionFeature.away`). Unknown values mean off.
enum AwayModeState: String, Equatable, CaseIterable {
    case off, armed, covered
}
