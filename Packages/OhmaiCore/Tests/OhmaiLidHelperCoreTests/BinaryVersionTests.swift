import Foundation
import Testing
@testable import OhmaiLidHelperCore

@Suite("BinaryVersion")
struct BinaryVersionTests {
    @Test func staleOnlyForADifferentReadableBuild() {
        #expect(BinaryVersion.isStale(running: "5", onDisk: "6"))
        #expect(!BinaryVersion.isStale(running: "6", onDisk: "6"))
        #expect(!BinaryVersion.isStale(running: "6", onDisk: nil))
        #expect(!BinaryVersion.isStale(running: "6", onDisk: ""))
    }

    @Test func readsTheEmbeddedPlistOfARealExecutable() {
        // Any system tool without an embedded plist reads as nil, never as stale.
        #expect(BinaryVersion.onDisk(URL(fileURLWithPath: "/usr/bin/true")) == nil)
    }
}
