import AppKit
import CoreGraphics
import Darwin
import ObjectiveC
import ScreenCaptureKit

enum SessionVirtualDisplayFailure: Error, CustomStringConvertible {
    case rejected(String)
    var description: String { switch self { case .rejected(let reason): reason } }
}

/// One session's extended display. The caller must retire capture before prepare/stop; this
/// owner never captures, mirrors, changes the main screen, or moves another display's mode.
@MainActor
final class SessionVirtualDisplay {
    private(set) var displayID: CGDirectDisplayID?
    private(set) var specification: VirtualDisplaySpecification?
    private var display: NSObject?
    private var lease: SessionDisplayRuntimeLease?
    // Deliberate hold while cleanup is unresolved. A caller dropping the owner after a timeout
    // must not release an unknown display or let a second runtime acquire its lease.
    private var cleanupHold: SessionVirtualDisplay?
    private var generation: UInt64 = 0
    private var preparing = false
    private var stopping = false
    private var serial: UInt32 = 0
    private struct OwnedIdentity: Equatable { let id: CGDirectDisplayID; let serial: UInt32 }
    // Survives verified stop's public-ID clearing; never reconstructed from a foreign inventory.
    private var ownedIdentity: OwnedIdentity?
    private var constructedInCycle = false
    private var physicalSnapshot: [CGDirectDisplayID: PhysicalMode]?
    private var retiredPhysicalSnapshot: [CGDirectDisplayID: PhysicalMode]?

    var ownsScreenChanges: Bool { lease != nil || cleanupHold != nil }
    var isActive: Bool { display != nil && specification != nil && !stopping }
    var ownedDisplayPresent: Bool {
        guard let id = displayID, let ids = try? Self.onlineIDs() else { return false }
        return ids.contains(id) && matchesIdentity(id)
    }
    /// Restoration evidence is separate from readiness. Absence requires all three inventories,
    /// a second CG/NSScreen check, and the same operation/owned identity across the SCK suspension.
    func retirementPresence() async -> SessionVirtualDisplayPresence {
        guard !preparing, !stopping, !Task.isCancelled else { return .unknown }
        let token = generation
        guard constructedInCycle else { return .neverCreated }
        guard let proof = ownedIdentity, proof.id != 0, proof.serial != 0,
              retainedIdentityConsistent(proof) else { return .unknown }
        guard let ids = try? Self.onlineIDs() else { return .unknown }
        if ids.contains(proof.id) {
            return SessionVirtualDisplayPresencePolicy.classify(constructed: true, knownIdentity: true,
                online: true, identityMatches: ownsScreenChanges && matchesIdentity(proof.id, serial: proof.serial),
                isMain: CGDisplayIsMain(proof.id) != 0, isMirrored: CGDisplayIsInMirrorSet(proof.id) != 0,
                absenceConfirmed: false, operationCurrent: generation == token && ownedIdentity == proof)
        }
        guard Self.screen(proof.id) == nil else { return .unknown }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let content = try? await discover(until: deadline),
              generation == token, !preparing, !stopping, !Task.isCancelled, ownedIdentity == proof,
              let second = try? Self.onlineIDs(), !second.contains(proof.id), Self.screen(proof.id) == nil,
              !content.displays.contains(where: { $0.displayID == proof.id }),
              ProcessInfo.processInfo.systemUptime < deadline else { return .unknown }
        return SessionVirtualDisplayPresencePolicy.classify(constructed: true, knownIdentity: true,
            online: false, identityMatches: false, isMain: false, isMirrored: false,
            absenceConfirmed: true, operationCurrent: generation == token && ownedIdentity == proof)
    }
    /// Parent combines this with ownsScreenChanges when suppressing NSApp screen notifications.
    /// Physical hot-plug, mirroring, main-display and mode changes are never masked by our lease.
    var physicalTopologyUnchanged: Bool {
        guard let physicalSnapshot = physicalSnapshot ?? retiredPhysicalSnapshot,
              let current = try? snapshotPhysicalModes() else { return false }
        return physicalSnapshot == current
    }
    func isOwnedDisplay(_ id: CGDirectDisplayID) -> Bool {
        displayID == id && id != 0 && display != nil && matchesIdentity(id)
    }
    func isReady(for source: SCDisplay) -> Bool {
        guard isActive, ownedDisplayPresent, physicalTopologyUnchanged,
              let id = displayID, source.displayID == id, let spec = specification,
              let mode = CGDisplayCopyDisplayMode(id), matches(mode, spec) else { return false }
        return source.width == spec.logicalWidth && source.height == spec.logicalHeight
            && source.frame == CGDisplayBounds(id)
    }

