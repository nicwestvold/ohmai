import SwiftUI

@main
struct OhmaiApp: App {
    @State private var model = AppModel(updater: makeUpdater())

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarIcon(state: model.iconState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
