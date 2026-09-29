import Foundation

/// Builds the display list a phone sees and decides what a phone's display request may do.
/// Pure, so the rules are tested without ScreenCaptureKit.
enum HostDisplayCatalog {
    struct Display: Equatable {
        var id: UInt32
        var name: String
        var width: Double
        var height: Double
        var pixelWidth: Int?
        var pixelHeight: Int?
        var main: Bool
    }

    /// Validated descriptors in a stable order (main display first, then by id), at most 16.
    static func descriptors(_ displays: [Display]) -> [DisplayDescriptor] {
        var seen = Set<UInt32>()
        let ordered = displays.sorted { ($0.main ? 0 : 1, $0.id) < ($1.main ? 0 : 1, $1.id) }
        var result: [DisplayDescriptor] = []
        for display in ordered where display.id != 0 && seen.insert(display.id).inserted {
            let descriptor = DisplayDescriptor(id: display.id, name: cleanName(display.name, id: display.id),
                                               width: display.width, height: display.height,
                                               pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight,
                                               main: display.main)
            guard (try? descriptor.validate()) != nil else { continue }
            result.append(descriptor)
            if result.count == 16 { break }
        }
        return result
    }

    enum Decision: Equatable {
        /// Tell the phone the list again (unknown display, already streaming it, or not allowed).
        case resendList
        /// Restart capture on this display within the session.
        case switchTo(UInt32)
    }

    /// Choosing what the Mac shares needs the same authority as controlling it: a view-only
    /// phone keeps whatever display the Mac chose.
    static func decide(requested: UInt32, available: [UInt32], streaming: UInt32?,
                       controlEffective: Bool) -> Decision {
        guard controlEffective, requested != 0, available.contains(requested), requested != streaming else {
            return .resendList
        }
        return .switchTo(requested)
    }

    static func cleanName(_ name: String, id: UInt32) -> String {
        let printable = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !printable.isEmpty else { return "Display \(id)" }
        var result = ""
        for character in printable {
            guard (result + String(character)).utf8.count <= 64 else { break }
            result.append(character)
        }
        return result
    }
}