    func prepare(_ spec: VirtualDisplaySpecification, whileCurrent: @escaping () -> Bool) async throws -> SCDisplay {
        guard !preparing, !stopping else { throw failure("virtual display operation already pending") }
        guard whileCurrent(), !Task.isCancelled else { throw failure("session changed before virtual display preparation") }
        guard !ownsScreenChanges || display != nil else { throw failure("previous cleanup is unresolved") }
        preparing = true
        generation &+= 1
        let token = generation
        defer { preparing = false }
        if lease == nil {
            ownedIdentity = nil; constructedInCycle = false
            retiredPhysicalSnapshot = nil
            guard CGPreflightScreenCaptureAccess() else { throw failure("screen recording permission unavailable") }
            try SessionPrivateDisplay.audit()
            lease = try SessionDisplayRuntimeLease.acquire()
            cleanupHold = self
            guard !(try Self.onlineIDs()).contains(where: SessionPrivateDisplay.isSessionDisplay) else {
                // Existing same-family displays are foreign; never adopt or remove them.
                lease = nil; cleanupHold = nil
                throw failure("another session virtual display is online")
            }
            physicalSnapshot = try snapshotPhysicalModes()
            retiredPhysicalSnapshot = nil
            serial = UInt32.random(in: 1...UInt32.max)
            // Ownership precedes identify/configure. Any later error leaves these resources held.
            display = try SessionPrivateDisplay.construct(spec, serial: serial)
            constructedInCycle = true
            if let display { displayID = try SessionPrivateDisplay.displayID(display) }
            guard let id = displayID, id != 0 else { throw failure("constructed display has unknown identity") }
            ownedIdentity = OwnedIdentity(id: id, serial: serial)
        }
        try requireCurrent(token, whileCurrent)
        // No display local is held across suspension: a concurrent stop can release the object.
        try configureOwned(spec)
        specification = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireCurrent(token, whileCurrent)
            guard physicalTopologyUnchanged else { throw failure("physical display topology changed") }
            if let id = displayID, try Self.onlineIDs().contains(id), matchesIdentity(id) {
                try selectExactOwnedMode(spec, deadline: deadline, token: token, whileCurrent: whileCurrent)
                if let screen = Self.screen(id), let mode = CGDisplayCopyDisplayMode(id), matches(mode, spec),
                   screen.frame.width == Double(spec.logicalWidth), screen.frame.height == Double(spec.logicalHeight),
                   abs(screen.backingScaleFactor - 2) < 0.01 {
                    let content = try await discover(until: deadline)
                    try requireCurrent(token, whileCurrent)
                    if let candidate = content.displays.first(where: { $0.displayID == id }) {
                        let filter = SCContentFilter(display: candidate, excludingWindows: [])
                        let rect = filter.contentRect
                        guard candidate.width == spec.logicalWidth, candidate.height == spec.logicalHeight,
                              rect.width == Double(spec.logicalWidth), rect.height == Double(spec.logicalHeight),
                              abs(Double(filter.pointPixelScale) - 2) < 0.01,
                              ProcessInfo.processInfo.systemUptime < deadline,
                              physicalTopologyUnchanged, try ownedModeTarget(id) else {
                            throw failure("capture filter or owned display geometry differs from exact requested mode")
                        }
                        specification = spec
                        return candidate
                    }
                }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw failure("virtual display mode/discovery deadline")
    }

    /// May be retried after a timeout. The lease and identity stay held until absence is proven.
    func stop() async throws {
        guard !stopping else { throw failure("virtual display cleanup already pending") }
        guard ownsScreenChanges else { return }
        generation &+= 1
        stopping = true
        specification = nil
        defer { stopping = false }
        try releaseOwnedDisplay()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let id = displayID, !(try Self.onlineIDs()).contains(id), Self.screen(id) == nil {
                let content = try await discover(until: deadline)
                if !content.displays.contains(where: { $0.displayID == id }),
                   !(try Self.onlineIDs()).contains(id), Self.screen(id) == nil,
                   ProcessInfo.processInfo.systemUptime < deadline {
                    retiredPhysicalSnapshot = physicalSnapshot
                    // Keep ownedIdentity/constructedInCycle for later restoration evidence.
                    displayID = nil; physicalSnapshot = nil; serial = 0
                    lease = nil; cleanupHold = nil
                    return
                }
            } else if displayID == nil && display == nil && !constructedInCycle {
                // Construction threw before returning any retained display.
                lease = nil; cleanupHold = nil; physicalSnapshot = nil
                return
            }
            // Caller cancellation cannot cause unsafe cleanup release.
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        throw failure("owned display removal unverified; lease retained")
    }

    // Keep the temporary strong reference in a synchronous stack frame that has returned before
    // cleanup discovery begins. A local in stop's async frame could itself delay object release.
    private func releaseOwnedDisplay() throws {
        guard let display else { return }
        guard let id = displayID, id != 0, try SessionPrivateDisplay.displayID(display) == id else {
            throw failure("unknown owned display identity; retaining resources")
        }
        if try Self.onlineIDs().contains(id) {
            guard matchesIdentity(id), CGDisplayIsMain(id) == 0, CGDisplayIsInMirrorSet(id) == 0 else {
                throw failure("owned display identity/main/mirror changed; retaining resources")
            }
        }
        self.display = nil
    }

    // Keep NSObject temporaries in a synchronous frame, not across removal discovery suspension.
    private func retainedIdentityConsistent(_ proof: OwnedIdentity) -> Bool {
        guard displayID == nil || displayID == proof.id,
              serial == 0 || serial == proof.serial else { return false }
        guard let display else { return true }
        return (try? SessionPrivateDisplay.displayID(display)) == proof.id
    }
    private func configureOwned(_ spec: VirtualDisplaySpecification) throws {
        guard let display, let id = displayID, id != 0, try SessionPrivateDisplay.displayID(display) == id else {
            throw failure("cannot configure unknown or replaced owned display")
        }
        let ids = try Self.onlineIDs()
        // A newly constructed display may not yet be online. Existing online identity is exact.
        if ids.contains(id), !matchesIdentity(id) || CGDisplayIsMain(id) != 0 || CGDisplayIsInMirrorSet(id) != 0 {
            throw failure("cannot configure foreign/main/mirrored display")
        }
        try SessionPrivateDisplay.configure(display, spec)
    }
    private func requireCurrent(_ token: UInt64, _ current: () -> Bool) throws {
        guard generation == token, !stopping, current(), !Task.isCancelled else { throw failure("virtual display preparation superseded") }
    }
    private func matchesIdentity(_ id: CGDirectDisplayID) -> Bool { matchesIdentity(id, serial: serial) }
    private func matchesIdentity(_ id: CGDirectDisplayID, serial expectedSerial: UInt32) -> Bool {
        SessionPrivateDisplay.isSessionDisplay(id) && expectedSerial != 0 && CGDisplaySerialNumber(id) == expectedSerial
    }
    private func ownedModeTarget(_ id: CGDirectDisplayID) throws -> Bool {
        guard let display else { return false }
        return SessionVirtualDisplayOwnership.permitsModeChange(requestedID: id,
            retainedID: try SessionPrivateDisplay.displayID(display), online: try Self.onlineIDs().contains(id),
            identityMatches: matchesIdentity(id), isMain: CGDisplayIsMain(id) != 0, isMirrored: CGDisplayIsInMirrorSet(id) != 0)
    }
    private func selectExactOwnedMode(_ spec: VirtualDisplaySpecification, deadline: Double,
                                      token: UInt64, whileCurrent: () -> Bool) throws {
        guard let id = displayID, try ownedModeTarget(id) else { throw failure("mode target is not our non-main/non-mirrored display") }
        if let mode = CGDisplayCopyDisplayMode(id), matches(mode, spec) { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let offered = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        guard let mode = offered.first(where: { matches($0, spec) }) else { return } // enumeration may still be settling
        try requireCurrent(token, whileCurrent)
        guard ProcessInfo.processInfo.systemUptime < deadline, try ownedModeTarget(id), physicalTopologyUnchanged else {
            throw failure("owned mode selection changed or expired")
        }
        let result = CGDisplaySetDisplayMode(id, mode, nil)
        guard result == .success else { throw failure("owned CGDisplaySetDisplayMode failed (\(result.rawValue))") }
    }
    private func matches(_ mode: CGDisplayMode, _ spec: VirtualDisplaySpecification) -> Bool {
        spec.matches(logicalWidth: mode.width, logicalHeight: mode.height, pixelWidth: mode.pixelWidth,
                     pixelHeight: mode.pixelHeight, refreshHz: mode.refreshRate)
    }
    private func failure(_ text: String) -> SessionVirtualDisplayFailure { .rejected(text) }
    private static func onlineIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw SessionVirtualDisplayFailure.rejected("display inventory unavailable") }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success, Int(count) <= ids.count else {
            throw SessionVirtualDisplayFailure.rejected("display inventory changed or failed")
        }
        return Array(ids.prefix(Int(count)))
    }
    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    private struct PhysicalMode: Equatable {
        let vendor: UInt32, product: UInt32, serial: UInt32
        let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
        let modeID: UInt32, modeFlags: UInt32, mirrorTarget: UInt32
        let refresh: Double
        let main: Bool, mirrored: Bool
        let bounds: CGRect
    }
    private func snapshotPhysicalModes() throws -> [CGDirectDisplayID: PhysicalMode] {
        var result: [CGDirectDisplayID: PhysicalMode] = [:]
        for id in try Self.onlineIDs() where id != displayID {
            guard let mode = CGDisplayCopyDisplayMode(id) else { throw failure("physical display mode unavailable") }
            result[id] = PhysicalMode(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                modeID: UInt32(bitPattern: mode.ioDisplayModeID), modeFlags: mode.ioFlags,
                mirrorTarget: CGDisplayMirrorsDisplay(id),
                refresh: mode.refreshRate, main: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0,
                bounds: CGDisplayBounds(id))
        }
        return result
    }
    private func discover(until deadline: Double) async throws -> SCShareableContent {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw failure("shareable-content deadline") }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = SessionDisplayDiscoveryGate(continuation)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                Task { @MainActor in
                    if let content { gate.resolve(.success(content)) }
                    else { gate.resolve(.failure(SessionVirtualDisplayFailure.rejected("shareable-content failed (\((error as NSError?)?.code ?? -1))"))) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(min(3, remaining) * 1_000_000_000))
                gate.resolve(.failure(SessionVirtualDisplayFailure.rejected("shareable-content deadline")))
            }
        }
    }
}

