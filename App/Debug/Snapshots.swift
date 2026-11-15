#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: with `OHMAI_SNAPSHOT_DIR` set, render the dropdown and each Settings
/// tab to PNG (light and dark) and quit. Lets the UI be reviewed without a screen.
@MainActor
enum Snapshots {
    /// `OHMAI_MEMPROBE=1`: open Settings, close it, and log the footprint at each step.
    static func memoryProbeIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["OHMAI_MEMPROBE"] != nil else { return }
        Task { @MainActor in
            func mb() -> String { Footprint.current().memoryBytes.map { "\($0 / 1_048_576) MB" } ?? "?" }
            try? await Task.sleep(for: .seconds(8))
            print("MEMPROBE idle: \(mb())")
            for cycle in 1...5 {
                for section in SettingsSection.allCases {
                    SettingsWindow.shared.show(model: model, page: section)
                    try? await Task.sleep(for: .seconds(1))
                }
                NSApp.windows.first { $0.title == "ohmai Settings" }?.performClose(nil)
                try? await Task.sleep(for: .seconds(2))
                malloc_zone_pressure_relief(nil, 0)
                print("MEMPROBE after open/close cycle \(cycle): \(mb())")
            }
            exit(0)
        }
    }

    static func runIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["OHMAI_SNAPSHOT_DIR"] else { return }
        // Let adapters deliver their first scan and the usage import finish before rendering.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<300 where model.usage.importing { try? await Task.sleep(for: .seconds(1)) }
            await model.usage.refresh()
            let out = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let pages: [(String, AnyView)] = [
                ("menu", AnyView(MenuContent(model: model).background(.regularMaterial))),
                ("settings-window", AnyView(SettingsRoot(model: model, initial: .general).frame(width: 720, height: 520))),
                ("settings-general", AnyView(GeneralTab(model: model).frame(width: 500))),
                ("settings-advanced", AnyView(AdvancedTab(model: model).frame(width: 500))),
                ("settings-agents", AnyView(AgentsTab(model: model).frame(width: 500))),
            ]
            for (name, view) in pages {
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    render(view, appearance: appearance, to: out.appending(path: "\(name)-\(suffix).png"))
                }
            }
            exit(0)
        }
    }

    private static func render(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
