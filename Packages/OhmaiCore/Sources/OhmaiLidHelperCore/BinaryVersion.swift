import Foundation

/// The build number embedded in an executable's `__info_plist` section, read fresh from disk.
/// Lets the helper notice the app was updated while it kept running the old code.
public enum BinaryVersion {
    public static func onDisk(_ executable: URL) -> String? {
        guard let info = CFBundleCopyInfoDictionaryForURL(executable as CFURL) as? [String: Any] else { return nil }
        return info["CFBundleVersion"] as? String
    }

    /// Restart only for a readable, different build. An unreadable file (mid-copy, deleted)
    /// never triggers a restart.
    public static func isStale(running: String, onDisk: String?) -> Bool {
        guard let onDisk, !onDisk.isEmpty else { return false }
        return onDisk != running
    }
}