@MainActor
private final class SessionDisplayDiscoveryGate {
    private var continuation: CheckedContinuation<SCShareableContent, Error>?
    init(_ continuation: CheckedContinuation<SCShareableContent, Error>) { self.continuation = continuation }
    func resolve(_ result: Result<SCShareableContent, Error>) {
        guard let continuation else { return }; self.continuation = nil; continuation.resume(with: result)
    }
}

/// Never remove this inode, including on success: concurrent processes must flock the same file.
private final class SessionDisplayRuntimeLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire() throws -> SessionDisplayRuntimeLease {
        let fd = Darwin.open("/private/tmp/farside-session-display-\(getuid()).lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SessionVirtualDisplayFailure.rejected("cannot open runtime lease") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw SessionVirtualDisplayFailure.rejected("runtime lease is unsafe or held by another process")
        }
        return SessionDisplayRuntimeLease(fd)
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

private enum SessionPrivateDisplay {
    private typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector) -> Unmanaged<AnyObject>?
    private typealias ObjectInit = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias ModeInit = @convention(c) (Unmanaged<AnyObject>, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
    private typealias ObjectSetter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias UIntSetter = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias SizeSetter = @convention(c) (AnyObject, Selector, CGSize) -> Void
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private typealias IDGetter = @convention(c) (AnyObject, Selector) -> UInt32
    private static let classes = ["CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode", "CGVirtualDisplay"]
    private static let descriptorSetters = ["setQueue:", "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:", "setVendorID:", "setProductID:", "setSerialNum:"]
    static let vendor: UInt32 = 0xFA51
    static let product: UInt32 = 0xB801
    static func isSessionDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == product
    }
    static func audit() throws {
        #if !arch(arm64)
        throw SessionVirtualDisplayFailure.rejected("private ABI allowlist supports arm64 only")
        #else
        for name in classes {
            guard NSClassFromString(name) is NSObject.Type else { throw SessionVirtualDisplayFailure.rejected("private class is not an NSObject") }
            _ = try checked(name, "alloc", returns: "@", args: ["@", ":"], isClass: true)
        }
        for name in classes.prefix(2) { _ = try checked(name, "init", returns: "@", args: ["@", ":"]) }
        _ = try checked(classes[2], "initWithWidth:height:refreshRate:", returns: "@", args: ["@", ":", "I", "I", "d"])
        _ = try checked(classes[3], "initWithDescriptor:", returns: "@", args: ["@", ":", "@"])
        _ = try checked(classes[3], "applySettings:", returns: "B", args: ["@", ":", "@"])
        _ = try checked(classes[3], "displayID", returns: "I", args: ["@", ":"])
        for setter in descriptorSetters {
            let value = ["setQueue:", "setName:"].contains(setter) ? "@" : setter == "setSizeInMillimeters:" ? "{CGSize=dd}" : "I"
            _ = try checked(classes[0], setter, returns: "v", args: ["@", ":", value])
        }
        _ = try checked(classes[1], "setHiDPI:", returns: "v", args: ["@", ":", "I"])
        _ = try checked(classes[1], "setModes:", returns: "v", args: ["@", ":", "@"])
        #endif
    }
    private static func checked(_ className: String, _ name: String, returns: String, args: [String], isClass: Bool = false) throws -> (Method, Selector) {
        guard let cls = NSClassFromString(className) else { throw SessionVirtualDisplayFailure.rejected("missing private class \(className)") }
        let selector = NSSelectorFromString(name)
        guard let method = isClass ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == args.count else { throw SessionVirtualDisplayFailure.rejected("missing private method/arity \(className).\(name)") }
        func type(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
            guard let pointer else { return "missing" }; defer { free(pointer) }
            let raw = String(cString: pointer)
            return raw.hasPrefix("@\"") ? "@" : raw
        }
        guard type(method_copyReturnType(method)) == returns,
              args.indices.map({ type(method_copyArgumentType(method, UInt32($0))) }) == args else {
            throw SessionVirtualDisplayFailure.rejected("unsupported private ABI \(className).\(name)")
        }
        return (method, selector)
    }
    private static func function<T>(_ cls: String, _ name: String, returns: String, args: [String], as: T.Type) throws -> (T, Selector) {
        let (method, selector) = try checked(cls, name, returns: returns, args: args)
        return (unsafeBitCast(method_getImplementation(method), to: T.self), selector)
    }
    private static func allocated(_ name: String) throws -> Unmanaged<AnyObject> {
        let (method, selector) = try checked(name, "alloc", returns: "@", args: ["@", ":"], isClass: true)
        let call = unsafeBitCast(method_getImplementation(method), to: Alloc.self)
        guard let cls = NSClassFromString(name), let allocated = call(cls, selector) else { throw SessionVirtualDisplayFailure.rejected("private allocation failed") }
        return allocated
    }
    private static func initialized(_ name: String) throws -> NSObject {
        let (call, selector) = try function(name, "init", returns: "@", args: ["@", ":"], as: Init.self)
        return try retained(call(try allocated(name), selector))
    }
    private static func retained(_ value: Unmanaged<AnyObject>?) throws -> NSObject {
        guard let object = value?.takeRetainedValue() as? NSObject else { throw SessionVirtualDisplayFailure.rejected("private initializer returned nil/non-NSObject") }
        return object
    }
    static func construct(_ specification: VirtualDisplaySpecification, serial: UInt32) throws -> NSObject {
        try audit()
        let descriptor = try initialized(classes[0])
        func object(_ key: String, _ value: AnyObject) throws {
            let (call, selector) = try function(classes[0], key, returns: "v", args: ["@", ":", "@"], as: ObjectSetter.self)
            call(descriptor, selector, value)
        }
        func uint(_ key: String, _ value: UInt32) throws {
            let (call, selector) = try function(classes[0], key, returns: "v", args: ["@", ":", "I"], as: UIntSetter.self)
            call(descriptor, selector, value)
        }
        try object("setQueue:", DispatchQueue.main as AnyObject)
        try object("setName:", "Farside Session" as NSString)
        // The descriptor is immutable. Reserve both rotations and raster-anchor HiDPI modes.
        try uint("setMaxPixelsWide:", UInt32(VirtualDisplaySpecification.maximumAxisPixels))
        try uint("setMaxPixelsHigh:", UInt32(VirtualDisplaySpecification.maximumAxisPixels))
        try uint("setVendorID:", vendor); try uint("setProductID:", product); try uint("setSerialNum:", serial)
        let (size, selector) = try function(classes[0], "setSizeInMillimeters:", returns: "v",
            args: ["@", ":", "{CGSize=dd}"], as: SizeSetter.self)
        size(descriptor, selector, CGSize(width: Double(specification.width) * 25.4 / 220,
                                         height: Double(specification.height) * 25.4 / 220))
        let (initialize, initializeSelector) = try function(classes[3], "initWithDescriptor:", returns: "@",
            args: ["@", ":", "@"], as: ObjectInit.self)
        return try retained(initialize(try allocated(classes[3]), initializeSelector, descriptor))
    }
    static func configure(_ display: NSObject, _ specification: VirtualDisplaySpecification) throws {
        let (initialize, initializeSelector) = try function(classes[2], "initWithWidth:height:refreshRate:", returns: "@",
            args: ["@", ":", "I", "I", "d"], as: ModeInit.self)
        let modes = try specification.advertisedModes.map { mode in
            try retained(initialize(try allocated(classes[2]), initializeSelector, UInt32(mode.width), UInt32(mode.height), Double(mode.refreshHz)))
        }
        let settings = try initialized(classes[1])
        let (hidpi, hidpiSelector) = try function(classes[1], "setHiDPI:", returns: "v", args: ["@", ":", "I"], as: UIntSetter.self)
        hidpi(settings, hidpiSelector, 1)
        let (setModes, modesSelector) = try function(classes[1], "setModes:", returns: "v", args: ["@", ":", "@"], as: ObjectSetter.self)
        setModes(settings, modesSelector, modes as NSArray)
        let (apply, applySelector) = try function(classes[3], "applySettings:", returns: "B", args: ["@", ":", "@"], as: Apply.self)
        guard apply(display, applySelector, settings) else {
            throw SessionVirtualDisplayFailure.rejected("private applySettings rejected requested mode")
        }
    }
    static func displayID(_ object: NSObject) throws -> CGDirectDisplayID {
        let (call, selector) = try function(classes[3], "displayID", returns: "I", args: ["@", ":"], as: IDGetter.self); return call(object, selector)
    }
}
