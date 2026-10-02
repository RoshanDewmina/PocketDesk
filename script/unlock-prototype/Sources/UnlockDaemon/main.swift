import Foundation
import UnlockCore

final class Broker: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "unlock.prototype.broker")
    var agents: [UInt32: (UUID, NSXPCConnection)] = [:]
    var budget = AttemptBudget()
    var busy = false
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let config = Prototype.configuration(), config.enabled else { return false }
        let uid = connection.effectiveUserIdentifier
        guard uid == 0 || uid == config.uid else { return false }
        connection.setCodeSigningRequirement(Prototype.requirement(uid == 0 ? ["control", "agent"] : ["agent"]))
        connection.exportedInterface = NSXPCInterface(with: DaemonAPI.self)
        connection.exportedObject = Client(broker: self, uid: uid, asid: UInt32(bitPattern: connection.auditSessionIdentifier))
        connection.resume()
        return true
    }
    func selected() -> NSXPCConnection? {
        guard let config = Prototype.configuration(), config.enabled, let console = Prototype.console(),
              console.loginWindow || console.uid == config.uid else { return nil }
        return agents[console.uid]?.1
    }
}
final class Client: NSObject, DaemonAPI {
    let broker: Broker
    let uid: UInt32
    let asid: UInt32
    init(broker: Broker, uid: UInt32, asid: UInt32) { self.broker = broker; self.uid = uid; self.asid = asid }
    func registerAgent(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        broker.queue.async {
            guard let config = Prototype.configuration(), config.enabled, self.uid == 0 || self.uid == config.uid else { reply(false); return }
            // Preserve exact login-domain targets for cleanup even if an agent later crashes.
            let manifest = URL(fileURLWithPath: Prototype.root + "/sessions.plist")
            var sessions = (NSDictionary(contentsOf: manifest)?["ASIDs"] as? [UInt32]) ?? []
            if !sessions.contains(self.asid) { sessions.append(self.asid) }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: ["ASIDs": sessions], format: .xml, options: 0),
                  (try? data.write(to: manifest, options: .atomic)) != nil else { reply(false); return }
            chmod(manifest.path, 0o600)
            let channel = NSXPCConnection(listenerEndpoint: endpoint)
            channel.setCodeSigningRequirement(Prototype.requirement(["agent"]))
            channel.remoteObjectInterface = NSXPCInterface(with: AgentAPI.self)
            let id = UUID()
            channel.invalidationHandler = { [weak broker = self.broker] in
                broker?.queue.async {
                    if broker?.agents[self.uid]?.0 == id { broker?.agents.removeValue(forKey: self.uid) }
                }
            }
            self.broker.agents[self.uid]?.1.invalidate()
            self.broker.agents[self.uid] = (id, channel)
            channel.resume(); reply(true)
        }
    }
    func capture(reply: @escaping (Data?, String) -> Void) {
        guard uid == 0 else { reply(nil, "DENIED"); return }
        broker.queue.async {
            guard !self.broker.busy, let channel = self.broker.selected() else { reply(nil, "NO_AGENT_OR_DISABLED"); return }
            self.broker.busy = true
            var completed = false // Accessed only on broker.queue.
            let finish: (Data?, String) -> Void = { data, status in
                self.broker.queue.async {
                    guard !completed else { return }; completed = true
                    self.broker.busy = false; reply(data, status)
                }
            }
            self.broker.queue.asyncAfter(deadline: .now() + 18) {
                guard !completed else { return }
                completed = true; self.broker.busy = false; channel.invalidate()
                reply(nil, "TIMEOUT_AGENT_DISABLED_UNINSTALL")
            }
            let agent = channel.remoteObjectProxyWithErrorHandler { _ in finish(nil, "XPC_FAILED") } as! AgentAPI
            agent.capture(Date().timeIntervalSince1970 + 15, reply: finish)
        }
    }
    func typePassword(_ bytes: Data, reply: @escaping (String) -> Void) {
        guard uid == 0 else { reply("DENIED"); return }
        broker.queue.async {
            guard Policy.validPassword(bytes), !self.broker.busy, let channel = self.broker.selected(),
                  Prototype.console()?.uid == Prototype.configuration()?.uid else { reply("DENIED"); return }
            guard self.broker.budget.take(now: Date().timeIntervalSince1970) else { reply("RATE_LIMITED"); return }
            self.broker.busy = true
            var completed = false
            let finish: (String) -> Void = { status in
                self.broker.queue.async {
                    guard !completed else { return }; completed = true
                    self.broker.busy = false; reply(status)
                }
            }
            self.broker.queue.asyncAfter(deadline: .now() + 12) {
                guard !completed else { return }
                completed = true; self.broker.busy = false; channel.invalidate()
                reply("TIMEOUT_RESULT_UNKNOWN_UNINSTALL")
            }
            let agent = channel.remoteObjectProxyWithErrorHandler { _ in finish("XPC_FAILED") } as! AgentAPI
            agent.typePassword(bytes, deadline: Date().timeIntervalSince1970 + 10, reply: finish)
        }
    }
}
guard geteuid() == 0, Prototype.configuration()?.enabled == true else { exit(1) }
let broker = Broker()
let listener = NSXPCListener(machServiceName: Prototype.service)
listener.delegate = broker
listener.resume()
RunLoop.current.run()
