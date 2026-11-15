import AppKit
import Foundation
import OhmaiCore
import OhmaiLedger
import OhmaiPiAdapter
import os

private let log = Logger(subsystem: "com.westvold.ohmai", category: "uninstall")

/// Removes everything ohmai installed, so deleting the app leaves nothing behind:
/// the root lid helper's launchd registration, the login item, the pi extension (only if
/// it's ours), and optionally the usage history and preferences. Then trashes the app.
@MainActor
enum Uninstaller {
    struct Result {
        var steps: [String] = []
        var problems: [String] = []
    }

    static func run(model: AppModel, deleteHistory: Bool) async {
        var result = Result()

        // 1. Sleep back on and the root helper gone. Release first, then unregister:
        //    launchd's SIGTERM makes the helper reset `disablesleep` too.
        model.prefsStore.prefs.lidClosedModeEnabled = false
        model.lidSession.apply(.allowSleep(.keepAwakeOff), batteryFloorPercent: 100)
        await model.lidSession.settle()
        if model.lidRegistration.status != .notRegistered {
            await model.lidRegistration.unregister()
            if model.lidRegistration.status == .notRegistered || model.lidRegistration.status == .notFound {
                result.steps.append("Removed the lid helper")
            } else {
                result.problems.append("The lid helper is still registered (\(model.lidRegistration.status.summary)).")
            }
        }

        // 2. Login item.
        if model.launchAtLogin.enabled || model.launchAtLogin.needsApproval {
            model.launchAtLogin.set(false)
            result.steps.append("Removed the login item")
        }

        // 3. pi extension, only if it's ours (the installer refuses otherwise).
        let pi = PiExtensionInstaller()
        if pi.status() == .installed || pi.status() == .outdated {
            do {
                try pi.uninstall()
                result.steps.append("Removed the pi extension")
            } catch {
                result.problems.append("Left ~/.pi/agent/extensions/ohmai.ts in place: it isn't ohmai's.")
            }
        }

        // 4. History and preferences, if asked.
        if deleteHistory {
            let support = UsageImporter.defaultDatabase.deletingLastPathComponent()
            do {
                if FileManager.default.fileExists(atPath: support.path) {
                    try FileManager.default.removeItem(at: support)
                }
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                }
                result.steps.append("Deleted usage history and preferences")
            } catch {
                result.problems.append("Couldn't delete \(support.path): \(error.localizedDescription)")
            }
        }

        log.notice("uninstall: \(result.steps.joined(separator: "; "), privacy: .public)")

        // 5. The app itself: trash it only from an Applications folder; otherwise show it.
        let app = Bundle.main.bundleURL
        let inApplications = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"]
            .contains { app.path.hasPrefix($0) }

        let alert = NSAlert()
        alert.messageText = result.problems.isEmpty ? "ohmai is uninstalled" : "ohmai is mostly uninstalled"
        var info = (result.steps.isEmpty ? ["Nothing else was installed."] : result.steps).map { "• \($0)" }
        info += result.problems.map { "⚠︎ \($0)" }
        info.append(inApplications ? "\nohmai will move itself to the Trash and quit."
                                   : "\nohmai isn't in Applications, so it'll show itself in Finder for you to delete.")
        alert.informativeText = info.joined(separator: "\n")
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()

        if inApplications {
            // The completion runs off the main thread: keep it out of main-actor isolation.
            NSWorkspace.shared.recycle([app]) { @Sendable _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([app])
            NSApp.terminate(nil)
        }
    }
}
