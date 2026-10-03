import Foundation

enum HostFeatureList {
    static func features(base: [String], allowBigText: Bool, accessibility: Bool,
                         peerFeatures: Set<String>? = nil, requestedMode: SessionMode = .picture) -> [String] {
        let full = allowBigText && accessibility ? base + [SessionFeature.displayScale] : base
        var seen = Set<String>()
        let unique = full.filter { seen.insert($0).inserted }
        guard let peerFeatures else { return Array(unique.prefix(32)) }
        if peerFeatures.contains(SessionFeature.extendedFeatureList) {
            let known = SessionFeature.host + [SessionFeature.couch, SessionFeature.displayScale]
            // Preserve every existing capability before this optional media preference if all 32 slots fill.
            let prioritized = known.filter { $0 != SessionFeature.lowDataPolicy && unique.contains($0) }
                + unique.filter { $0 != SessionFeature.lowDataPolicy && !known.contains($0) }
                + unique.filter { $0 == SessionFeature.lowDataPolicy }
            return Array(prioritized.filter { $0 != SessionFeature.causalInput || peerFeatures.contains(SessionFeature.causalInput) }.prefix(32))
        }
        let legacy = SessionFeature.legacyHost.filter { unique.contains($0) }
        if requestedMode == .couch, unique.contains(SessionFeature.couch) {
            return [SessionFeature.couch] + legacy.prefix(15)
        }
        return Array(legacy.prefix(16))
    }
}
