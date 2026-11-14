// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OhmaiCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OhmaiCore", targets: ["OhmaiCore"]),
        .library(name: "OhmaiPower", targets: ["OhmaiPower"]),
        .library(name: "OhmaiLidXPC", targets: ["OhmaiLidXPC"]),
        .library(name: "OhmaiLidHelperCore", targets: ["OhmaiLidHelperCore"]),
    ],
    targets: [
        // Domain types, leases and the pure `Policy`. Foundation only: no I/O.
        .target(name: "OhmaiCore"),
        // The XPC contract shared by the app and the lid helper. Foundation only.
        .target(name: "OhmaiLidXPC"),
        // OS-facing power code: IOKit power sources, IOPMAssertion, the lid helper client.
        .target(name: "OhmaiPower", dependencies: ["OhmaiCore", "OhmaiLidXPC"]),
        // Everything the root lid helper does, minus `main`. Runs as root: keep it small.
        .target(name: "OhmaiLidHelperCore", dependencies: ["OhmaiCore", "OhmaiPower", "OhmaiLidXPC"]),
        .testTarget(name: "OhmaiCoreTests", dependencies: ["OhmaiCore"]),
        .testTarget(name: "OhmaiPowerTests", dependencies: ["OhmaiPower"]),
        .testTarget(name: "OhmaiLidHelperCoreTests", dependencies: ["OhmaiLidHelperCore"]),
    ]
)
