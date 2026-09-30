import Foundation
import Network

/// The parts of a network path that decide whether an open signaling socket may have lost its
/// route. Address-only republishing (some home routers re-announce IPv6 every few seconds) leaves
/// this unchanged; the keepalive still catches a socket that such churn really broke.
struct NetworkPathSignature: Equatable {
    var satisfied: Bool
    var interfaces: [String]
    var expensive: Bool
    var constrained: Bool
    var ipv4: Bool
    var ipv6: Bool

    init(satisfied: Bool, interfaces: [String], expensive: Bool = false, constrained: Bool = false,
         ipv4: Bool = true, ipv6: Bool = true) {
        self.satisfied = satisfied
        self.interfaces = interfaces
        self.expensive = expensive
        self.constrained = constrained
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    init(_ path: NWPath) {
        self.init(satisfied: path.status == .satisfied,
                  interfaces: path.availableInterfaces.map { "\($0.name):\($0.type)" },
                  expensive: path.isExpensive, constrained: path.isConstrained,
                  ipv4: path.supportsIPv4, ipv6: path.supportsIPv6)
    }
}

/// Reports meaningful path changes after the first reading, on the main actor.
@MainActor
final class NetworkPathWatcher {
    private var monitor: NWPathMonitor?
    private var last: NetworkPathSignature?
    var onChange: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkPathSignature(path)
            Task { @MainActor in self?.observe(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "com.roshan.farside.network-path"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel(); monitor = nil
        last = nil
    }

    func observe(_ signature: NetworkPathSignature) {
        defer { last = signature }
        guard let last, last != signature else { return }
        onChange?()
    }
}
