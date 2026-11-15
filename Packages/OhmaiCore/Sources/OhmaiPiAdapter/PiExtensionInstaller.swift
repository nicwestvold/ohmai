import Foundation

/// Installs ohmai's pi extension into `~/.pi/agent/extensions/ohmai.ts`, only when asked.
public struct PiExtensionInstaller: Sendable {
    public enum Status: Equatable, Sendable {
        /// `~/.pi/agent` doesn't exist.
        case piNotFound
        case notInstalled
        case installed
        /// An older (or edited) ohmai extension is there.
        case outdated
    }

    public enum Failure: Error, Equatable {
        case piNotFound
        case notOurs
        case bundledExtensionMissing
    }

    /// Identifies a file as ours, so uninstall never removes someone else's extension.
    static let marker = "ohmai-extension-version:"

    private let agentDirectory: URL
    private let bundled: Data?

    public init(agentDirectory: URL? = nil, bundled: Data? = PiExtensionInstaller.bundledExtension) {
        self.agentDirectory = agentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent", directoryHint: .isDirectory)
        self.bundled = bundled
    }

    public static var bundledExtension: Data? {
        Bundle.module.url(forResource: "ohmai", withExtension: "ts").flatMap { try? Data(contentsOf: $0) }
    }

    var target: URL { agentDirectory.appending(path: "extensions/ohmai.ts") }

    public func status() -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agentDirectory.path) else { return .piNotFound }
        guard let installed = fm.contents(atPath: target.path) else { return .notInstalled }
        return installed == bundled ? .installed : .outdated
    }

    /// Writes (or replaces) the extension. pi picks it up on its next start or `/reload`.
    public func install() throws {
        guard let bundled else { throw Failure.bundledExtensionMissing }
        let fm = FileManager.default
        guard fm.fileExists(atPath: agentDirectory.path) else { throw Failure.piNotFound }
        if let existing = fm.contents(atPath: target.path), !Self.isOurs(existing) { throw Failure.notOurs }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bundled.write(to: target, options: .atomic)
    }

    /// Removes the extension, but only if it's ours.
    public func uninstall() throws {
        guard let existing = FileManager.default.contents(atPath: target.path) else { return }
        guard Self.isOurs(existing) else { throw Failure.notOurs }
        try FileManager.default.removeItem(at: target)
    }

    static func isOurs(_ data: Data) -> Bool {
        String(decoding: data.prefix(1024), as: UTF8.self).contains(marker)
    }
}
