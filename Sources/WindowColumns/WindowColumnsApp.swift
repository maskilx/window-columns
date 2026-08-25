import SwiftUI

@main
struct WindowColumnsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // The window itself is created by `SettingsWindow`; this scene exists
        // only because an App needs one, and an accessory app never shows it.
        Settings {
            EmptyView()
        }
    }
}
