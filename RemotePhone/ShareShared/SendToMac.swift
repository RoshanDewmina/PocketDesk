import Foundation

/// Nonsecret lookup IDs. These identify a saved host record and owner grant; they confer no authority.
struct SendToMacDestination: Codable, Equatable {
    var hostRecordID: String
    var ownerPairID: String

    var isValid: Bool { Self.isHex(hostRecordID, count: 64) && Self.isHex(ownerPairID, count: 64) }
    static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// What the app tells the Send to My Mac share extension through the App Group: the paired Mac's
/// display name and whether a session is live now or was recently. Never keys, rooms, tokens or content.
struct SendToMacBeacon: Codable, Equatable {
    var macName: String
    /// A live, foreground session that can take an item right away; refreshed while connected.
    var liveUntil: Date?
    var lastConnected: Date?
    var filesSupported: Bool
    var destination: SendToMacDestination? = nil
    /// Independent handoff lifetime, never the authenticated protocol epoch or a credential.
    var liveSessionID: String? = nil

    /// Farside reconnects by itself within this window after leaving the screen.
    static let reconnectWindow: TimeInterval = 15 * 60

    func isLive(at now: Date) -> Bool {
        destination?.isValid == true && liveSessionID.map { SendToMacOutbox.isValidID($0) } == true
            && (liveUntil.map { $0 > now } ?? false)
    }

    /// Live now, or connected recently enough that opening Farside reconnects without a tap.
    func isConnectable(at now: Date) -> Bool {
        guard destination?.isValid == true else { return false }
        return isLive(at: now) || (lastConnected.map {
            let age = now.timeIntervalSince($0)
            return age >= 0 && age <= Self.reconnectWindow
        } ?? false)
    }
}

/// One item from the share sheet waiting for the app. It expires quickly and the app asks before
/// sending anything the extension could not hand over while Farside was live.
struct SendToMacItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case file, text, link }
    let id: String
    let kind: Kind
    var name: String?
    var bytes: Int64?
    var text: String?
    let created: Date
    let expires: Date
    /// Staged while the app was live, so the app sends it without asking again.
    var immediate: Bool
    // Optional solely to decode pre-binding items. A destinationless item always requires retargeting.
    var destination: SendToMacDestination? = nil
    var destinationName: String? = nil
    var liveSessionID: String? = nil

    func isBound(to selected: SendToMacDestination?) -> Bool {
        guard let destination, destination.isValid, let selected, selected.isValid else { return false }
        return destination == selected
    }

    func canAutomaticallySend(to selected: SendToMacDestination?, liveSessionID current: String?, at now: Date) -> Bool {
        let age = now.timeIntervalSince(created)
        return isBound(to: selected) && immediate && age >= 0 && age < 30 && expires > now
            && liveSessionID.map(SendToMacOutbox.isValidID) == true && liveSessionID == current
    }

    static let lifetime: TimeInterval = 10 * 60
    static let maximumTextBytes = 256 * 1024
    static let maximumFileBytes: Int64 = 1 << 30
    static let maximumLinkBytes = 2048
}

/// The app's report on an item it took, for the extension's progress view.
struct SendToMacReceipt: Codable, Equatable {
    enum State: String, Codable { case sending, sent, failed }
    let id: String
    var state: State
    var fraction: Double?
    var message: String
}

/// The app's filesystem work shares one ordered lane. Resolve the App Group container on that
/// lane too; constructing the inbox on main must not ask the filesystem for its container.
final class SendToMacFileIO {
    static let disabledKey = "sendToMacBackgroundIODisabled"
    static let queue = DispatchQueue(label: "com.roshan.PocketDesk.sendToMac.files", qos: .utility)
    private let rootProvider: () -> URL?
    private let background: Bool
    private let queue: DispatchQueue

    convenience init(root: URL? = nil, useBackgroundIO: Bool? = nil, queue: DispatchQueue = SendToMacFileIO.queue) {
        self.init(rootProvider: { root ?? SendToMacOutbox.root }, useBackgroundIO: useBackgroundIO, queue: queue)
    }

    init(rootProvider: @escaping () -> URL?, useBackgroundIO: Bool? = nil, queue: DispatchQueue = SendToMacFileIO.queue) {
        self.rootProvider = rootProvider
        background = useBackgroundIO ?? !UserDefaults.standard.bool(forKey: Self.disabledKey)
        self.queue = queue
    }

