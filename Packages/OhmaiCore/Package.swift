// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OhmaiCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OhmaiCore", targets: ["OhmaiCore"]),
    ],
    targets: [
        // Domain types, leases and the pure `Policy`. Foundation only: no I/O.
        .target(name: "OhmaiCore"),
        .testTarget(name: "OhmaiCoreTests", dependencies: ["OhmaiCore"]),
    ]
)
