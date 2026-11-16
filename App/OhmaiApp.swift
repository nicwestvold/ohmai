import SwiftUI

@main
struct OhmaiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarIcon(state: model.iconState)
        }
        .menuBarExtraStyle(.window)
        // Settings is an ordinary window (SettingsWindow) so it's freed when closed.
    }
}
