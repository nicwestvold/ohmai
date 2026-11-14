import Foundation

/// The app's only view of updates. Only `SparkleUpdater` (not yet written) may import Sparkle.
/// See docs/updates.md.
@MainActor
protocol Updater: AnyObject {
    /// Drives whether "Check for Updates…" is shown.
    var canCheckForUpdates: Bool { get }
    /// Bound to the Settings toggle.
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

/// Ships until Sparkle is wired: the menu item is hidden and the toggle is disabled.
final class NoopUpdater: Updater {
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}

/// Composition root for updates, switched by the `OHMAI_UPDATES_ENABLED` build setting.
@MainActor
func makeUpdater() -> any Updater {
    #if OHMAI_UPDATES_ENABLED
    #error("OHMAI_UPDATES_ENABLED is set, but SparkleUpdater isn't wired yet. See docs/updates.md.")
    #else
    NoopUpdater()
    #endif
}
