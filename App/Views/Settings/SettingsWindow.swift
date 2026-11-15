import AppKit
import SwiftUI

/// Settings in an ordinary window that's torn down when it closes. SwiftUI's built-in
/// `Settings` scene keeps its window and view graph alive for the life of the app (measured:
/// ohmai went from ~34 MB to 55-65 MB after browsing Settings and never came back down).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: AppModel, page: SettingsSection = .general) {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsRoot(model: model, initial: page))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "ohmai Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 720, height: 520))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ohmai.settings")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the hosting controller and window so SwiftUI's view graph is freed.
        window?.contentViewController = nil
        window = nil
    }
}

/// A sidebar like System Settings: colored icon tiles, one page per concern.
struct SettingsRoot: View {
    let model: AppModel
    @State private var selection: SettingsSection

    init(model: AppModel, initial: SettingsSection) {
        self.model = model
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { page in
                Label {
                    Text(page.title)
                } icon: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralTab(model: model)
                case .agents: AgentsTab(model: model)
                case .advanced: AdvancedTab(model: model)
                }
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, agents, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "terminal.fill"
        case .advanced: "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .agents: .blue
        case .advanced: .indigo
        }
    }
}
