// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OhmaiCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OhmaiCore", targets: ["OhmaiCore"]),
        .library(name: "OhmaiPower", targets: ["OhmaiPower"]),
    ],
    targets: [
        // Domain types, leases and the pure `Policy`. Foundation only: no I/O.
        .target(name: "OhmaiCore"),
        // OS-facing power code: IOKit power sources, IOPMAssertion.
        .target(name: "OhmaiPower", dependencies: ["OhmaiCore"]),
        .testTarget(name: "OhmaiCoreTests", dependencies: ["OhmaiCore"]),
        .testTarget(name: "OhmaiPowerTests", dependencies: ["OhmaiPower"]),
    ]
)
