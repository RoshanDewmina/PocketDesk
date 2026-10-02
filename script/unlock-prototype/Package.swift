// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FarsideUnlockPrototype", platforms: [.macOS("26.0")], products: [
    .executable(name: "UnlockDaemon", targets: ["UnlockDaemon"]),
    .executable(name: "UnlockAgent", targets: ["UnlockAgent"]),
    .executable(name: "UnlockControl", targets: ["UnlockControl"])
], targets: [
    .target(name: "UnlockCore"),
    .executableTarget(name: "UnlockDaemon", dependencies: ["UnlockCore"]),
    .executableTarget(name: "UnlockAgent", dependencies: ["UnlockCore"]),
    .executableTarget(name: "UnlockControl", dependencies: ["UnlockCore"]),
    .testTarget(name: "UnlockCoreTests", dependencies: ["UnlockCore"])
], swiftLanguageModes: [.v5])