    func write(_ operation: @escaping (URL?) -> Void) {
        let work = { operation(self.rootProvider()) }
        if background { queue.async(execute: work) } else { work() }
    }

    @MainActor
    func read<Value>(_ operation: @escaping (URL?) -> Value, completion: @escaping @MainActor (Value) -> Void) {
        if background {
            queue.async {
                let value = operation(self.rootProvider())
                DispatchQueue.main.async { completion(value) }
            }
        } else {
            completion(operation(rootProvider()))
        }
    }

    /// The main actor supplies an immutable authority snapshot. FIFO writes preserve End/selection
    /// changes, and an I/O backlog can only shorten (never renew) the snapshot's live lifetime.
    func updateBeacon(_ snapshot: SendToMacBeacon?) {
        write { root in
            guard let snapshot else { SendToMacOutbox.storeBeacon(nil, root: root); return }
            let old = SendToMacOutbox.loadBeacon(root: root)
            var beacon = old.flatMap { $0.destination == snapshot.destination ? $0 : nil } ?? snapshot
            beacon.macName = snapshot.macName
            beacon.destination = snapshot.destination
            beacon.liveSessionID = snapshot.liveSessionID
            beacon.liveUntil = snapshot.liveUntil
            if let connected = snapshot.lastConnected {
                beacon.lastConnected = connected
                beacon.filesSupported = snapshot.filesSupported
            }
            SendToMacOutbox.storeBeacon(beacon, root: root)
        }
    }
}

enum SendToMacOutbox {
    static let appGroup = "group.com.roshan.PocketDesk"
    static let outboxNotification = "com.roshan.PocketDesk.sendToMac.outbox"

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("SendToMac", isDirectory: true)
    }

    // MARK: Beacon

    static func loadBeacon(root: URL? = root) -> SendToMacBeacon? {
        guard let url = root?.appendingPathComponent("beacon.json"),
              let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(SendToMacBeacon.self, from: data)
    }

    static func storeBeacon(_ beacon: SendToMacBeacon?, root: URL? = root) {
        guard let root else { return }
        let url = root.appendingPathComponent("beacon.json")
        guard let beacon else { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(beacon) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Items

    private static func folder(_ id: String, root: URL?) -> URL? {
        guard isValidID(id) else { return nil }
        return root?.appendingPathComponent("Outbox", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func makeID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Stages an item with `payload` (a file the share sheet handed over) moved beside it.
    static func stage(_ item: SendToMacItem, payload: URL? = nil, root: URL? = root) throws {
        guard let folder = folder(item.id, root: root) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let payload {
            try FileManager.default.moveItem(at: payload, to: folder.appendingPathComponent("payload", isDirectory: false))
        }
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
    }

    static func payloadURL(for item: SendToMacItem, root: URL? = root) -> URL? {
        folder(item.id, root: root)?.appendingPathComponent("payload", isDirectory: false)
    }

    /// Unexpired items, oldest first. Expired or unreadable ones are deleted on the way.
    static func pending(at now: Date = Date(), root: URL? = root) -> [SendToMacItem] {
        guard let outbox = root?.appendingPathComponent("Outbox", isDirectory: true),
              let entries = try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)
        else { return [] }
        var items: [SendToMacItem] = []
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("item.json")), data.count <= 512 * 1024,
                  let item = try? JSONDecoder().decode(SendToMacItem.self, from: data),
                  item.id == entry.lastPathComponent, item.expires > now
            else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            items.append(item)
        }
        return items.sorted { $0.created < $1.created }
    }

    static func remove(_ id: String, root: URL? = root) {
        guard let folder = folder(id, root: root) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Receipts

    private static func receiptURL(_ id: String, root: URL?) -> URL? {
        guard isValidID(id) else { return nil }
        return root?.appendingPathComponent("Receipts", isDirectory: true).appendingPathComponent(id + ".json")
    }

    static func storeReceipt(_ receipt: SendToMacReceipt, root: URL? = root) {
        guard let url = receiptURL(receipt.id, root: root), let data = try? JSONEncoder().encode(receipt) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func loadReceipt(_ id: String, root: URL? = root) -> SendToMacReceipt? {
        guard let url = receiptURL(id, root: root), let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(SendToMacReceipt.self, from: data)
    }

    static func removeReceipt(_ id: String, root: URL? = root) {
        guard let url = receiptURL(id, root: root) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Signalling

    static func postOutboxChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(outboxNotification as CFString), nil, nil, true)
    }
}
