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
        .library(name: "OhmaiAdapterSupport", targets: ["OhmaiAdapterSupport"]),
        .library(name: "OhmaiClaudeAdapter", targets: ["OhmaiClaudeAdapter"]),
        .library(name: "OhmaiCodexAdapter", targets: ["OhmaiCodexAdapter"]),
    ],
    targets: [
        // Domain types, leases and the pure `Policy`. Foundation only: no I/O.
        .target(name: "OhmaiCore"),
        // The XPC contract shared by the app and the lid helper. Foundation only.
        .target(name: "OhmaiLidXPC"),
        // Reads the power source and thermal state. Shared by the app and the root helper.
        .target(name: "OhmaiPowerSource", dependencies: ["OhmaiCore"]),
        // OS-facing power code: IOPMAssertion, power monitoring, the lid helper client.
        .target(name: "OhmaiPower", dependencies: ["OhmaiCore", "OhmaiPowerSource", "OhmaiLidXPC"]),
        // Everything the root lid helper does, minus `main`. Runs as root: keep it small.
        .target(name: "OhmaiLidHelperCore", dependencies: ["OhmaiCore", "OhmaiPowerSource", "OhmaiLidXPC"]),
        // Shared by adapters: process liveness and start time, exit and directory watchers.
        .target(name: "OhmaiAdapterSupport", dependencies: ["OhmaiCore"]),
        // Claude Code: `~/.claude/sessions/<pid>.json` (undocumented) plus pid liveness.
        .target(name: "OhmaiClaudeAdapter", dependencies: ["OhmaiCore", "OhmaiAdapterSupport"]),
        // Codex: rollout files (undocumented); turn boundaries from line prefixes only.
        .target(name: "OhmaiCodexAdapter", dependencies: ["OhmaiCore", "OhmaiAdapterSupport"]),
        .testTarget(name: "OhmaiCoreTests", dependencies: ["OhmaiCore"]),
        .testTarget(name: "OhmaiPowerTests", dependencies: ["OhmaiPower", "OhmaiPowerSource"]),
        .testTarget(name: "OhmaiLidHelperCoreTests", dependencies: ["OhmaiLidHelperCore"]),
        .testTarget(
            name: "OhmaiClaudeAdapterTests",
            dependencies: ["OhmaiClaudeAdapter", "OhmaiAdapterSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OhmaiCodexAdapterTests",
            dependencies: ["OhmaiCodexAdapter", "OhmaiAdapterSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
