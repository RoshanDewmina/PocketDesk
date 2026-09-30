import Foundation

struct MacVitalsPresentation: Equatable {
    struct Row: Equatable {
        var title: String
        var value: String
    }

    static let tooOld = "Your Mac’s Farside is too old to report battery and load. Update it on your Mac."
    static let waiting = "Waiting for your Mac to report."

    let caption: String
    let spoken: String
    let isWarning: Bool
    let rows: [Row]

    init(_ vitals: MacVitals) {
        caption = ""
        spoken = ""
        isWarning = false
        rows = []
    }

    #if DEBUG
    static func preview(_ name: String) -> MacVitals? { nil }
    #endif
}
