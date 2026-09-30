import Foundation

/// One of the Mac's displays as listed to the phone (`SessionFeature.displaySelection`).
/// Sizes are logical points, the same units as `geometry`; pixels when macOS reports them.
struct DisplayDescriptor: Codable, Equatable, Identifiable {
    var id: UInt32
    var name: String
    var width: Double
    var height: Double
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var main: Bool = false
    var scaleSteps: [ScaleStep]? = nil
    var scaleBaselineWidth: Double? = nil
    var scaleCurrentWidth: Double? = nil

    func validate() throws {
        guard id != 0, !name.isEmpty, name.utf8.count <= 64,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              width.isFinite, height.isFinite, (1...20_000).contains(width), (1...20_000).contains(height),
              pixelWidth.map({ (1...40_000).contains($0) }) ?? true,
              pixelHeight.map({ (1...40_000).contains($0) }) ?? true
        else { throw RemoteError.invalidMessage }
        try validateScale()
    }

    /// "Built-in Retina Display · 1470 × 956" (points), with pixels when they differ.
    var resolution: String {
        let points = "\(Int(width.rounded())) × \(Int(height.rounded()))"
        guard let pixelWidth, let pixelHeight, pixelWidth != Int(width.rounded()) else { return points }
        return "\(points) · \(pixelWidth) × \(pixelHeight) px"
    }
}

extension RemoteAction {
    static let displayActions: Set<String> = ["displays", "display", "displayScale"]

    /// `displays`: the phone asks for the list (no fields); the host answers with `displays` and the
    /// streamed `display`. `display`: the phone asks to stream display `display`. The host also puts
    /// the streamed `display` on `capture`. Returns true when the action is a display action that is
    /// now fully validated. Hosts advertise the feature first; each side sends these only to a peer
    /// that understands them, because older peers end the session on unknown actions.
    func validateDisplaySelection() throws -> Bool {
        if let displays {
            guard action == "displays", displays.count <= 16,
                  Set(displays.map(\.id)).count == displays.count else { throw RemoteError.invalidMessage }
            try displays.forEach { try $0.validate() }
        }
        if let display {
            guard display != 0, ["displays", "display", "displayScale", "capture"].contains(action) else { throw RemoteError.invalidMessage }
        }
        guard Self.displayActions.contains(action) else { return false }
        guard interaction == nil, pointerLocatorSupported == nil, pointerProbe == nil, pointerLocation == nil,
              pointerSync == nil, streamQuality == nil, textFocusProbe == nil, textFocusEditable == nil,
              clipboard == nil, features == nil, hostState == nil, hostStream == nil, curtain == nil, hostEvent == nil,
              agentAlert == nil,
              x == 0, y == 0, text.isEmpty, key.isEmpty, modifiers.isEmpty
        else { throw RemoteError.invalidMessage }
        if action == "display" {
            guard display != nil, displays == nil else { throw RemoteError.invalidMessage }
        }
        if action == "displayScale" {
            guard let width = looksLikeWidth, display != nil, displays == nil,
                  width == 0 || (width.isFinite && BigTextLimits.widthRange.contains(width)) else { throw RemoteError.invalidMessage }
        }
        return true
    }
}

/// The display the phone last chose for each Mac, so the next connection shows it again.
/// Keyed by a hash of the pairing room, never by anything that could reach the Mac.
struct DisplayMemory {
    struct Choice: Codable, Equatable {
        var id: UInt32
        var name: String
    }

    static let defaultsKey = "displayChoiceByMac"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func macKey(room: String) -> String { String(SecureRandom.digest("farside-display|" + room).prefix(24)) }

    func choice(forRoom room: String) -> Choice? {
        load()[Self.macKey(room: room)]
    }

    func remember(_ choice: Choice, forRoom room: String) {
        var all = load()
        all[Self.macKey(room: room)] = choice
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// The remembered display in this list: the same id, or else the only one with the same name.
    static func match(_ choice: Choice?, in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        guard let choice else { return nil }
        if let exact = displays.first(where: { $0.id == choice.id }) { return exact }
        let named = displays.filter { $0.name == choice.name }
        return named.count == 1 ? named[0] : nil
    }

    private func load() -> [String: Choice] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let all = try? JSONDecoder().decode([String: Choice].self, from: data) else { return [:] }
        return all
    }
}
