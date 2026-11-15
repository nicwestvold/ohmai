#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: with `OHMAI_SNAPSHOT_DIR` set, render the dropdown and each Settings
/// tab to PNG (light and dark) and quit. Lets the UI be reviewed without a screen.
@MainActor
enum Snapshots {
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
                ("settings-general", AnyView(GeneralTab(model: model).frame(width: 500))),
                ("settings-power", AnyView(PowerTab(model: model).frame(width: 500))),
                ("settings-lid", AnyView(LidClosedTab(model: model).frame(width: 500))),
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
