import Foundation

struct WakeHardwareAddress: Codable, Equatable {
    let bytes: [UInt8]
    init(_ text: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }),
              parts.allSatisfy({ UInt8($0, radix: 16) != nil }) else { throw WakeConfigurationError.invalid }
        bytes = parts.map { UInt8($0, radix: 16)! }
        try validate()
    }
    func validate() throws {
        guard bytes.count == 6, bytes[0] & 1 == 0, bytes.contains(where: { $0 != 0 }) else { throw WakeConfigurationError.invalid }
    }
    var magicPacket: Data { Data(Array(repeating: 255, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 }) }
}

enum WakeIdentity {
    static func valid(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

enum WakeConfigurationError: Error { case invalid, storageUnavailable }

/// Saved locally by the person at this powered helper. IDs never derive from MAC/name/Bonjour.
struct HostWakeTarget: Codable, Equatable, Identifiable {
    let id: UUID
    let targetHostID: String
    let helperHostID: String
    let ownerPairID: String
    let hardwareAddress: WakeHardwareAddress
    let interfaceName: String
    func validate() throws {
        try hardwareAddress.validate()
        guard WakeIdentity.valid(targetHostID), WakeIdentity.valid(helperHostID), WakeIdentity.valid(ownerPairID), targetHostID != helperHostID, !interfaceName.isEmpty, interfaceName.utf8.count <= 32,
              interfaceName.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw WakeConfigurationError.invalid }
    }
}

/// Caller derives these facts from the authenticated current peer, never decoded request fields.
struct HostWakeAuthority: Equatable {
    let helperHostID: String
    let ownerPairID: String
    let sessionID: String
    let epoch: UInt64
    let validUntil: TimeInterval
    func valid(at now: TimeInterval) -> Bool {
        WakeIdentity.valid(helperHostID) && WakeIdentity.valid(ownerPairID) && now.isFinite && validUntil.isFinite && now < validUntil && epoch > 0 && !sessionID.isEmpty
    }
}

final class HostWakeTargetStore {
    private struct Envelope: Codable { let version: Int; let targets: [HostWakeTarget] }
    private let defaults: UserDefaults
    private let key = "ownerRegisteredWakeTargetsV1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func read() throws -> [HostWakeTarget] {
        guard let data = defaults.data(forKey: key) else {
            guard defaults.object(forKey: key) == nil else { throw WakeConfigurationError.storageUnavailable }
            return []
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.targets.count <= 16, Set(envelope.targets.map(\.id)).count == envelope.targets.count else { throw WakeConfigurationError.storageUnavailable }
        try envelope.targets.forEach { try $0.validate() }
        return envelope.targets
    }
    /// Explicit local owner registration. A unreadable existing envelope is never replaced.
    func register(_ target: HostWakeTarget, helperHostID: String, ownerPairID: String) throws {
        try target.validate()
        guard target.helperHostID == helperHostID, target.ownerPairID == ownerPairID else { throw WakeConfigurationError.invalid }
        var targets = try read()
        guard !targets.contains(where: { $0.id == target.id }), targets.count < 16 else { throw WakeConfigurationError.invalid }
        targets.append(target)
        defaults.set(try JSONEncoder().encode(Envelope(version: 1, targets: targets)), forKey: key)
    }
    func remove(_ id: UUID) throws {
        let targets = try read().filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(Envelope(version: 1, targets: targets)), forKey: key)
    }
}

/// Serialized, bounded request admission. Parent's sendUnderAuthority must recheck the exact
/// current peer/owner/epoch/route and execute the operation under its revocation serialization.
final class HostLANWakeService {
    typealias Status = WakeReply.Status
    private let lock = NSLock()
    private let resolve: (UUID) -> HostWakeTarget?
    private let send: (HostWakeTarget) -> Status
    private let clock: () -> TimeInterval
    private var seen: Set<String> = []
    private var replayContext: HostWakeAuthority?
    private var lastSent: [UUID: TimeInterval] = [:]
    init(resolve: @escaping (UUID) -> HostWakeTarget?, send: @escaping (HostWakeTarget) -> Status,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.resolve = resolve; self.send = send; self.clock = clock
    }
    func request(_ request: WakeRequest, receivedAt: TimeInterval, authority: HostWakeAuthority,
                 sendUnderAuthority: (HostWakeAuthority, () -> Status) -> Status) -> WakeReply {
        func reply(_ status: Status) -> WakeReply { WakeReply(targetID: request.targetID, requestID: request.requestID, status: status) }
        let status = sendUnderAuthority(authority) { [self] in
            // Authority lock precedes this leaf lock; never enter parent authority while held.
            lock.lock(); defer { lock.unlock() }
            let now = clock()
            guard (try? request.validate()) != nil, authority.valid(at: now), receivedAt.isFinite,
                  receivedAt <= now, now - receivedAt <= 30 else { return .denied }
            if replayContext?.sessionID != authority.sessionID || replayContext?.epoch != authority.epoch ||
                replayContext?.ownerPairID != authority.ownerPairID || replayContext?.helperHostID != authority.helperHostID {
                seen.removeAll(); replayContext = authority
            }
            guard !seen.contains(request.requestID), seen.count < 128 else { return .denied }
            seen.insert(request.requestID)
            guard let target = resolve(request.targetID), target.id == request.targetID, (try? target.validate()) != nil,
                  target.helperHostID == authority.helperHostID, target.ownerPairID == authority.ownerPairID else { return .denied }
            lastSent = lastSent.filter { now - $0.value < 60 }
            guard lastSent[target.id] == nil, lastSent.count < 16 else { return .denied }
            lastSent[target.id] = now
            let finalNow = clock()
            guard authority.valid(at: finalNow), finalNow >= receivedAt, finalNow - receivedAt <= 30,
                  resolve(target.id) == target else { return .denied }
            return send(target)
        }
        return reply(status)
    }
}
